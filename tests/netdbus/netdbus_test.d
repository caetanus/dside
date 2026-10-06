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
// No D-Bus daemon is involved: a method-call message is built, given arguments, and read back.
import qt.netdbus.qdbusmessage, qt.netdbus.qvariant;
import std.stdio, std.conv : to;

void main() {
    auto msg = QDBusMessage.createMethodCall("org.gnome.OnlineAccounts",
        "/org/gnome/OnlineAccounts/Accounts/account_1", "org.freedesktop.DBus.Properties", "Get");
    assert(msg.arguments().length == 0, "a fresh method call carries no arguments");

    // What GOA needs going OUT: strings. And the shapes a reply comes back in: string, int, bool.
    msg.setArguments([QVariant("org.gnome.OnlineAccounts.Mail"), QVariant("ImapHost"),
                      QVariant(993), QVariant(true)]);

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

    writeln("netdbus OK: QtDBus beside a discovered module builds, and QDBusMessage arguments ",
            "cross as QVariant[] both ways (", args.length, " args)");
}
