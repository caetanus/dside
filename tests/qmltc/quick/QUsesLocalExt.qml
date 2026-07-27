import QtQuick
// (b) cross-file with USE-SITE EXTENSION: the local Greeter type is extended at the use site with
// an extra property + a binding that reads the local type's own property (hello). The compiled
// child class must carry BOTH Greeter.qml's members and the use-site's.
Item {
    width: 7
    Greeter {
        property string extra: hello + " there"
    }
}
