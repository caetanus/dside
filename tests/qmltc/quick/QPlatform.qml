// `Qt.platform.pluginName` — the third QML global with no QObject behind it, after the colour
// helpers and `Qt.styleHints`. Nothing in the meta channel reaches it, so the runtime returns what
// the engine returns there: QGuiApplication::platformName().
//
// It is also a CONSTANT for the life of the process — the platform does not change under a running
// application — so it must not be recorded as a dependency, which is the other half of this and the
// half that would otherwise report a dead one on an object called `Qt`.
//
// Qt's own context menus pick their popup type with it (`Qt.platform.pluginName !== "wayland"`), so
// this is a prerequisite for compiling those; the comparison here is the value itself, which under
// the test environment is "offscreen" on both sides and would be whatever the platform is elsewhere.
import QtQuick
Rectangle {
    width: 20; height: 20
    property string plat: Qt.platform.pluginName
    property bool notWayland: Qt.platform.pluginName !== "wayland"
    property string combined: "on " + Qt.platform.pluginName
}
