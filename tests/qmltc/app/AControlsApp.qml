// AN APPLICATION USING QT'S CONTROLS, rather than one of Qt's styles defining them. The compiler
// meets `Button`/`Label`/`Slider` as public types with a style already resolved behind them —
// which is the position every real app is in and the exact inverse of the styles corpus.
import QtQuick
import QtQuick.Controls
Item {
    id: root
    width: 240; height: 110
    property int clicks: 0
    property real level: slider.value
    Column {
        spacing: 4
        Label { text: "level " + Math.round(root.level * 100) + "%" }
        Slider { id: slider; value: 0.35 }
        Button { text: "press"; onClicked: root.clicks += 1 }
        CheckBox { id: cb; text: "on"; checked: root.level > 0.2 }
    }
    property string summary: cb.checked ? "high" : "low"
}
