// Adversarial qmlRegisterType (critics r6 #7): the happy-path test registered a SINGLE type and
// the "N types coexist" claim pointed at a throwaway probe. Here TWO DISTINCT D types are
// registered and BOTH instantiated from one .qml — proving distinct runtime metaobjects coexist
// (and exercising the shape-keyed buildMo cache: same-named-but-different types must NOT collide).
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, qrc, cxxrt, std.stdio;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("register_two.qrc"), "qt.qml"));

__gshared int g_alpha = -1, g_beta = -1;

@QObject class Alpha {                       // property `av` + slot recording to g_alpha
    Signal!int avChanged;
    @Property("avChanged") int av = 0;
    @Slot void report(int v) { g_alpha = v; }
}
@QObject class Beta {                        // DIFFERENT shape: property `bv` + a 2-arg-ish slot
    Signal!int bvChanged;
    @Property("bvChanged") int bv = 0;
    @Slot void note(int v) { g_beta = v; }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    qmlRegisterType!Alpha("App", 1, 0, "Alpha");
    qmlRegisterType!Beta("App", 1, 0, "Beta");
    qmlRegisterType!Alpha("App", 1, 0, "Alpha");   // repeated registration must not corrupt anything

    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/register_two.qml");   // instantiates BOTH Alpha and Beta

    // Alpha { av: 10; onCompleted: report(av*2) }  Beta { bv: 3; onCompleted: note(bv*2) }
    assert(g_alpha == 20, "Alpha instance drove its own @Property+@Slot");
    assert(g_beta == 6,   "Beta instance drove its own @Property+@Slot (distinct metaobject)");
    writeln("qml OK: two distinct D types registered + both instantiated from QML (alpha=",
        g_alpha, ", beta=", g_beta, ")");
}
