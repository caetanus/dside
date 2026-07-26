// @Property string no meta-objeto runtime — o teste FOCADO que faltava (CRITICS #8).
// Um @QObject D expõe @Property string com notify. Escrever via setProperty e LER via
// property() passam pelo qt_metacall (WriteProperty/ReadProperty -> callProp), isolando
// o caminho de LEITURA de string (qtd_qs_set) — a lacuna que só era exercitada de
// through por sinal/slot. Sem QApplication: property read/write não precisa de event loop.
import qtmoc;
import cxxrt, std.stdio;

@QObject class Model {
    Signal!string textChanged;
    @Property("textChanged") string text = "initial";   // Q_PROPERTY(QString text NOTIFY textChanged)
}

void main() {
    auto m = newQObject!Model();

    // ReadProperty do valor inicial: o metacall lê o campo D e o converte pra QString
    // (o caminho qtd_qs_set). Antes do fix isso era um TODO e devolvia lixo/vazio.
    assert(m.propStr("text") == "initial", "ReadProperty inicial falhou");

    // WriteProperty: setProperty -> campo D + notify. UTF-8 non-ASCII pra pegar bug de len.
    m.setProp("text", "olá çãé 42");
    assert(m.text == "olá çãé 42", "WriteProperty não setou o campo D");

    // ReadProperty de novo: o valor novo tem que voltar pelo metacall.
    assert(m.propStr("text") == "olá çãé 42", "ReadProperty após write falhou");

    writeln("cannon/t10 OK: @Property string read/write via qt_metacall round-trips (", m.propStr("text"), ")");
}
