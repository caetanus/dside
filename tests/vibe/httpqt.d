// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// THE TWO THINGS THE OTHER TESTS DO NOT REACH: a DNS lookup, and a host that is not loopback.
// Everything before this ran against 127.0.0.1 with an address already in hand; a name resolution
// is a different path through eventcore, and a real network is a different set of waits.
//
// And "progress in Qt" is the point rather than decoration: the byte count is written through the
// META-OBJECT, which is what a QProgressBar or a QML binding would read, and a Qt timer of Qt's own
// keeps ticking while the request is in flight. If it stopped, the UI froze — which is the failure
// this exists to catch, and the reason the tick count is asserted rather than printed.
// AN HTTP REQUEST TO example.org, WITH PROGRESS IN QT. The point is not the bytes: it is that the
// request is vibe's, the DNS lookup is vibe's, and every wait behind them is Qt's — while a Qt
// object counts the same bytes and a Qt timer keeps ticking, which is what "the UI does not freeze"
// means when it is measured instead of asserted.
import qt.widgets.qcoreapplication;
import qt.widgets.qtimer;
import qtmoc : QObject, Slot, Property, Signal, newQObject, qobjOf, connectMeta, propInt, setProp;
import cxxrt : __cpp_new;
import appctor : QCOREAPP_CTOR;
pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);

import eventcore.core : setupEventDriver;
import eventcore.drivers.posix.qt : QtEventDriver;

import vibe.core.core : runTask, runEventLoop, exitEventLoop;
import vibe.http.client : requestHTTP, HTTPClientRequest, HTTPClientResponse;
import core.time : msecs, MonoTime;
import std.stdio;

/// The progress lives on a Qt object, written through the meta-object like any other Qt property,
/// so what a QProgressBar would bind to is exactly what this reads back.
@QObject class Progress {
    @Property("bytesChanged") int bytes = 0;
    Signal!() bytesChanged;
    @Slot void tick() { ++uiTicks; }
    int uiTicks;
}

__gshared Progress g_p;
__gshared int g_status;
__gshared int g_total;
__gshared string g_err;
__gshared int g_chunks;

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "h\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);
    setupEventDriver(new QtEventDriver);

    g_p = newQObject!Progress();
    // A Qt timer of Qt's own, running while the request is in flight: if it stops ticking, the
    // "UI" froze, which is the failure this test exists to catch.
    auto ui = new QTimer();
    ui.setInterval(10);
    connectMeta(ui, "timeout()", g_p, "tick()");
    ui.start();

    runTask(() nothrow {
        try {
            requestHTTP("http://example.org/",
                (scope HTTPClientRequest req) { req.headers["User-Agent"] = "dside-vibe-qt"; },
                (scope HTTPClientResponse res) {
                    g_status = res.statusCode;
                    auto body_ = res.bodyReader;
                    ubyte[256] buf;
                    while (!body_.empty) {
                        const n = body_.leastSize < buf.length ? cast(size_t) body_.leastSize : buf.length;
                        if (n == 0) break;
                        body_.read(buf[0 .. n]);
                        g_total += cast(int) n;
                        ++g_chunks;
                        // ...written through the meta-object, the way a bound QML/widget property
                        // would receive it.
                        setProp(g_p, "bytes", g_total);
                        g_p.bytesChanged.emit();
                    }
                });
        } catch (Exception e) { g_err = e.msg; }
        try exitEventLoop(); catch (Exception) {}
    });

    const t0 = MonoTime.currTime;
    runEventLoop();
    const ms = (MonoTime.currTime - t0).total!"msecs";
    ui.stop();

    const seen = propInt(g_p, "bytes");
    if (g_err.length) { writeln("http-qt FAIL: ", g_err); return; }
    writefln("status=%s bytes=%s (property read back: %s) chunks=%s  qt ui ticks=%s in %sms",
             g_status, g_total, seen, g_chunks, g_p.uiTicks, ms);
    writeln(g_status == 200 && g_total > 0 && seen == g_total && g_p.uiTicks >= 1
            ? "HTTP OVER VIBE, DNS AND ALL WAITS ON QT — and Qt kept ticking while it ran"
            : "http-qt FAIL: the request, the property or the UI did not move");
}
