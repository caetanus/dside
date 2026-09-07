// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// A REAL LIBRARY ON THE QT EVENT DRIVER, which is the only thing that settles whether the driver
// is finished. Two libp2p hosts in one process: one listens, the other dials, and between them
// they do a TCP connect, a security handshake, a muxer, Identify and Ping — every one of those a
// descriptor or a timer that eventcore has to service, and here eventcore's wait is Qt's.
//
// `version (QtDriver)` builds the same program on the STOCK epoll driver instead, which is how the
// cost was measured rather than assumed: ~165 us round trip on Qt's wait against ~105 us on epoll,
// on this machine, over loopback. The difference is the trip through QSocketNotifier and Qt's
// signal machinery, and it is reported because a reader deserves the number, not a claim that
// there is no cost.
// libp2p ON QT'S WAIT: two hosts in one process, a real dial, a real Noise/muxer handshake,
// Identify and Ping — with eventcore's event driver being Qt.
version (QtDriver) {
    import qt.widgets.qcoreapplication;
    import cxxrt : __cpp_new;
    import appctor : QCOREAPP_CTOR;
    pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);
    import eventcore.core : setupEventDriver;
    import eventcore.drivers.posix.qt : QtEventDriver;
}

import vibe.core.core : runTask, runEventLoop, exitEventLoop, sleep;
import core.time : Duration, msecs, seconds, MonoTime;
import std.stdio;

import libp2p.core.peer_id : PeerId;
import libp2p.crypto.keys : Keypair;
import libp2p.host.host;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.protocol.identify;
import libp2p.protocol.ping;
import libp2p.transport.tcp : TcpTransport;

__gshared bool g_pinged, g_identified, g_failed;
__gshared string g_err;
__gshared long g_rttUsecs;

void main() {
    version (QtDriver) {
        __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "p\0".ptr, null];
        auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
        __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);
        setupEventDriver(new QtEventDriver);
    }

    runTask(() nothrow {
        try {
            HostConfig cfg;
            cfg.agentVersion = "libp2p-on-qt";
            cfg.swarm.idleTimeout = 10.seconds;

            auto keyA = Keypair.generateEd25519;
            auto a = new Host(keyA, [new TcpTransport], cfg);
            scope (exit) a.close();
            auto identA = new IdentifyService(a);
            // The listening side needs the protocol too, or the dial gets as far as multistream
            // and stops there — "no protocol in common", which is a libp2p answer and not an
            // event-loop one. (Both peers register both services in the library's own interop
            // program, for the same reason.)
            PingConfig pcA;
            pcA.interval = 200.msecs;
            pcA.timeout = 5.seconds;
            auto pingA = new Ping(a, pcA);
            a.listen(Multiaddr.parse("/ip4/127.0.0.1/tcp/0"));
            auto addrA = a.addrs[0];
            auto idA = a.id;

            auto keyB = Keypair.generateEd25519;
            auto b = new Host(keyB, [new TcpTransport], cfg);
            scope (exit) b.close();

            PingConfig pc;
            pc.interval = 200.msecs;
            pc.timeout = 5.seconds;
            auto ping = new Ping(b, pc);
            ping.onResult = (PeerId p, Duration rtt) { g_rttUsecs = rtt.total!"usecs"; g_pinged = true; };
            ping.onFailure = (PeerId p, Exception e) { g_failed = true; g_err = e.msg; };
            auto identB = new IdentifyService(b);
            identB.onIdentified = (IdentifyInfo i) { g_identified = true; };

            b.connect(idA, [addrA]);

            const until = MonoTime.currTime + 20.seconds;
            while (MonoTime.currTime < until && !((g_pinged && g_identified) || g_failed))
                sleep(20.msecs);
        } catch (Exception e) {
            g_failed = true; g_err = e.msg;
        }
        try exitEventLoop(); catch (Exception) {}
    });

    runEventLoop();

    if (g_failed) { writeln("libp2p-on-qt FAIL: ", g_err); return; }
    writefln("identified=%s pinged=%s rtt=%sus", g_identified, g_pinged, g_rttUsecs);
    writeln(g_identified && g_pinged
            ? "libp2p ON QT'S WAIT: two hosts, a real handshake, Identify and Ping"
            : "libp2p-on-qt FAIL: the exchange did not complete");
}
