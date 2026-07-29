import QtQuick
import QtQuick.Templates as T
// A CHILD OBJECT assigned to a member of an object group (`first.handle: Rectangle {}`, which is
// how Qt's Controls give a RangeSlider its handles). Scalar writes into such a group already
// worked; a child object did not, for no reason other than a gate that only knew about
// D-registered groups — the emission itself resolves the group with propObj at RUNTIME.
//
// implicitWidth is non-default (21, not 0), so the object being absent or unassigned shows.
T.RangeSlider {
    first.handle: Rectangle { objectName: "h1"; implicitWidth: 21; implicitHeight: 9 }
    second.handle: Rectangle { objectName: "h2"; implicitWidth: 13; implicitHeight: 7 }
}
