// Several Controls at once, each configured and read back. A Control's properties come from a
// deep C++ chain (Control -> Item), so these compare members no document assigns as well.
import QtQuick.Templates
Pane {
    // hoverEnabled is set explicitly on BOTH controls, and that is a finding, not a convenience:
    // QQuickControl::componentComplete() computes it (calcHoverEnabled), and this compiler never
    // calls componentComplete — the engine calls it on every object it builds. Left to its
    // default the two sides disagree (engine true, ours false) for that reason alone. Pinning it
    // keeps the other 79 properties compared honestly; calling componentComplete is the fix, and
    // it matters beyond this property since Controls initialise themselves there.
    property CheckBox cb: CheckBox { id: chk; text: "on"; checked: true; hoverEnabled: true }
    property Slider sl: Slider { id: sld; from: 0; to: 10; value: 7; hoverEnabled: true }
    property bool checkedMirror: chk.checked
    property real sliderPlus: sld.value + 1
}
