// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A GAP PROBE, NOT A TEST: this document is EXPECTED to differ from the engine, and the entry
// `repeater-sibling-position` in tests/expected-fails.json is what says so. The day it matches, that
// entry describes a world that no longer exists and expected-fails-run says so.
//
// THE DIFFERENCE: a positioner holding a Repeater AND a static sibling after it does not place the
// Repeater's items. The engine reports y = 0 and 10 for the two delegate instances; the compiled
// document reports 0 and 0.
//
// Narrowed to the three things it needs — remove any one and the document matches the engine:
//   * the container must be a POSITIONER (an Item matches);
//   * the delegate's root must have its height from a CHILD rather than set directly;
//   * a static sibling must follow the Repeater in the same positioner.
//
// The cause is visible in the generated order and is one of construction, not of layout: the
// Repeater is appended to the Column, then the sibling, and the Repeater's items are created only at
// `drainComplete` — so the sibling is in place before the items exist, where the engine has the items
// before the Column completes. Found 2026-09-12 by the differential of QInlineUseTwice, which needed
// two use sites of an inline component and therefore had a static sibling after a Repeater; that
// fixture now uses an Item so it fails for its own reason only.
import QtQuick

Item {
    id: root
    property var rows: [1, 2]

    component Head: Item { property bool open: true; width: 10; height: 10 }

    Column {
        Repeater {
            model: root.rows
            delegate: Column { id: sect; Head { open: sect.height > 0 } }
        }
        Head { }
    }
}
