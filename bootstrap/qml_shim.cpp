// qml_shim.cpp — implementation of the C ABI declared in qml_shim.h.
//
// Each function is a thin trampoline: cast the opaque handle back to the real
// Qt type and forward the call. This is the pattern the generator automates.

#include "qml_shim.h"

#include <QByteArray>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QString>
#include <QUrl>

extern "C" {

// QGuiApplication ----------------------------------------------------------
QtdApp qtd_app_new(int *argc, char **argv) {
    // QGuiApplication keeps a reference to *argc and to argv, so the caller
    // must keep both alive for the whole run (the D side does).
    return new QGuiApplication(*argc, argv);
}

void qtd_app_delete(QtdApp app) {
    delete static_cast<QGuiApplication *>(app);
}

int qtd_app_exec(QtdApp /*app*/) {
    return QGuiApplication::exec();
}

// QQmlApplicationEngine ----------------------------------------------------
QtdQmlEngine qtd_qmlengine_new(void) {
    return new QQmlApplicationEngine();
}

void qtd_qmlengine_delete(QtdQmlEngine engine) {
    delete static_cast<QQmlApplicationEngine *>(engine);
}

void qtd_qmlengine_load_data(QtdQmlEngine engine, const char *qml,
                             const char *base_url) {
    static_cast<QQmlApplicationEngine *>(engine)->loadData(
        QByteArray(qml), QUrl(QString::fromUtf8(base_url)));
}

int qtd_qmlengine_root_count(QtdQmlEngine engine) {
    return static_cast<int>(
        static_cast<QQmlApplicationEngine *>(engine)->rootObjects().size());
}

} // extern "C"
