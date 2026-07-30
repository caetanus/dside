// qmlRegisterType: a D @QObject registered as a QML ELEMENT, instantiated from QML.
// Unlike backend_test (a D object injected via setContextProperty), here QML itself
// creates the D type — `Backend { inValue: 21 }` — driving a D @Property (WriteProperty)
// and a D @Slot (InvokeMetaMethod) on the QML-owned instance.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, qrc, cxxrt, std.stdio;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("register.qrc"), "qt.qml"));

// The QML-created instance is owned by the engine, not the test — observe the round-trip
// through a module global the @Slot writes.
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

    qmlRegisterType!Backend("App", 1, 0, "Backend");   // now `import App 1.0; Backend {}` works

    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/register.qml");

    // register.qml: Backend { inValue: 21; Component.onCompleted: fromQml(inValue*2) }
    assert(g_received == 42,
        "qmlRegisterType: QML-instantiated D type failed to drive @Property + @Slot");
    writeln("qml OK: qmlRegisterType!Backend -> QML `Backend { inValue: 21 }` drove D @Property + @Slot (received=",
        g_received, ")");
}
