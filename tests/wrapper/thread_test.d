// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `new QThread` IS A QThread — one object, with a trampoline whose run() lands in D.
//
// Qt creates the OS thread; the trampoline attaches it to druntime on the way in, so inside run()
// D is ordinary D: TLS works, the GC knows the stack, an allocation is safe and a delegate can
// close over state. That is the whole trick — the interface is Qt's, the runtime is D's, and there
// is no second thread and no second object to keep in sync.
//
// Without the attach this is not a slow path but undefined behaviour: the first GC allocation on a
// thread the collector cannot see decides how it fails. So the body allocates on purpose.
import qt.widgets.qapplication, qt.widgets.qthread, qt.widgets.qtvirt;
import qtmoc, cxxrt;
import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.memory : GC;
import std.stdio : writeln;
import std.conv : to;

import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void* self, ref int, char**, int);

shared bool ran;
shared int  sum;
shared bool known;
__gshared string built;

@QObject class Worker {
    mixin QtdWidget!QThread;   // the same subclass trampoline every other bound base uses

    // Qt calls this on the thread IT created. Everything in here is D.
    void run() {
        // THE INVARIANT, asserted directly. An earlier version of this test checked symptoms —
        // TLS reads back, a GC allocation survives — and PASSED with the attach disabled, because
        // neither is reliably observable: TLS is real memory either way, and an allocation kept in
        // a __gshared slot is scanned no matter which thread made it. A test that cannot fail is
        // not evidence. `Thread.getThis()` is null on a thread druntime has never seen, full stop.
        atomicStore(known, Thread.getThis() !is null);

        // ...and then actually use the runtime, including a COLLECTION from this thread: stopping
        // the world enumerates the threads druntime knows about, which is the operation that has
        // no defined meaning when the caller is not one of them.
        int t = 0;
        foreach (i; 1 .. 101) t += i;
        built = "sum=" ~ t.to!string;
        GC.collect();
        atomicStore(sum, t);
        atomicStore(ran, true);
    }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "thread\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    auto w = new Worker();
    auto t = QThread.wrap(w.__qtdObj());
    t.start(QThread.Priority.InheritPriority);
    assert(t.wait(30_000), "the worker thread did not finish in 30s");

    assert(atomicLoad(ran), "run() never reached D");
    assert(atomicLoad(known), "druntime never saw the thread Qt created: Thread.getThis() was null "
                              ~ "inside run(), so D code there had no registered stack, no GC "
                              ~ "participation and no defined behaviour");
    assert(atomicLoad(sum) == 5050, "the D body computed " ~ atomicLoad(sum).to!string);
    assert(built == "sum=5050", "the GC allocation inside run() did not survive: " ~ built);

    writeln("thread OK: QThread::run() ran D code on Qt's thread — TLS, GC allocation and all");
}
