// grab_qt6.cpp — self-screenshot helper: after a delay, grab the QML window to
// a PNG and quit. Lets the app produce a clean, deterministic screenshot.
#include <QGuiApplication>
#include <QImage>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QString>
#include <QTimer>

extern "C" void qtd_qml_screenshot_and_quit(void *engine, const char *path, int delayMs) {
    auto *e = static_cast<QQmlApplicationEngine *>(engine);
    QString out = QString::fromUtf8(path);
    QTimer::singleShot(delayMs, [e, out]() {
        for (QObject *o : e->rootObjects()) {
            if (auto *w = qobject_cast<QQuickWindow *>(o)) {
                QImage img = w->grabWindow();
                if (!img.isNull()) img.save(out);
                break;
            }
        }
        QGuiApplication::quit();
    });
}
