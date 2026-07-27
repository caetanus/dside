// @Property string in the runtime meta-object — the FOCUSED test that was missing (CRITICS #8).
// A D @QObject exposes @Property string with notify. Writing via setProperty and READING via
// property() both go through qt_metacall (WriteProperty/ReadProperty -> callProp), isolating
// the string READ path (qtd_qs_set) — the gap that was only exercised indirectly via
// signal/slot. No QApplication: property read/write needs no event loop.
import qtmoc;
import cxxrt, std.stdio;

@QObject class Model {
    Signal!string textChanged;
    @Property("textChanged") string text = "initial";   // Q_PROPERTY(QString text NOTIFY textChanged)
}

void main() {
    auto m = newQObject!Model();

    // ReadProperty of the initial value: the metacall reads the D field and converts it to QString
    // (the qtd_qs_set path). Before the fix this was a TODO and returned garbage/empty.
    assert(m.propStr("text") == "initial", "initial ReadProperty failed");

    // WriteProperty: setProperty -> D field + notify. Non-ASCII UTF-8 to catch a len bug.
    m.setProp("text", "olá çãé 42");
    assert(m.text == "olá çãé 42", "WriteProperty did not set the D field");

    // ReadProperty again: the new value must come back through the metacall.
    assert(m.propStr("text") == "olá çãé 42", "ReadProperty after write failed");

    writeln("cannon/t10 OK: @Property string read/write via qt_metacall round-trips (", m.propStr("text"), ")");
}
