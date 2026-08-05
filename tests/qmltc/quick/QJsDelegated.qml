// A binding the compiler REFUSES, handed to the QML ENGINE instead of dropped.
//
// A member read by a name known only at RUN TIME is the shape that has no D translation at all:
// there is no property to name and no type to hold the result. It is also what every Qt Control
// that shows a model writes -- `control.model[control.headerView.textRole]` on a HeaderView
// delegate -- so the twelve refusals across both style corpora are this one expression.
//
// What is measured here is NOT that it compiles: it is that the value the engine computes for the
// delegated binding is the value the engine computes for the interpreted one. Both are compared as
// STRINGS, concatenated with a prefix, because an empty read and a read that found nothing are
// indistinguishable in any numeric slot -- the trap that hid a delegate having no context at all.
//
// The LIVE half matters as much as the first value: `key` is what decides which member is read, and
// the engine tracks that dependency itself (QQmlExpression::setNotifyOnValueChanged), which is the
// whole reason the fallback is a binding and not a one-shot. The `.set` sidecar drives it.
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    property string key: "alpha"
    property string alpha: "A"
    property string beta: "B"
    // ...on the ROOT's own base property, reading its own declared members by computed name.
    objectName: "r:" + root[root.key]
    Text {
        id: kid
        // ...and one level below, through the enclosing object -- the level Qt's Controls write it
        // at (the read sits on a Control's contentItem, not on the delegate root).
        text: "k:" + root[root.key]
    }
    property string kidText: kid.text
    // A compiled binding that deliberately does NOT depend on `key`. It is here to keep the
    // reactive half honest: while the compiler emitted `keyChanged` only where a COMPILED binding
    // asked for it, adding any binding on `key` was enough to make the delegated reads live -- and
    // a fixture that did that would have measured the engine's capture through a signal it created
    // itself. Nothing but the capture can move the two delegated bindings below.
    property string echo: "e:" + root.alpha
}
