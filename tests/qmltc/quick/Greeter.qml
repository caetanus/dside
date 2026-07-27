import QtQml
// A local .qml-defined type (a fresh QtObject), used as a child by QUsesLocal.qml.
QtObject {
    property string hello: "hi"
    property string msg: hello + "!"
}
