import QtQuick.Templates as T
// A VALUE group that is a plain Q_GADGET: `icon` on a Control is a QQuickIcon, which has its own
// meta-object, so setVgroup does a read-modify-write through it. A value type marked `^` in the
// property table is reached through an EXTENSION instead (QFont -> QQuickFontValueType) and has no
// meta-object of its own — that one stays refused, and telling the two apart is what made this
// safe to enable. The registry supplies the distinction; it is not a list of type names.
T.Button {
    text: "b"
    icon.width: 24
    icon.height: 18
    icon.name: "ok"
}
