// Reading a QML singleton's properties. qmltc-d compiles the singleton as its own class plus a
// lazy one-instance accessor, so `SingletonFixture.integerProperty` is an ordinary read.
import QtQml 2.15
import "."
QtObject {
    property int number: SingletonFixture.integerProperty
    property string message: SingletonFixture.stringProperty
    property int doubled: SingletonFixture.integerProperty * 2
}
