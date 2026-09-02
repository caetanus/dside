// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// THE APPLICATION THE BUNDLE TEST DEPLOYS. It has to reach far enough into Qt to be a real
// deployment: constructing a QApplication is what loads the platform plugin, and the platform
// plugin is the piece no linker records and therefore the piece a mapping tool has to have found.
// A program that only touched QtCore would pass while the interesting half of the bundle was
// missing.
import qt.widgets.qapplication, qt.widgets.qwidget;
import cxxrt, std.stdio;
import appctor : QAPP_CTOR;

pragma(mangle, QAPP_CTOR) extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "deployapp\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto w = new QWidget();
    w.resize(120, 40);
    writeln("deployapp OK: QApplication constructed and a widget made");
}
