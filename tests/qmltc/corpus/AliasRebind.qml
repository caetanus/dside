// Assigning THROUGH an alias reassigns the alias's TARGET — including installing a binding with
// Qt.binding, or dropping one with a plain value. The selector lives on the target property.
import QtQml
QtObject {
    id: root
    property int dummy: 12
    property int origin: dummy / 2
    property alias aliasToOrigin: root.origin
    function viaAlias() { aliasToOrigin = Qt.binding(function() { return dummy * 3 }); }
    function constViaAlias() { aliasToOrigin = 42; }
}
