// The THIRD construction phase. The engine gives a bound type classBegin(), then componentComplete()
// once the tree is built, and then — from QQmlComponent::completeCreate() — QQmlFinalizerHook::
// componentFinalized(), once the WHOLE component is finalized. A TableView does all of its work
// there: nothing in QQmlParserStatus stands in for it, and calling componentComplete() twice with an
// event-loop turn in between changes nothing (both measured).
//
// The observables below are the ones that stay at TableView's "not computed" sentinel without it:
// `rows` and `columns` are -1, `contentWidth` and `contentHeight` are -1, and `model` is unset. With
// the hook they are the engine's 1/0/0/0 — which is what this fixture compares.
//
// The interface is not a per-type mechanism and is not hard-coded anywhere: the registry publishes
// it (`interfaces: ["QQmlFinalizerHook"]` on QQuickTableView), Q_INTERFACES puts it in the
// meta-object, and the runtime finds it by IID for whatever type has one.
import QtQuick
Item {
    width: 100; height: 40

    TableView {
        id: tv
        width: 100; height: 40
    }

    // -1 on both sides would compare EQUAL and prove nothing, so each is read as its own property:
    // a regression puts the sentinel back and every one of these changes at once.
    property int rowCount: tv.rows
    property int colCount: tv.columns
    property real cw: tv.contentWidth
    property real ch: tv.contentHeight
    // ...and the derived form, so a wrong value cannot hide behind a matching pair.
    property bool computed: tv.rows >= 0 && tv.columns >= 0
}
