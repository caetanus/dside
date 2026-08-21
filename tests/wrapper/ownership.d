// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// CRITICS #5 — ownership invariants: where a binding dies in production.
// The GC wrapper's whole reason to exist is that a C++-destroyed object must NOT dangle.
// This isolates that contract (wraptest covers identity/pins/orphan-GC; this covers
// destruction): a C++ delete invalidates the D wrapper via destroyed(), and use-after-
// destruction THROWS (checkAlive) instead of segfaulting.
import qt.core.qobject, qt.core.qcoreapplication;
import holder, cxxrt, std.stdio;

import appctor : QCOREAPP_CTOR;
pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcoreapp_ctor(void* self, ref int, char**, int);

enum DeferredDelete = 52;   // QEvent::DeferredDelete — deleteLater posts this; we flush it

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "own\0".ptr, null];
    auto raw = __cpp_new(__QCoreApplication_size);
    __qcoreapp_ctor(raw, argc, argv.ptr, 0);   // an event system so deleteLater actually fires
    cast(void) QCoreApplication.wrap(raw);

    // (1) C++ destroys the object while the D wrapper is still held.
    auto victim = new QObject();
    auto cptr = victim.ptr();
    assert(holder.find(cptr) is victim, "identity before destruction");
    victim.deleteLater();
    QCoreApplication.sendPostedEvents(null, DeferredDelete);   // Qt deletes it -> destroyed()

    // destroyed() must have nulled _cpp and dropped the holder entry.
    assert(holder.find(cptr) is null, "wrapper invalidated + unregistered after C++ destruction");

    // (2) Use-after-destruction: MUST throw (checkAlive), not segfault.
    bool threw = false;
    try { cast(void) victim.objectName(); } catch (Throwable) { threw = true; }
    assert(threw, "use of a destroyed object must throw, not dangle");

    // (3) A parented child dies WITH its parent (Qt owns it), and its wrapper is invalidated
    // too — no double-free, no dangling child.
    auto parent = new QObject();
    auto child = new QObject(parent);      // parented -> Qt-owned, pinned
    auto childCptr = child.ptr();
    assert(holder.find(childCptr) is child, "child identity");
    parent.deleteLater();
    QCoreApplication.sendPostedEvents(null, DeferredDelete);
    assert(holder.find(childCptr) is null, "parented child invalidated when parent destroyed");
    bool childThrew = false;
    try { cast(void) child.objectName(); } catch (Throwable) { childThrew = true; }
    assert(childThrew, "use of a destroyed child must throw");

    writeln("ownership OK: C++ destruction invalidates the wrapper (self + parented child); "
        ~ "use-after-destruction throws");
}
