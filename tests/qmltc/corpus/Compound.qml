import QtQml
// Phase-10: compound assignment (+= etc.) and console.log (no-op).
QtObject {
    property int n: 5
    property string s: "a"
    function go() {
        n += 3;
        n *= 2;
        s += "b";
        console.log("tracing", n, s);
    }
    Component.onCompleted: go()
}
