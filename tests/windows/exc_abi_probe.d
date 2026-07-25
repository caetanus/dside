// exc_abi_probe.d — D side of the Windows/MSVC-x64 exception+guard de-risk probe.
// See exc_abi_probe.cpp for what this proves and how to build/run it.
//
// The generator emits exactly this shape (see emit_cxx.d `struct Guard`): D declares a NULLARY
// pragma(mangle,"<C++ symbol>") decl purely to take `&__raw` (the symbol's address), then calls
// the shared guard with that address + self + args. Here we hand-write it for `Thrower`.
import std.stdio, std.string;

class QtCppException : Exception { this(string m) { super(m); } }

// Called by the C++ Lippincott handler; throws a D exception that must unwind back through the
// C++ guard frame (the whole point of the probe).
extern(C) void qtd_throw_d(const(char)* type, const(char)* msg) {
    throw new QtCppException(msg ? msg.fromStringz.idup : "");
}

struct Big { long a, b, c; }   // matches the C++ Big layout (24-byte POD, returned via sret)

extern(C) void* qtd_new_thrower();
extern(C) int   qtd_g_int(void* fn, void* self, int a0);
extern(C) Big   qtd_g_big(void* fn, void* self, int a0);

// Nullary decls whose ONLY job is to give `&__raw_*` = the address of the C++ member symbol.
// MSVC-mangled names (?compute@Thrower@@QEAAHH@Z etc.) — on a real port these come from
// clang_Cursor_getMangling; here, fill them in from `dumpbin /symbols exc_abi_probe.obj` (or
// `llvm-nm`) once, since the probe is standalone. The two below are the Itanium names (Linux);
// replace with the MSVC ones when running on Windows.
private pragma(mangle, "_ZN7Thrower7computeEi") extern(C++) void __raw_compute();
private pragma(mangle, "_ZN7Thrower2mkEi")      extern(C++) void __raw_mk();

void main() {
    auto self = qtd_new_thrower();

    writeln("compute(7) = ", qtd_g_int(cast(void*)&__raw_compute, self, 7));   // 14
    auto b = qtd_g_big(cast(void*)&__raw_mk, self, 7);                          // {7,14,21}
    writeln("sret Big   = {", b.a, ",", b.b, ",", b.c, "}");

    bool caught = false;
    try { qtd_g_int(cast(void*)&__raw_compute, self, -1); }
    catch (QtCppException e) { caught = true; writeln("caught: ", e.msg); }
    if (!caught) { writeln("PROBE FAIL: cross-language unwind did NOT work"); return; }

    writeln("PROBE OK");
}
