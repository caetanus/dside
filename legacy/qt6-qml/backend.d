// backend.d — the app's D model, exposed to QML via the native meta-object.
module backend;

import qtmeta;

final class Dashboard {
    @qtProperty int counter;
    @qtProperty int cpu;
    @qtProperty int mem;
    @qtProperty int net;

    @qtSlot void increment() {
        counter = counter + 1;
        notify!"counter"();
    }

    @qtSlot void refresh() {
        // deterministic "metrics" so screenshots are reproducible
        cpu = (cpu * 7 + 31) % 100;
        mem = (mem * 5 + 47) % 100;
        net = (net * 3 + 71) % 100;
        notify!"cpu"();
        notify!"mem"();
        notify!"net"();
    }

    mixin QtObject;
}
