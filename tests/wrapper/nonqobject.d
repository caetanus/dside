// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A NON-QObject THAT THE BINDING OWNS — the three states CRITICS round 12 #2 asks for.
//
// `QTreeWidgetItem` is not a QObject: no parent(), no destroyed(), nothing to ask afterwards. It is
// also allocated on the C++ heap by its generated constructor, so somebody has to free it. Until
// now nobody did — the finalizer only unregistered the wrapper and the object leaked.
//
// Ownership is therefore decided where the API moves it, never by asking later, and the three
// states are exactly the three answers that decision can have:
//
//   1. NOBODY TOOK IT       -> we still own it, so the finalizer frees it
//   2. QT TOOK IT           -> the transfer cleared ownership, so we must NOT free it
//   3. QT TOOK IT AND DIED  -> we never owned it, so we never touch the freed pointer
//
// State 3 is the one with no mechanism behind it and the reason the whole design is "declare the
// transfer" rather than "ask who owns me": by the time a finalizer could ask, the object it would
// have to ask may already be gone. Measured — destroying the tree leaves the wrapper's pointer
// non-null, so `checkAlive()` would not save anyone.
import qt.widgets.qapplication, qt.widgets.qtreewidget, qt.widgets.qtreewidgetitem;
import cxxrt, holder;
import core.memory : GC;
import std.stdio : writeln;

import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern (C) void qtd_qobject_delete(void* o) nothrow;

// A freed block is not observable from D, so the count of live wrappers stands in for it: the
// finalizer unregisters, and unregistering is the step that runs beside the delete.
extern (C) void* qtd_holder_find(void*) nothrow @nogc;
// ...and the count of blocks OUR shim freed. Unregistering happens whether or not anything was
// deleted, so the identity map alone cannot tell a freed object from a leaked one — the first
// version of this test asserted exactly that and would have passed with the deleter removed.
extern (C) void qtd_watch(void*) nothrow @nogc;
extern (C) int  qtd_watch_freed() nothrow @nogc;

// Own frames + a clobbered stack, or the collector's conservative scan keeps the wrapper alive and
// the finalizer never runs. A GC probe that cannot prove it collected proves nothing — this test's
// ancestor passed against an unfixed holder for exactly that reason.
void* makeOrphan() { auto i = new QTreeWidgetItem(0); return i.ptr(); }
void* makeAdopted(QTreeWidget t) { auto i = new QTreeWidgetItem(0); t.addTopLevelItem(i); return i.ptr(); }
void clobber() { ubyte[8192] j = 0xAB; foreach (ref b; j) b = cast(ubyte)(b ^ 1); if (j[0] == 7) writeln(j[1]); }

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "nonq\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    // 1. NOBODY TOOK IT. The wrapper owns the C++ object and the finalizer frees it; the wrapper
    //    leaves the identity map, which is the observable half of that.
    auto orphan = makeOrphan();
    assert(qtd_holder_find(orphan) !is null, "the orphan was not registered");
    qtd_watch(orphan);
    clobber(); GC.collect(); GC.collect();
    assert(qtd_holder_find(orphan) is null,
           "the orphan's finalizer never ran — the C++ object is still leaked");
    // ...AND THE BLOCK WAS FREED — where that is observable at all.
    //
    // On the Itanium ABI `delete p` calls the destructor and then the CALLER's `operator delete`,
    // so replacing it (qtd_watchfree.cpp) sees the free. The MS x64 ABI does it the other way
    // round: for a polymorphic type, `delete p` dispatches through vtable slot 0 to the vector
    // deleting destructor with the deleting flag set, and THAT function frees, inside the library
    // that defines the class. Disassembled from the shim this test exercises:
    //
    //     qtd_del_QTreeWidgetItem:
    //         movq (%rcx), %rax     ; the object's vptr
    //         movq (%rax), %rax     ; slot 0 — ??_GQTreeWidgetItem, in Qt6Widgets.dll
    //         movl $0x1, %edx       ; "and free the block"
    //         jmpq *%rax
    //
    // The free therefore happens inside Qt6Widgets.dll and no replacement in this binary can see
    // it — measured: every other delete in the run WAS observed, this address never was. So the
    // assertion is kept where the instrument can answer, and its absence is stated where it
    // cannot, rather than quietly passing on a check that did not run.
    version (Windows) {
        writeln("nonqobject: block-freed check skipped — the MS x64 ABI frees inside Qt's DLL");
    } else {
        assert(qtd_watch_freed() == 1,
               "the orphan was unregistered but its BLOCK was never freed — unregistering is not deleting");
    }

    // 2. QT TOOK IT. `addTopLevelItem` is declared as a transfer, so the wrapper stopped owning it
    //    at that call. The tree is still alive and must still have its item.
    auto tree = new QTreeWidget(null);
    auto adopted = makeAdopted(tree);
    clobber(); GC.collect(); GC.collect();
    assert(tree.topLevelItemCount() == 1,
           "the tree lost its item: the binding freed something Qt owns");
    assert(tree.topLevelItem(0).ptr() is adopted, "the tree's item is not the one we added");

    // 3. QT TOOK IT AND DIED. Destroying the tree deletes the item. We never owned it after the
    //    transfer, so nothing here frees it a second time — and nothing asks it anything either,
    //    which is the point: the question would be the use-after-free.
    qtd_qobject_delete(tree.ptr());
    clobber(); GC.collect(); GC.collect();

    writeln("nonqobject OK: unattached freed, transferred left alone, owner's death touches nothing");
}
