#!/usr/bin/env python3
"""List or extract the entries of an NVIDIA__BLOB__V2 update blob.

This is the `blob` file in a SHIELD recovery image, which NVIDIA's
flash-all.sh writes to the `staging` partition. It carries the bootloader
stack (EBT/cboot, TOS, BCT, ...) and one DTB per supported board revision.
Reading it changes nothing; nothing here talks to a device.
"""
import argparse
import os
import struct
import sys

MAGIC = b"NVIDIA__BLOB__V2"
HEADER = struct.Struct("<16sIIIII")  # magic, version, size, header size, entry count, type
ENTRY = struct.Struct("<40sIII")     # partition name, offset, size, version


def read_entries(data):
    magic, version, size, header_size, count, blob_type = HEADER.unpack_from(data, 0)
    if magic != MAGIC:
        sys.exit("not an NVIDIA__BLOB__V2 file")
    if size != len(data):
        print(f"warning: header says {size} bytes, file has {len(data)}", file=sys.stderr)
    entries = []
    for i in range(count):
        name, offset, length, ver = ENTRY.unpack_from(data, header_size + i * ENTRY.size)
        if offset + length > len(data):
            sys.exit(f"entry {i} runs past the end of the file")
        entries.append((name.rstrip(b"\0").decode("ascii"), offset, length, ver))
    return version, blob_type, entries


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("blob", help="path to the blob file")
    ap.add_argument("-x", "--extract", metavar="DIR", help="write every entry into DIR")
    args = ap.parse_args()

    with open(args.blob, "rb") as f:
        data = f.read()
    version, blob_type, entries = read_entries(data)
    print(f"# NVIDIA__BLOB__V2 version 0x{version:08x}, type {blob_type}, {len(entries)} entries")

    for idx, (name, offset, length, ver) in enumerate(entries):
        out_name = f"{idx:02d}-{name}.bin"
        print(f"{idx:2d}  {name:<8} offset=0x{offset:08x} size={length:>8}  version={ver}  {out_name}")
        if args.extract:
            os.makedirs(args.extract, exist_ok=True)
            with open(os.path.join(args.extract, out_name), "wb") as out:
                out.write(data[offset:offset + length])


if __name__ == "__main__":
    main()
