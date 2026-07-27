import QtQml
// Phase-2 fixture: a self-referencing string binding (greeting depends on hello).
QtObject {
    property string hello: "Hello, World"
    property string greeting: hello + "!"
}
