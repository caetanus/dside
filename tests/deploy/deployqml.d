// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// THE OTHER HALF OF A DEPLOYMENT, and the half the widgets application cannot exercise.
//
// A QML application needs things no linker and no `import` line records: the module directories the
// engine resolves at run time, the plugin `.so` inside each of them, and — this is the one that
// bites — the Qt modules that arrive through THOSE plugins rather than through the executable.
// `libqtquick2plugin.so` brings Qt6QmlWorkerScript with it, so a tool that collected plugins before
// it had finished walking what the QML modules dragged in would never go looking for that module's
// plugins at all.
//
// The document is LOADED from a file rather than built in D, because loading is what makes the
// engine resolve imports; a tree constructed in code would prove the bundle for a program nobody
// ships.
// One package: this binding's spec puts everything under `qt.quick`, which is a property of the
// spec and not of Qt — so the imports are written the way THIS binding lays them out.
import qt.quick.qqmlapplicationengine, qt.quick.qguiapplication, qt.quick.qurl, qt.quick.qstring;
import cxxrt, std.stdio;

mixin(qtdApplication!"QGuiApplication");

void main(string[] args) {
    cast(void) createApp("deployqml");   // Qt keeps it; nothing here needs the handle
    auto engine = new QQmlApplicationEngine();
    // An lvalue, because `load` takes `ref const(QUrl)`: a temporary does not bind to it.
    auto url = QUrl.fromLocalFile(args.length > 1 ? args[1] : "app.qml");
    engine.load(url);
    // An empty root-object list means the document did not load: a QML module the engine could not
    // resolve, a plugin it could not open, a scenegraph backend that is not there. Every one of
    // those is a hole in the manifest, and every one of them is silent unless it is asked about.
    if (engine.rootObjects().length == 0) {
        stderr.writeln("deployqml FAIL: the engine loaded no root object");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writeln("deployqml OK: the QML document loaded and produced a root object");
}
