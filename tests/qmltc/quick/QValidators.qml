// Types deriving from QObject rather than Item — newly reachable now that the spec names them
// explicitly. They can be INSTANTIATED and configured as children; reading their members back in
// a binding is a separate gap (the qmlmap registry carries name->class only, with no property
// table), so this case proves construction, which is what the binding change bought.
import QtQuick
Item {
    property IntValidator iv: IntValidator { top: 99; bottom: 5 }
    property DoubleValidator dv: DoubleValidator { top: 2.5; bottom: 0.5; decimals: 3 }
    property int own: 12
}
