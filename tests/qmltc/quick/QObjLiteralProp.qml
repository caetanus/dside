// A declared property whose value is an object LITERAL. The child was built, parented and held in
// the field -- everything worked except being able to READ through it: the literal path recorded no
// type for the property, so it was not a path head and `probe.width` had nothing to resolve against.
//
// Qt's Fusion TreeViewDelegate is the case that names it: `property ColorImage arrow: ColorImage {}`
// and then `implicitWidth: Math.max(arrow.implicitWidth, 20)` on the indicator.
//
// `w` is what carries it: 33 with the read compiled, and the property's declared default (0)
// without -- and `probe` itself must be an object on both sides, which is the other half.
import QtQuick
Item {
    id: root
    width: 100; height: 40
    property Item probe: Item { width: 33; height: 11 }
    property real w: probe.width
    property real h: Math.max(probe.height, 20)   // ...and through a function, as Qt writes it
}
