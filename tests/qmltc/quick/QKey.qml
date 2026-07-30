import QtQuick
// KEYBOARD is its own axis, and the machinery under test is the FOCUS CHAIN plus the bound type's own
// C++ key handling — not a QML handler (`Keys.onPressed` with an arrow function is not compiled yet, so
// a fixture built on it would measure nothing). A TextInput consumes keys in C++: if the compiled object
// is focused and in a live scene, typing must change `text` exactly as it does under the engine. A
// document can be pixel-identical and click-correct and still never receive a key.
TextInput {
    width: 80; height: 24
    focus: true
    text: ""
}
