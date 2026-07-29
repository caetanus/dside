import QtQuick.Templates as T
// A QUALIFIED import: Qt's own QtQuick.Controls are written `import QtQuick.Templates as T` and
// rooted `T.Button`. The qualifier names the import, not a scope of the type — without stripping
// it, all 69 of Qt's shipped Controls files fail at the root and nothing in them is reached.
T.Button {
    objectName: "qualified"
    text: "ok"
    property int n: 7
}
