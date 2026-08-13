// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// exc_abi_probe.cpp — Windows/MSVC-x64 de-risk probe for the exception + guard layer.
// See docs/windows-roadmap.md "Tier 2.5". This is the SAME experiment that was proven on
// Linux (ldc AND dmd); re-run it on a Windows box before trusting exceptions on MSVC.
//
// It exercises the two things that are ABI/EH-specific:
//   (A) calling a C++ member function through a raw symbol address as if it were a free
//       function with `this` as arg 0 (the per-signature guard trick), and
//   (B) a D exception thrown from inside this C++ catch(...) unwinding back through the C++
//       frame to a D handler (cross-language unwind — DWARF on Linux, SEH on Windows).
//
// BUILD (MSVC-x64, from an x64 Native Tools prompt or clang-cl):
//   clang-cl /std:c++17 /EHsc /c exc_abi_probe.cpp
//   ldc2   -mtriple=x86_64-windows-msvc exc_abi_probe.d exc_abi_probe.obj
//   dmd    -m64                          exc_abi_probe.d exc_abi_probe.obj    (repeat for BOTH)
// Expect, on BOTH compilers:
//   compute(7) = 14
//   sret Big   = {7,14,21}
//   caught: negative!
//   PROBE OK
// If "caught:" never prints (or it crashes / std::terminate), cross-language unwind does NOT
// work under SEH -> switch the guard's translation to the thread-local + check fallback
// (see the roadmap). If compute()/sret print wrong values, the reinterpret_cast this=arg0 /
// sret ordering doesn't hold on MS x64 -> the guard emission needs an MS-ABI variant.
#include <stdexcept>
#include <typeinfo>

extern "C" void qtd_throw_d(const char* type, const char* msg);   // implemented in D
[[noreturn]] static void qtd_lippincott() {
    try { throw; }
    catch (const std::exception& e) { qtd_throw_d(typeid(e).name(), e.what()); }
    catch (...) { qtd_throw_d("", "unknown"); }
#if defined(_MSC_VER)
    __assume(false);
#else
    __builtin_unreachable();
#endif
}

// A 24-byte POD (>16 bytes) is returned via a hidden sret pointer on BOTH SysV and MS x64 —
// so mk() exercises the ABI-sensitive sret path. It has a matching D layout (see the .d); note
// we do NOT use std::string here because its ABI has no matching D type (D `string` is a 16-byte
// fat slice, C++ std::string is a 32-byte SSO object) — the real binding maps QString<->a struct.
struct Big { long a, b, c; };

// compute/mk are OUT-OF-LINE (defined below the class) so they have real linkable symbols —
// the whole point is to take their address; an inline member has no symbol (same as Qt).
struct Thrower {
    int compute(int x);
    Big mk(int x);            // value RETURN by value (sret) — the ABI-sensitive case
};
int Thrower::compute(int x) { if (x < 0) throw std::runtime_error("negative!"); return x * 2; }
Big Thrower::mk(int x) { return Big{ x, x * 2, x * 3 }; }
extern "C" void* qtd_new_thrower() { return new Thrower(); }

// Guard for int(void*,int): reinterpret the fn ptr to the signature, call in try/catch.
extern "C" int qtd_g_int(void* fn, void* self, int a0) {
    try { return reinterpret_cast<int(*)(void*, int)>(fn)(self, a0); }
    catch (...) { qtd_lippincott(); }
}
// Guard for a value-RETURN (sret) signature Big(void*,int).
extern "C" Big qtd_g_big(void* fn, void* self, int a0) {
    try { return reinterpret_cast<Big(*)(void*, int)>(fn)(self, a0); }
    catch (...) { qtd_lippincott(); }
}
