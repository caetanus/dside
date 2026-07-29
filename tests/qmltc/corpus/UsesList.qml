// Bare children land in the base type's list<> default property and are dumped at their index.
import QtQml 2.15
ListHolder {
    property string hello: "parent"
    QtObject { property string hello: "item zero"; property int n: 0 }
    QtObject { property string hello: "item one";  property int n: 1 }
}
