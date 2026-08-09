// PROPERTIES WHOSE TYPE IS ONLY KNOWN AT RUN TIME — `var` holding an object, a map, and a member
// read by a name computed at run time. This is where mechanism 2 (QVariant) and mechanism 4
// (delegation) are decided, and it is ordinary application code rather than an edge case.
import QtQuick
Item {
    width: 220; height: 50
    property var config: ({ "mode": "wide", "size": 12, "tags": ["a", "b"] })
    property string key: "mode"
    property string mode: config[key]
    property int size: config["size"]
    property string first: config.tags[0]
    Text { text: mode + "/" + size + "/" + first }
}
