import QtQml
// Phase-9: a QML enum used in bindings.
QtObject {
    enum Color { Red, Green, Blue }
    enum Mode { Off = 10, On = 20 }
    property int c: Enums.Green
    property int m: Enums.On
    property int sum: Enums.Blue + Enums.On
}
