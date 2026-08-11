// Um tipo local com o SEU próprio id, o seu próprio alias e o seu próprio nome de propriedade.
// O gémeo CLocalTwo declara os MESMOS nomes com valores diferentes — se algum estado do compilador
// atravessar a fronteira entre documentos, os dois trocam valores e o diferencial vê-o.
import QtQuick
Rectangle {
    id: root
    property int tag: 1
    property string origin: "one"
    Rectangle { id: box; color: "#111111" }
    width: 10 + tag; height: 10
}
