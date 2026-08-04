// A delegate's CHILD reads the per-item context. `index` and `modelData` belong to no object the
// document names — the view publishes them on the per-item QQmlContext — and only the delegate's
// ROOT was given that context: its children got the document's, where those names do not exist.
//
// Qt's own Controls need exactly this. Every `text: model[control.textRole]` in a ComboBox or a
// HeaderView is written on the delegate's contentItem, not on its root, which is why fifteen of the
// diagnostics across both style corpora are that one shape.
//
// The child's text is what carries it: with the context inherited it reads the item's index, and
// without it reads nothing at all.
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    Repeater {
        model: 2
        delegate: Item {
            id: cell
            // An int cannot carry the answer: item 0's index IS zero, and so is a lookup that
            // found nothing. Concatenated into a string it can — "r0" against a bare "r".
            objectName: "o" + index   // the ROOT, on a BASE property (the path CDelegate proves)
            property string mineText: "r" + index

            // ...read back OUT of the child, so the comparison sees what the child computed. Without
            // it the child's `text` sits on no path either side dumps and the test cannot fail.
            property string kidText: kidLabel.text
            Text {
                id: kidLabel
                // ...the CHILD, one level below the delegate root
                text: "kid" + index
            }
        }
    }
}
