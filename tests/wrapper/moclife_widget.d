// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QtdWidget lifetime (critics r6 #1): the attached-subclass path (mixin QtdWidget!Base ->
// generated Qtd_<Base> trampoline + qtd_moc_attach) must ALSO clear the side-tables on
// destruction — the round-5 "all paths" claim was false; only ~QtdMocObject (newQObject) did.
// Now Qtd_<Base> has a destructor calling qtd_moc_detach. This test destroys the subclass and
// requires g_moAttach + _reg back to baseline.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qtvirt;
import qtmoc, cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern (C) size_t qtd_moc_attach_count() nothrow;
extern (C) void qtd_qobject_delete(void* o) nothrow;

@QObject class Hub {
    mixin QtdWidget!QWidget;
    Signal!int changed;
    @Slot void onValue(int v) { changed.emit(v); }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "mw\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    auto app = QApplication.wrap(raw);

    auto base = qtd_moc_attach_count();
    auto w = new Hub();
    assert(qtd_moc_attach_count() == base + 1, "QtdWidget subclass registered one g_moAttach entry");
    assert(qobjOf(w) !is null, "qobjOf resolves the live subclass");

    qtd_qobject_delete(w.__qtdObj());   // Qt-style delete -> ~Qtd_QWidget -> qtd_moc_detach

    assert(qtd_moc_attach_count() == base, "destroying the QtdWidget subclass cleaned g_moAttach");
    assert(qobjOf(w) is null, "destroying the QtdWidget subclass cleaned the D _reg");
    writeln("QtdWidget lifetime OK: destroying the attached subclass clears g_moAttach + _reg");
}
