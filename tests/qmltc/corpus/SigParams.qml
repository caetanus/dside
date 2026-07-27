import QtQml
// Phase-10: a signal WITH parameters; the handler reads the argument.
QtObject {
    signal valueChanged(int v)
    signal named(string who)
    property int last: 0
    property string greeting: ""
    function fire() { valueChanged(42); named("Ada") }
    onValueChanged: { last = v }
    onNamed: { greeting = "hi " + who }
    Component.onCompleted: fire()
}
