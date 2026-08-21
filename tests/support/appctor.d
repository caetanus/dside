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

version (Windows) {
    enum QAPP_CTOR     = "??0QApplication@@QEAA@AEAHPEAPEADH@Z";
    enum QCOREAPP_CTOR = "??0QCoreApplication@@QEAA@AEAHPEAPEADH@Z";
} else {
    enum QAPP_CTOR     = "_ZN12QApplicationC1ERiPPci";
    enum QCOREAPP_CTOR = "_ZN16QCoreApplicationC1ERiPPci";
}
