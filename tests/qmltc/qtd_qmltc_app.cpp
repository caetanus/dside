// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A visual QtQuick type (QQuickText etc.) touches the font database the moment a property like
// `text` is set (updateLayout -> QFontMetrics), which fatals unless a QGuiApplication exists to
// bring up the platform integration. The qmltc-d differential ORACLE already builds one; the
// generated D `--dump` check needs the same. This tiny extern(C) hook the generated main calls
// for a bound visual root creates a (leaked, process-lifetime) QGuiApplication once.
#include <QGuiApplication>

extern "C" void qtd_qmltc_init_gui_app() {
    if (QGuiApplication::instance()) return;
    static int argc = 1;
    static char arg0[] = "qmltc-d";
    static char *argv[] = { arg0, nullptr };
    new QGuiApplication(argc, argv);
}
