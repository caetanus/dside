// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A SECOND D type from the same registry — proving the type vocabulary is a table, not a
// special case. `reading` is a double property of the D base.
import AppTypes 1.0
Meter {
    reading: 2.5
    property double squared: reading * reading
}
