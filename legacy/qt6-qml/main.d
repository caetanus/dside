// main.d — Qt6 QML dashboard app built on the generated qt-dlang-gen binding.
module app;

import qt.qml.qguiapplication;
import qt.qml.qqmlapplicationengine;
import metaobj : qtd_ctx_set_object;
import backend;
import std.string : toStringz;

extern (C) void qtd_qml_screenshot_and_quit(void* engine, const(char)* path, int delayMs);

__gshared Dashboard dash;

int main(string[] args) {
    int argc = 1;
    char*[2] argv = [cast(char*) toStringz("qt6-dashboard"), null];

    auto app = new QGuiApplication(&argc, argv.ptr);
    scope (exit) app.dispose();

    dash = new Dashboard();
    dash.setup();
    dash.cpu = 42; dash.mem = 63; dash.net = 28; dash.counter = 7;

    auto engine = new QQmlApplicationEngine();
    scope (exit) engine.dispose();
    qtd_ctx_set_object(engine._h, "dash", dash.obj);   // expose D model to QML

    string qml = args.length > 1 ? args[1] : "ui.qml";
    engine.load(qml);

    // optional: `--shot <path>` -> grab window to PNG and quit
    foreach (i, a; args)
        if (a == "--shot" && i + 1 < args.length)
            qtd_qml_screenshot_and_quit(engine._h, args[i + 1].toStringz, 700);

    return QGuiApplication.exec();
}
