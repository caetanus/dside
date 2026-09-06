// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A MODEL BUILT ON THE D SIDE, read the way a delegate should read one.
//
// The rows are a QVariantList of QVariantMap — which is what a QML view already accepts, with no
// QAbstractListModel and no roles to register. Every field crosses on its own path — QString,
// qlonglong, double, bool — so a document that read one of them back would pass with three broken.
//
// READ THROUGH `modelData`, WHICH IS THE SPELLING BOTH QT MAJORS SUPPORT. `required property int
// number` is what this compiler can COMPILE (docs/qmltc-d-good-practices.md §5.2) and it is Qt 6
// only: measured here, the same document reads every value back on Qt 6.11 and leaves all four
// undefined on Qt 5.15, because filling a delegate's required properties from the model arrived
// with Qt 6. This test is about the model crossing from D, so it uses the portable spelling and the
// manual carries the version note.
//
// EACH ROW REPORTS ITSELF. The first version accumulated into a property here and had the root
// report it when the count changed, which passed on Qt6 and read back empty on Qt5: the delegates
// are completed after that handler there. That was a RACE IN THE TEST, and it is worth separating
// from the version difference above — the first hid the second.
import QtQml 2.15
QtObject {
    id: root
    property Instantiator inst: Instantiator {
        model: backend.rows
        delegate: QtObject {
            Component.onCompleted: backend.row(modelData.number, modelData.text, modelData.weight, modelData.marked)
        }
    }
}
