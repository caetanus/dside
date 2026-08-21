// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// Deep risk №1 of docs/windows-roadmap.md, settled by running it: does the explicit-`self`
// pattern xiboca emits survive the Microsoft x64 calling convention?
//
// Three shapes for the SAME C++ symbol. Only one may be compiled at a time — LDC refuses two
// declarations of one mangled name with different types, which is itself the check working.
//
//   default        void size(void* self, Sz* ret)   the MS x64 order      -> CORRECT
//   -d-version=SretFirst   void size(Sz* ret, void* self)                 -> returns 0x0, no crash
//   -d-version=SysV        Sz   size(void* self)    the Linux shape       -> SEGFAULT
//
// The middle one is why this is a program and not an argument: it fails silently.
import std.stdio;

extern(C++) struct Sz { int w, h; }
extern(C) void* mk(int a, int b);

pragma(mangle, "?area@Widget@@QEBAHXZ")  extern(C++) int  warea(void* self);
pragma(mangle, "?grow@Widget@@QEAAXH@Z") extern(C++) void wgrow(void* self, int by);

version (SysV)
    pragma(mangle, "?size@Widget@@QEBA?AUSz@@XZ") extern(C++) Sz wsize(void* self);
else version (SretFirst)
    pragma(mangle, "?size@Widget@@QEBA?AUSz@@XZ") extern(C++) void wsize_raw(Sz* ret, void* self);
else
    pragma(mangle, "?size@Widget@@QEBA?AUSz@@XZ") extern(C++) void wsize_raw(void* self, Sz* ret);

void main() {
    auto w = mk(3, 4);
    stdout.writefln("mk    -> %s", w !is null);            stdout.flush();
    stdout.writefln("area  -> %d (expect 12)", warea(w));  stdout.flush();
    wgrow(w, 2);
    stdout.writefln("grow  -> %d (expect 30)", warea(w));  stdout.flush();

    stdout.writeln("size  -> value return + this"); stdout.flush();
    Sz s;
    version (SysV)          s = wsize(w);
    else version (SretFirst) wsize_raw(&s, w);
    else                     wsize_raw(w, &s);

    stdout.writefln("      -> %dx%d (expect 5x6)", s.w, s.h);
    writeln((s.w == 5 && s.h == 6) ? "ABI-PROBE: PASS" : "ABI-PROBE: FAIL");
}
