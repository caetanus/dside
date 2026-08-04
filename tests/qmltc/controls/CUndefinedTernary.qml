// `undefined` is not a VALUE in QML: it RESETS the property to its default. The whole-value form
// (`x: undefined`) has compiled for a long time; inside a TERNARY it was refused -- and the refusal
// named the declared TYPE, `Qt::Alignment`, which sent the census looking at flags support that was
// never the problem. Qt's DialogButtonBox writes
// `alignment: count === 1 ? Qt.AlignRight : undefined`, and so does Dialog's footer.
//
// The condition is true so the VALUE branch runs: a refusal leaves the property at its default,
// which is exactly what the reset branch would produce, so only the value branch can fail. The dump
// compares `contentItem.alignment` on its own -- the enum crosses as its KEY, which is how every
// enum crosses this channel in both directions.
import QtQuick
import QtQuick.Templates as T
T.Control {
    id: root
    width: 100; height: 40
    contentItem: T.DialogButtonBox {
        id: on
        alignment: true ? Qt.AlignRight : undefined
    }
}
