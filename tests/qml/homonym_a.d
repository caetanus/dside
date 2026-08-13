// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
module homonym_a;   // defines `Dup` — SAME T.stringof as homonym_b.Dup, DIFFERENT shape
import qtmoc;
__gshared int a_hit = -1;
@QObject class Dup {
    Signal!int alphaCh;
    @Property("alphaCh") int av = 0;
    @Slot void alphaSlot(int v) { a_hit = v; }
}
