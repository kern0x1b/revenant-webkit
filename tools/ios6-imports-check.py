import argparse
import os
import struct
import subprocess
import sys

LC_SYMTAB = 0x2
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022


def read_uleb(data, pos):
    value = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, pos


def cache_exports(path):
    data = open(path, "rb").read()
    if not data.startswith(b"dyld_v1"):
        sys.exit(f"{path} is not a dyld shared cache")
    mapping_offset, mapping_count, images_offset, images_count = struct.unpack_from("<IIII", data, 16)
    mappings = [struct.unpack_from("<QQQII", data, mapping_offset + i * 32) for i in range(mapping_count)]

    def file_offset(address):
        for start, size, offset, _, _ in mappings:
            if start <= address < start + size:
                return address - start + offset
        raise ValueError(f"address {address:#x} is outside every mapping")

    exports = set()
    for index in range(images_count):
        address = struct.unpack_from("<Q", data, images_offset + index * 32)[0]
        header = file_offset(address)
        magic, _, _, _, command_count = struct.unpack_from("<IiiII", data, header)
        if magic != 0xFEEDFACE:
            continue
        pos = header + 28
        trie = symtab = None
        for _ in range(command_count):
            command, size = struct.unpack_from("<II", data, pos)
            if command in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                trie = struct.unpack_from("<10I", data, pos + 8)[8:10]
            elif command == LC_SYMTAB:
                symtab = struct.unpack_from("<4I", data, pos + 8)
            pos += size
        if trie and trie[1]:
            stack = [(0, "")]
            while stack:
                node, prefix = stack.pop()
                cursor = trie[0] + node
                terminal, cursor = read_uleb(data, cursor)
                if terminal:
                    exports.add(prefix)
                cursor += terminal
                children = data[cursor]
                cursor += 1
                for _ in range(children):
                    end = data.index(b"\0", cursor)
                    label = data[cursor:end].decode("latin1")
                    child, cursor = read_uleb(data, end + 1)
                    stack.append((child, prefix + label))
        elif symtab:
            symbol_offset, symbol_count, string_offset, _ = symtab
            for k in range(symbol_count):
                string_index, symbol_type = struct.unpack_from("<IB", data, symbol_offset + k * 12)
                if symbol_type & 0x01 and symbol_type & 0x0E in (0x0A, 0x0E):
                    end = data.index(b"\0", string_offset + string_index)
                    exports.add(data[string_offset + string_index:end].decode("latin1"))
    return exports


def nm(arguments, binary):
    return subprocess.run(["nm", *arguments, binary], capture_output=True, text=True, check=True).stdout


def binaries(folder):
    for base, _, names in os.walk(folder):
        for name in names:
            path = os.path.join(base, name)
            if os.path.islink(path):
                continue
            with open(path, "rb") as handle:
                if handle.read(4) in (b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                    yield path


def main():
    parser = argparse.ArgumentParser(
        description="Refuse a build that imports a symbol the device's iOS does not export. "
                    "A missing lazy import loads fine and kills the process at its first call.")
    parser.add_argument("--cache", required=True, help="dyld_shared_cache_armv7 copied from the device")
    parser.add_argument("--dist", required=True, help="the laid-out frameworks, dist/rev-sys-fw")
    args = parser.parse_args()

    exports = cache_exports(args.cache)
    found = list(binaries(args.dist))
    own = set()
    for binary in found:
        own.update(line.split()[-1] for line in nm(["-gU"], binary).splitlines() if line.strip())

    missing = []
    for binary in found:
        for line in nm(["-m", "-u"], binary).splitlines():
            parts = line.split()
            if not parts:
                continue
            symbol = next((part for part in parts if part.startswith("_")), None)
            if symbol is None or "weak" in parts or symbol in own or symbol in exports:
                continue
            missing.append((os.path.relpath(binary, args.dist), symbol))

    if missing:
        print("these imports are not exported by the device's iOS:")
        for binary, symbol in sorted(missing):
            print(f"  {binary}  {symbol}")
        sys.exit(1)
    print(f"imports: every non-weak import of {len(found)} binaries resolves against {len(exports)} exports")


main()
