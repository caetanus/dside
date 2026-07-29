import QtQuick
import QtQuick.Templates as T
// An OBJECT-valued property used as a TRUTH VALUE (`control.indicator ? ... : ...`), which Qt's
// own Controls use to guard padding. In QML that is a null test, and the object is fetched through
// the meta-object, so it needs no type knowledge. Only for a bool target — as a value the
// expression would be the object itself.
//
// `hasInd` is deliberately read from a control that HAS an indicator and one that does not, so the
// two branches are both exercised and a check that always answered the same way would show.
T.CheckBox {
    id: control
    indicator: Rectangle { objectName: "ind"; width: 12; height: 12 }
    property int padded: control.indicator ? 5 : 0
    property int unpadded: control.contentItem ? 7 : 1
}
