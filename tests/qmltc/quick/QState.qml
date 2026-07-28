// States: `state: "big"` selects a State whose PropertyChanges override properties of a target.
// The engine applies it at creation, so the effect is observable statically — no animation, no
// timing. Compiled as DATA (like Connections), not as objects: a State is not something the
// document reads back, it is a table of overrides.
import QtQuick
Item {
    id: root
    width: 100
    property int tag: 1
    state: "big"
    states: State {
        name: "big"
        PropertyChanges { target: root; width: 300; tag: 7 }
    }
}
