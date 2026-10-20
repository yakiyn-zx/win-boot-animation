#!/usr/bin/env python3
"""Windows .lnk shortcut surgery tool (read / retarget).

Retargets a shortcut by swapping its target leaf name for an EQUAL-LENGTH
new leaf name.  This is a pure byte substitution: every size/length/offset
field inside the file (IDList item offsets, LinkInfo offsets, StringData
length prefixes) stays valid and the file size is unchanged, so the shell
keeps resolving the shortcut exactly as before -- same display name, same
icon (ICON_LOCATION is kept), same AppUserModel.ID / taskbar grouping
(ExtraData holds no target path and is left untouched).

Hard rules learned the hard way (see ../references/lnk-format.md):
  * LinkTargetIDList can NEVER be removed -- the shortcut stops resolving.
  * Rebuilding the IDList is fragile (the header IDListSize must include
    the 2-byte terminal ID; an off-by-2 there is invisible but fatal).
    Prefer this equal-length substitution.
  * The new leaf name MUST have the same number of characters as the old
    one (e.g. WorkBuddy.exe -> WorkBuddy.vbs, 13 chars both).  Pick a
    launcher file name that matches (app.vbs, launch.vbs, start.exe ...).

subcommands:
  dump <src.lnk>                          full structure dump
  subst <src.lnk> <dst.lnk> <old> <new>   retarget (leaf names, equal length)
"""
import struct
import sys

LINK_CLSID = bytes.fromhex('0114020000000000c000000000000046')


def parse_idlist(d, base):
    """Return (items, consumed) starting at `base` (first item)."""
    items = []
    i = base
    while True:
        sz = struct.unpack('<H', d[i:i + 2])[0]
        if sz == 0:
            return items, i + 2 - base
        items.append(d[i:i + sz])
        i += sz


def dump(path):
    d = open(path, 'rb').read()
    print('=== %s (%d bytes) ===' % (path, len(d)))
    hsize, = struct.unpack('<I', d[0:4])
    clsid = d[4:20]
    flags, = struct.unpack('<I', d[20:24])
    fattr, = struct.unpack('<I', d[24:28])
    fsize, = struct.unpack('<I', d[0x34:0x38])
    iconindex, = struct.unpack('<I', d[0x38:0x3C])
    showcmd, = struct.unpack('<I', d[0x3C:0x40])
    print('header size %d  clsid ok %s' % (hsize, clsid == LINK_CLSID))
    print('flags 0x%08x  fileattr 0x%08x  filesize %d  iconindex %d  show %d'
          % (flags, fattr, fsize, iconindex, showcmd))
    for nm, off in (('ctime', 0x1C), ('atime', 0x24), ('wtime', 0x2C)):
        print('  %s %016x' % (nm, struct.unpack('<Q', d[off:off + 8])[0]))

    i = 76
    if flags & 0x1:
        idsize, = struct.unpack('<H', d[i:i + 2])
        print('IDListSize field: %d (at offset %d)' % (idsize, i))
        items, consumed = parse_idlist(d, i + 2)
        print('IDList items: %d, consumed %d bytes (field says %d) -> %s'
              % (len(items), consumed, idsize,
                 'OK' if consumed == idsize else '*** MISMATCH ***'))
        for n, it in enumerate(items):
            print('  item %d (%d bytes): %s' % (n, len(it), it.hex()))
            if len(it) > 3:
                print('    type 0x%02x flags 0x%02x size@0 %04x attrs@0x0e %04x'
                      % (it[2], it[3],
                         struct.unpack('<H', it[4:6])[0],
                         struct.unpack('<H', it[14:16])[0]))
        i += 2 + idsize
    else:
        print('no IDList flag')

    if flags & 0x2:
        lisz, = struct.unpack('<I', d[i:i + 4])
        print('LinkInfo at %d, size %d' % (i, lisz))
        print('  linkinfoheader %d  flags 0x%08x  vid_off %d  lbp_off %d'
              % (struct.unpack('<I', d[i + 4:i + 8])[0],
                 struct.unpack('<I', d[i + 8:i + 12])[0],
                 struct.unpack('<I', d[i + 12:i + 16])[0],
                 struct.unpack('<I', d[i + 16:i + 20])[0]))
        lbp_off, = struct.unpack('<I', d[i + 16:i + 20])
        if lbp_off:
            pos = i + lbp_off
            print('  LocalBasePath: %r' % d[pos:].split(b'\x00')[0])
        i += lisz

    for bit, nm in ((0x4, 'NAME'), (0x8, 'RELATIVE_PATH'), (0x10, 'WORKING_DIR'),
                    (0x20, 'ARGUMENTS'), (0x40, 'ICON_LOCATION')):
        if flags & bit:
            cnt, = struct.unpack('<H', d[i:i + 2])
            print('StringData %-14s (%d chars): %r'
                  % (nm, cnt, d[i + 2:i + 2 + cnt * 2].decode('utf-16le', 'replace')))
            i += 2 + cnt * 2

    while i + 4 <= len(d):
        sz, = struct.unpack('<I', d[i:i + 4])
        if sz < 4:
            print('ExtraData terminal at %d' % i)
            i += 4
            break
        sig, = struct.unpack('<I', d[i + 4:i + 8])
        print('ExtraData block at %d size %d sig 0x%08x' % (i, sz, sig))
        print('  hex: %s' % d[i:i + sz].hex())
        i += sz
    print('consumed %d of %d -> %s'
          % (i, len(d), 'OK' if i == len(d) else '*** LEFTOVER ***'))


