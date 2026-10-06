// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A SECOND Qt module named beside a discovered one, and QList<QVariant> on a VALUE type — the two
// gaps solid-mail hit binding QtDBus next to QtQuick for GNOME Online Accounts.
//
// 1. This binding discovers QtNetwork and names `QtDBus/QtDBus` in `headers`. QtDBus classes are
//    then discovered, and before the fix the shims included only <QtNetwork>, so the BUILD of this
//    test failed (`qtdctor.cpp: unknown type name 'QDBusError'`). Building it is the first check.
// 2. QDBusMessage is a value type, and its arguments() / setArguments() — QList<QVariant> — were
//    `template/std … unmapped-type`: the value-type emitter had no container path. Without them a
//    D program can neither pass a D-Bus call's arguments nor read its reply.
//
// 3. QDBusPendingCallWatcher::finished(QDBusPendingCallWatcher*) had no connectFinished: the
//    signal's argument is a pointer to the watcher itself, and the definition check asked the
//    FORWARD declaration qdbuspendingcall.h makes of it. solid-mail polled isFinished() on a timer.
//
// 4. QVariant(string) built a QByteArray (QVariant's QByteArray constructor won the `string`
//    overload by declaration order); a D-Bus call then carried `ay` where `s` was expected.
//
// No D-Bus daemon is involved: a method-call message is built, given arguments, and read back;
// the watcher watches a call that is already complete, which Qt reports through a QUEUED emission.
import qt.netdbus.qdbusmessage, qt.netdbus.qvariant, qt.netdbus.qbytearray : qba;
import qt.netdbus.qdbuspendingcall,
       qt.netdbus.qdbuspendingcallwatcher, qt.netdbus.qcoreapplication;
import cxxrt, appctor : QCOREAPP_CTOR;
import std.stdio, std.conv : to;

pragma(mangle, QCOREAPP_CTOR) extern(C++) void __qcore_ctor(void*, ref int, char**, int);

void main() {
    // The watcher's queued emission needs a real application (measured; see the watcher below).
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "netdbus\0".ptr, null];
    auto app = cast(QCoreApplication) __cpp_new(__traits(classInstanceSize, QCoreApplication));
    __qcore_ctor(cast(void*) app, argc, argv.ptr, 0);
    auto msg = QDBusMessage.createMethodCall("org.gnome.OnlineAccounts",
        "/org/gnome/OnlineAccounts/Accounts/account_1", "org.freedesktop.DBus.Properties", "Get");
    assert(msg.arguments().length == 0, "a fresh method call carries no arguments");

    // What GOA needs going OUT: strings. And the shapes a reply comes back in: string, int, bool.
    msg.setArguments([QVariant("org.gnome.OnlineAccounts.Mail"), QVariant("ImapHost"),
                      QVariant(993), QVariant(true)]);

    // A D `string` is TEXT: QVariant("x") must hold a QString (QMetaType 10), as C++'s QVariant("x")
    // does — not a QByteArray (12). It held a byte array while QVariant's QByteArray constructor,
    // declared first, won the `string` overload; D-Bus then sent `ay` and GOA refused the call.
    assert(QVariant("text").userType() == 10, "QVariant(string) must be a QString, got QMetaType "
           ~ QVariant("text").userType().to!string);
    assert(QVariant.__make("text").userType() == 10, "QVariant.__make(string) must be a QString too");
    auto raw = qba("raw");
    assert(QVariant(raw).userType() == 12, "a QByteArray is still reachable explicitly");

    auto args = msg.arguments();
    assert(args.length == 4, "expected 4 arguments back, got " ~ args.length.to!string);
    assert(args[0].toString().toString() == "org.gnome.OnlineAccounts.Mail", "string argument lost");
    assert(args[1].toString().toString() == "ImapHost", "second string argument lost");
    assert(args[2].toInt(null) == 993, "int argument lost");
    assert(args[3].toBool(), "bool argument lost");

    // A COPY behaves exactly as in C++. QDBusMessage shares its d-pointer and its setters do NOT
    // detach, so arguments set on a copy are seen by the original — measured in plain C++ on Qt 5
    // and Qt 6 (the original reports 1 argument afterwards). The first version of this test
    // asserted the opposite and failed against the binding, which was right.
    // The copy goes through the real copy constructor (reference count taken); both are destroyed
    // at the end of main, so a byte copy here would release the shared d-pointer twice.
    auto copy = msg;
    copy.setArguments([QVariant("other")]);
    assert(copy.arguments().length == 1 && msg.arguments().length == 1,
           "a D copy of a QDBusMessage must share its d-pointer, as the C++ copy does");

    // The watcher's `finished`. A completed call is announced on the NEXT event-loop pass (Qt
    // queues it), so the count is 0 right after connecting — a direct emission, or a delegate fired
    // at connect time, would show here — and exactly 1 once the loop has run. The argument must
    // be the watcher itself, as C++ receives it. Measured in plain C++ (Qt 5 and Qt 6) first: with
    // no QCoreApplication, or with sendPostedEvents alone, Qt itself never emits it.
    auto reply = msg.createReply([QVariant(42)]);
    auto pending = QDBusPendingCall.fromCompletedCall(reply);
    assert(pending.isFinished(), "a call built from a reply is already finished");
    auto watcher = QDBusPendingCallWatcher.__make(pending);
    int fired; QDBusPendingCallWatcher seen;
    watcher.connectFinished((QDBusPendingCallWatcher w) { fired++; seen = w; });
    assert(fired == 0, "finished fired before the event loop ran");
    // How many passes Qt takes is not a contract (one in a C++ probe, a few here): spin a bounded
    // number, then a few more so a SECOND emission would be counted too.
    foreach (k; 0 .. 200) { if (fired) break; QCoreApplication.processEvents(0); }
    foreach (k; 0 .. 5) QCoreApplication.processEvents(0);
    assert(fired == 1, "finished must fire once, fired " ~ fired.to!string);
    assert(seen is watcher, "the signal's argument must be the watcher that emitted it");
    // The reply is reached through the call the watcher shares its d-pointer with.
    assert(pending.reply().arguments()[0].toInt(null) == 42, "the completed reply lost its value");

    writeln("netdbus OK: QtDBus beside a discovered module builds, and QDBusMessage arguments ",
            "cross as QVariant[] both ways (", args.length, " args), the watcher's finished(watcher) connects");
}
