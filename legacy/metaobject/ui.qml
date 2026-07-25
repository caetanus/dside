import QtQuick

// Headless round-trip surface. `backend` is a D QObject (context property).
Item {
    // D property -> QML binding; re-evaluates when countChanged fires.
    property int mirror: backend.count

    // QML -> D slot.
    function bump() { backend.increment() }
}
