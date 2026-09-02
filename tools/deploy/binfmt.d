// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// WHAT A BINARY SAYS ABOUT ITSELF, read out of the file rather than asked of the loader.
//
// `ldd` answers this question by RUNNING the program, which is wrong twice over for a deployment
// tool: it needs the target platform to be this one, and it resolves against THIS machine's
// libraries, which are exactly what the bundle is supposed to stop depending on. Both formats
// carry the answer statically — ELF in PT_DYNAMIC, PE in the import directory — so both are read
// here, and a Windows bundle can be mapped from Linux and the reverse.
module binfmt;

import std.file : read;
import std.string : indexOf;
import std.algorithm : canFind;
import std.conv : to;

/// What a shared object or executable declares. `soname` is empty for executables.
struct BinInfo {
    bool ok;              /// false when the file is not a binary this understands
    string why;           /// why not, when !ok
    bool elf;             /// ELF (otherwise PE)
    string soname;
    string[] needed;      /// DT_NEEDED / import-table DLL names, in file order
    string[] runpath;     /// DT_RUNPATH, else DT_RPATH, split on ':'; unexpanded
    bool runpathIsRpath;  /// the entry found was the deprecated DT_RPATH
    // THE WORD SIZE AND THE MACHINE, because a name is not enough to pick a file. `/etc/ld.so.conf`
    // on a multilib system lists /usr/lib32 beside /usr/lib, both hold a `libfreetype.so.6`, and a
    // resolver that takes the first match by name hands a 64-bit application the 32-bit one. Read
    // here so the caller can require the referrer's own answer.
    ubyte klass;          /// ELF: 1 = 32-bit, 2 = 64-bit. PE: 1 = i386, 2 = x86-64/arm64
    ushort machine;       /// ELF e_machine / PE COFF Machine
}

private T le(T)(const(ubyte)[] b, size_t off) {
    if (off + T.sizeof > b.length) return T.init;
    T v = 0;
    foreach_reverse (i; 0 .. T.sizeof) v = cast(T)((v << 8) | b[off + i]);
    return v;
}

private string cstr(const(ubyte)[] b, size_t off) {
    if (off >= b.length) return "";
    auto end = off;
    while (end < b.length && b[end] != 0) ++end;
    return cast(string) b[off .. end].idup;
}

BinInfo readBinary(string path) {
    const(ubyte)[] b;
    try b = cast(const(ubyte)[]) read(path);
    catch (Exception e) return BinInfo(false, "cannot read: " ~ e.msg);
    if (b.length >= 4 && b[0] == 0x7f && b[1] == 'E' && b[2] == 'L' && b[3] == 'F') return readElf(b);
    if (b.length >= 2 && b[0] == 'M' && b[1] == 'Z') return readPe(b);
    return BinInfo(false, "neither ELF nor PE");
}

// --- ELF ---------------------------------------------------------------------------------------
private enum { PT_LOAD = 1, PT_DYNAMIC = 2 }
private enum { DT_NULL = 0, DT_NEEDED = 1, DT_STRTAB = 5, DT_SONAME = 14, DT_RPATH = 15,
               DT_RUNPATH = 29 }

