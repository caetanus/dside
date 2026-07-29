import QtQuick
// Enum-typed properties written as a KEY STRING: the meta-object converts through QMetaEnum on
// write, so the numeric value never has to be known by the generator — the same generic channel a
// QColor literal uses. Every value here is deliberately NON-DEFAULT (the defaults are AlignTop,
// AlignLeft and ElideNone), so the comparison fails if the conversion silently does nothing.
Text {
    text: "enum"
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    wrapMode: Text.WordWrap
}
