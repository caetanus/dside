// A COMPARISON whose operand is a model role. A comparison hands its operands no type -- what two
// values are compared as is their own business -- and a role is read through the meta-object, which
// needs the D type named at the call site. So `model.index === 1` gave the read nothing to be, and
// the whole binding was refused. The other operand knows: a literal 1 is an int.
//
// Qt writes this in both corpora: MonthGrid's `opacity: model.month === control.month ? 1 : 0`.
//
// The values are 0.25 and 0.75 rather than 0 and 1 so that a REFUSAL is visible: opacity defaults to
// 1, and a binding that never compiled leaves it there.
import QtQuick
Item {
    id: root
    width: 100; height: 40
    Repeater {
        model: 2
        delegate: Item {
            opacity: model.index === 1 ? 0.25 : 0.75
        }
    }
}
