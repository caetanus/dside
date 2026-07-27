// critics r8 #3: qmlRegisterType must give a type REAL identity. Two DISTINCT D types that happen
// to share T.stringof ("Dup", from different modules) registered under the SAME uri/name/version
// is a CONFLICT (throws) — not a silent "already registered" that drops the second type. And
// re-registering the SAME type under the same key stays an idempotent no-op.
import qt.qml.qcoreapplication;
import qtmoc, cxxrt, std.stdio;
import a = homonym_a;
import b = homonym_b;
pragma(mangle, "_ZN16QCoreApplicationC1ERiPPci") extern(C++) void __qcore_ctor(void*, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    // a.Dup claims App/Thing 1.0
    qmlRegisterType!(a.Dup)("App", 1, 0, "Thing");

    // the SAME type + key again: idempotent no-op (must NOT throw, must NOT re-consume a pool slot)
    qmlRegisterType!(a.Dup)("App", 1, 0, "Thing");

    // b.Dup is a DIFFERENT D type (distinct mangleof) — under the SAME public key it is a conflict.
    bool threw = false;
    try qmlRegisterType!(b.Dup)("App", 1, 0, "Thing");
    catch (Exception e) { threw = true; }
    assert(threw, "distinct homonym under same uri/name/version must throw, not silently no-op");

    // ...but b.Dup under a DIFFERENT name registers fine.
    qmlRegisterType!(b.Dup)("App", 1, 0, "Other");

    writeln("qml collision OK: same-type re-register is a no-op; distinct homonym on same key threw");
}
