// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// THE APPLICATION CONSTRUCTOR, MANGLED FOR THE ABI IN FRONT OF US.
//
// Tests construct QApplication/QCoreApplication by hand: the constructor Qt actually uses
// (`int &argc, char **argv, int`) carries an internal third argument and is not part of the bound
// API. Forty test files carried the Itanium symbol as a string literal — which is not a statement
// about Qt but about the C++ compiler that built it. True on Linux; against an MSVC-built Qt the
// same constructor is `??0QApplication@@QEAA@AEAHPEAPEADH@Z`, and the link fails with an undefined
// symbol whose demangled name is identical to the one being asked for.
//
// Both symbols were READ from the shipped libraries with llvm-nm, not computed:
//
//     llvm-nm --defined-only Qt6Widgets.lib | grep '??0QApplication@@'
//     llvm-nm --defined-only libQt6Widgets.so | c++filt
//
// One place, so a third ABI is one edit rather than forty.
module appctor;

// ...AND NOW DERIVED RATHER THAN TABULATED. The two lists above this line were a table of four
// strings with no entry for QGuiApplication, so writing a QtQuick program meant inventing a symbol
// that this very file exists to prevent inventing (reported from the outside, bugs.md #5). The
// rule is in the generated runtime — `cxxrt.qtdAppCtorSymbol` — where it ships with the binding,
// and `tests/wrapper/appmixin.d` checks every derivation against the library that defines it.
//
// New code should use `mixin(qtdApplication!"QGuiApplication")` and call `createApp`, which also
// carries the `__gshared argc` rule Qt requires. These two names stay for the 32 files that
// already declare the constructor themselves.
import cxxrt : qtdAppCtorSymbol;

version (Windows) {
    enum QAPP_CTOR     = qtdAppCtorSymbol("QApplication", true);
    enum QCOREAPP_CTOR = qtdAppCtorSymbol("QCoreApplication", true);
} else {
    enum QAPP_CTOR     = qtdAppCtorSymbol("QApplication", false);
    enum QCOREAPP_CTOR = qtdAppCtorSymbol("QCoreApplication", false);
}
