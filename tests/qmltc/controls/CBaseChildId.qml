// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A BASE property bound to an object literal that carries an `id`. Three kinds of child can hold
// one -- a DEFAULT child, a DECLARED property's, and a BASE property's -- and only the first two
// were pre-scanned, so `contentItem: Item { id: kid }` followed by any read of `kid.<prop>` was
// refused with the same "expression not supported" the other two kinds used to give.
//
// Two reads are compared, because the second was the one that led here: a plain property through
// the id, and an ATTACHED property on the object the id names -- whose type-name spelling
// (`Window.width`) already compiled while the object spelling did not.
import QtQuick
import QtQuick.Templates as T
T.Control {
    id: control
    width: 100; height: 40
    contentItem: Item { id: kid; objectName: "the-kid" }
    // A NAME, not a size: a Control resizes its contentItem during layout, so `kid.width` is 1 on
    // both sides by the time the dump runs and a refusal would look identical to a working read.
    property string kidName: kid.objectName
    // With no window there is no attached object, so this is 0 on both sides: what it carries is
    // that the read COMPILES at all, which is the half that led here.
    property int wndWidth: kid.Window.width
}
