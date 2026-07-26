import QtQml
// Headless round-trip: binds to a D @Property, and on change calls a D @Slot.
QtObject {
    property int mirror: backend.inValue          // D property -> QML binding (ReadProperty)
    onMirrorChanged: backend.fromQml(mirror * 2)   // QML -> D slot (InvokeMetaMethod)
    Component.onCompleted: backend.fromQml(1)      // prove QML->D at load
}
