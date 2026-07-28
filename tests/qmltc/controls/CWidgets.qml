// Several Controls at once, each configured and read back. A Control's properties come from a
// deep C++ chain (Control -> Item), so these compare members no document assigns as well.
import QtQuick.Templates
Pane {
    // hoverEnabled is deliberately NOT set: QQuickControl computes it in componentComplete(),
    // so it is the property that shows whether the compiler completes its objects the way the
    // engine does. It used to be pinned here because we did not call componentComplete at all.
    property CheckBox cb: CheckBox { id: chk; text: "on"; checked: true }
    property Slider sl: Slider { id: sld; from: 0; to: 10; value: 7 }
    property bool checkedMirror: chk.checked
    property real sliderPlus: sld.value + 1
}