BinInfo readElf(const(ubyte)[] b) {
    BinInfo r; r.elf = true;
    if (b.length < 64) return BinInfo(false, "truncated ELF header");
    const bits64 = b[4] == 2;
    if (b[5] != 1) return BinInfo(false, "big-endian ELF is not supported");
    r.klass = b[4];
    r.machine = le!ushort(b, 18);
    const phoff  = bits64 ? cast(size_t) le!ulong(b, 32) : cast(size_t) le!uint(b, 28);
    const phentsz= bits64 ? le!ushort(b, 54) : le!ushort(b, 42);
    const phnum  = bits64 ? le!ushort(b, 56) : le!ushort(b, 44);

    // The dynamic section names its string table by VIRTUAL address, so the loadable segments are
    // needed to turn that back into a file offset. Reading .dynstr through the section headers
    // instead would work on a linker's output and not on a stripped one, where they can be gone.
    struct Seg { ulong vaddr, off, filesz; }
    Seg[] loads;
    Seg dyn;
    bool haveDyn;
    foreach (i; 0 .. phnum) {
        const p = phoff + i * phentsz;
        if (p + phentsz > b.length) break;
        const type = le!uint(b, p);
        Seg s;
        if (bits64) { s.off = le!ulong(b, p + 8);  s.vaddr = le!ulong(b, p + 16); s.filesz = le!ulong(b, p + 32); }
        else        { s.off = le!uint (b, p + 4);  s.vaddr = le!uint (b, p + 8);  s.filesz = le!uint (b, p + 16); }
        if (type == PT_LOAD) loads ~= s;
        else if (type == PT_DYNAMIC) { dyn = s; haveDyn = true; }
    }
    if (!haveDyn) { r.ok = true; return r; }  // a static binary needs nothing at run time

    ulong toOff(ulong v) {
        foreach (s; loads) if (v >= s.vaddr && v < s.vaddr + s.filesz) return v - s.vaddr + s.off;
        return ulong.max;
    }

    // Two passes: the string table's address can appear after the entries that index into it.
    const esz = bits64 ? 16 : 8;
    ulong strtabVa = ulong.max;
    for (size_t o = cast(size_t) dyn.off; o + esz <= b.length; o += esz) {
        const tag = bits64 ? le!ulong(b, o) : le!uint(b, o);
        const val = bits64 ? le!ulong(b, o + 8) : le!uint(b, o + 4);
        if (tag == DT_NULL) break;
        if (tag == DT_STRTAB) strtabVa = val;
    }
    if (strtabVa == ulong.max) return BinInfo(false, "PT_DYNAMIC without DT_STRTAB");
    const strOff = toOff(strtabVa);
    if (strOff == ulong.max) return BinInfo(false, "DT_STRTAB is outside every PT_LOAD");

    string[] rpath, runpath;
    for (size_t o = cast(size_t) dyn.off; o + esz <= b.length; o += esz) {
        const tag = bits64 ? le!ulong(b, o) : le!uint(b, o);
        const val = bits64 ? le!ulong(b, o + 8) : le!uint(b, o + 4);
        if (tag == DT_NULL) break;
        switch (tag) {
            case DT_NEEDED:  r.needed ~= cstr(b, cast(size_t)(strOff + val)); break;
            case DT_SONAME:  r.soname  = cstr(b, cast(size_t)(strOff + val)); break;
            case DT_RPATH:   rpath   ~= cstr(b, cast(size_t)(strOff + val)); break;
            case DT_RUNPATH: runpath ~= cstr(b, cast(size_t)(strOff + val)); break;
            default: break;
        }
    }
    // DT_RUNPATH wins where both are present — that is the loader's own rule, and a file that
    // carries both is not rare: a build system adds one and the linker keeps the other.
    import std.array : split, join;
    auto chosen = runpath.length ? runpath : rpath;
    r.runpathIsRpath = runpath.length == 0 && rpath.length > 0;
    foreach (e; chosen) foreach (part; e.split(':')) if (part.length) r.runpath ~= part;
    r.ok = true;
    return r;
}

