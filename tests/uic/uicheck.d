// uicheck.d — differential oracle harness: for each .ui, the tree WE build (uiForm +
// setupUi) must serialize identically to the tree QUiLoader.load() builds (Qt's own uic).
// The dump + the oracle load live in qtd_uidump.cpp; we just diff the two strings.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qdialog, qt.widgets.qmainwindow;
import qt.widgets.qcheckbox, qt.widgets.qcborarray, qt.widgets.qcborvalue;
import qt.widgets.qjsondocument, qt.widgets.qjsonparseerror;
import cxxrt, uiform, qrc, std.stdio, std.string;

// Error-return -> typed D exception (the json/png case). Qt reports bad JSON via a
// QJsonParseError OUT-PARAM (not a C++ exception, so the Lippincott net never fires); a
// thin wrapper checks it and throws. Same shape for QImage (isNull), QFile (error()), etc.
class JsonParseException : Exception { this(string m) { super(m); } }
QJsonDocument parseJsonOrThrow(string json) {
    QJsonParseError err;                                  // default-inits to NoError (0)
    auto doc = QJsonDocument.fromJson(json, &err);
    auto code = *cast(QJsonParseError.ParseError*) &err.error[0];
    if (code != QJsonParseError.ParseError.NoError)
        throw new JsonParseException(err.errorString().toString);
    return doc;
}

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
extern (C) const(char)* qtd_ui_dump(void*);
extern (C) const(char)* qtd_ui_load_and_dump(const(char)*);
extern (C) void qtd_test_throw();   // raises a C++ exception via the Lippincott path

// one struct per form (distinct <class> names)
mixin(uiForm(import("dialog.ui")));    // Ui_Dialog
mixin(uiForm(import("login.ui")));     // Ui_LoginForm
mixin(uiForm(import("mainwin.ui")));   // Ui_MainWindow
mixin(uiForm(import("tabs.ui")));      // Ui_TabForm
mixin(uiForm(import("egroup.ui")));    // Ui_ShapeForm
mixin(uiForm(import("spacer.ui")));    // Ui_SpacerForm
mixin(qrcRegister(import("icons.qrc")));  // register :/ui/* so both trees resolve icons
mixin(uiForm(import("icon.ui")));      // Ui_IconForm
mixin(uiForm(import("font.ui")));      // Ui_FontForm
mixin(uiForm(import("sizepolicy.ui")));  // Ui_SizePolForm
mixin(uiForm(import("palette.ui")));   // Ui_PaletteForm
mixin(uiForm(import("connect.ui")));   // Ui_ConnForm
mixin(uiForm(import("buddy.ui")));     // Ui_BuddyForm
mixin(uiForm(import("embeddeddialog.ui")));      // Ui_embeddedDialog (real corpus: Qt:: 2-part enums + buddy)
mixin(uiForm(import("proxy.ui")));               // Ui_ProxyDialog (QLineEdit::Password, QDialogButtonBox::Ok — class 2-part)
mixin(uiForm(import("translationsettings.ui"))); // Ui_TranslationSettings
mixin(uiForm(import("bookwindow.ui")));  // Ui_BookWindow

__gshared int fails;

void check(T, R)(string path, R root) {
    T ui;
    ui.setupUi(root);
    string ours = qtd_ui_dump(cast(void*) root).fromStringz.idup;
    string oracle = qtd_ui_load_and_dump(path.toStringz).fromStringz.idup;
    if (ours == oracle) {
        writefln("  MATCH     %s", path);
    } else {
        writefln("  MISMATCH  %s", path);
        writeln("--- ours ---\n", ours, "--- oracle ---\n", oracle);
        fails++;
    }
}

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "uicheck\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    check!Ui_Dialog("tests/uic/dialog.ui", QDialog_new());
    check!Ui_LoginForm("tests/uic/login.ui", QWidget_new());
    check!Ui_MainWindow("tests/uic/mainwin.ui", QMainWindow_new());
    check!Ui_TabForm("tests/uic/tabs.ui", QWidget_new());
    check!Ui_ShapeForm("tests/uic/egroup.ui", QWidget_new());
    check!Ui_SpacerForm("tests/uic/spacer.ui", QWidget_new());
    check!Ui_IconForm("tests/uic/icon.ui", QWidget_new());
    check!Ui_FontForm("tests/uic/font.ui", QWidget_new());
    check!Ui_SizePolForm("tests/uic/sizepolicy.ui", QWidget_new());
    check!Ui_PaletteForm("tests/uic/palette.ui", QWidget_new());
    check!Ui_ConnForm("tests/uic/connect.ui", QWidget_new());
    check!Ui_BuddyForm("tests/uic/buddy.ui", QWidget_new());
    check!Ui_embeddedDialog("tests/uic/embeddeddialog.ui", QDialog_new());
    check!Ui_ProxyDialog("tests/uic/proxy.ui", QDialog_new());
    check!Ui_TranslationSettings("tests/uic/translationsettings.ui", QDialog_new());
    check!Ui_BookWindow("tests/uic/bookwindow.ui", QMainWindow_new());

    // Behavioral: the <connection> must actually fire (string-based QObject.connect ->
    // QMetaObject_Connection return; the meta-object forwards toggled(bool)->setChecked(bool)).
    {
        Ui_ConnForm ui;
        ui.setupUi(QWidget_new());
        ui.src.setChecked(true);
        if (ui.dst.isChecked())
            writeln("  CONNECT   connect.ui: src.toggled(bool) -> dst.setChecked(bool) fired");
        else { writeln("  CONNFAIL  connect.ui: connection did not fire"); fails++; }
    }

    // Iterator -> D range: a C++ forward iterator (begin()/end()) is exposed as a D range,
    // so `foreach (v; arr[])` iterates natively (front yields the value_type QCborValue).
    {
        auto arr = QCborArray_new();
        auto a = QCborValue(10L); arr.append(a);
        auto b = QCborValue(20L); arr.append(b);
        auto c = QCborValue(30L); arr.append(c);
        long sum = 0; int n = 0;
        foreach (v; arr[]) { sum += v.toInteger(0); n++; }
        if (n == 3 && sum == 60)
            writeln("  RANGE     QCborArray: foreach (v; arr[]) -> ", n, " items, sum ", sum);
        else { writeln("  RANGEFAIL QCborArray iteration: n=", n, " sum=", sum); fails++; }
    }

    // C++ exception -> D: a thrown C++ exception is classified by the Lippincott shim and
    // re-raised as a D QtCppException, unwinding back through the C++ trampoline frame.
    {
        bool caught = false; string msg;
        try { qtd_test_throw(); }
        catch (QtCppException e) { caught = true; msg = e.msg; }
        if (caught) writeln("  EXC       C++ exception -> QtCppException: ", msg);
        else { writeln("  EXCFAIL   C++ exception not translated to D"); fails++; }
    }

    // Error-return -> typed D exception: bad JSON throws JsonParseException; valid parses.
    {
        bool caught = false; string msg;
        try { parseJsonOrThrow("{ not valid json ]"); }
        catch (JsonParseException e) { caught = true; msg = e.msg; }
        cast(void) parseJsonOrThrow(`{"a":1}`);   // valid -> must NOT throw
        if (caught) writeln("  JSONERR   bad JSON -> JsonParseException: ", msg);
        else { writeln("  JSONFAIL  bad JSON not caught"); fails++; }
    }

    if (fails) { writefln("uicheck: %d MISMATCH(es)", fails); assert(false); }
    writeln("uicheck OK: our uic == QUiLoader for every .ui");
}
