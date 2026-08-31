"""Shared helpers for reading a Diagbox 9.x installation offline.

Diagbox stores its whole diagnostic model in Firebird 2.5 databases plus
".DU8" string dictionaries. Nothing here talks to a car; it only reads the
installed data files (from copies) and turns them into JSON.
"""
import os
import struct

# ---------------------------------------------------------------- dictionary


def load_du8(path):
    """Return the list of strings of a Diagbox .DU8 dictionary.

    Layout: u32 magic, u32 table_offset, u32 data_offset, u32 count,
    then `count` u32 absolute offsets of NUL-terminated UTF-8 strings.
    Thesaurus references are 1-based, so id N is entry N-1.
    """
    with open(path, 'rb') as fh:
        b = fh.read()
    _magic, tstart, dstart, _cnt = struct.unpack_from('<IIII', b, 0)
    n = (dstart - tstart) // 4
    offs = list(struct.unpack_from('<%dI' % n, b, tstart))
    out, size = [], len(b)
    for i, o in enumerate(offs):
        if o >= size:
            out.append('')
            continue
        nxt = offs[i + 1] if i + 1 < n and offs[i + 1] <= size else size
        if nxt < o:
            nxt = min(o + 512, size)
        s = b[o:nxt]
        z = s.find(b'\0')
        if z >= 0:
            s = s[:z]
        out.append(s.decode('utf-8', 'replace'))
    return out


BOOKS = ('POLUXDATA', 'POLUXMES', 'POLUXXPERT', 'POLUXPORT', 'POLUXSPV')


class Thesaurus:
    """Resolves Diagbox label references such as '@P7917-POLUXDATA'.

    Grammar observed in the databases:
      @<letter><digits>-<BOOK>  thesaurus lookup (letter is P/L/F/T/...)
      @T<literal>               literal text
      @<backslash>*<n>          placeholder marker, kept verbatim
    Fragments may be concatenated in one field.
    """

    def __init__(self, transdir, lang='en_GB'):
        self.lang = lang
        self.books = {}
        for book in BOOKS:
            p = os.path.join(transdir, '%s%s.DU8' % (book, lang))
            if os.path.exists(p):
                self.books[book] = load_du8(p)

    def _one(self, book, num):
        arr = self.books.get(book)
        if not arr or not 1 <= num <= len(arr):
            return None
        return arr[num - 1]

    def resolve(self, ref):
        """Expand a reference into display text.

        A field is a sequence of segments: thesaurus lookups and '@T' literal
        runs build the text, while '@\\*' segments carry the arguments that
        fill the '*1', '*2' ... slots inside the looked-up sentences.
        """
        if ref is None:
            return None
        s = str(ref)
        out, args, i, n = [], [], 0, len(s)
        while i < n:
            if s[i] != '@':
                out.append(s[i])
                i += 1
                continue
            i += 1
            if i >= n:
                break
            if s[i] == chr(92):                     # '@\*' argument segment
                i += 1
                if i < n and s[i] == '*':
                    i += 1
                start = i
                while i < n and s[i] != '@':
                    i += 1
                args.append(s[start:i].strip())
                continue
            j = i + 1
            while j < n and s[j].isdigit():
                j += 1
            digits = s[i + 1:j]
            if digits and j < n and s[j] == '-':
                k = j + 1
                while k < n and (s[k].isalnum() or s[k] == '_'):
                    k += 1
                txt = self._one(s[j + 1:k], int(digits))
                out.append(txt if txt is not None else s[i:k])
                i = k
            else:                                   # '@T' literal run
                i += 1
                while i < n and s[i] != '@':
                    out.append(s[i])
                    i += 1
        return self._fill(''.join(out), args)

    @staticmethod
    def _fill(text, args):
        """Replace '*1', '*2' ... with the collected arguments."""
        out, i, n = [], 0, len(text)
        while i < n:
            if text[i] == '*' and i + 1 < n and text[i + 1].isdigit():
                j = i + 1
                while j < n and text[j].isdigit():
                    j += 1
                k = int(text[i + 1:j]) - 1
                out.append(args[k] if 0 <= k < len(args) else '')
                i = j
            else:
                out.append(text[i])
                i += 1
        return ' '.join(''.join(out).split())


# ----------------------------------------------------------------- firebird


def connect(fbdir, dbfile):
    import fdb
    os.environ['FIREBIRD'] = fbdir
    if hasattr(os, 'add_dll_directory'):
        os.add_dll_directory(fbdir)
    fdb.load_api(os.path.join(fbdir, 'fbembed.dll'))
    return fdb.connect(database=dbfile, user='SYSDBA', password='masterkey',
                       charset='NONE')


def rows(con, sql, *args):
    """Run a query and yield dicts, decoding CP1252 text."""
    cur = con.cursor()
    if args:
        cur.execute(sql, args)
    else:
        cur.execute(sql)
    cols = [d[0].strip().upper() for d in cur.description]
    for r in cur:
        rec = {}
        for c, v in zip(cols, r):
            if isinstance(v, (bytes, bytearray)):
                v = v.decode('cp1252', 'replace').rstrip()
            elif isinstance(v, str):
                v = v.rstrip()
            rec[c] = v
        yield rec