def subst(src, dst, old_leaf, new_leaf):
    """Equal-length leaf-name substitution, fully structure-driven.

    Works on any shortcut: locates the IDList file item by searching for
    the old leaf name bytes, swaps the ANSI and UTF-16 copies, then swaps
    the leaf inside LinkInfo's LocalBasePath.  No hardcoded offsets, no
    hardcoded sizes -- everything is derived from the file itself.
    """
    old_a = old_leaf.encode('ascii') + b'\x00'
    new_a = new_leaf.encode('ascii') + b'\x00'
    old_u = old_leaf.encode('utf-16le') + b'\x00\x00'
    new_u = new_leaf.encode('utf-16le') + b'\x00\x00'
    assert len(old_a) == len(new_a) and len(old_u) == len(new_u), \
        'leaf names must have equal length (%r vs %r)' % (old_leaf, new_leaf)

    d = bytearray(open(src, 'rb').read())
    orig_len = len(d)

    # ---- structural pre-checks ------------------------------------------
    assert struct.unpack('<I', d[0:4])[0] == 76, 'bad header size'
    assert d[4:20] == LINK_CLSID, 'bad CLSID (not a shell link?)'
    flags, = struct.unpack('<I', d[20:24])
    assert flags & 0x1, 'source has no IDList (cannot patch in place)'
    assert flags & 0x2, 'source has no LinkInfo'

    # ---- 1) IDList: swap the leaf name inside every item that has it ----
    idlist_size, = struct.unpack('<H', d[76:78])
    items, consumed = parse_idlist(bytes(d), 78)
    assert consumed == idlist_size, 'source IDList inconsistent (field %d, walked %d)' % (
        idlist_size, consumed)

    renamed = 0
    for n, it in enumerate(items):
        ca, cu = it.count(old_a), it.count(old_u)
        if ca == 0 and cu == 0:
            continue                      # directory items: keep as-is
        assert ca == 1, 'ansi name appears %d times in item %d' % (ca, n)
        assert cu == 1, 'utf16 name appears %d times in item %d' % (cu, n)
        items[n] = it.replace(old_a, new_a).replace(old_u, new_u)
        renamed += 1
    assert renamed >= 1, 'old leaf %r not found in IDList' % old_leaf
    new_idlist = b''.join(items) + b'\x00\x00'
    d[78:78 + idlist_size] = new_idlist
    assert len(new_idlist) == idlist_size, 'IDList size changed (internal error)'

    # ---- 2) LinkInfo: swap the leaf inside LocalBasePath -----------------
    li_start = 78 + idlist_size
    li_size, = struct.unpack('<I', d[li_start:li_start + 4])
    lbp_off, = struct.unpack('<I', d[li_start + 16:li_start + 20])
    assert lbp_off, 'no LocalBasePath (unicode-only path?)'
    lbp_pos = li_start + lbp_off
    region = li_size - lbp_off
    # LocalBasePath is a NUL-terminated ANSI string with NO length field;
    # it is padded to the end of the LinkInfo block.
    old_path = bytes(d[lbp_pos:lbp_pos + region]).split(b'\x00')[0]
    assert old_path.endswith(old_leaf.encode('ascii')), \
        'LocalBasePath %r does not end with %r' % (old_path, old_leaf)
    # keep the directory part, swap only the leaf, keep the NUL terminator
    new_path = old_path[:-len(old_leaf)] + new_leaf.encode('ascii')
    new_path += b'\x00'
    assert len(new_path) <= region, 'new path longer than LocalBasePath region'
    d[lbp_pos:lbp_pos + region] = new_path + b'\x00' * (region - len(new_path))

    # NOTE: ExtraData (Tracker + PropertyStore) is intentionally untouched:
    # it holds no target path -- only a tracking machine name and the
    # AppUserModel.ID (taskbar grouping), both of which should survive.

    assert len(d) == orig_len, 'file size changed (internal error)'
    open(dst, 'wb').write(bytes(d))
    print('substituted -> %s (%d bytes, size unchanged)' % (dst, len(d)))
    print('  target : %s' % new_path.rstrip(b'\x00').decode())
    print('  renamed in %d IDList item(s)' % renamed)


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'dump':
        dump(sys.argv[2])
    elif cmd == 'subst':
        subst(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        raise SystemExit(
            'usage: lnktool.py dump <lnk>\n'
            '       lnktool.py subst <src.lnk> <dst.lnk> <old_leaf> <new_leaf>')
