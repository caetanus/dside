module homonym_b;   // defines `Dup` too — different signal/slot/property names => different shape
import qtmoc;
__gshared int b_hit = -1;
@QObject class Dup {
    Signal!int betaCh;
    @Property("betaCh") int bv = 0;
    @Slot void betaSlot(int v) { b_hit = v; }
}
