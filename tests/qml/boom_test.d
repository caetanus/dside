// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// critics r8 #5: a QML factory whose D constructor THROWS must become an observable creation
// FAILURE with complete cleanup — not a silent carrier with a null backing object (which would
// later dispatch a slot/property into null and crash). The D factory catches the throw and records
// it via qtdOnCallbackError (so qtdCallbackErrors increments), returns null; the C++ carrier then
// drops its half-attached side-table entry, warns, and stays inert. The process must SURVIVE.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, qrc, cxxrt, std.stdio;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("boom.qrc"), "qt.qml"));

@QObject class Boom {
    Signal!int changed;
    @Property("changed") int value = 0;
    @Slot void poke(int v) { value = v; }
    this() { throw new Exception("boom: D constructor failed on purpose"); }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    qmlRegisterType!Boom("App", 1, 0, "Boom");

    immutable before = qtdCallbackErrors;
    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/boom.qml");   // instantiates Boom -> factory throws -> recorded, no crash

    // The failure was OBSERVED, not swallowed: the factory recorded the throw.
    assert(qtdCallbackErrors > before,
        "a throwing QML constructor must be recorded (qtdCallbackErrors), not silently dropped");
    assert(qtdLastCallbackError !is null && qtdLastCallbackError.msg.length,
        "the recorded error must carry the constructor's message");

    // Reaching here at all is the other half of the contract: the process SURVIVED a failed
    // QML instantiation (the carrier degraded to an inert QObject, dispatch guarded against null).
    writeln("qml OK: throwing QML constructor became an observable failure, process survived (errors=",
        qtdCallbackErrors - before, ")");
}
