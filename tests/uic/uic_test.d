// uic_test.d — proves the CTFE `.ui` -> typed Ui struct works end to end: the mixin
// generates `struct Ui_LoginForm` with typed, named-widget fields; setupUi builds the
// real Qt widget tree; and the fields give compile-time-checked access. Headless.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpushbutton;
import qt.widgets.qlabel, qt.widgets.qvboxlayout, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);

mixin(uiForm(import("login.ui")));   // -> struct Ui_LoginForm { QLabel titleLabel; QPushButton okButton, cancelButton; setupUi(QWidget); }

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto root = QWidget_new();
    Ui_LoginForm ui;
    ui.setupUi(root);

    // Typed, compile-time-checked access to the named widgets — the whole point of uic.
    assert(ui.titleLabel !is null && ui.okButton !is null && ui.cancelButton !is null);
    assert(ui.okButton.text().toString() == "OK");
    assert(ui.cancelButton.text().toString() == "Cancel");
    assert(ui.titleLabel.text().toString() == "Please log in");

    ui.okButton.setText("Entrar");                       // typed method on a typed field
    assert(ui.okButton.text().toString() == "Entrar");

    writeln("uic OK: CTFE .ui -> typed Ui_LoginForm (titleLabel/okButton/cancelButton), text roundtrip");
}
