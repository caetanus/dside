// Container QList<T> round-trip, Qt5/Qt6 AGNOSTIC. The QList layout differs
// COMPLETELY between versions (Qt6: QArrayDataPointer {d,ptr,size}; Qt5:
// QListData {Data* d} with elements inline in the array + free via QListData::dispose).
// Exercises both element paths and stress-tests create/destroy to validate
// the dtor without corrupting the heap:
//   - pointer (free only): QApplication.topLevelWidgets() -> QList<QWidget*>
//   - QByteArray (per-element release + free): QObject.dynamicPropertyNames()
// (QStringList does NOT work for this: it's an alias of QList<QString> on Qt6 but a subclass
// on Qt5 — so arguments()/libraryPaths() give different types per version.)
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "qltest\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    // pointer path (QList<QWidget*> -> QWidget[]): free the block + at()/length.
    auto w1 = QWidget_new(); w1.show();
    auto w2 = QWidget_new(); w2.show();
    auto tops = QApplication.topLevelWidgets();
    assert(tops.length >= 2, "topLevelWidgets() does not see the 2 widgets");
    foreach (t; tops) assert(t !is null, "null element");        // exercises at() at each index
    foreach (i; 0 .. 50_000) { auto t = QApplication.topLevelWidgets(); assert(t.length >= 2); }

    // QByteArray path (element with release): QList<QByteArray> -> string[].
    // On a fresh QObject the list is empty — this still exercises container create/free
    // for the bytes type (the non-empty per-element release is validated separately). Stress.
    auto names = w1.dynamicPropertyNames();
    assert(names.length == 0, "a fresh object should not have dynamic props");
    foreach (i; 0 .. 50_000) { auto n = w1.dynamicPropertyNames(); assert(n.length == 0); }

    writefln("qlist OK: topLevelWidgets=%d (pointer), dynamicPropertyNames=%d (bytes) — 100k create/free without crash",
        tops.length, names.length);
}
