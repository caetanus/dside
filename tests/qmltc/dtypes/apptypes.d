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
}

/// A second type, to prove the registry is a table and not a special case.
@QObject class Meter {
    Signal!() readingChanged;
    @Property("readingChanged") double reading = 0.0;
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
