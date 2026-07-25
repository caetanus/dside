// app.d — proves the native meta-object round-trip QML <-> D, headless.
module app;

import qt.qml.qguiapplication;
import qt.qml.qqmlapplicationengine;
import metaobj;
import backend;
import std.string : toStringz;
import std.stdio : writeln;

int main(string[] args) {
    int argc = 1;
    char*[2] argv = [cast(char*) toStringz("mob"), null];
    auto app = new QGuiApplication(&argc, argv.ptr);
    scope (exit) app.dispose();

    // No __gshared needed: setup()'s scoped GC pin keeps `g` alive for Qt's
    // callbacks and releases it when the QObject is destroyed.
    auto g = new Backend();
    g.setup();
    g.count = 10;

    auto engine = new QQmlApplicationEngine();
    scope (exit) engine.dispose();

    // setContextProperty BEFORE load so the QML sees `backend`.
    qtd_ctx_set_object(engine._h, "backend", g.obj);
    engine.load(args.length > 1 ? args[1] : "ui.qml");

    auto roots = engine.rootObjects();
    assert(roots.length == 1, "QML failed to load");
    void* root = roots[0];

    // 1) D property -> QML binding
    int m0 = qtd_obj_read_int(root, "mirror");
    writeln("mirror (D count=10)          = ", m0);
    assert(m0 == 10);

    // 2) QML -> D slot  (bump() calls backend.increment())
    qtd_obj_invoke(root, "bump");
    writeln("backend.count after QML bump = ", g.count);
    assert(g.count == 11);

    // 3) D signal (countChanged) -> QML binding re-evaluates
    int m1 = qtd_obj_read_int(root, "mirror");
    writeln("mirror after notify          = ", m1);
    assert(m1 == 11);

    writeln("META-OBJECT ROUND-TRIP OK: QML<->D property, slot, signal — no moc");
    return 0;
}
