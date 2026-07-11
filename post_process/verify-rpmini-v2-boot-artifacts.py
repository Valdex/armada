#!/usr/bin/env python3
"""Fail-closed checks for the raw arm64 Image and RP Mini V2 FDT."""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys


FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9
ARM64_IMAGE_MAGIC = 0x644D5241


def fail(message: str) -> None:
    raise ValueError(message)


def validate_kernel(path: pathlib.Path) -> None:
    data = path.read_bytes()
    if len(data) < 64:
        fail(f"kernel is too small: {len(data)} bytes")
    magic = struct.unpack_from("<I", data, 0x38)[0]
    if magic != ARM64_IMAGE_MAGIC:
        fail(
            f"{path} is not a raw arm64 Linux Image "
            f"(magic at 0x38 is 0x{magic:08x})"
        )


def c_string(data: bytes, offset: int, end: int) -> tuple[str, int]:
    nul = data.find(b"\0", offset, end)
    if nul < 0:
        fail("unterminated FDT string")
    try:
        value = data[offset:nul].decode("ascii")
    except UnicodeDecodeError as exc:
        fail(f"non-ASCII FDT string: {exc}")
    return value, nul + 1


def align4(value: int) -> int:
    return (value + 3) & ~3


def string_list(value: bytes) -> list[str]:
    return [
        item.decode("ascii", errors="strict")
        for item in value.split(b"\0")
        if item
    ]


def u32(value: bytes, property_name: str) -> int:
    if len(value) != 4:
        fail(f"{property_name} is not one FDT cell")
    return struct.unpack(">I", value)[0]


def node_enabled(properties: dict[str, bytes]) -> bool:
    status = properties.get("status", b"").rstrip(b"\0").decode(
        "ascii", errors="strict"
    )
    return status in ("", "ok", "okay")


def validate_dtb(path: pathlib.Path) -> None:
    data = path.read_bytes()
    if len(data) < 40:
        fail(f"DTB is too small: {len(data)} bytes")

    header = struct.unpack_from(">10I", data, 0)
    (
        magic,
        total_size,
        struct_offset,
        strings_offset,
        _reserve_offset,
        version,
        _last_compatible_version,
        _boot_cpu,
        strings_size,
        struct_size,
    ) = header
    if magic != FDT_MAGIC:
        fail(f"bad FDT magic: 0x{magic:08x}")
    if version < 17:
        fail(f"unsupported old FDT version: {version}")
    if total_size > len(data) or total_size < 40:
        fail(f"invalid FDT total size: {total_size} (file is {len(data)})")
    if struct_offset + struct_size > total_size:
        fail("FDT structure block is out of bounds")
    if strings_offset + strings_size > total_size:
        fail("FDT strings block is out of bounds")

    pos = struct_offset
    struct_end = struct_offset + struct_size
    strings_end = strings_offset + strings_size
    node_stack: list[str] = []
    node_properties: dict[str, dict[str, bytes]] = {}
    saw_end = False

    while pos + 4 <= struct_end:
        token = struct.unpack_from(">I", data, pos)[0]
        pos += 4
        if token == FDT_BEGIN_NODE:
            name, pos = c_string(data, pos, struct_end)
            pos = align4(pos)
            node_stack.append(name)
            node_path = "/" + "/".join(part for part in node_stack if part)
            node_properties.setdefault(node_path, {})
        elif token == FDT_END_NODE:
            if not node_stack:
                fail("unbalanced FDT nodes")
            node_stack.pop()
        elif token == FDT_PROP:
            if pos + 8 > struct_end:
                fail("truncated FDT property header")
            length, name_offset = struct.unpack_from(">II", data, pos)
            pos += 8
            if pos + length > struct_end:
                fail("truncated FDT property value")
            if name_offset >= strings_size:
                fail("FDT property name is out of bounds")
            name, _ = c_string(
                data, strings_offset + name_offset, strings_end
            )
            value = data[pos : pos + length]
            pos = align4(pos + length)
            if not node_stack:
                fail("FDT property outside a node")
            node_path = "/" + "/".join(part for part in node_stack if part)
            node_properties[node_path][name] = value
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            saw_end = True
            break
        else:
            fail(f"unknown FDT structure token: {token}")

    if not saw_end or node_stack:
        fail("incomplete or unbalanced FDT structure")

    root_properties = node_properties.get("/", {})
    model = root_properties.get("model", b"").rstrip(b"\0").decode(
        "ascii", errors="strict"
    )
    compatibles = string_list(root_properties.get("compatible", b""))
    if model != "Retroid Pocket Mini V2":
        fail(f"wrong DTB model: {model!r}")
    required = {"retroidpocket,rpminiv2", "qcom,sm8250"}
    missing = sorted(required.difference(compatibles))
    if missing:
        fail(f"DTB compatible is missing: {', '.join(missing)}")

    panels = [
        (node_path, properties)
        for node_path, properties in node_properties.items()
        if "ch13726a,rpminiv2"
        in string_list(properties.get("compatible", b""))
    ]
    if len(panels) != 1:
        fail(f"expected one RP Mini V2 panel, found {len(panels)}")
    panel_path, panel = panels[0]
    if not panel_path.endswith("/dsi@ae94000/panel@0"):
        fail(f"RP Mini V2 panel is on an unexpected DSI path: {panel_path}")
    if not node_enabled(panel):
        fail(f"RP Mini V2 panel is disabled: {panel_path}")
    if u32(panel.get("rotation", b""), f"{panel_path}:rotation") != 90:
        fail(f"{panel_path} does not have the required 90-degree rotation")

    for node_path, properties in node_properties.items():
        panel_compatibles = string_list(properties.get("compatible", b""))
        if node_enabled(properties) and any(
            compatible.startswith("ch13726a,")
            and compatible != "ch13726a,rpminiv2"
            for compatible in panel_compatibles
        ):
            fail(f"enabled non-V2 CH13726A panel found: {node_path}")

    touchscreens = [
        (node_path, properties)
        for node_path, properties in node_properties.items()
        if "focaltech,ft5452"
        in string_list(properties.get("compatible", b""))
    ]
    if len(touchscreens) != 1:
        fail(f"expected one FT5452 touchscreen, found {len(touchscreens)}")
    touchscreen_path, touchscreen = touchscreens[0]
    if not touchscreen_path.endswith("/i2c@a94000/touchscreen@38"):
        fail(f"RP Mini V2 touchscreen is on an unexpected path: {touchscreen_path}")
    if not node_enabled(touchscreen):
        fail(f"RP Mini V2 touchscreen is disabled: {touchscreen_path}")
    size_x = u32(
        touchscreen.get("touchscreen-size-x", b""),
        f"{touchscreen_path}:touchscreen-size-x",
    )
    size_y = u32(
        touchscreen.get("touchscreen-size-y", b""),
        f"{touchscreen_path}:touchscreen-size-y",
    )
    if (size_x, size_y) != (1080, 1240):
        fail(
            f"wrong V2 touchscreen size: {size_x}x{size_y}, expected 1080x1240"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel", required=True, type=pathlib.Path)
    parser.add_argument("--dtb", required=True, type=pathlib.Path)
    args = parser.parse_args()
    try:
        validate_kernel(args.kernel)
        validate_dtb(args.dtb)
    except (OSError, UnicodeError, ValueError, struct.error) as exc:
        print(f"rpmini-v2 boot artifact verification failed: {exc}", file=sys.stderr)
        return 1
    print("Verified raw arm64 Image and Retroid Pocket Mini V2 SM8250 DTB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
