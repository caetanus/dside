// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Differential ORACLE for .qml files rooted in a D-defined QML type.
//
// It is the SAME oracle as the C++ one — qtd_qmlvalues.cpp's walk/format/dump, reached through
// qtd_qmlvalues_main — with one thing added in front: the app's D `@QObject` types are registered
// with qmlRegisterType, so the real QML engine can instantiate `Backend { ... }`. That keeps Qt
// itself as the source of truth; only the type's implementation language changed.
//
// Usage is identical to the C++ oracle: <file.qml> [name=value ...] [--props <file>]
module qtd_qmlvalues_d;

import apptypes;
import core.runtime : Runtime;

extern (C) int qtd_qmlvalues_main(int argc, char** argv);

extern (C) int main(int argc, char** argv) {
    Runtime.initialize();                 // D runtime (GC/TypeInfo) for the CTFE meta-object build
    registerAppTypes();                   // `import AppTypes 1.0` now resolves in the engine
    return qtd_qmlvalues_main(argc, argv);
}
