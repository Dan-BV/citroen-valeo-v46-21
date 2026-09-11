#!/usr/bin/env python3
"""Emulate the real ExpandKey/Encrypt from libSTD.so with Unicorn.

Removes any doubt about the hand-reimplemented 2-round AES: this runs the actual
ARM64 code. The .so is mapped at its own vaddr (identity), R_AARCH64_RELATIVE
relocations applied so the Sbox/Rcon pointers resolve, and the two exported
functions are called on scratch buffers.

    from emu_cipher import Cipher
    c = Cipher("libSTD.so")
    rk = c.expand_key(key16)          # -> 48 bytes
    ct = c.encrypt(pt16, rk)          # -> 16 bytes
"""
import struct
from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_LITTLE_ENDIAN, UC_HOOK_CODE
from unicorn.arm64_const import (UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2,
                                 UC_ARM64_REG_SP, UC_ARM64_REG_LR, UC_ARM64_REG_PC)

PAGE = 0x1000
STACK = 0x7000000
SCRATCH = 0x8000000
RETURN = 0xdead0000


def _align_down(x):
    return x & ~(PAGE - 1)


def _align_up(x):
    return (x + PAGE - 1) & ~(PAGE - 1)


class Cipher:
    def __init__(self, path):
        self.expand_addr = None
        self.encrypt_addr = None
        d = open(path, "rb").read()
        self.uc = uc = Uc(UC_ARCH_ARM64, UC_MODE_LITTLE_ENDIAN)

        # Map LOAD segments at their p_vaddr (identity load base 0).
        e_phoff = struct.unpack("<Q", d[0x20:0x28])[0]
        e_phentsize = struct.unpack("<H", d[0x36:0x38])[0]
        e_phnum = struct.unpack("<H", d[0x38:0x3a])[0]
        mapped = []
        for i in range(e_phnum):
            ph = d[e_phoff + i * e_phentsize: e_phoff + (i + 1) * e_phentsize]
            if struct.unpack("<I", ph[0:4])[0] != 1:      # PT_LOAD
                continue
            p_off = struct.unpack("<Q", ph[8:16])[0]
            p_va = struct.unpack("<Q", ph[16:24])[0]
            p_filesz = struct.unpack("<Q", ph[32:40])[0]
            p_memsz = struct.unpack("<Q", ph[40:48])[0]
            base = _align_down(p_va)
            size = _align_up(p_va + p_memsz) - base
            if base not in [m[0] for m in mapped]:
                uc.mem_map(base, size)
                mapped.append((base, size))
            uc.mem_write(p_va, d[p_off:p_off + p_filesz])

        # Apply R_AARCH64_RELATIVE (type 1027): *(r_offset) = r_addend.
        self._apply_relatives(d, uc)

        # Function addresses from dynsym.
        self._symbols(d)

        uc.mem_map(STACK, 0x100000)
        uc.mem_map(SCRATCH, 0x10000)

    def _sections(self, d):
        e_shoff = struct.unpack("<Q", d[0x28:0x30])[0]
        es = struct.unpack("<H", d[0x3a:0x3c])[0]
        n = struct.unpack("<H", d[0x3c:0x3e])[0]
        out = []
        for i in range(n):
            b = d[e_shoff + i * es: e_shoff + (i + 1) * es]
            out.append({
                "type": struct.unpack("<I", b[4:8])[0],
                "off": struct.unpack("<Q", b[24:32])[0],
                "size": struct.unpack("<Q", b[32:40])[0],
                "link": struct.unpack("<I", b[40:44])[0],
                "entsz": struct.unpack("<Q", b[56:64])[0],
            })
        return out

    def _apply_relatives(self, d, uc):
        for s in self._sections(d):
            if s["type"] != 4 or s["entsz"] == 0:         # SHT_RELA
                continue
            for j in range(s["size"] // s["entsz"]):
                r = d[s["off"] + j * s["entsz"]: s["off"] + (j + 1) * s["entsz"]]
                r_offset = struct.unpack("<Q", r[0:8])[0]
                r_info = struct.unpack("<Q", r[8:16])[0]
                r_addend = struct.unpack("<q", r[16:24])[0]
                if (r_info & 0xffffffff) == 1027:         # R_AARCH64_RELATIVE
                    uc.mem_write(r_offset, struct.pack("<Q", r_addend & 0xffffffffffffffff))

    def _symbols(self, d):
        for s in self._sections(d):
            if s["type"] not in (11, 2) or s["entsz"] == 0:
                continue
            stroff = self._sections(d)[s["link"]]["off"]
            for j in range(s["size"] // s["entsz"]):
                sym = d[s["off"] + j * s["entsz"]: s["off"] + (j + 1) * s["entsz"]]
                st_name = struct.unpack("<I", sym[0:4])[0]
                val = struct.unpack("<Q", sym[8:16])[0]
                end = d.index(b"\0", stroff + st_name)
                nm = d[stroff + st_name:end].decode(errors="replace")
                if nm == "ExpandKey" and self.expand_addr is None:
                    self.expand_addr = val
                elif nm == "Encrypt" and self.encrypt_addr is None:
                    self.encrypt_addr = val

    def _call(self, addr, args, out_addr, out_len):
        uc = self.uc
        uc.reg_write(UC_ARM64_REG_SP, STACK + 0x80000)
        uc.reg_write(UC_ARM64_REG_LR, RETURN)
        for i, v in enumerate(args):
            uc.reg_write([UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2][i], v)
        uc.emu_start(addr, RETURN, count=100000)
        return uc.mem_read(out_addr, out_len)

    def expand_key(self, key16):
        key_p, out_p = SCRATCH, SCRATCH + 0x40
        self.uc.mem_write(key_p, bytes(key16))
        return bytes(self._call(self.expand_addr, [key_p, out_p], out_p, 48))

    def encrypt(self, pt16, rk48):
        pt_p, rk_p, out_p = SCRATCH + 0x100, SCRATCH + 0x140, SCRATCH + 0x180
        self.uc.mem_write(pt_p, bytes(pt16))
        self.uc.mem_write(rk_p, bytes(rk48))
        return bytes(self._call(self.encrypt_addr, [pt_p, rk_p, out_p], out_p, 16))


if __name__ == "__main__":
    c = Cipher("libSTD.so")
    print("ExpandKey @", hex(c.expand_addr), " Encrypt @", hex(c.encrypt_addr))
    rk = c.expand_key(bytes(range(16)))
    print("expand(00..0f) =", rk.hex())
    print("encrypt(zero block) =", c.encrypt(bytes(16), rk).hex())
