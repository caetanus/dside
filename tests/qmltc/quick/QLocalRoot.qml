import QtQuick
// (b) cross-file ROOT: a local Item-derived type (LocalBase) as the root, extended at the use site
// with a base prop (width) and a property reading the local type's own `base`. Compiled class must
// subclass QQuickItem and carry both LocalBase.qml's members and the use-site's.
LocalBase {
    width: 40
    property int extra: base + 1
}
