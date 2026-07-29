import QtQml 2.15
// Phase-10: function-expression handler bodies `on<Sig>: function(a,b){...}`.
QtObject {
    property int hits: 0
    signal ping
    onPing: function() { hits++; }
    property string who: ""
    property int amt: 0
    signal paid(string name, int cents)
    onPaid: function(name, cents) { who = name; amt = cents; }
    function fireAll() { ping(); ping(); paid("Ada", 99); }
    Component.onCompleted: fireAll()
}
