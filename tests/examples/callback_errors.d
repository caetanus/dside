// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// AN EXCEPTION THAT CROSSES THE QT BOUNDARY IS NEVER SILENT — in a release build too.
//
// solid-mail saved a draft from a @Slot called by QML; the store threw (a NOT NULL column bound as
// NULL) and the user got nothing: no message, no log, no draft. The policy recorded it (count +
// last error), but its only output sat in `debug { }`, and tests are not built with -debug — which
// is exactly why cannon_t11, which checks the count and the hook, stayed green the whole time.
//
// What is checked is the OUTPUT, read from outside: this program runs itself as a child and reads
// the child's real stderr. A counter kept by the sink itself would rise even if nothing reached the
// log, so it proves nothing about the log.
//   child "on":  three throws from one slot -> the first prints in full (type, file:line, message,
//                naming the slot `Draft.save`), the two repeats print one line each; the hook still
//                fires and the counters still count.
//   child "off": the app turned the default line off (its hook reports elsewhere) -> no line, and
//                the hook and counters are untouched by that choice.
import qtmoc;
import cxxrt, std.stdio, std.conv : to;
import std.algorithm : canFind, count;
import std.process : execute;
import std.file : thisExePath;

@QObject class Src { Signal!int go; }

class StoreError : Exception {
    this(string m, string f = __FILE__, size_t l = __LINE__) { super(m, f, l); }
}

@QObject class Draft {
    int calls;
    @Slot void save(int v) { calls++; throw new StoreError("NOT NULL constraint failed: drafts.body"); }
}

void child(bool log) {
    qtdCallbackErrorLog = log;
    auto src = newQObject!Src();
    auto draft = newQObject!Draft();
    connectMeta(src, "go(int)", draft, "save(int)");

    __gshared int hookHits;
    __gshared string hookWhere;
    qtdCallbackErrorHook = (Throwable e) nothrow { hookHits++; hookWhere = qtdLastCallbackWhere; };

    immutable before = qtdCallbackErrors;
    foreach (i; 0 .. 3) src.go.emit(i);

    assert(draft.calls == 3, "the slot ran three times");
    assert(qtdCallbackErrors == before + 3, "counted: " ~ (qtdCallbackErrors - before).to!string);
    assert(hookHits == 3, "the hook must fire whether or not the line is printed");
    assert(hookWhere == "Draft.save", "the hook can name the failing slot, got '" ~ hookWhere ~ "'");
    assert(cast(StoreError) qtdLastCallbackError !is null, "the last error is the StoreError itself");
    writeln("child done");
}

void main(string[] args) {
    if (args.length > 1) { child(args[1] == "on"); return; }

    // QT_FORCE_STDERR_LOGGING: with no terminal Qt may send its messages to journald instead,
    // and the parent reads stderr. execute() returns stdout and stderr together.
    auto env = ["QT_FORCE_STDERR_LOGGING": "1"];

    auto on = execute([thisExePath, "on"], env);
    assert(on.status == 0 && on.output.canFind("child done"), "child 'on' failed:\n" ~ on.output);
    auto o = on.output;
    assert(o.count("a D exception escaped Draft.save") == 3,
           "one line per swallowed exception, each naming the slot — got:\n" ~ o);
    assert(o.canFind("StoreError@") && o.canFind("callback_errors.d(")
           && o.canFind("NOT NULL constraint failed: drafts.body"),
           "the first one prints type, file:line and message — got:\n" ~ o);
    assert(o.count("repeat of this site") == 2, "repeats are one line each — got:\n" ~ o);

    auto off = execute([thisExePath, "off"], env);
    assert(off.status == 0 && off.output.canFind("child done"), "child 'off' failed:\n" ~ off.output);
    assert(!off.output.canFind("a D exception escaped"),
           "qtdCallbackErrorLog = false must silence the default line — got:\n" ~ off.output);

    writeln("callback_errors OK: a slot exception is logged through Qt in a release build ",
            "(full once, one line per repeat, named Draft.save); hook + counters unchanged; opt-out works");
}
