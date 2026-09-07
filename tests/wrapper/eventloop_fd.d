// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// QT'S WAIT, SERVICING A DESCRIPTOR IT DOES NOT OWN.
//
// A program that draws with Qt and does its I/O with another runtime — vibe-core's fibers, say —
// has two event loops and one thread, and only one of them can own the wait. Polling the second
// costs a wakeup per millisecond whether or not anything happened. The way out is to hand the other
// loop's descriptors to Qt and let Qt's wait cover both, which is what `QSocketNotifier` is for.
//
// This is the load-bearing measurement for that design, and it is deliberately about TIME rather
// than about a callback arriving: a callback proves the notifier is wired, and only the elapsed
// time proves the wait was a wait. Another thread makes the pipe readable after 60 ms while this
// one asks Qt to wait with no deadline; coming back at once would read exactly like a busy loop
// from the outside, and that is the failure this exists to catch.
//
// Measured while writing it, and the reason the drain below is there: a fresh QCoreApplication has
// posted events of its own, so the FIRST wait returns immediately with work in hand —
// `WaitForMoreEvents` waits only when there is nothing to do.
import qt.widgets.qapplication;
import cxxrt : __cpp_new;
import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void*, ref int, char**, int);

extern(C) void* qtd_ec_notifier_new(int fd, int type, void function(void*, int) cb, void* ctx);
extern(C) void  qtd_ec_notifier_free(void* n);
extern(C) void  qtd_ec_notifier_enable(void* n, int on);
extern(C) int   qtd_ec_process(int msecs);

import core.sys.posix.unistd : pipe, write, read, close;
import core.thread : Thread;
import core.time : msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio;

__gshared int g_fired;

extern(C) void onReadable(void* ctx, int fd) nothrow {
    g_fired++;
    ubyte[1] b;
    read(fd, b.ptr, 1);
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(cast(void*) app, argc, argv.ptr, 0);

    int[2] fds;
    if (pipe(fds) != 0) { writeln("eventloop_fd FAIL: pipe()"); return; }
    auto n = qtd_ec_notifier_new(fds[0], 0 /* QSocketNotifier::Read */, &onReadable, null);
    if (n is null) { writeln("eventloop_fd FAIL: no notifier"); return; }

    foreach (_; 0 .. 8) qtd_ec_process(0);          // drain what startup posted
    if (g_fired != 0) { writeln("eventloop_fd FAIL: fired before the fd was ready"); return; }

    auto w = new Thread({ Thread.sleep(60.msecs); ubyte one = 42; write(fds[1], &one, 1); });
    w.start();
    auto sw = StopWatch(AutoStart.yes);
    qtd_ec_process(-1);                              // no deadline: Qt's own wait
    const woke = sw.peek.total!"msecs";
    w.join();

    // ...and the notifier can be silenced without being destroyed, which is what a driver does to
    // an fd it still owns but is not waiting on.
    qtd_ec_notifier_enable(n, 0);
    ubyte one = 43; write(fds[1], &one, 1);
    foreach (_; 0 .. 4) qtd_ec_process(0);
    const firedWhileDisabled = g_fired - 1;

    qtd_ec_notifier_free(n);
    close(fds[0]); close(fds[1]);

    if (g_fired < 1) { writeln("eventloop_fd FAIL: the callback never fired"); return; }
    if (firedWhileDisabled != 0) {
        writeln("eventloop_fd FAIL: a disabled notifier still fired ", firedWhileDisabled, " time(s)");
        return;
    }
    if (woke < 50) {
        writefln("eventloop_fd FAIL: the wait returned after %sms — it did not wait, so anything "
                 ~ "built on it would have to poll", woke);
        return;
    }
    writefln("eventloop_fd OK: Qt's wait blocked %sms on a descriptor it does not own and woke on "
             ~ "it — no polling, and a disabled notifier stays quiet", woke);
}
