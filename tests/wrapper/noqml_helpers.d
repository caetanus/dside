// The transpiler-support helpers in the shared moc runtime (QQmlContext attach, module bootstrap,
// default-property append) are QML features living in a unit that EVERY binding compiles — the
// QtWidgets and libsample ones included. Their bodies are guarded; their SYMBOLS are deliberately
// not, so the D side can declare them unconditionally without a per-binding version identifier.
//
// That contract had no test. It is what broke the default build once (a QML-only type escaped its
// #ifdef) and it is what a future "split qtmoc-core from qtmoc-qml" must not silently violate: the
// C++ compile probes (qtmoc-probe-noqml) prove the unit COMPILES without QtQml, and this proves a
// non-QML binding still LINKS and RUNS code that calls the helpers — as no-ops.
import qt.widgets.qobject : QObject;   // qtmoc exports a `QObject` UDA too — name it explicitly
import qtmoc : attachContext, ensureModule, listAppend, bindLeaf, connectNotify,
                contextStr, contextInt, contextObject;   // ...and the value-returning ones (r14 #1)
import std.stdio;

void main() {
    auto o = new QObject();   // `null` would be ambiguous with the adopt ctor this(void*)

    // Each of these is a no-op in a binding with no QtQml: what is under test is that the symbol
    // exists (link) and that calling it is harmless (run), not that it does anything here.
    attachContext(o);
    ensureModule("QtQuick");
    auto appended = listAppend(o, "data", o);
    bindLeaf(o, "objectName", "objectNameChanged(QString)", o, "deleteLater()");
    connectNotify(o, "objectName", o, "deleteLater()");

    // listAppend reports failure rather than pretending: no QtQml means no list to append to.
    if (appended) { writeln("noqml_helpers FAIL: listAppend claimed success without QtQml"); return; }

    // ...and the ones that return a VALUE, which is where the first stub attempt broke the
    // semantics it claimed to preserve (critics r14 #1). `qtd_context_prop_qs` always returns a
    // QString — with QML or without — and D frees it after reading. A stub that returned nullptr
    // because the return type is a pointer turned an empty string into a null dereference inside
    // qsToD. So the shape under test is not "the symbol links": it is that the VALUE is the one the
    // real body produces.
    auto cs = contextStr(o, "anything");
    if (cs.length != 0) {
        writeln("noqml_helpers FAIL: contextStr returned `", cs, "` without QtQml, expected empty");
        return;
    }
    auto ci = contextInt(o, "anything");
    if (ci != 0) { writeln("noqml_helpers FAIL: contextInt returned ", ci); return; }
    auto co = contextObject(o);
    if (co !is null) { writeln("noqml_helpers FAIL: contextObject returned non-null"); return; }

    // ...and the object still works, i.e. the no-ops did not corrupt anything.
    o.setObjectName("still-alive");
    if (o.objectName().toString() != "still-alive") {
        writeln("noqml_helpers FAIL: object damaged"); return;
    }

    writeln("noqml_helpers OK: QML helpers link and no-op without QtQml — including the ones "
            ~ "that return a value, which must be the real body's (critics r14 #1)");
}