// --- PE ----------------------------------------------------------------------------------------
BinInfo readPe(const(ubyte)[] b) {
    BinInfo r; r.elf = false;
    if (b.length < 0x40) return BinInfo(false, "truncated DOS header");
    const pe = le!uint(b, 0x3c);
    if (pe + 24 > b.length || b[pe] != 'P' || b[pe + 1] != 'E') return BinInfo(false, "no PE signature");
    const nsec   = le!ushort(b, pe + 6);
    const optsz  = le!ushort(b, pe + 20);
    const opt    = pe + 24;
    if (opt + 2 > b.length) return BinInfo(false, "truncated optional header");
    const plus   = le!ushort(b, opt) == 0x20b;
    r.klass = plus ? 2 : 1;
    r.machine = le!ushort(b, pe + 4);
    const ddOff  = opt + (plus ? 112 : 96);
    const ddCount= le!uint(b, opt + (plus ? 108 : 92));
    const secOff = opt + optsz;

    ulong rva2off(uint rva) {
        foreach (i; 0 .. nsec) {
            const s = secOff + i * 40;
            if (s + 40 > b.length) break;
            const va = le!uint(b, s + 12), vsz = le!uint(b, s + 8);
            const raw = le!uint(b, s + 20), rsz = le!uint(b, s + 16);
            const span = vsz > rsz ? vsz : rsz;
            if (rva >= va && rva < va + span) return rva - va + raw;
        }
        return ulong.max;
    }

    // Directory 1 is the import table and 13 is the delay-load table. Qt's own DLLs use delay
    // loading, so a tool that reads only the first one reports a dependency set that is short
    // exactly where it matters.
    void harvest(uint dirIndex, uint nameFieldOff, uint descSize) {
        if (dirIndex >= ddCount) return;
        const d = ddOff + dirIndex * 8;
        if (d + 8 > b.length) return;
        const rva = le!uint(b, d);
        if (rva == 0) return;
        auto off = rva2off(rva);
        if (off == ulong.max) return;
        for (;; off += descSize) {
            if (off + descSize > b.length) break;
            bool allZero = true;
            foreach (k; 0 .. descSize) if (b[cast(size_t)(off + k)] != 0) { allZero = false; break; }
            if (allZero) break;
            const nrva = le!uint(b, cast(size_t)(off + nameFieldOff));
            if (nrva == 0) continue;
            const noff = rva2off(nrva);
            if (noff == ulong.max) continue;
            auto nm = cstr(b, cast(size_t) noff);
            if (nm.length && !r.needed.canFind(nm)) r.needed ~= nm;
        }
    }
    harvest(1, 12, 20);   // IMAGE_IMPORT_DESCRIPTOR.Name
    harvest(13, 16, 32);  // IMAGE_DELAYLOAD_DESCRIPTOR.DllNameRVA
    r.ok = true;
    return r;
}

// --- rewriting a RUNPATH -------------------------------------------------------------------------
/// Replace an ELF's DT_RUNPATH/DT_RPATH in place, and report whether it could be done.
///
/// THE AUDITWHEEL CASE IS THE ONE THIS SOLVES. A third-party library built somewhere else carries
/// an absolute RPATH — `/home/builder/deps/lib`, `/opt/vendor/lib` — which resolves on the build
/// machine and nowhere else, and which is longer than the `$ORIGIN` that should replace it. Those
/// fit, so they get rewritten, and the bundle stops depending on a directory that does not exist
/// on the user's disk.
///
/// WHAT IT WILL NOT DO IS PRETEND. A string in `.dynstr` cannot grow: every other offset into that
/// table is an absolute byte position and moving the end of one string moves every string after it.
/// Making room means rebuilding the file the way `patchelf` does, and this does not do that — it
/// says so, names the shortfall, and leaves the file untouched, because a deployment tool that
/// silently declines produces a bundle whose failure surfaces on someone else's machine.
///
/// `wantRpath` PICKS WHICH TAG, and in a bundle the answer is the deprecated one. DT_RUNPATH
/// applies only to the object that carries it; DT_RPATH is inherited by everything loaded beneath
/// it. Measured on a bundle of this repository's own `hello`: 103 of the 118 copied libraries carry
/// no run path at all — distributions do not ship one — so the search for `libfreetype.so.6` made
/// on behalf of `libfontconfig.so.1` consults neither, reaches the system directories and loads the
/// machine's copy instead of the bundled one. With the EXECUTABLE carrying DT_RPATH the same search
/// walks up to it and finds the bundled file, and not one of those 103 needs touching. The scope
/// that is wrong for a library on a shared system is exactly right for a self-contained tree.
struct PatchResult { bool changed; bool ok; string why; }

