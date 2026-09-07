// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATE'S `required property` FILLED FROM A LIST OF OBJECTS.
//
// The per-item context carries a model's roles by name for a QAbstractItemModel; for a plain list
// of objects it carries `modelData` — the element itself — and the keys are on that. So a delegate
// written `required property string t` over a list of maps found nothing under `t` and kept its
// default. Measured on a real reader: every row of a paginated page came out with an empty string
// and a number of 0, so the text was there and invisible and every row believed it was the chapter
// title. The engine fills these itself, which is why only the compiled side was wrong — and why
// only a differential could see it.
//
// The fill now asks in the order the engine resolves it: the context first, then the element's own
// key.
//
// `joined` is on the ROOT because that is what the differential compares, and it carries BOTH
// fields of both rows: a fill that answered the number and not the string would still pass a
// fixture that read one of them.
import QtQuick 2.15
Item {
    id: root
    width: 60; height: 20
    property string joined: ""
    // The Repeater sits inside a Row so its items are the ROW's children: as a direct child of
    // the root they become `data[0]`/`data[1]` on the oracle's side and have no label on ours,
    // and the differential refuses the document over the paths rather than comparing the value.
    Row {
        Repeater {
            model: [ { n: 1, t: "um" }, { n: 2, t: "dois" } ]
            Item {
                required property int n
                required property string t
                Component.onCompleted: root.joined += n + ":" + t + " "
            }
        }
    }
}
