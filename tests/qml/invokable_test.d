// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A D METHOD THAT RETURNS, CALLED FROM QML.
//
// `@Slot` cannot carry this: Qt draws the line at the return type, and QMetaObject's own
// invokeMethod refuses Q_RETURN_ARG on a method declared void. `@Invokable` declares the return to
// the meta-object and marshals it back, which is what makes a QML function that returns a value
// reachable from the engine at all.
//
// The check is on the VALUES, not on the call: a return that is declared and then discarded looks
// exactly like one that works, and is what this replaces.
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, qrc, cxxrt, std.stdio;
import appctor : QCOREAPP_CTOR;
pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("invokable.qrc"), "qt.qml"));

__gshared int g_num = -1;
__gshared string g_str = "";

@QObject class Backend {
    @Invokable int twice(int v) { return v * 2; }
    @Invokable string shout(string s) { return s ~ "!"; }
    @Slot void report(int n, string s) { g_num = n; g_str = s; }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    qmlRegisterType!Backend("App", 1, 0, "Backend");
    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/invokable.qml");

    assert(g_num == 42, "@Invokable int: QML read back " ~ g_num.stringof);
    assert(g_str == "ok!", "@Invokable string: QML read back '" ~ g_str ~ "'");
    writeln("invokable OK: QML called D methods that RETURN — int 21->", g_num,
            " and string 'ok'->'", g_str, "'");
}
