// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// moc/CTFE with QString args: a D @QObject emits textChanged(QString), connected
// to the REAL setText(QString) slot of a built-in QLabel. Proves QString (UTF-8)
// marshaling crossing a custom-signal D -> Qt-slot via the runtime meta-object.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlabel;
import qt.widgets.qvboxlayout, qt.widgets.qtimer, qt.widgets.qstring;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class Editor {
    Signal!string textChanged;
    private string _t;
    @Slot void setText(string s) {
        if (s != _t) { _t = s; textChanged.emit(s); }   // emit the QString custom signal
    }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t7\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto widget = new QWidget();
    auto label = new QLabel(cast(QWidget) null, 0);
    auto layout = new QVBoxLayout(widget);
    layout.addWidget(label);
    widget.show();

    auto ed = newQObject!Editor();
    // custom signal QString (D) -> slot built-in QString (Qt)
    connectMeta(ed, "textChanged(QString)", label, "setText(QString)");

    ed.setText("olá çãé 42");                    // textChanged("olá çãé 42") -> label.setText
    assert(label.text().toString() == "olá çãé 42", "QString custom-signal -> Qt-slot failed");

    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t7 OK: @QObject D textChanged(QString) -> QLabel.setText, label=%s", label.text().toString());
}
