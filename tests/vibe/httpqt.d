// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// A REAL DOWNLOAD — 176 kB over TLS, with a progress bar's worth of steps landing on a Qt property.
//
// The three things the loopback tests do not reach: a DNS lookup, a host that is not this machine,
// and a body big enough to ARRIVE IN PIECES. The first version of this fetched example.org, whose
// 559 bytes come in three reads — enough to prove the request works and not enough to prove a
// progress bar would ever move.
//
// So the assertion is not "it downloaded". It is that the percentage passed THROUGH THE MIDDLE
// (a body that arrives in one read sets 100 and nothing else, and a bar bound to that has shown a
// result, never progress), and that Qt's own 10 ms timer KEPT ITS CADENCE while it ran — about
// ms/10 ticks, not merely one. Everything the transfer waits on is Qt's.
//
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
import std.conv : to;
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
__gshared int g_len;          // Content-Length, when the server gives one
__gshared int[] g_pcts;       // every percentage the Qt property was set to, in order

void main(string[] args) {
    const url = args.length > 1 ? args[1] : "https://duckduckgo.com/";
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
            requestHTTP(url,
                (scope HTTPClientRequest req) {
                    req.headers["User-Agent"] = "dside-vibe-qt";
                    // IDENTITY, and this is not a detail. Asked for the default, the server sends
                    // a COMPRESSED body and `Content-Length` is the compressed size, while the
                    // reader hands over the decompressed one — so a percentage computed from the
                    // two counts the wrong pair and runs past the end. Measured: 176699 bytes of
                    // body against a Content-Length of 45238, and a progress bar that reached 390%.
                    // A download that wants a percentage has to compare like with like.
                    req.headers["Accept-Encoding"] = "identity";
                },
                (scope HTTPClientResponse res) {
                    g_status = res.statusCode;
                    if (auto cl = "Content-Length" in res.headers) g_len = (*cl).to!int;
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
                        // A DOWNLOAD HAS A PERCENTAGE, and a progress bar is what it is for.
                        if (g_len > 0) {
                            const pct = cast(int) (cast(long) g_total * 100 / g_len);
                            if (g_pcts.length == 0 || g_pcts[$ - 1] != pct) g_pcts ~= pct;
                        }
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
    writefln("status=%s bytes=%s/%s (property read back: %s) chunks=%s steps=%s  qt ui ticks=%s in %sms",
             g_status, g_total, g_len, seen, g_chunks, g_pcts.length, g_p.uiTicks, ms);
    if (g_pcts.length)
        writefln("  progress: %s%% .. %s%% .. %s%%",
                 g_pcts[0], g_pcts[$ / 2], g_pcts[$ - 1]);
    // A DOWNLOAD, not a fetch: the percentage has to have PASSED THROUGH the middle. A body that
    // arrives in one read would set 100 and nothing else, and a progress bar bound to that has
    // never shown progress — it showed a result. So intermediate steps are the assertion.
    const moved = g_pcts.length >= 3 && g_pcts[0] < 100 && g_pcts[$ - 1] == 100;
    // ...AND THE UI KEPT ITS CADENCE, which is a stronger claim than "it ticked". A 10 ms timer
    // over `ms` milliseconds owes about ms/10 ticks; a third of that is the floor, so a slow
    // machine passes and a UI that stalled for most of the download does not. Measured across
    // runs of very different length — 59 ticks in 591 ms, 19 in 193 — the rate held.
    const owed = cast(int) (ms / 10) / 3;
    const responsive = g_p.uiTicks >= (owed < 1 ? 1 : owed);
    writeln(g_status == 200 && g_total > 0 && seen == g_total && responsive && moved
            ? "A REAL DOWNLOAD OVER VIBE, EVERY WAIT ON QT — the bar moved through the middle and Qt kept ticking"
            : "http-qt FAIL: the request, the property, the progress or the UI's cadence did not hold");
}
