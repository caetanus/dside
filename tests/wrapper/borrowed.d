// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A POINTER QT HANDED BACK IS NOT OURS TO DELETE.
//
// `QThread.currentThread()` compiles to `QThread.wrap(__QThread_1())`, and the current thread has
// no Qt parent and is not the application singleton — the two questions the finalizer used to ask
// before scheduling a deleteLater. So dropping the D reference to a GETTER's result asked Qt to
// delete the running thread. Qt documents that deleting a running QThread crashes, and it does:
// the backtrace is QThreadPrivate::finish -> QThread::~QThread from the deleteLater event.
//
// This is the regression test for that, and it has to force each step rather than hope for it:
// drop the reference, collect, then RUN THE EVENT LOOP, because deleteLater is a posted event and
// nothing happens until it is delivered.
//
// `QThreadPool.globalInstance()` is the same shape through a different API, and it is here because
// a fix keyed on one class name would pass with only the first.
import qt.widgets.qthread;
import qt.widgets.qthreadpool;
import qt.widgets.qcoreapplication;
import qt.widgets.qapplication;
import cxxrt;
import core.memory : GC;
import std.stdio : writeln;

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);

void* takeThread() { auto t = QThread.currentThread(); assert(t.isRunning()); return t.ptr(); }
void* takePool()   { auto p = QThreadPool.globalInstance(); return p.ptr(); }
void clobberStack() { ubyte[8192] junk = 0xAB; foreach (ref b; junk) b = cast(ubyte)(b ^ 1); if (junk[0] == 7) writeln(junk[1]); }

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "borrowed\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    // In functions of their own, and the frame overwritten afterwards: D's collector scans the
    // stack CONSERVATIVELY, so a dead slot still holding the pointer keeps the wrapper alive and
    // the finalizer never runs. The first version of this test passed for exactly that reason —
    // it proved nothing, because nothing was collected.
    auto threadPtr = takeThread();
    auto poolPtr = takePool();
    clobberStack();
    GC.collect(); GC.collect(); GC.collect();
    // ...and DELIVER what was posted. Without this the test passes for the wrong reason — a
    // deleteLater that was scheduled and never ran looks exactly like one that never happened.
    QCoreApplication.processEvents(0);
    QCoreApplication.sendPostedEvents(null, 0);
    QCoreApplication.processEvents(0);

    // If the finalizer deleted them, the objects are gone and Qt has already crashed inside
    // ~QThread. Reaching here at all is most of the assertion; asking Qt again is the rest.
    assert(QThread.currentThread().ptr() is threadPtr,
           "the current thread changed identity — it was deleted and re-wrapped");
    assert(QThread.currentThread().isRunning(),
           "the current thread is no longer running: the binding deleted a borrowed object");
    assert(QThreadPool.globalInstance().ptr() is poolPtr,
           "the global thread pool changed identity — it was deleted and re-wrapped");

    writeln("borrowed OK: a pointer Qt returned survives the GC — currentThread() and ",
            "globalInstance() are still alive and unchanged");
}
