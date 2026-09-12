// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A GAP PROBE, NOT A TEST: this document is EXPECTED to differ from the engine, and the entry
// `delegate-class-walk` in tests/expected-fails.json is what says so.
//
// THE DIFFERENCE: the two sides disagree on the `__class` of a delegate instance whose root type
// declares no properties of its OWN. The engine reports `QQuickColumn`; the compiled document
// reports `QQuickBasePositioner`, one class further up.
//
// The cause is the walk in tests/qmltc/qtd_qmlvalues.cpp, which climbs the meta-object chain while
// the class name does not start with 'Q' OR the class declares no properties of its own. Our object
// is a generated subclass of QQuickColumn; QQuickColumn adds nothing to QQuickBasePositioner, so the
// walk climbs past it. The comment there already names the weakness of the leading-Q test — every
// fixture in this corpus is called `Q…` by convention, so a generated class passes it too.
//
// Found 2026-09-12 by the object-path differential of QRequiredVarRole, whose delegate root was a
// Column for no reason of its own; that fixture now uses an Item so it fails for its own subject
// only, and this probe carries the difference. It reproduces at commit beb7bb7 and before it.
import QtQuick

Item {
    id: root
    // The REQUIRED declarations are part of the reproduction: without them the delegate instance is
    // a plain QQuickColumn on both sides and the two walks agree. With them the engine gives the
    // instance a QML subclass carrying those properties, and the two chains stop at different
    // levels. Narrowed by removing them, which made the probe pass.
    property var groups: JSON.parse('[{"label":"um","refs":[{"t":"a"}]}]')

    Column {
        Repeater {
            model: root.groups
            delegate: Column {
                required property string label
                required property var refs
                Item { width: 10; height: 10 }
            }
        }
    }
}
