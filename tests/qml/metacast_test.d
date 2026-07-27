module metacast_test;   // critics r8 #2: the metaobject must not lie about the object it represents
import qtmoc;
import core.stdc.stdio : printf;

// A runtime @QObject whose metaObject()->className() is "Dup".
@QObject class Dup {
    Signal!int ch;
    @Slot void s(int v) {}
}

void main() {
    auto o = newQObject!Dup();

    // The metaobject ANNOUNCES the class name...
    assert(o.mocClassName == "Dup", "metaObject()->className() must be \"Dup\"");

    // ...so qt_metacast MUST honor it. Before r8 #2 this returned null: the object claimed to be
    // a "Dup" yet denied being castable to one, breaking qobject_cast and type discovery.
    void* self = o.metaCast("Dup");
    assert(self !is null, "qt_metacast(\"Dup\") must return non-null");
    assert(self is qobjOf(o), "qt_metacast(\"Dup\") must return the QObject itself");

    // A genuine base still resolves (delegation to QObject::qt_metacast is intact).
    assert(o.metaCast("QObject") !is null, "qt_metacast(\"QObject\") must resolve the base");

    // An unrelated name must NOT resolve — a positive-only fix would be a different lie.
    assert(o.metaCast("QWidget") is null, "qt_metacast(\"QWidget\") must be null");
    assert(o.metaCast("Nonexistent") is null, "qt_metacast(unknown) must be null");

    printf("metacast: className+qt_metacast agree (self=%p) OK\n", self);
}
