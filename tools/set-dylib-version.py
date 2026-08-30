#!/usr/bin/env python3
"""Set compatibility_version and current_version in a Mach-O LC_ID_DYLIB.

CMake does not pass -compatibility_version through to framework targets, and
WebKitLegacy links against the SDK's WebCore stub, which declares 1.0.0. dyld
refuses to load a library declaring less than what the client recorded.
"""
import struct
import sys

LC_ID_DYLIB = 0xd
MH_MAGIC = 0xfeedface


def encode(version):
    parts = (list(map(int, version.split("."))) + [0, 0])[:3]
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def patch(path, version):
    with open(path, "r+b") as handle:
        data = handle.read(8192)
        magic, = struct.unpack("<I", data[:4])
        if magic != MH_MAGIC:
            raise SystemExit(f"{path}: not a 32-bit little-endian Mach-O")
        ncmds, = struct.unpack("<I", data[16:20])
        offset = 28  # mach_header is 28 bytes on 32-bit
        encoded = encode(version)
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
            if cmd == LC_ID_DYLIB:
                handle.seek(offset + 16)  # past cmd, cmdsize, name offset, timestamp
                handle.write(struct.pack("<II", encoded, encoded))
                return True
            offset += cmdsize
    return False


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: set-dylib-version.py <mach-o> <version>")
    print(f"{sys.argv[1]}: {'patched' if patch(sys.argv[1], sys.argv[2]) else 'no LC_ID_DYLIB'}")
