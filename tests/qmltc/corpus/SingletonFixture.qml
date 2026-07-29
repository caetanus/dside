// A QML singleton: ONE instance, reached from another document by type name.
pragma Singleton
import QtQml 2.15
QtObject {
    property int integerProperty: 42
    property string stringProperty: "hello"
}
