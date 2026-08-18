// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A model role read by NAME. Every Qt Control that shows a model writes its label this way --
// `text: model[control.textRole]` on a ComboBox delegate, `control.model[control.headerView.
// textRole]` on a HeaderView, `model.day` on a MonthGrid -- and all of them were refused with
// "expression for 'string'". The roles are PROPERTIES of the object the per-item context carries,
// so this is the meta-object channel again: a property read by name, nothing type-specific.
//
// `index` is one of those properties, which is why it can stand in for a role here: a plain int
// model needs no ListModel (not a bound type in this binding) and exercises the identical read.
//
// Every value compared is a STRING. As an int, item 0's index and a read that found nothing are
// both 0 -- the trap that hid a delegate having no context at all for the whole life of the
// feature. Concatenated, "v0" and a bare "v" cannot be confused.
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    Repeater {
        model: 2
        delegate: Item {
            id: cell
            objectName: "v" + model["index"]          // a BASE property of the delegate root
            property string mine: "r" + model["index"] // a DECLARED property of the delegate root
            // ...and read back out of the CHILD, so the child's own binding is compared too
            property string kidText: kidLabel.text
            // ...and the LITERAL-name spelling on a DECLARED property, which is a different
            // dependency consumer from the base-property one above -- there are three, and a rule
            // that lands in only some of them makes the same read live on one and dead on another.
            // What is NOT tested here is that liveness: nothing in this document can change a role,
            // so only the value is compared.
            property string dotName: "d" + model.index
            Text {
                id: kidLabel
                text: "kid-" + model["index"]
            }
        }
    }
}
