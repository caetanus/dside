// A QObject-derived QML type held in a PROPERTY. The child must be built as its BOUND type, not
// as a bare @QObject — otherwise setting a member creates a Qt dynamic property and the object is
// not really a FontMetrics at all. `bold` is set here; `font` and the metrics it derives are the
// type's own, so the comparison covers members the document never assigns.
import QtQuick
Item {
    property FontMetrics fm: FontMetrics { }
    property int own: 12
}
