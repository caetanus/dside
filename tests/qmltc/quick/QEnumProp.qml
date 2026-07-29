import QtQuick
// Enum-typed properties written as a KEY STRING: the meta-object converts through QMetaEnum on
// write, so the numeric value never has to be known by the generator — the same generic channel a
// QColor literal uses. Every value here is deliberately NON-DEFAULT (the defaults are AlignTop,
// AlignLeft and ElideNone), so the comparison fails if the conversion silently does nothing.
Text {
    text: "enum"
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    wrapMode: Text.WordWrap
    // `Qt` is the namespace enum holder, not a bound type. The COMPARISON path always accepted it,
    // so an assignment has to as well — otherwise the same `Qt.AlignRight` compiles in one
    // position and not the other. AlignRight is not the default (AlignLeft is).
    verticalAlignment: Qt.AlignBottom
}
