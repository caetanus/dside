// A .qml rooted in an APP-DEFINED type written in D (apptypes.Backend, exported by
// qmlRegisterType). Sets inherited properties and derives a new one from them.
import AppTypes 1.0
Backend {
    value: 21
    label: "hi"
    property int doubled: value * 2
}
