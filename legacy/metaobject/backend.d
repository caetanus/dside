// backend.d — a D QObject exposed to QML, defined declaratively.
// The meta-object description AND the Qt<->D dispatch are CTFE-generated from
// the UDAs by `mixin QtObject` — no moc, no external codegen.
module backend;

import qtmeta;

final class Backend {
    @qtProperty int count;

    @qtSlot void increment() {
        ++count;
        notify!"count"();          // fire countChanged -> QML binding re-evaluates
    }

    mixin QtObject;
}
