// A `default property alias`: an alias is a REFERENCE, so a bare child of a user of this type
// lands on the alias TARGET — which is what the engine (and the dump) reaches it through.
import QtQml 2.15
QtObject {
    id: self
    property string tag: "alias holder"
    property QtObject someObject
    default property alias child: self.someObject
}
