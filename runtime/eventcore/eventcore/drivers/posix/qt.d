// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// QT AS EVENTCORE'S EVENT LOOP, so a program can draw with Qt and do its I/O with vibe-core's
// fibers in ONE thread without either loop polling the other.
//
// Two loops and one thread: only one of them can own the wait. Polling the second costs a wakeup
// per millisecond whether or not anything happened. So Qt owns the wait and every descriptor
// eventcore cares about is handed to Qt through a `QSocketNotifier` — Qt's own way of saying "tell
// me when this is ready". Nothing spins.
//
// WHY THIS MODULE IS NAMED INTO SOMEBODY ELSE'S PACKAGE. `PosixEventLoop` is `package`-protected,
// so only a module inside `eventcore.drivers.posix` may derive from it — which is also why
// eventcore's own CFRunLoop driver, the precedent for exactly this, lives in that tree. D's package
// protection is by module NAME, not by compilation unit, so a module shipped here and named there
// has the access without eventcore being vendored, forked or patched. Measured before it was
// written: a subclass compiles from this directory against an untouched eventcore 0.9.39.
//
// The overrides are PUBLIC and not `protected`, matching the epoll loop: eventcore's own
// sockets/events modules call `registerFD` on the loop from outside the class hierarchy, so a
// `protected` override compiles here and breaks there ("no property `registerFD` for `m_loop`").
//
// HOW IT IS SELECTED. Build eventcore with no driver version identifier (its `generic`
// configuration): `NativeEventDriver` is then the interface and `setupEventDriver()` installs one
// at run time. Add `EventcoreQtDriver` to compile this file. Nothing in eventcore changes.
module eventcore.drivers.posix.qt;

version (EventcoreQtDriver):

import eventcore.drivers.posix.driver;
import core.time : Duration, msecs;
import core.stdc.stdlib : malloc, free, realloc;

/// The C++ half lives in this project's shim (runtime/qtmoc/qtd_eventloop.cpp) and is declared
/// here and nowhere else: this file must not depend on the Qt BINDING, only on four C symbols.
private extern(C) @system @nogc nothrow {
    void* qtd_ec_notifier_new(int fd, int type, void function(void*, int) cb, void* ctx);
    void  qtd_ec_notifier_free(void* n);
    void  qtd_ec_notifier_enable(void* n, int on);
    int   qtd_ec_process(int msecs);
}

private enum QtRead = 0, QtWrite = 1;      // QSocketNotifier::Type

/// One registered (descriptor, readiness) pair. Allocated with malloc, not the GC: it is reached
/// from a C callback, and a GC-owned context reached only from C is a context that can be collected
/// under the loop.
private struct Watch {
    void* notifier;
    QtEventLoop loop;
    size_t fd;
    EventType kind;
}

final class QtEventLoop : PosixEventLoop {
@safe nothrow:
    private {
        // fd -> the two watches it may have. A flat array indexed by fd is what the descriptors
        // themselves already are; eventcore's own drivers index by fd the same way.
        Watch*[2][] m_watch;
        // What fired during the last wait, drained after it. The callback must NOT call notify()
        // itself: it runs inside Qt's dispatch, and notify() resumes fibers — re-entering Qt's loop
        // from inside its own dispatch is how a stack gets torn in two.
        size_t* m_pending;
        EventType* m_pendingKind;
        size_t m_pendingCount, m_pendingCap;
    }

    override bool doProcessEvents(Duration timeout)
    @trusted {
        // Qt's own three semantics, and the driver's three: wait, drain, wait-with-deadline.
        int ms;
        if (timeout == Duration.max) ms = -1;
        else {
            const t = timeout.total!"msecs";
            ms = t <= 0 ? 0 : (t > int.max ? int.max : cast(int) t);
        }
        if (!qtd_ec_process(ms)) return false;   // no QCoreApplication yet: nothing was waited on

        bool any = m_pendingCount > 0;
        // Drained by index rather than by iterator: a notify() may register or unregister
        // descriptors, which is allowed and would invalidate anything held across the call.
        for (size_t i = 0; i < m_pendingCount; ++i) {
            const fd = m_pending[i];
            final switch (m_pendingKind[i]) {
                case EventType.read:   notify!(EventType.read)(fd);   break;
                case EventType.write:  notify!(EventType.write)(fd);  break;
                case EventType.status: notify!(EventType.status)(fd); break;
            }
        }
        m_pendingCount = 0;
        // ...and only now are the notifiers listening again. They are level-triggered: left
        // enabled while the descriptor is still ready and unread, Qt would dispatch them again
        // immediately and the loop would spin at 100% doing nothing. Disabled on fire, re-enabled
        // once eventcore has had its turn.
        rearm();
        return any;
    }

