// A child declares an id, and the PARENT's bindings read the child's properties through it.
// Reactivity must follow: changing the child's property re-runs the parent's binding.
import QtQml 2.15
QtObject {
    id: root
    property QtObject kid: QtObject {
        id: inner
        property int n: 7
        property string who: "kid"
    }
    property int doubled: inner.n * 2
    property string label: "from " + inner.who
}
