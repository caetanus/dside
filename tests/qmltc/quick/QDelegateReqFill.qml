// The MIRROR IMAGE of the per-item context, and the reason a required property cannot be filled
// from it. Measured, both halves in this one file:
//
//   ours   `index` (DECLARED here) is NOT in our context; `modelData` (not declared) IS
//   engine  the opposite -- it withheld the context because the delegate declares required
//           properties, and injected `index` straight onto the item
//
// So in a delegate that declares required properties, a bare context name is either a value the
// engine does not have (undeclared: `modelData` reads undefined and the binding throws) or one we
// cannot see (declared: it left our context). Reading it invents an answer either way, and the
// compiler refuses it -- which is what makes both sides agree on the empty string below.
//
// `index` is an INT here and is NOT what this file measures: the engine injects 0 and our unwritten
// field reads 0, so the two agree by accident. It is declared only to put the delegate on the
// required side of the boundary. As a string it exposes the other half of the finding -- the engine
// says "0" and we say "" -- and that half has no fix through the context, by the measurement above:
// a name the type declares is exactly a name our context no longer has.
import QtQml 2.15
import QtQuick 2.15
Item {
    width: 100; height: 40
    Repeater {
        model: 2
        delegate: Item {
            required property int index
            objectName: "m" + modelData   // refused: the engine has no `modelData` here
        }
    }
}
