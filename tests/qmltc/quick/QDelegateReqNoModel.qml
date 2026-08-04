// The boundary the engine draws around the per-item context, in the case where it takes it AWAY.
//
// Declaring required properties turns the context injection off. This delegate declares one -- and
// not `model` -- so the engine has neither an injected `model` nor a context to ask: indexing
// `undefined` throws, the binding produces nothing, and `objectName` stays empty.
//
// The compiler has to refuse the read for the same reason, and then both sides are empty and agree.
// Reading the context anyway would invent a value the engine does not have, which is what this file
// exists to catch: without the refusal ours says "n0" against the engine's "".
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    property string key: "index"
    Repeater {
        model: 2
        delegate: Item {
            required property int index
            objectName: "n" + model[root.key]
        }
    }
}
