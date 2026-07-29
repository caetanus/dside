import QtQuick
import QtQuick.Templates as T
// A scalar read THROUGH an object-valued property (`control.indicator.width`). The inner object
// does not exist while the wire runs, so its connect goes to a LATE phase that the root fires once
// the whole tree is complete. Connecting to indicatorChanged instead would only fire when the
// indicator is REPLACED, leaving the binding silently stale when its width changes — which is
// exactly what the .set does.
//
// The result lands in a DECLARED property on purpose: binding a contentItem's own width instead
// measures Qt's Control layout (a Control manages its contentItem geometry), not this feature.
T.CheckBox {
    id: control
    indicator: Rectangle { objectName: "ind"; width: 30; height: 10 }
    property real mirror: control.indicator.width + 5
}
