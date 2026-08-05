// A binding the compiler REFUSES, handed to the QML ENGINE instead of dropped -- on BOTH Qt5 and
// Qt6, which is why it lives in this corpus and not only in the QtQuick one.
//
// A member read by a name known only at RUN TIME has no D translation: there is no property to name
// and no type to hold the result. It is also the shape every Qt Control that shows a model writes
// (`control.model[control.headerView.textRole]`), so the twelve refusals across both style corpora
// are this one expression.
//
// What is measured HERE is the value: the delegated binding holds what the interpreted one holds,
// on both Qt versions. It is compared through `--dumpall`, which walks every property of both
// sides -- `objectName` is a base property, and the declared-property label protocol would never
// name it.
//
// The LIVE half is not measured here and cannot be: this binding runs against the QtQml-only
// registry, which carries no property rows at all, so no base property in reach has a notify the
// compiler can connect to and nothing in this document can observe a second value. It is measured
// on Qt6 by tests/qmltc/quick/QJsDelegated.qml, where the objects are real Items.
import QtQml 2.15
QtObject {
    id: root
    property string key: "alpha"
    property string alpha: "A"
    property string beta: "B"
    objectName: "r:" + root[root.key]
}
