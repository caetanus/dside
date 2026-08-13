// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QML <-> D via the moc: a D @QObject backend exposed to a qrc-embedded .qml. Proves the
// direction the project targets — QML frontend, D backend objects via the runtime meta-object.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine, qt.qml.qqmlcontext;
import qt.qml.qqmlengine, qt.qml.qstring, qt.qml.qurl;
import cppq = qt.qml.qobject;   // the C++ QObject (renamed: `@QObject` UDA below is qtmoc's)
import qtmoc, qrc, cxxrt, std.stdio;
// The QML root is a non-visual QtObject tree (import QtQml only), so a QCoreApplication
// event loop is enough — no need to pull QtGui's QGuiApplication into the binding.
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("app.qrc"), "qt.qml"));

@QObject class Backend {
    Signal!int inChanged;
    @Property("inChanged") int inValue = 0;
    int received = -1;
    @Slot void fromQml(int v) { received = v; }
    void bump(int v) { inValue = v; inChanged.emit(v); }   // D-side change -> notify
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    auto backend = newQObject!Backend();
    auto engine = new QQmlApplicationEngine();
    engine.rootContext().setContextProperty("backend", cppq.QObject.wrap(qobjOf(backend)));
    engine.load("qrc:/main.qml");

    // Component.onCompleted ran during load: fromQml(1).
    assert(backend.received == 1, "QML->D slot at load (onCompleted) failed");
    // D property change -> QML binding re-evaluates mirror -> onMirrorChanged -> D slot.
    backend.bump(21);
    assert(backend.received == 42, "D property -> QML binding -> D slot round-trip failed");
    writeln("qml OK: D @Property -> QML binding -> D @Slot round-trip (received=", backend.received, ")");
}
