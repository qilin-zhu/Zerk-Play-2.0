"""Make a Flutter APK claim, and actually work at, minSdkVersion 23 (Android 6.0).

Two separate problems, both handled here:

1. The manifest. Flutter 3.35 raised the engine's minSdkVersion to 24 and the
   manifest merger takes the maximum across all libraries, so `tools:overrideLibrary`
   does not help - the packaged APK still says 24 and Android 6.0 refuses to
   install it. The attribute is a 4-byte integer, so it is overwritten in place
   and no offsets move.

2. The engine itself. libflutter.so imports `pthread_setname_np`, which bionic
   only gained in API 24. Bionic binds eagerly (there is no lazy PLT), so
   System.loadLibrary("flutter") fails with
       dlopen failed: cannot locate symbol "pthread_setname_np"
   and the process dies before the first frame - the app installs and then
   closes instantly. The import is redirected to `pthread_self`, which exists
   on every Android release and ignores the two arguments the engine passes, so
   the call becomes a harmless no-op. The only thing lost is thread names on
   API 23 (they show up in logs and the profiler).

The APK must be re-aligned and re-signed afterwards: both edits invalidate the
signature, and the re-sign has to declare --min-sdk-version 23 so a v1 (JAR)
signature is added - API 23 cannot verify v2-only signatures.

Usage:
    python3 tools/patch_apk_minsdk.py in.apk out.apk 23
"""
import struct
import sys
import zipfile

from elf_symbols import Elf

RES_XML_TYPE = 0x0003
RES_STRING_POOL_TYPE = 0x0001
RES_XML_START_ELEMENT_TYPE = 0x0102
TYPE_INT_DEC = 0x10
MANIFEST = 'AndroidManifest.xml'

# libc symbols newer than API 23 that a shipped .so must not import, mapped to
# the always-available symbol that replaces them.
LATE_LIBC = {
    'pthread_setname_np': 'pthread_self',
    'pthread_getname_np': 'pthread_self',
}


class StringPool:
    """Just enough of the AXML string pool to resolve element/attribute names."""

    def __init__(self, data, offset):
        self.header_size = struct.unpack_from('<H', data, offset + 2)[0]
        self.string_count, self.style_count, self.flags, self.strings_start, _ = struct.unpack_from(
            '<IIIII', data, offset + 8)
        self.offset = offset
        self.utf8 = bool(self.flags & 0x100)

    def get(self, data, index):
        if index == 0xFFFFFFFF:
            return None
        offsets_at = self.offset + self.header_size
        # String data starts at chunk start + stringsStart; the per-string
        # offsets are relative to that base, not to the chunk.
        base = self.offset + self.strings_start
        pos = base + struct.unpack_from('<I', data, offsets_at + index * 4)[0]
        if self.utf8:
            # UTF-8 pools store a character count and a byte count, each as a
            # 1- or 2-byte varint; only the byte count matters here.
            _chars, pos = _varint(data, pos)
            nbytes, pos = _varint(data, pos)
            return data[pos:pos + nbytes].decode('utf-8', 'replace')
        n = struct.unpack_from('<H', data, pos)[0]
        pos += 2
        if n & 0x8000:
            n = ((n & 0x7FFF) << 16) | struct.unpack_from('<H', data, pos)[0]
            pos += 2
        return data[pos:pos + n * 2].decode('utf-16-le', 'replace')


def _varint(data, pos):
    n = data[pos]
    if n & 0x80:
        return ((n & 0x7F) << 8) | data[pos + 1], pos + 2
    return n, pos + 1


def patch_manifest(data, new_min_sdk):
    """Overwrite the minSdkVersion int in place; returns [(old, new)]."""
    if struct.unpack_from('<H', data, 0)[0] != RES_XML_TYPE:
        raise SystemExit('AndroidManifest.xml is not binary AXML (already text?)')

    pool = None
    patched = []
    pos = struct.unpack_from('<H', data, 2)[0]  # file header size
    total = len(data)
    while pos + 8 <= total:
        ctype, chead, csize = struct.unpack_from('<HHI', data, pos)
        if csize == 0:
            break
        if ctype == RES_STRING_POOL_TYPE:
            pool = StringPool(data, pos)
        elif ctype == RES_XML_START_ELEMENT_TYPE and pool is not None:
            _ns, name_idx, attr_start, attr_size, attr_count, _, _, _ = struct.unpack_from(
                '<IIHHHHHH', data, pos + chead)
            if pool.get(data, name_idx) == 'uses-sdk':
                base = pos + chead + attr_start
                for i in range(attr_count):
                    a = base + i * attr_size
                    _a_ns, a_name, _raw = struct.unpack_from('<III', data, a)
                    _v_size, _res0, v_type, v_data = struct.unpack_from('<HBBI', data, a + 12)
                    if pool.get(data, a_name) == 'minSdkVersion' and v_type == TYPE_INT_DEC:
                        data[a + 16:a + 20] = struct.pack('<I', new_min_sdk)
                        patched.append((v_data, new_min_sdk))
        pos += csize
    if not patched:
        raise SystemExit('no <uses-sdk android:minSdkVersion> attribute found')
    return patched


def patch_native(raw):
    """Redirect late libc imports; returns a list of human-readable changes."""
    try:
        elf = Elf(bytearray(raw))
    except ValueError:
        # No dynamic symbol table means nothing can be imported; leave it be.
        return raw, []
    changes = []
    for name, replacement in LATE_LIBC.items():
        if not any(n == name for n, _b in elf.imports()):
            continue
        count = elf.rename_import(name, replacement)
        changes.append('%s -> %s (%d)' % (name, replacement, count))
    return bytes(elf.data), changes


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    src, dst, new_min_sdk = sys.argv[1], sys.argv[2], int(sys.argv[3])

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w') as zout:
        manifest = bytearray(zin.read(MANIFEST))
        changes = patch_manifest(manifest, new_min_sdk)
        print('patched minSdkVersion %d -> %d' % (changes[0][0], new_min_sdk))
        for item in zin.infolist():
            raw = bytes(manifest) if item.filename == MANIFEST else zin.read(item.filename)
            if item.filename.endswith('.so'):
                raw, done = patch_native(raw)
                for line in done:
                    print('  %s: %s' % (item.filename, line))
            info = zipfile.ZipInfo(item.filename, date_time=item.date_time)
            info.compress_type = item.compress_type
            info.external_attr = item.external_attr
            info.create_system = item.create_system
            zout.writestr(info, raw)
    print('wrote %s' % dst)


if __name__ == '__main__':
    main()
