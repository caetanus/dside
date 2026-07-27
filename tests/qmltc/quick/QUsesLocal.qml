import QtQuick
// (b) cross-file: an Item root with a LOCAL type (Greeter, defined in Greeter.qml) as a default
// child. qmltc-d must resolve Greeter -> Greeter.qml and compile it as its own D class.
Item {
    width: 20
    Greeter {}
}
