// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `property var` holds a QVariant: QML does not declare a static type for it. The value here is
// a literal, so the type IS known at compile time — which is the case worth compiling.
//
// LIMIT, stated rather than discovered later: the type comes from the INITIALISER. A var that
// changes type at runtime (QML allows it; a typed D field does not) or that holds an object or
// array is refused with "unsupported binding/type" instead of being guessed into a wrong type.
// Verified: `property var obj: ({a: 1})` and `property var arr: [1,2,3]` both fail the compile.
import QtQml 2.15
QtObject {
    property var n: 42
    property var s: "hello"
    property var b: true
    property var d: 2.5
    property int doubled: n * 2
    property string tagged: s + "!"
}
