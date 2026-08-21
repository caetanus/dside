// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// THE DOOR I OPENED HAS TO STAY LOCKED.
//
// The meta-object runtime keeps unsynchronised side tables and pins an OWNER THREAD at first use;
// mutating them from another thread aborts loudly rather than corrupting a map. That guard has
// been there since round 8 — but until QThread became subclassable there was no ordinary way for a
// user to reach it, because D code never ran on a thread Qt made. Now `run()` lands in D, so the
// first thing anyone will try is creating a QObject in there.
//
// This asserts the guard still fires on that exact path. It is a SAFETY test, not a feature test:
// the desired outcome is a deterministic abort with a message, not a working worker QObject. Worker
// QObjects remain outside the contract (CRITICS, structural debt) and this is what keeps "outside
// the contract" from meaning "silently corrupts a map".
//
// Testing an abort needs a child process: the parent re-executes itself with an argument, the child
// does the forbidden thing, and the parent requires it to have died by signal.
import qt.widgets.qapplication, qt.widgets.qthread, qt.widgets.qtvirt;
import qtmoc, cxxrt;
import std.process : execute;
import std.file : thisExePath;
import std.stdio : writeln;
import std.string : indexOf;

import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern (C) int qtd_moc_owner_check() nothrow;

@QObject class Offender { @Property("vChanged") int v; Signal!() vChanged; }

// A second worker for the ATTACH-FAILURE path (critics r14 #6). Its `run()` must NOT be entered
// when the runtime cannot attach the thread — so it announces itself, and the parent requires the
// announcement to be ABSENT.
@QObject class NeverRuns {
    mixin QtdWidget!QThread;
    void run() {
        import core.stdc.stdio : printf;
        printf("VIRTUAL ENTERED\n");
    }
}

@QObject class Worker {
    mixin QtdWidget!QThread;
    void run() {
        // Not the owner thread — the guard's whole precondition. Asserting it here means a future
        // change that quietly makes this the owner thread turns the test into a false pass.
        assert(qtd_moc_owner_check() == 0, "run() is already the owner thread: nothing is being tested");
        cast(void) newQObject!Offender();   // must abort
    }
}

void main(string[] args) {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "tg\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    // The forced-failure child: same trampoline, same Qt-created thread, with the attach refused.
    if (args.length > 1 && args[1] == "--child-attachfail") {
        auto w = new NeverRuns();
        auto t = QThread.wrap(w.__qtdObj());
        t.start(QThread.Priority.InheritPriority);
        t.wait(30_000);
        writeln("CHILD-ATTACHFAIL DONE");
        return;
    }

    if (args.length > 1 && args[1] == "--child") {
        auto w = new Worker();
        auto t = QThread.wrap(w.__qtdObj());
        t.start(QThread.Priority.InheritPriority);
        t.wait(30_000);
        writeln("CHILD SURVIVED");       // reaching here at all is the failure
        return;
    }

    auto r = execute([thisExePath(), "--child"], ["QT_QPA_PLATFORM": "offscreen"]);
    assert(r.status != 0,
           "creating a QObject on a Qt-created thread did NOT abort — the owner-thread guard is "
           ~ "unreachable from QThread::run(), which is the path subclassing QThread just opened");
    assert(r.output.indexOf("CHILD SURVIVED") < 0, "the child ran past the forbidden call");
    assert(r.output.indexOf("off its owner thread") >= 0,
           "the child died without the guard's message — it failed for some other reason:\n" ~ r.output);

    // ...and the OTHER half of the same mechanism, THROUGH THE TRAMPOLINE ON A REAL FOREIGN
    // THREAD (critics r13 #7, corrected by r14 #6). The first version of this called
    // qtdAttachThreadImpl(true) on the MAIN thread, where `Thread.getThis()` is not null — so the
    // forced branch was never entered, the assertion was conditional on a situation that does not
    // occur, and the test printed a claim it had not exercised.
    //
    // Now the seam is an environment variable, the child runs a D virtual on a thread QT created,
    // and the proof is NEGATIVE: the virtual announces itself, and the announcement must be absent.
    {
        auto r2 = execute([thisExePath(), "--child-attachfail"],
                          ["QT_QPA_PLATFORM": "offscreen", "QTD_FORCE_ATTACH_FAIL": "1"]);
        assert(r2.output.indexOf("VIRTUAL ENTERED") < 0,
               "the attach failed and the trampoline entered D anyway:\n" ~ r2.output);
        assert(r2.output.indexOf("CHILD-ATTACHFAIL DONE") >= 0,
               "the child did not finish — the refusal was not graceful:\n" ~ r2.output);
        assert(r2.output.indexOf("FATAL-SAFE") >= 0,
               "the refusal was silent; it must say so through libc, without touching D:\n" ~ r2.output);
        // ...and the control: without the seam, the same child DOES enter the virtual. Otherwise
        // this test passes for a thread that never started.
        auto r3 = execute([thisExePath(), "--child-attachfail"], ["QT_QPA_PLATFORM": "offscreen"]);
        assert(r3.output.indexOf("VIRTUAL ENTERED") >= 0,
               "the control run did not enter the virtual, so the negative proves nothing:\n" ~ r3.output);
    }

    writeln("threadguard OK: a QObject created inside QThread::run() aborts with the owner-thread ",
            "message, and a failed thread attach refuses to enter D on a REAL foreign thread, " ~
            "proven by the virtual NOT announcing itself (critics r14 #6)");
}
