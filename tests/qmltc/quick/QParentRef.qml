// A child reading `parent.<prop>` — the centring idiom in Qt's own Controls
// (`x: (parent.width - width) / 2`). QQuickItem exposes `parent` as a Q_PROPERTY, so the OBJECT is
// fetched through the meta-object at runtime and nothing static is assumed about it; only the
// member's type comes from the enclosing frame. The .set mutates the parent's width, so a
// one-shot would keep the first value.
import QtQuick
Item {
    id: root
    width: 200
    height: 100
    Rectangle {
        objectName: "centred"
        width: 40
        x: (parent.width - width) / 2
        y: parent.height / 4
    }
}
