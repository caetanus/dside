// app.d — the D side of the bootstrap hello world.
//
// Binds the C ABI from qml_shim.h via `extern(C)` and drives a QML window.
// No Qt headers, no C++ ABI, no libclang at build time — just plain D against
// a flat C interface. This is what a generated binding will look like.

module app;

import std.string : toStringz;
import std.algorithm : canFind;
import std.stdio : stderr, writeln;

// --- generated-binding surface (hand-written here; phase 1 will emit this) ---
extern (C) nothrow @nogc {
    void *qtd_app_new(int *argc, char **argv);
    void  qtd_app_delete(void *app);
    int   qtd_app_exec(void *app);

    void *qtd_qmlengine_new();
    void  qtd_qmlengine_delete(void *engine);
    void  qtd_qmlengine_load_data(void *engine, const(char) *qml, const(char) *baseUrl);
    int   qtd_qmlengine_root_count(void *engine);
}

// Inline QML for a self-contained binary. A real app loads a .qml file.
enum string helloQml = `
import QtQuick
import QtQuick.Window

Window {
    width: 420
    height: 200
    visible: true
    title: "Hello from D"
    Text {
        anchors.centerIn: parent
        text: "Olá, mundo — D + Qt6 QML"
        font.pixelSize: 22
    }
}
`;

int main(string[] args) {
    // QGuiApplication stores references to argc/argv — keep these locals alive
    // for the whole run (main outlives everything, so stack storage is fine).
    int argc = 1;
    char*[2] argv = [cast(char *) toStringz(args.length ? args[0] : "hello"), null];

    void *app = qtd_app_new(&argc, argv.ptr);
    scope (exit) qtd_app_delete(app);

    void *engine = qtd_qmlengine_new();
    scope (exit) qtd_qmlengine_delete(engine);

    // Empty base URL => synchronous, local load. A non-empty custom/network
    // scheme would make QQmlApplicationEngine load asynchronously.
    qtd_qmlengine_load_data(engine, helloQml.toStringz, "");

    if (qtd_qmlengine_root_count(engine) == 0) {
        stderr.writeln("error: QML failed to load (no root objects)");
        return 1;
    }

    // --selftest: prove QML parsed and the object tree was built, without
    // entering the event loop. Run headless with QT_QPA_PLATFORM=offscreen.
    if (args.canFind("--selftest")) {
        writeln("selftest OK: ", qtd_qmlengine_root_count(engine), " root object(s)");
        return 0;
    }

    return qtd_app_exec(app);
}
