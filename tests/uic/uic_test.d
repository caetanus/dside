// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// uic_test.d — the CTFE `.ui` -> typed Ui struct, now via the generic engine: the mixin
// generates the imports it needs, a `struct Ui_LoginForm` with typed named-widget fields,
// setupUi (objectName/resize/box-layout assembly + generic set<Prop> for geometry,
// alignment (<set> enum), wordWrap (<bool>)), and retranslateUi (translatable strings).
// The test only brings what IT uses directly. Headless.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;

import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);

mixin(uiForm(import("login.ui")));   // -> imports + struct Ui_LoginForm { setupUi(QWidget); retranslateUi(QWidget); }

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto root = new QWidget();
    Ui_LoginForm ui;
    ui.setupUi(root);                    // builds the real widget tree (incl. resize/alignment/wordWrap)

    // Typed, compile-time-checked access to the named widgets — the point of uic.
    assert(ui.titleLabel !is null && ui.okButton !is null && ui.cancelButton !is null);
    assert(ui.okButton.text().toString() == "OK");
    assert(ui.cancelButton.text().toString() == "Cancel");
    assert(ui.titleLabel.text().toString() == "Please log in");

    ui.okButton.setText("Entrar");       // typed method on a typed field
    assert(ui.okButton.text().toString() == "Entrar");

    writeln("uic OK: CTFE .ui -> typed Ui_LoginForm via generic engine ",
            "(resize/alignment/wordWrap set, text in retranslateUi, roundtrip)");
}
