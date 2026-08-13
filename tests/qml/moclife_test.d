// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Side-table lifetime: creating a moc object registers it in g_moAttach (C++) and _reg (D);
// destroying the QtdMocObject must drop BOTH (round-5 #5 — cleanup for the non-QML path too,
// not only QML-created instances). Proves the destructor closes the side-table.
import qtmoc, cxxrt, std.stdio;

extern (C) size_t qtd_moc_attach_count() nothrow;
extern (C) void qtd_moc_delete(void* o) nothrow;

@QObject class Hub {
    Signal!int changed;
    @Slot void onValue(int v) { changed.emit(v); }
}

void main() {
    auto base = qtd_moc_attach_count();
    auto h = newQObject!Hub();
    auto qobj = qobjOf(h);
    assert(qobj !is null, "qobjOf resolves the live object");
    assert(qtd_moc_attach_count() == base + 1, "creation registered one side-table entry");

    qtd_moc_delete(qobj);   // ~QtdMocObject -> clears g_moAttach + _reg

    assert(qtd_moc_attach_count() == base, "destroy cleaned g_moAttach");
    assert(qobjOf(h) is null, "destroy cleaned the D _reg (qobjOf now null)");
    writeln("moc lifetime OK: destroying a newQObject moc object clears g_moAttach + _reg");
}
