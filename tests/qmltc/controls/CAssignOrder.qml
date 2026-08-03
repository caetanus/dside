import QtQuick
import QtQuick.Templates as T
// The ORDER between an object's own assignments and its children. The engine assigns everything
// written in the document body first and creates `background`, `contentItem` and `indicator` in
// componentComplete — they are DEFERRED properties (Q_CLASSINFO("DeferredPropertyNames", …) on
// QQuickControl and friends). Building the children first is observable, and what it shows is not
// the child but the number of times the PARENT made it re-lay out.
//
// This is Qt's CheckBox reduced to the two lines that matter: `spacing` is written after the
// contentItem in source order, and the contentItem's leftPadding reads it. Built child-first, that
// binding settles at 28 (spacing still 0), the Control sizes the text, and the later `spacing: 6`
// re-runs it to 34 — a second text layout, this time with a valid height, which moves
// `baselineOffset` from the engine's value to one 4.5 higher. The final leftPadding is 34 either
// way, so ONLY the baseline shows it: a fixture that compared leftPadding alone would pass while
// the defect stood, which is why the baseline is what this reads.
T.CheckBox {
    id: control

    // READ it, or it is not a recorded label and the comparison never looks at it. Checked: with
    // only the objects declared, the differential compared `leftPadding` (34 on both) and passed.
    property real contentBaseline: control.contentItem ? control.contentItem.baselineOffset : -1
    property real ownBaseline: control.baselineOffset

    padding: 6
    spacing: 6
    // NO `text`: with a non-empty one the two orders agree, because a Text with content re-lays
    // out on the width change either way and both sides end at the same baseline. The defect only
    // shows on the EMPTY text Qt's own bare CheckBox has — which is why the reduction that kept
    // `text: "order"` passed with the child-first order still in place (checked, not assumed).

    indicator: Rectangle { implicitWidth: 28; implicitHeight: 28 }

    contentItem: Text {
        text: control.text
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        leftPadding: control.indicator ? control.indicator.width + control.spacing : 0
    }
}
