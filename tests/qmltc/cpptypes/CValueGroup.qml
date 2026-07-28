// A VALUE-type grouped property: `vt` is a Q_GADGET (ValueTypeGroup), not a QObject*. Assigning
// `vt.count` cannot go through the group object the way a QObject group does — there is no object.
// QML reads the value, changes the member, and writes the whole value back.
import QmltcTests
PrivatePropertyType {
    vt.count: 42
    property int mirrored: vt.count
}
