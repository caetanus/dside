// qmlcachegen AOT: register.qml is compiled ahead of time to bytecode and linked in
// (register_qml unit + qmlcache_loader hook). Crucially NO .qml source is shipped — there
// is no qrcRegister here — so the engine can only serve qrc:/register.qml from the linked
// precompiled unit. If the round-trip runs, the AOT cache is definitively what's consumed.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, cxxrt, std.stdio;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);

__gshared int g_received = -1;

@QObject class Backend {
    Signal!int inChanged;
    @Property("inChanged") int inValue = 0;
    @Slot void fromQml(int v) { g_received = v; }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    qmlRegisterType!Backend("App", 1, 0, "Backend");

    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/register.qml");   // served by the linked AOT unit — no .qml source present

    assert(g_received == 42, "AOT: precompiled qml unit failed to drive the D round-trip");
    writeln("qml OK: qmlcachegen AOT bytecode (no .qml source shipped) drove D @Property + @Slot (received=",
        g_received, ")");
}
