// `listProp: [ Type{}, Type{} ]` — an array binding fills a list<> property. Each element is an
// ordinary child object; the engine reaches it at its INDEX in that property, so that is the
// dump label.
import QtQml
QtObject {
    property string hello: "parent"
    property list<QtObject> kids
    kids: [
        QtObject { property string hello: "kid zero"; property int n: 0 },
        QtObject { property string hello: "kid one";  property int n: 1 }
    ]
}
