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
    Signal!string withString;    // no toggle(string) exists — used to pin the compile-time refusal
    string log;
    void notASlot(int v) {}      // a plain method: not in the meta-object, so not connectable
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

    // The TYPED form: names instead of signature strings, checked at compile time. The overload is
    // chosen by the signal's parameter types, so the same slot name resolves differently per
    // signal — no qOverload needed.
    auto q = newQObject!Panel();
    connect!("plain",    "toggle")(q, q);
    connect!("withInt",  "toggle")(q, q);
    connect!("withBool", "toggle")(q, q);
    q.plain.emit(); q.withInt.emit(4); q.withBool.emit(false);
    assert(q.log == "[][i4][bF]", "typed connect dispatched wrongly: log = " ~ q.log);

    // Misuse is a BUILD error, not a runtime surprise. The positive case is asserted first, so a
    // negative that merely fails to instantiate for some unrelated reason can't pass vacuously.
    static assert(__traits(compiles, connect!("withInt", "toggle")(q, q)),
        "the valid typed connect must compile");
    static assert(!__traits(compiles, connect!("withInt", "nosuch")(q, q)),
        "connect to a missing slot name must not compile");
    static assert(!__traits(compiles, connect!("nosuch", "toggle")(q, q)),
        "connect from a missing signal name must not compile");
    // A signal whose parameters no overload of the slot accepts: the string form would have
    // thrown at runtime, and before that it failed silently.
    static assert(!__traits(compiles, connect!("withString", "toggle")(q, q)),
        "connect must not compile when no overload takes the signal's parameters");
    static assert(!__traits(compiles, connect!("withInt", "notASlot")(q, q)),
        "connect to a method that is not @Slot must not compile");

    p.plain.emit();
    p.withInt.emit(7);
    p.withBool.emit(true);
    p.withBool.emit(false);

    assert(p.log == "[][i7][bT][bF]",
        "overloaded slots dispatched to the wrong body: log = " ~ p.log);
    writefln("slot overload OK: toggle()/toggle(int)/toggle(bool) dispatched to their own bodies "
             ~ "(string form %s, typed form %s); bad typed connects rejected at compile time",
             p.log, q.log);
}
