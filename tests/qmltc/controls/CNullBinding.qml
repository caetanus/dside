import QtQuick
import QtQuick.Templates as T
// A BINDING THAT DEREFERENCES NULL WRITES NOTHING, and an unset `color` is OPAQUE BLACK.
//
// Two rules, one document, because both are about the value a property has when its binding never
// produced one — and both were found the same way, by judging -O1 over Qt's own Controls for the
// first time. Five of Qt's documents (Fusion's CheckIndicator, RadioIndicator, SliderGroove and
// ButtonPanel, Universal's CheckIndicator) disagreed with the engine on nothing else.
//
// `absent` is never assigned, so it is null — which is not a contrived state: it is exactly what an
// `impl` component's `control` is when the document is built on its own, and what any `parent`,
// model or window handle is before it is wired. In JS `null.x` THROWS, and the engine lets the
// throw abort the whole binding: the property keeps its default, and nothing is written. Our reads
// were null-tolerant and produced a value instead.
//
// `s1` is the decisive one. Had the expression merely evaluated to `undefined`, the engine would
// read "xundefined"; it reads "", so the concatenation never happened. `b1` is the opposite case
// and belongs here for it: `false` is both the aborted default AND what the tolerant read computed,
// so it agrees either way and made the defect look smaller than it was. Measured against the
// compiler as it stood before this document existed, four of these five differ (`bare` and `c1`
// #00000000 for #000000, `n1` 3 for 0, `s1` "x" for "") and `b1` does not.
//
// `bare` carries the second rule. QML's default for a `color` property is OPAQUE BLACK; a
// default-constructed QColor is INVALID, and the two print differently (#000000 against
// #00000000). It needs no binding at all to show, which is why it is the shortest line here.
T.Control {
    id: root
    property Item absent

    readonly property color c1: Qt.darker(absent.palette.text, 1.2)
    property string s1: "x" + absent.objectName
    property int n1: absent.width + 3
    property bool b1: absent.enabled && !absent.activeFocus

    property color bare
}
