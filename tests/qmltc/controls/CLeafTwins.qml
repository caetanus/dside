import QtQuick
import QtQuick.Templates as T
// TWO DEEP READS OF THE SAME PROPERTY NAME, through DIFFERENT owners, inside ONE binding.
//
// The innermost object's `total` reads `indicator.width` through the object that contains it AND
// through the one containing that. Everything the leaf-connection table used to key on is
// identical for the two: the receiver is `leaf`, the slot is one per BINDING (`__rc_total()`), the
// inner property is `indicator` and the signal is `widthChanged()`. Only the OWNER differs — and
// the owner was not in the key, so the second registration disconnected the first while both calls
// returned success.
//
// BOTH owners have to be OUTER ones. When one of them is `this`, the compiler also emits a direct
// `tryConnectMeta(propObj(this, "indicator"), "widthChanged()", ...)`, and that redundant edge
// carries the update even with the table entry gone — the defect is real and invisible. Three
// levels is the shallowest document where neither dependency has a second path home.
//
// The symptom is silent: `total` simply stops following one of the two. Nothing throws, nothing
// warns, and the frame is merely stale rather than wrong-looking. Hence a LIVE differential — the
// .set mutates each side separately, and a lost connection can only be seen after a change.
T.CheckBox {
    id: outerMost
    property real wA: 30
    property real wB: 40
    indicator: Rectangle { objectName: "indA"; width: outerMost.wA; height: 10 }
    contentItem: T.CheckBox {
        id: mid
        indicator: Rectangle { objectName: "indB"; width: outerMost.wB; height: 10 }
        contentItem: T.CheckBox {
            id: leaf
            property real total: mid.indicator.width + outerMost.indicator.width
        }
    }
}
