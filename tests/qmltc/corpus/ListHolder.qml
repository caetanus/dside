// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A `list<>` default property: bare children of a user go INTO the list, so the engine reaches
// them at an index, not through children().
import QtQml 2.15
QtObject {
    property string tag: "list holder"
    default property list<QtObject> items
}
