// critics r8 #4: the meta-method contract is enforced at COMPILE TIME, so a declaration whose
// semantics the runtime can't honor never builds (instead of compiling and then lying). This
// target's proof IS that it compiles: each `static assert` fails the build if the rule regresses.
import qtmoc;
import core.stdc.stdio : printf;

// A @Slot that returns a value: the runtime would discard the return (invokeMethod with
// Q_RETURN_ARG answered false) -> must be REJECTED.
@QObject class BadSlot { @Slot int answer() { return 42; } }
static assert(!__traits(compiles, newQObject!BadSlot()),
    "non-void @Slot must be rejected at compile time");

// A @Property whose NOTIFY names no signal of the class: resolved to index -1 silently
// (no notification ever fired) -> must be REJECTED.
@QObject class BadNotify { Signal!int ch; @Property("nope") int v; }
static assert(!__traits(compiles, newQObject!BadNotify()),
    "unknown NOTIFY must be rejected at compile time");

// A @Property whose NOTIFY signal has an INCOMPATIBLE signature (callProp emits one arg of the
// property type; a 2-arg notify would read garbage for arg 2) -> must be REJECTED.
@QObject class BadNotifySig { Signal!(int, int) ch; @Property("ch") int v; }
static assert(!__traits(compiles, newQObject!BadNotifySig()),
    "NOTIFY with an incompatible signature must be rejected at compile time");

// The honest, valid shapes still compile: void slot, parameterless notify, typed notify.
@QObject class Good {
    Signal!int ch;
    Signal!() bumped;
    @Slot void set(int v) { ch.emit(v); }
    @Property("ch") int typed = 0;
    @Property("bumped") int counter = 0;
}
static assert(__traits(compiles, newQObject!Good()),
    "valid @Slot/@Property/NOTIFY shapes must still compile");

// A property write must REPORT a miss. QObject::setProperty returns false for an undeclared name
// and then creates a DYNAMIC property, so the write appears to succeed while nothing the
// meta-object knows about changed — invisible across ~1400 generated call sites until it was made
// to throw.
@QObject class Writable { @Property int good; }

void main() {
    auto w = newQObject!Writable();
    setProp(w, "good", 7);
    assert(propInt(w, "good") == 7, "a declared write must land");
    bool threw = false;
    try setProp(w, "nosuch", 1); catch (Exception) { threw = true; }
    assert(threw, "writing an undeclared name must throw rather than create a dynamic property");

    printf("metacontract: slot-return + NOTIFY rules enforced at compile time OK\n"); }
