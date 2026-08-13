// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Real homonyms (critics r7 #3): two D classes with the SAME T.stringof ("Dup") from different
// modules, registered as distinct QML elements and BOTH instantiated. Proves buildMo keys the full
// SHAPE (name alone would collide -> BetaDup would inherit AlphaDup's metaobject and misfire).
import qt.qml.qcoreapplication, qt.qml.qqmlapplicationengine;
import qtmoc, qrc, cxxrt, std.stdio;
import a = homonym_a;
import b = homonym_b;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);
mixin(qrcRegister(import("homonym.qrc"), "qt.qml"));

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    qmlRegisterType!(a.Dup)("App", 1, 0, "AlphaDup");   // both T.stringof == "Dup"
    qmlRegisterType!(b.Dup)("App", 1, 0, "BetaDup");

    auto engine = new QQmlApplicationEngine();
    engine.load("qrc:/homonym.qml");

    assert(a.a_hit == 5, "AlphaDup drove its own slot (distinct metaobject despite same class name)");
    assert(b.b_hit == 7, "BetaDup drove its own slot");
    writeln("qml OK: two homonymous D types (both class `Dup`) got DISTINCT metaobjects (a=",
        a.a_hit, ", b=", b.b_hit, ")");
}
