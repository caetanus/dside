// Container QList<T> round-trip, AGNÓSTICO Qt5/Qt6. O layout do QList difere
// TOTALMENTE entre as versões (Qt6: QArrayDataPointer {d,ptr,size}; Qt5:
// QListData {Data* d} com elementos inline no array + free via QListData::dispose).
// Exercita os dois caminhos de elemento e faz stress do create/destroy pra validar
// o dtor sem corromper o heap:
//   - ponteiro (só free): QApplication.topLevelWidgets() -> QList<QWidget*>
//   - QByteArray (release por-elemento + free): QObject.dynamicPropertyNames()
// (QStringList NÃO serve p/ isso: é alias de QList<QString> no Qt6 mas subclasse
// no Qt5 — então arguments()/libraryPaths() dão tipos diferentes por versão.)
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "qltest\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    // caminho ponteiro (QList<QWidget*> -> QWidget[]): free do bloco + at()/length.
    auto w1 = QWidget_new(); w1.show();
    auto w2 = QWidget_new(); w2.show();
    auto tops = QApplication.topLevelWidgets();
    assert(tops.length >= 2, "topLevelWidgets() não vê os 2 widgets");
    foreach (t; tops) assert(t !is null, "elemento nulo");        // exercita at() em cada índice
    foreach (i; 0 .. 50_000) { auto t = QApplication.topLevelWidgets(); assert(t.length >= 2); }

    // caminho QByteArray (elemento com release): QList<QByteArray> -> string[].
    // Numa QObject nova a lista é vazia — ainda exercita create/free do container
    // pro tipo bytes (o release por-elemento não-vazio é validado à parte). Stress.
    auto names = w1.dynamicPropertyNames();
    assert(names.length == 0, "objeto novo não deveria ter props dinâmicas");
    foreach (i; 0 .. 50_000) { auto n = w1.dynamicPropertyNames(); assert(n.length == 0); }

    writefln("qlist OK: topLevelWidgets=%d (ponteiro), dynamicPropertyNames=%d (bytes) — 100k create/free sem crash",
        tops.length, names.length);
}
