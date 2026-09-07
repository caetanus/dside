// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// THE WHOLE THING: eventcore's driver IS Qt. One wait, two runtimes.
//
// vibe owns the loop; its driver's wait is `QCoreApplication::processEvents`, and every descriptor
// vibe cares about is a QSocketNotifier. So Qt's timers and windows are serviced on the same wait
// that services vibe's sockets, and nothing polls anything.
import qt.widgets.qcoreapplication;
import qt.widgets.qtimer;
import qtmoc : QObject, Slot, newQObject, qobjOf, connectMeta;
import cxxrt : __cpp_new;
import appctor : QCOREAPP_CTOR;
pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);

import eventcore.core : setupEventDriver;
import eventcore.drivers.posix.qt : QtEventDriver;

import vibe.core.core : runTask, sleep, runEventLoop, exitEventLoop;
import vibe.core.net : listenTCP, connectTCP, TCPConnection;
import core.time : msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio;

__gshared string g_got;
__gshared int g_ticks;
__gshared int g_qtTicks;

/// The OTHER half of the claim. vibe's work running on Qt's wait proves one direction; a Qt timer
/// firing during vibe's loop proves the other, and only both together mean one wait serves two
/// runtimes. Without this the test would pass on a program that had quietly stopped being a Qt
/// program at all.
@QObject class QtSide {
    @Slot void tick() { g_qtTicks++; }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "q\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);

    // ...before anything touches the loop.
    setupEventDriver(new QtEventDriver);

    auto l = listenTCP(0, (TCPConnection c) nothrow {
        try { auto b = new ubyte[5]; c.read(b); c.write(b); c.close(); } catch (Exception) {}
    }, "127.0.0.1");
    const port = l.bindAddress.port;

    auto side = newQObject!QtSide();
    auto qt = new QTimer();
    qt.setInterval(15);
    connectMeta(qt, "timeout()", side, "tick()");
    qt.start();

    auto sw = StopWatch(AutoStart.yes);
    runTask(() nothrow {
        try {
            // the vibe TIMER path — its deadline becomes Qt's wait deadline
            foreach (i; 0 .. 3) { sleep(20.msecs); g_ticks++; }
            // the vibe FD path — its descriptors are Qt's notifiers
            auto c = connectTCP("127.0.0.1", port);
            c.write(cast(const(ubyte)[]) "hello");
            auto b = new ubyte[5];
            c.read(b);
            g_got = cast(string) b.idup;
            c.close();
        } catch (Exception e) { g_got = "EXC:" ~ e.msg; }
        exitEventLoop();
    });

    runEventLoop();
    const ms = sw.peek.total!"msecs";
    l.stopListening();

    qt.stop();
    writefln("vibe ticks=%s  qt ticks=%s  tcp=[%s]  in %sms", g_ticks, g_qtTicks, g_got, ms);
    writeln(g_ticks == 3 && g_got == "hello" && g_qtTicks >= 2
            ? "QT IS EVENTCORE'S EVENT LOOP — vibe timers and vibe sockets, on Qt's wait"
            : "FAIL");
}
