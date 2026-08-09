// A TIMER THAT HAS ALREADY FIRED. `repeat`/`interval`/`running` plus a handler mutating state is
// the most ordinary piece of application machinery there is, and nothing in the styles corpus has
// one. The interval is short and the comparison happens after the scene has run, so both sides
// have advanced; `triggeredOnStart` makes the first tick deterministic.
import QtQuick
Item {
    id: root
    width: 120; height: 40
    property int ticks: 0
    Timer {
        interval: 1000000; running: true; repeat: false; triggeredOnStart: true
        onTriggered: root.ticks += 1
    }
    Text { text: "ticks=" + root.ticks }
}
