// The bare child lands on the base type's single-object `default property`, and is dumped under
// that property's name.
import QtQml
DefaultHolder {
    property string hello: "parent"
    QtObject {
        property string hello: "the default child"
        property int n: 5
    }
}
