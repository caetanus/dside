module metathread_test;   // critics r8 #6: the single-thread contract is enforced, not assumed
import qtmoc;
import core.thread : Thread;
import core.stdc.stdio : printf;

@QObject class Ping { Signal!int ch; @Slot void s(int v) {} }

__gshared int g_fromWorker = -99;

void main() {
    // Creating a @QObject on the main thread pins main as the runtime owner.
    auto p = newQObject!Ping();
    assert(qtd_moc_owner_check() == 1, "the main thread must be the runtime owner after first use");

    // A worker thread is correctly detected as a NON-owner. This detection is exactly what backs
    // the enforcement: a MUTATION (newQObject/destroy/register) off this thread would call
    // qtd_thread_guard and ABORT loudly — here we only QUERY, so we can assert the mechanism
    // without killing the process. Silent cross-thread map mutation (the old behavior) is UB.
    auto t = new Thread({ g_fromWorker = qtd_moc_owner_check(); });
    t.start();
    t.join();
    assert(g_fromWorker == 0, "a worker thread must be detected as a non-owner (0), not the owner");

    printf("metathread: owner=main (check=1), worker detected as non-owner (check=0) OK\n");
}
