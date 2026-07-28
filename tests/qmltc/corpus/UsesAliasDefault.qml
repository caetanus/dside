// The bare child lands on `someObject`, the target of the base type's default-property alias.
import QtQml
AliasHolder {
    property string hello: "parent"
    QtObject { property string hello: "child via alias"; property int n: 3 }
}
