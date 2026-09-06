// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A QML MODEL PUBLISHED FROM D, WITHOUT JSON AND WITHOUT QAbstractListModel.
//
// A QVariantList of QVariantMap is already a model: a view iterates it and a delegate reads the
// keys by name. What the D side could not do was BUILD one — the list setter makes a flat list of
// scalars from strings — so an application had one way to hand rows over, which was to serialise
// them as JSON and have the QML parse the string again on every change. That pays a serialise, a
// parse, and a delegate written `modelData.<key>`, which is the shape the compiler must delegate.
//
// `setModel` takes an array of STRUCTS and uses the field names as the keys, so the row's schema is
// declared once, in D, and it is the same list of names the delegate claims as required properties.
//
// The assertion is on the VALUES, and on all four field types: they cross by four different routes
// (QString, qlonglong, double, bool) and a test that read one of them back would pass with the other
// three broken.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine, qt.qml.qqmlcontext;
import qt.qml.qqmlengine;
import cppq = qt.qml.qobject;   // the C++ QObject (renamed: the `@QObject` UDA below is qtmoc's)
import qtmoc, qrc, cxxrt, std.stdio;
import appctor : QCOREAPP_CTOR;
pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("model.qrc"), "qt.qml"));

struct Verse { int number; string text; double weight; bool marked; }

__gshared string g_seen = "";

@QObject class Backend {
    @Property("rowsChanged") QmlVar rows;
    Signal!() rowsChanged;
    import std.conv : to;
    /// One call per row, from the row itself: no order in the document to get wrong.
    @Slot void row(int number, string text, double weight, bool marked) {
        g_seen ~= number.to!string ~ ":" ~ text ~ ":" ~ weight.to!string
                ~ ":" ~ (marked ? "true" : "false") ~ " ";
    }

    void publish() {
        setModel(this, "rows", [Verse(1, "no princípio", 0.5, false),
                                Verse(2, "era o verbo", 1.25, true)]);
        rowsChanged.emit();
    }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    auto backend = newQObject!Backend();
    auto engine = new QQmlApplicationEngine();
    engine.rootContext().setContextProperty("backend", cppq.QObject.wrap(qobjOf(backend)));
    engine.load("qrc:/model.qml");

    // Published AFTER the document is up, which is the case that matters: a model handed over later
    // has to notify, and a view that read it once would show an empty list for ever.
    backend.publish();
    // The rows are instantiated on the event loop, not inside the write: Qt6 completes them
    // earlier than Qt5 does, and a test that read the result straight after publishing passed on
    // one and reported an empty string on the other.
    foreach (_; 0 .. 4) QCoreApplication.processEvents(0);

    assert(g_seen == "1:no princípio:0.5:false 2:era o verbo:1.25:true ",
           "the delegates read back '" ~ g_seen ~ "'");
    writeln("model OK: 2 rows crossed as QVariantMaps and every field type read back — '",
            g_seen[0 .. $ - 1], "'");
}
