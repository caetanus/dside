// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;
import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("egroup.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = new QWidget();
    Ui_ShapeForm ui; ui.setupUi(root);
    assert(ui.shapeGroup !is null && ui.lineRadio !is null && ui.circleRadio !is null && ui.nameEdit !is null);
    assert(ui.lineRadio.text().toString() == "Line");
    assert(ui.shapeGroup.checkedButton() !is null);   // lineRadio is checked -> group has a checked button
    writeln("uic OK: button group (2 radios) + tab order -> typed Ui_ShapeForm, checked button set");
}
