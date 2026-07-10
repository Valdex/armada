#!/usr/bin/env python3
import pathlib
import re
import sys


def find_block(lines, key, start, end):
    for index in range(start, end):
        if lines[index].strip() != f'"{key}"':
            continue
        if index + 1 >= end or lines[index + 1].strip() != "{":
            continue
        depth = 0
        for cursor in range(index + 1, end):
            depth += lines[cursor].count("{")
            depth -= lines[cursor].count("}")
            if depth == 0:
                return index, cursor
    return None


def require_block(lines, key, start, end):
    block = find_block(lines, key, start, end)
    if block is None:
        raise SystemExit(f"missing config block: {key}")
    return block


def set_default_compat(config_path, tool_name):
    if not config_path.exists():
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            '"InstallConfigStore"\n'
            "{\n"
            '\t"Software"\n'
            "\t{\n"
            '\t\t"Valve"\n'
            "\t\t{\n"
            '\t\t\t"Steam"\n'
            "\t\t\t{\n"
            "\t\t\t}\n"
            "\t\t}\n"
            "\t}\n"
            "}\n"
        )

    lines = config_path.read_text().splitlines(keepends=True)

    _, root_end = require_block(lines, "InstallConfigStore", 0, len(lines))
    software_start, software_end = require_block(lines, "Software", 0, root_end)
    valve_start, valve_end = require_block(lines, "Valve", software_start, software_end)
    steam_start, steam_end = require_block(lines, "Steam", valve_start, valve_end)

    entry = [
        '\t\t\t\t\t"0"\n',
        "\t\t\t\t\t{\n",
        f'\t\t\t\t\t\t"name"\t\t"{tool_name}"\n',
        '\t\t\t\t\t\t"config"\t\t""\n',
        '\t\t\t\t\t\t"priority"\t\t"75"\n',
        "\t\t\t\t\t}\n",
    ]

    mapping = find_block(lines, "CompatToolMapping", steam_start, steam_end)
    if mapping is None:
        lines[steam_end:steam_end] = [
            '\t\t\t\t"CompatToolMapping"\n',
            "\t\t\t\t{\n",
            *entry,
            "\t\t\t\t}\n",
        ]
    else:
        mapping_start, mapping_end = mapping
        zero = find_block(lines, "0", mapping_start, mapping_end)
        if zero is None:
            lines[mapping_start + 2:mapping_start + 2] = entry
        else:
            zero_start, zero_end = zero
            lines[zero_start:zero_end + 1] = entry

    config_path.write_text("".join(lines))


def set_display_name(compatibilitytool_path):
    text = compatibilitytool_path.read_text()
    text, count = re.subn(
        r'("display_name"\s+)"[^"]+"',
        r'\1"Proton 11.0 (CachyOS)"',
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("missing display_name entry")
    compatibilitytool_path.write_text(text)


def set_compat_tool_name(compatibilitytool_path, tool_name):
    text = compatibilitytool_path.read_text()

    text, count = re.subn(
        r'("compat_tools"\s*\{\s*)"[^"]+"',
        lambda match: f'{match.group(1)}"{tool_name}"',
        text,
        count=1,
    )
    if count != 1:
        raise SystemExit("missing compat_tools entry")
    compatibilitytool_path.write_text(text)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: set-steam-default-compat.py STEAM_HOME TOOL_NAME COMPAT_DIR")

    steam_home = pathlib.Path(sys.argv[1])
    tool_name = sys.argv[2]
    tool_dir = pathlib.Path(sys.argv[3]) / tool_name

    compatibilitytool_path = tool_dir / "compatibilitytool.vdf"
    set_compat_tool_name(compatibilitytool_path, tool_name)
    set_display_name(compatibilitytool_path)
    set_default_compat(steam_home / "config" / "config.vdf", tool_name)


if __name__ == "__main__":
    main()
