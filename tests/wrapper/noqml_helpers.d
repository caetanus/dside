// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
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
                contextStr, contextInt, contextObject,   // ...and the value-returning ones (r14 #1)
                setModel, varText, varCount, newQObject, QmlVar, Property, Signal;   // ...the `var` slot
import std.stdio;
import qtmoc : QObjectUDA = QObject;   // the UDA; the class above is the C++ one

/// The smallest thing that has a `property var`. Its slot is QObject + QByteArray + QVariant, all
/// of them QtCore, which is the claim the assertion below makes good.
@QObjectUDA class VarHolder {
    @Property("rowsChanged") QmlVar rows;
    Signal!() rowsChanged;
}

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

    // ...AND THE `var` SLOT, WHICH IS NOT A QML HELPER AT ALL AND WAS GUARDED AS IF IT WERE.
    //
    // A `property var`'s storage is QObject, QByteArray and QVariant — QtCore, every one of them.
    // Behind the QtQml switch, `qtd_moc_var_write` compiled to an empty function, and the shape of
    // that failure is why this assertion is here rather than a compile probe: `setModel` builds its
    // QVariantList through calls that are QtCore and were never guarded, so the model was built;
    // the notify fired, because a signal is independent of any of this; and only the WRITE went
    // nowhere. QML then read `undefined` for that one property while every `@Property string` next
    // to it kept working. Measured on Android by the session that ships the reader: a blank page on
    // the phone and a rendered one on the desktop, from the same D source.
    //
    // So: write a model through the same call an application makes, and read it back. Without the
    // guard removed this comes back empty here, on the desktop, with no device needed.
    static struct Row { int n; string t; }
    auto vo = newQObject!VarHolder();
    setModel(vo, "rows", [Row(1, "um"), Row(2, "dois")]);
    // A SCALAR first, so a failure says which half is broken, and then the MODEL. The model is
    // counted rather than rendered: a row is a map and a map has no string form, so `varText` reads
    // back "" whether the property holds two rows or none — a check written on it would pass on an
    // empty property, which is precisely the state under test.
    import qtmoc : setProp;
    setProp(vo, "rows", 42);
    if (varText(vo, "rows") != "42") {
        writeln("noqml_helpers FAIL: a scalar written to a `var` property read back `",
                varText(vo, "rows"), "` without QtQml — the slot is QtCore and must not be "
                ~ "behind the QML switch");
        return;
    }
    setModel(vo, "rows", [Row(1, "um"), Row(2, "dois")]);
    const n = varCount(vo, "rows");
    if (n != 2) {
        writeln("noqml_helpers FAIL: setModel wrote 2 rows and the property holds ", n,
                " without QtQml (-1 means it is not a list at all)");
        return;
    }

    writeln("noqml_helpers OK: QML helpers link and no-op without QtQml — including the ones "
            ~ "that return a value, which must be the real body's (critics r14 #1) — and a `var` "
            ~ "property round-trips, scalar and model alike, since its slot needs no QtQml");
}