    override void registerFD(FD fd, EventMask mask, bool edge_triggered = true)
    @nogc {
        ensure(cast(size_t) fd);
        if (mask & EventMask.read)  arm(cast(size_t) fd, EventType.read,  QtRead);
        if (mask & EventMask.write) arm(cast(size_t) fd, EventType.write, QtWrite);
        // EventMask.status has no notifier of its own: an error or hangup shows up as readability
        // on every POSIX descriptor, and Qt reports it through the read notifier.
    }

    override void unregisterFD(FD fd, EventMask mask)
    @nogc {
        const i = cast(size_t) fd;
        if (i >= m_watch.length) return;
        if (mask & EventMask.read)  disarm(i, 0);
        if (mask & EventMask.write) disarm(i, 1);
    }

    override void updateFD(FD fd, EventMask old_mask, EventMask mask, bool edge_triggered = true)
    @nogc {
        const i = cast(size_t) fd;
        ensure(i);
        if ((mask & EventMask.read)  && !(old_mask & EventMask.read))  arm(i, EventType.read,  QtRead);
        if (!(mask & EventMask.read) &&  (old_mask & EventMask.read))  disarm(i, 0);
        if ((mask & EventMask.write) && !(old_mask & EventMask.write)) arm(i, EventType.write, QtWrite);
        if (!(mask & EventMask.write) &&  (old_mask & EventMask.write)) disarm(i, 1);
    }

    override void dispose()
    @nogc {
        foreach (i; 0 .. m_watch.length) { disarm(i, 0); disarm(i, 1); }
        () @trusted {
            if (m_watch.ptr) free(m_watch.ptr);
            if (m_pending) free(m_pending);
            if (m_pendingKind) free(m_pendingKind);
        } ();
        m_watch = null; m_pending = null; m_pendingKind = null;
        m_pendingCap = m_pendingCount = 0;
        super.dispose();
    }

    // ---- the parts the callback needs -------------------------------------------------------

    private void ensure(size_t fd) @nogc @trusted {
        if (fd < m_watch.length) return;
        const n = fd + 64;
        auto p = cast(Watch*[2]*) realloc(m_watch.ptr, n * (Watch*[2]).sizeof);
        if (!p) return;
        foreach (i; m_watch.length .. n) { p[i][0] = null; p[i][1] = null; }
        m_watch = p[0 .. n];
    }

    private void arm(size_t fd, EventType kind, int qtType) @nogc @trusted {
        const slot = qtType == QtRead ? 0 : 1;
        if (fd >= m_watch.length || m_watch[fd][slot]) return;
        auto w = cast(Watch*) malloc(Watch.sizeof);
        if (!w) return;
        w.loop = this; w.fd = fd; w.kind = kind; w.notifier = null;
        w.notifier = qtd_ec_notifier_new(cast(int) fd, qtType, &onReady, w);
        if (!w.notifier) { free(w); return; }
        m_watch[fd][slot] = w;
    }

    private void disarm(size_t fd, int slot) @nogc @trusted {
        if (fd >= m_watch.length) return;
        auto w = m_watch[fd][slot];
        if (!w) return;
        m_watch[fd][slot] = null;
        qtd_ec_notifier_free(w.notifier);
        free(w);
    }

    private void rearm() @nogc @trusted {
        foreach (i; 0 .. m_watch.length)
            foreach (s; 0 .. 2)
                if (auto w = m_watch[i][s]) qtd_ec_notifier_enable(w.notifier, 1);
    }

    private void enqueue(size_t fd, EventType kind) @nogc @trusted {
        if (m_pendingCount == m_pendingCap) {
            const n = m_pendingCap ? m_pendingCap * 2 : 32;
            auto a = cast(size_t*) realloc(m_pending, n * size_t.sizeof);
            auto b = cast(EventType*) realloc(m_pendingKind, n * EventType.sizeof);
            if (!a || !b) return;
            m_pending = a; m_pendingKind = b; m_pendingCap = n;
        }
        m_pending[m_pendingCount] = fd;
        m_pendingKind[m_pendingCount] = kind;
        ++m_pendingCount;
    }
}

/// Called by Qt, inside its dispatch. It records and silences, and does nothing else: notify()
/// resumes fibers, and resuming a fiber from inside Qt's own dispatch would run eventcore's work on
/// Qt's stack. The driver drains this immediately afterwards, on its own.
private extern(C) void onReady(void* ctx, int fd) @system @nogc nothrow {
    auto w = cast(Watch*) ctx;
    if (!w || !w.loop) return;
    qtd_ec_notifier_enable(w.notifier, 0);
    w.loop.enqueue(w.fd, w.kind);
}

/// The driver eventcore's machinery builds around this loop. Install it with
/// `setupEventDriver(new QtEventDriver)` before anything touches the event loop, then run Qt's.
alias QtEventDriver = PosixEventDriver!QtEventLoop;