PatchResult setRunpath(string path, string value, bool wantRpath = false) {
    import std.file : read, write;
    ubyte[] b;
    try b = cast(ubyte[]) read(path);
    catch (Exception e) return PatchResult(false, false, "cannot read: " ~ e.msg);
    if (b.length < 64 || !(b[0] == 0x7f && b[1] == 'E' && b[2] == 'L' && b[3] == 'F'))
        return PatchResult(false, false, "not an ELF file");
    if (b[5] != 1) return PatchResult(false, false, "big-endian ELF is not supported");
    const bits64 = b[4] == 2;
    const phoff  = bits64 ? cast(size_t) le!ulong(b, 32) : cast(size_t) le!uint(b, 28);
    const phentsz= bits64 ? le!ushort(b, 54) : le!ushort(b, 42);
    const phnum  = bits64 ? le!ushort(b, 56) : le!ushort(b, 44);

    struct Seg { ulong vaddr, off, filesz; }
    Seg[] loads; Seg dyn; bool haveDyn;
    foreach (i; 0 .. phnum) {
        const p = phoff + i * phentsz;
        if (p + phentsz > b.length) break;
        const type = le!uint(b, p);
        Seg s;
        if (bits64) { s.off = le!ulong(b, p + 8); s.vaddr = le!ulong(b, p + 16); s.filesz = le!ulong(b, p + 32); }
        else        { s.off = le!uint (b, p + 4); s.vaddr = le!uint (b, p + 8);  s.filesz = le!uint (b, p + 16); }
        if (type == PT_LOAD) loads ~= s;
        else if (type == PT_DYNAMIC) { dyn = s; haveDyn = true; }
    }
    if (!haveDyn) return PatchResult(false, false, "no PT_DYNAMIC");

    ulong toOff(ulong v) {
        foreach (s; loads) if (v >= s.vaddr && v < s.vaddr + s.filesz) return v - s.vaddr + s.off;
        return ulong.max;
    }
    const esz = bits64 ? 16 : 8;
    ulong strtabVa = ulong.max;
    for (size_t o = cast(size_t) dyn.off; o + esz <= b.length; o += esz) {
        const tag = bits64 ? le!ulong(b, o) : le!uint(b, o);
        if (tag == DT_NULL) break;
        if (tag == DT_STRTAB) strtabVa = bits64 ? le!ulong(b, o + 8) : le!uint(b, o + 4);
    }
    if (strtabVa == ulong.max) return PatchResult(false, false, "no DT_STRTAB");
    const strOff = toOff(strtabVa);
    if (strOff == ulong.max) return PatchResult(false, false, "DT_STRTAB is outside every PT_LOAD");

    for (size_t o = cast(size_t) dyn.off; o + esz <= b.length; o += esz) {
        const tag = bits64 ? le!ulong(b, o) : le!uint(b, o);
        if (tag == DT_NULL) break;
        if (tag != DT_RPATH && tag != DT_RUNPATH) continue;
        const val = bits64 ? le!ulong(b, o + 8) : le!uint(b, o + 4);
        const at = cast(size_t)(strOff + val);
        auto cur = cstr(b, at);
        if (cur == value) return PatchResult(false, true, "already " ~ value);
        if (value.length > cur.length)
            return PatchResult(false, false,
                "the existing RUNPATH is " ~ to!string(cur.length) ~ " byte(s) and the new one needs "
                ~ to!string(value.length) ~ "; a .dynstr entry cannot grow in place");
        foreach (i, ch; value) b[at + i] = cast(ubyte) ch;
        foreach (i; value.length .. cur.length) b[at + i] = 0;
        const newTag = wantRpath ? DT_RPATH : DT_RUNPATH;
        if (tag != newTag) {
            if (bits64) foreach (i; 0 .. 8) b[o + i] = cast(ubyte)((cast(ulong) newTag >> (8 * i)) & 0xff);
            else        foreach (i; 0 .. 4) b[o + i] = cast(ubyte)((cast(uint)  newTag >> (8 * i)) & 0xff);
        }
        try write(path, b);
        catch (Exception e) return PatchResult(false, false, "cannot write: " ~ e.msg);
        return PatchResult(true, true, cur.length ? "was `" ~ cur ~ "`" : "was empty");
    }
    return PatchResult(false, false, "the file carries neither DT_RUNPATH nor DT_RPATH, and one "
                       ~ "cannot be added without rebuilding the string table");
}
