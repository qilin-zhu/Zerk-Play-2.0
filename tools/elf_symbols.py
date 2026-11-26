"""Minimal ELF dynamic-symbol surgery, shared by the APK patcher and its check.

Only what is needed to answer two questions about an Android .so:
  * which symbols does it import and with what binding;
  * can the name of one import be redirected to another name that already
    exists in the same string table.
"""
import struct


class Elf:
    def __init__(self, data):
        if data[:4] != b'\x7fELF':
            raise ValueError('not an ELF file')
        self.data = data
        self.is64 = data[4] == 2
        self.end = '<' if data[5] == 1 else '>'
        self.sections = self._sections()
        self.dynsym = next((s for s in self.sections if s['typ'] == 11), None)
        if self.dynsym is None:
            raise ValueError('no SHT_DYNSYM (not a shared object?)')
        self.strtab = self.sections[self.dynsym['link']]
        self._str_base = self.strtab['offset']
        self._str_end = self.strtab['offset'] + self.strtab['size']

    def _sections(self):
        data, end = self.data, self.end
        if self.is64:
            e_shoff, = struct.unpack(end + 'Q', data[0x28:0x30])
            e_shentsize, e_shnum, _ = struct.unpack(end + 'HHH', data[0x3A:0x40])
        else:
            e_shoff, = struct.unpack(end + 'I', data[0x20:0x24])
            e_shentsize, e_shnum, _ = struct.unpack(end + 'HHH', data[0x2E:0x34])
        out = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            if self.is64:
                name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack(
                    end + 'IIQQQQIIQQ', data[off:off + 64])
            else:
                name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack(
                    end + 'IIIIIIIIII', data[off:off + 40])
            out.append(dict(typ=typ, offset=offset, size=size, link=link, entsize=entsize))
        return out

    def _sym_off(self, index):
        return self.dynsym['offset'] + index * self.dynsym['entsize']

    def _sym_count(self):
        return self.dynsym['size'] // self.dynsym['entsize']

    def read_str(self, offset):
        pos = self._str_base + offset
        end = self.data.find(b'\x00', pos)
        return self.data[pos:end].decode('utf-8', 'replace')

    def string_offset(self, name):
        """Offset of an existing string in .dynstr, or None."""
        pos = self._str_base
        needle = name.encode() + b'\x00'
        while pos < self._str_end:
            if self.data.startswith(needle, pos):
                return pos - self._str_base
            nxt = self.data.find(b'\x00', pos)
            if nxt < 0:
                break
            pos = nxt + 1
        return None

    def symbols(self):
        """[(index, name, bind)] for every entry; bind 2 is STB_WEAK."""
        out = []
        for i in range(self._sym_count()):
            off = self._sym_off(i)
            if self.is64:
                nm, info, other, shndx, value, sz = struct.unpack(self.end + 'IBBHQQ', self.data[off:off + 24])
            else:
                nm, value, sz, info, other, shndx = struct.unpack(self.end + 'IIIBBH', self.data[off:off + 16])
            out.append((i, self.read_str(nm), info >> 4, shndx))
        return out

    def imports(self):
        """[(name, bind)] for undefined symbols."""
        return [(n, b) for _i, n, b, shndx in self.symbols() if shndx == 0]

    def rename_import(self, old, new):
        """Point the undefined symbol `old` at the existing string `new`.

        The dynamic linker resolves an undefined symbol by name from .dynstr,
        so rewriting st_name is enough; nothing else in the file moves. Returns
        the number of entries changed.
        """
        target = self.string_offset(new)
        if target is None:
            raise ValueError('target symbol %r is not in .dynstr of this file' % new)
        changed = 0
        for i, name, bind, shndx in self.symbols():
            if shndx == 0 and name == old:
                struct.pack_into(self.end + 'I', self.data, self._sym_off(i), target)
                changed += 1
        return changed
