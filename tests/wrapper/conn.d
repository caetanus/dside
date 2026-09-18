// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// The connection HANDLE's lifetime. `qtd_conn_*` heap-allocates a QMetaObject::Connection so that
// a later disconnect() can name the connection; nothing freed it when the caller ignored the
// result, which is the usual spelling (`timer.connectTimeout(&dg);`). ~this frees it now — and the
// whole risk of that change is in the two things it must NOT do: sever a connection the caller
// still wants, and free a handle twice. Both are asserted here, because neither would be visible
// as a failure at the call site: a wrongly-severed signal just stops arriving.
import qt.core.qobject, qt.core.qanystringview, qt.core.qstring, qt.core.qtsignals;
import std.stdio;

__gshared int fired;

void main() {
    // A NESTED function, so `&bump` is a delegate — which is what connect takes. A module-level
    // function would be a function pointer and would not convert.
    void bump(const(QString)*) { fired++; }

    // The handle is DISCARDED at the call — the connection must live on. This is the spelling
    // that leaked, so it is also the one whose behaviour must not change.
    auto a = new QObject();
    a.connectObjectNameChanged(&bump);
    a.setObjectName(QAnyStringView("one"));
    assert(fired == 1, "a discarded handle must not disconnect");

    // ...and the same when the handle is named and simply goes out of scope, which is where the
    // destructor actually runs rather than on a temporary.
    auto b = new QObject();
    { auto held = b.connectObjectNameChanged(&bump); }
    b.setObjectName(QAnyStringView("two"));
    assert(fired == 2, "a handle that went out of scope must not disconnect");

    // disconnect() still severs, and is idempotent — it nulls the handle, so the destructor that
    // follows must not free it a second time.
    auto c = new QObject();
    auto conn = c.connectObjectNameChanged(&bump);
    conn.disconnect();
    c.setObjectName(QAnyStringView("three"));
    assert(fired == 2, "disconnect() severs");
    conn.disconnect();
    assert(fired == 2, "disconnect() is idempotent");

    // ONE OWNER. Two copies of a handle is a double free, and a handle is exactly the kind of
    // value that gets copied into a field without anyone thinking about it. Compile-time, because
    // at run time the second free is silent until it is not.
    static assert(!__traits(compiles, {
        QtdConnection x; QtdConnection y = x;
    }), "QtdConnection must not be copyable");
    // ...while the spellings that matter stay legal: returning one (a move) and naming it.
    static assert(__traits(compiles, {
        QObject o; auto h = o.connectObjectNameChanged(&bump); h.disconnect();
    }), "returning and naming a handle must still compile");

    writeln("conn OK");
}
