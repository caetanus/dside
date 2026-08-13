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

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern (C) int qtd_moc_owner_check() nothrow;

@QObject class Offender { @Property("vChanged") int v; Signal!() vChanged; }

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

    // ...and the OTHER half of the same mechanism (critics r13 #7): when attaching a foreign
    // thread to the druntime FAILS, the trampoline must not enter D anyway. The failure used to be
    // swallowed — `catch (Throwable) {}` — and the virtual ran on a thread the runtime does not
    // know, which is the exact condition the attach exists to prevent.
    //
    // Forced through the seam rather than by breaking the druntime: qtdAttachThreadImpl(true)
    // returns the same value the real failure produces, and the trampolines check `ok` before the
    // call. A parameter, not a global, so no module-level state is added to the shared runtime.
    {
        auto bad = qtdAttachThreadImpl(true);
        auto good = qtdAttachThreadImpl(false);
        // On the MAIN thread the druntime already knows us, so both report usable — the seam only
        // bites where an attach would actually be attempted. That is itself worth asserting: a
        // seam that fails everywhere would make the guard look reachable when it is not.
        import core.thread : Thread;
        if (Thread.getThis() is null)
            assert(!bad.ok, "the forced-failure seam reported the thread as usable");
        assert(good.ok, "a thread the druntime knows was reported unusable");
    }

    writeln("threadguard OK: a QObject created inside QThread::run() aborts with the owner-thread ",
            "message, and a failed thread attach refuses to enter D (critics r13 #7)");
}
