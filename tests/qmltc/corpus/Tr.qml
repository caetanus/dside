// `qsTr` uses the .qml file's base name as its translation context, which is what the engine
// does — so the compiled call resolves against the same context. With no translator covering
// the string, Qt returns the source, exactly as QML does.
import QtQml
QtObject {
    objectName: qsTr("Hello World \n")
    property string greeting: qsTr("Hi") + "!"
}
