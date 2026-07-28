// Qt supports OVERLOADED slots: toggle(), toggle(int) and toggle(bool) are three distinct
// meta-object entries told apart by their full signature, and moc emits all three. The D runtime
// keys slots by function SYMBOL rather than by name so it does the same — keying by name would
// collapse them into one entry and silently drop the rest.
//
// bool vs int is the pair most easily confused: both are one word on the wire, so a dispatcher
// that resolved by name (or by arity) would run the wrong body and still "work".
import qtmoc, std.stdio;

@QObject class Panel {
    Signal!() plain;
    Signal!int  withInt;
    Signal!bool withBool;
    string log;
    @Slot void toggle()        { log ~= "[]"; }
    @Slot void toggle(int v)   { log ~= "[i" ~ (cast(char)('0' + v)) ~ "]"; }
    @Slot void toggle(bool b)  { log ~= b ? "[bT]" : "[bF]"; }
}

void main() {
    auto p = newQObject!Panel();
    // Each connect names a DIFFERENT signature of the same slot name.
    connectMeta(p, "plain()",     p, "toggle()");
    connectMeta(p, "withInt(int)",  p, "toggle(int)");
    connectMeta(p, "withBool(bool)", p, "toggle(bool)");

    p.plain.emit();
    p.withInt.emit(7);
    p.withBool.emit(true);
    p.withBool.emit(false);

    assert(p.log == "[][i7][bT][bF]",
        "overloaded slots dispatched to the wrong body: log = " ~ p.log);
    writefln("slot overload OK: toggle()/toggle(int)/toggle(bool) each dispatched to its own "
             ~ "body (log %s)", p.log);
}
