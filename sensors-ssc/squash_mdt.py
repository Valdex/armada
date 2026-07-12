#!/usr/bin/env python3
"""Merge Qualcomm split firmware (.mdt + .bNN) into a monolithic .mbn.

Python port of linux-msm/pil-squasher (BSD-3-Clause, Linaro 2019) so it runs
anywhere (macOS lacks elf.h, the device lacks a compiler). Byte-compatible
except that short .bNN reads are zero-padded instead of leaking heap garbage.

Usage: squash_mdt.py <mbn output> <mdt header>
"""
import struct
import sys


def main(out_path, mdt_path):
    if ".mdt" not in mdt_path:
        sys.exit(f"{mdt_path} is not a mdt file")
    mdt = open(mdt_path, "rb").read()
    if mdt[:4] != b"\x7fELF":
        sys.exit(f"not an ELF file {mdt_path}")

    ei_class = mdt[4]
    if ei_class == 1:  # ELFCLASS32
        ehdr_size, phent = 52, 32
        phoff, phnum = struct.unpack_from("<I", mdt, 28)[0], struct.unpack_from("<H", mdt, 44)[0]
        # Elf32_Phdr: p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align
        unpack_phdr = lambda off: struct.unpack_from("<8I", mdt, off)
        fields = lambda p: (p[1], p[4], p[6])  # p_offset, p_filesz, p_flags
    elif ei_class == 2:  # ELFCLASS64
        ehdr_size, phent = 64, 56
        phoff, phnum = struct.unpack_from("<Q", mdt, 32)[0], struct.unpack_from("<H", mdt, 56)[0]
        # Elf64_Phdr: p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align
        unpack_phdr = lambda off: struct.unpack_from("<2I6Q", mdt, off)
        fields = lambda p: (p[2], p[5], p[1])
    else:
        sys.exit(f"Unsupported ELF class {ei_class}")

    out = bytearray()

    def pwrite(data, offset):
        if len(out) < offset + len(data):
            out.extend(b"\x00" * (offset + len(data) - len(out)))
        out[offset:offset + len(data)] = data

    pwrite(mdt[:ehdr_size], 0)
    # hash data in the mdt sits right after segment 0's file image
    hashoffset = fields(unpack_phdr(phoff))[1]

    for i in range(phnum):
        off = phoff + i * phent
        pwrite(mdt[off:off + phent], off)
        p_offset, p_filesz, p_flags = fields(unpack_phdr(off))
        if not p_filesz:
            continue
        segment = b""
        if (p_flags >> 24) & 7 == 2:  # QCOM MDT hash segment: prefer mdt copy
            segment = mdt[hashoffset:hashoffset + p_filesz]
            if segment and len(segment) != p_filesz:
                sys.exit(f"failed to load segment {i}: {len(segment)}")
            hashoffset += p_filesz
        if not segment:
            try:
                segment = open(mdt_path.replace(".mdt", f".b{i:02d}"), "rb").read(p_filesz)
            except OSError as e:
                print(f"warning: {e}", file=sys.stderr)
                continue
            segment = segment.ljust(p_filesz, b"\x00")
        pwrite(segment, p_offset)

    open(out_path, "wb").write(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"{sys.argv[0]}: <mbn output> <mdt header>")
    main(sys.argv[1], sys.argv[2])
