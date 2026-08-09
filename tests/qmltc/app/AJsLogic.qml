// REAL JAVASCRIPT: a for loop, an array, an object literal, string building. The styles corpus has
// arithmetic and ternaries and almost nothing else, so this is the shape that decides whether the
// static translator holds up or the expression goes to the engine — either is a pass, but the
// document has to BEHAVE the same.
import QtQuick
Item {
    width: 220; height: 50
    property var items: [3, 1, 4, 1, 5]
    property int sum: {
        var t = 0;
        for (var i = 0; i < items.length; ++i) t += items[i];
        return t;
    }
    property string joined: items.join("-")
    function biggest() {
        var m = items[0];
        for (var i = 1; i < items.length; ++i) if (items[i] > m) m = items[i];
        return m;
    }
    property int peak: biggest()
    Text { text: joined + " sum=" + sum + " peak=" + peak }
}
