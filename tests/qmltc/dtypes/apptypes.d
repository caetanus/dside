// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// App-defined QML types written in D — the point being that QML does not care which language
// produced a type, only that it has a meta-object. These are plain `@QObject` classes: qtmoc
// builds their QMetaObject by CTFE and `qmlRegisterType!T` exports them as QML elements, exactly
// as a C++ type with Q_OBJECT/QML_ELEMENT would be.
//
// The SAME module feeds both sides of the differential:
//   - the ORACLE registers these types and lets the real QML engine instantiate the .qml;
//   - the qmltc-d-generated D class DERIVES from them (plain D inheritance — no C++ trampoline,
//     no meta round-trip: an inherited @Property is a real D field).
module apptypes;

import qtmoc;

/// A scalar-property base: `value` with a notify signal, plus a slot QML can call.
@QObject class Backend {
    Signal!() valueChanged;
    Signal!() labelChanged;
    @Property("valueChanged") int value = 0;
    @Property("labelChanged") string label = "";
    @Slot void bump() { value = value + 1; valueChanged.emit(); }
    /// CHANGES THE PUBLISHED OBJECT, which is the only way a differential can ask whether a compiled
    /// read of `theme.<member>` is LIVE or a one-shot snapshot. Invoked by name on the root from the
    /// `.set` file, on both sides: the engine re-evaluates its binding, and ours has to hear the
    /// notify the runtime connected when the name resolved. Without this the fixture proves the
    /// value is right once and says nothing about whether it stays right.
    @Slot void retheme() {
        appTheme.paper = "#ffffff";
        appTheme.paperChanged.emit();
        appTheme.ink = "#101010";
        appTheme.changed.emit();
    }
}

/// A second type, to prove the registry is a table and not a special case.
@QObject class Meter {
    Signal!() readingChanged;
    @Property("readingChanged") double reading = 0.0;
}

/// AN OBJECT THE APPLICATION PUBLISHES BY NAME, not a type QML instantiates — a palette, which is
/// what a real application's `theme` is. It is here rather than in the type list above because a
/// context property is a different thing from a registered type: nothing in the document names
/// `Theme`, and the compiler cannot look the name up in any registry. What it CAN do is what the
/// engine does — ask the context at run time and read the member through the meta-object — and that
/// is what the fixture beside this measures.
///
/// One notify for the whole object (`changed`) as well as per-property ones, because both spellings
/// occur in the wild and a reader has to try both.
@QObject class Theme {
    Signal!() changed;
    Signal!() paperChanged;
    @Property("paperChanged") string paper = "#fdf6e3";
    @Property("changed") string ink = "#073642";
    @Property("changed") int steps = 3;
}

/// ...and the publication itself, in a MODULE CONSTRUCTOR, so it happens in every program this
/// module is linked into — the compiled fixture and the oracle both — with no driver having to
/// remember. There is no engine yet at this point and there does not need to be: the name is queued
/// and applied to whichever engine appears first. See publishContext.
__gshared Theme appTheme;
shared static this() {
    // `newQObject!T`, not `new T`: a D-defined @QObject's C++ carrier is built by the factory (it is
    // what registers the instance and hands it a QMetaObject), and `new` alone leaves `qobjOf` null.
    // Measured — the first version of this published a null and BOTH sides of the differential then
    // answered `Cannot read property 'paper' of null`, which compared equal and looked green.
    appTheme = newQObject!Theme();
    publishContext("theme", appTheme);
}

/// ONE list, two consumers — the registry can never drift from what is registered:
///   registerAppTypes()  -> what the ENGINE (oracle side) can instantiate;
///   appTypesDoc         -> the `.qmltypes` qmltc-d reads to compile against these types.
import std.meta : AliasSeq;
alias AppQmlTypes = AliasSeq!(Backend, Meter);

enum appUri = "AppTypes";
enum appVMaj = 1, appVMin = 0;

/// Registered under `import AppTypes 1.0`. Called by the oracle driver before the engine loads
/// the .qml, and by nothing else — the compiled-to-D side needs no registration at all.
void registerAppTypes() {
    static foreach (T; AppQmlTypes)
        qmlRegisterType!T(appUri, appVMaj, appVMin, T.stringof);
}

/// The `.qmltypes` description of these types, built by CTFE from the same meta-object info.
/// This is the type REGISTRY qmltc-d consumes — Qt's own format, and Qt's own reader validates it.
enum appTypesDoc = () {
    string[] cs;
    static foreach (T; AppQmlTypes)
        cs ~= qmlTypeComponent!T(appUri, appVMaj, appVMin, T.stringof);
    return qmlTypesModule(cs);
}();
