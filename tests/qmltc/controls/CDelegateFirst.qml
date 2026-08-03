import QtQuick
import QtQuick.Templates as T
// A `Component` property is a TEMPLATE the type builds children FROM, so it has to be in place
// before any child is appended. Qt's Menu is the case that names it: an `Action` put in
// `contentData` is wrapped into a `MenuItem` made from `delegate`, and with the delegate still null
// the Action is appended raw. Measured behind the attached-child gate, that was 144 properties per
// item the engine has and we do not, times seven Actions, on every document with a context menu —
// 2016 of the 2034 paths in that whole bucket.
//
// `count` is the observable, and it is the only one: it is how many ITEMS the menu holds, and an
// Action appended raw is not one. Everything geometric stays at zero because a closed menu lays
// nothing out, and the Action's own `text` reads the same either way — checked, so that the test
// compares the thing that moves. With the delegate bound after the children this reads 0 against
// the engine's 2.
T.Menu {
    id: menu

    delegate: T.MenuItem {
        padding: 7
        implicitHeight: 21
    }

    T.Action { text: "one" }
    T.Action { text: "two" }

    property int itemCount: menu.count
}
