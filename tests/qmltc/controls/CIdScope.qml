// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// `id` is not a property and does not OVERRIDE. Splicing a local type's body into its use site
// merges two documents' scopes, and the dedup that makes the use site win for a real property was
// dropping the definition's `id` as well. The object then answered only to the use-site name, so a
// binding written in the DEFINITION resolved its own `control` to whatever the enclosing document
// called `control` — which in Qt's Controls is always the enclosing control. Measured on Qt's own
// TextField with the attached gate open: `Menu.qml`'s `model: control.contentModel` compiled to
// `__outer.__outer` (the TextField, which has no contentModel), so the menu's ListView never got a
// model and nothing under it was laid out.
//
// Both halves are read here, and they must disagree: `fromDefn` is written in the inner document
// and means the inner object; `fromUse` is written HERE and means this one. A fix that makes the
// definition's id win everywhere breaks the second, which is why both are in the fixture.
T.Button {
    id: control
    property string who: "outer"

    background: CIdScopeInner {
        id: panel
        fromUse: control.who
    }
}
