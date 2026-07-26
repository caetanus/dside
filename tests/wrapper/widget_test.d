import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpushbutton;
import qt.widgets.qtimer, qt.widgets.qstring, qt.widgets.qsize;
import holder, cxxrt, core.memory, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size);
    __qapp_ctor(raw, argc, argv.ptr, 0);
    auto app = QApplication.wrap(raw);
    auto w = new QWidget();
    auto sz = QSize(200, 120); w.resize(sz);
    auto lbl = qstr("Quit"); auto b = new QPushButton(lbl, w);   // child of w -> pinned
    auto bc = b.ptr();
    b.connectClicked((bool _) { QApplication.quit(); });
    w.show();
    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(30);
    QApplication.exec();
    b = null; foreach (_; 0..5) GC.collect();
    assert(holder.find(bc) !is null, "child button pinned by parenting (survives GC)");
    writeln("wrapper widget app OK");
}
