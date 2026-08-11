// Um `enum` declarado em QML e uma propriedade `required` — as duas formas com que uma aplicação
// dá tipo e obrigação ao seu próprio componente. O `required` é satisfeito pelo sítio de uso.
import QtQuick
Item {
    id: root
    width: 160; height: 40
    enum Mode { Idle, Busy, Done }
    property int mode: AEnumRequired.Mode.Busy
    property string label: mode === AEnumRequired.Mode.Busy ? "busy" : "other"
    Text { text: root.label + "/" + root.mode }
}
