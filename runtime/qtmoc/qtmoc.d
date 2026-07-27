// qtmoc — sinais/slots para QObjects definidos em D, SEM moc: o meta-objeto é
// construído em tempo de execução (QMetaObjectBuilder, ver qtdmoc.cpp) e, via
// CTFE + __traits, geramos as assinaturas, o emit dos sinais e o despacho dos
// slots. O usuário só marca a classe com @QObject e os métodos com @Slot:
//
//     @QObject class Counter {
//         Signal!int valueChanged;                                   // um sinal
//         @Slot void setValue(int v) { ...; valueChanged.emit(v); }  // um slot
//     }
//
//     auto c = newQObject!Counter();                    // constrói o meta-objeto
//     connectMeta(c, "valueChanged(int)", c, "onValue(int)");
//
// Em D uma UDA sozinha não injeta membros nem construtor — por isso a instância
// nasce pela factory newQObject!T (que fica com o void* do QObject num registro
// externo, em vez de um campo dentro da classe do usuário).
module qtmoc;

import std.traits : Parameters, hasUDA, getUDAs;

// ---- runtime C++ (qtdmoc.cpp) -----------------------------------------------
alias SlotCb = extern (C) void function(void*, int, void**) nothrow;
alias PropCb = extern (C) void function(void*, int, int, void**) nothrow;
extern (C) nothrow {
    void* qtd_moc_new(const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int, void*, SlotCb, PropCb);
    // Register a D @QObject type as a QML element (only linked in for QtQml bindings).
    alias MakeCb = extern (C) void* function(void*, void*) nothrow;
    alias DestroyCb = extern (C) void function(void*, void*) nothrow;
    void* qtd_qml_register_type(const(char)*, int, int, const(char)*,
                      const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int,
                      MakeCb, DestroyCb, SlotCb, PropCb);
    void  qtd_moc_activate(void*, int, void**);
    void* qtd_connect_meta(void*, const(char)*, void*, const(char)*);
    void* qtd_metacast(void*, const(char)*);   // QObject::qt_metacast(n) sobre um qobj — pro teste de identidade
    const(char)* qtd_moc_classname(void*);     // metaObject()->className() do qobj
    // marshaling de QString (implementado em qtdmoc.cpp, que linka QtCore)
    void* qtd_str_to_qs(const(char)*, int);
    void  qtd_qs_free(void*);
    void* qtd_tr(const(char)*, const(char)*, const(char)*, int);   // QCoreApplication::translate
    bool  qtd_install_translator(const(char)*);                    // new QTranslator + install (C++)
    void  qtd_qs_set(void*, const(char)*, int);   // assign a D string into an existing QString
    int   qtd_qs_utf8len(void*);
    void  qtd_qs_utf8(void*, char*);
    // acesso a propriedades por nome (via QVariant)
    int   qtd_prop_get_int(void*, const(char)*);
    void  qtd_prop_set_int(void*, const(char)*, int);
    void* qtd_prop_get_qs(void*, const(char)*);
    void  qtd_prop_set_qs(void*, const(char)*, const(char)*, int);
}

// ---- callback error policy (round-4 #6: silence is not acceptable) ----------
// A slot/property/signal callback invoked BY Qt must be `nothrow` — a D exception can't
// unwind across the C++ frame. Instead of swallowing it, record it: a thread-local last
// error + count (inspectable/testable), an optional global hook, and a debug stderr note.
// (Errors — asserts, etc. — are bugs and are intentionally NOT caught here: they terminate.)
__gshared void function(Throwable) nothrow qtdCallbackErrorHook;   // opt-in global sink
size_t qtdCallbackErrors;          // thread-local (module scope) — count for asserts/tests
Throwable qtdLastCallbackError;    // thread-local — the most recent swallowed exception
void qtdOnCallbackError(Throwable e) nothrow {
    qtdCallbackErrors++;
    qtdLastCallbackError = e;
    if (qtdCallbackErrorHook !is null) qtdCallbackErrorHook(e);
    debug {
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "qtd: callback threw (swallowed at C++ boundary): %.*s\n",
            cast(int) e.msg.length, e.msg.ptr);
    }
}

// converte um QString* (arg de meta-call) numa string D.
string qsToD(void* qs) {
    int n = qtd_qs_utf8len(qs);
    auto buf = new char[n];
    if (n) qtd_qs_utf8(qs, buf.ptr);
    return cast(string) buf[0 .. n];
}

// ---- tradução (tr / translate / install) ------------------------------------
private string trImpl(string context, string source, string disambig, int n) {
    auto qs = qtd_tr((context ~ "\0").ptr, (source ~ "\0").ptr,
                     disambig is null ? null : (disambig ~ "\0").ptr, n);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}

/// `tr` LIVRE e UFCS — `"foo".tr`, `"foo".tr("disambiguation")`. O CONTEXTO é o NOME do módulo
/// do chamador (via `__MODULE__`, que é resolvido no call site) — casando exatamente com o que o
/// lupdate-d extrai, então a mesma `.qm` cobre extração e runtime. Sem tradutor/`.qm` cobrindo a
/// string, o Qt devolve `source`, então é sempre seguro. Para contexto explícito use `translate`.
string tr(string source, string disambiguation = null, int n = -1, string context = __MODULE__) {
    return trImpl(context, source, disambiguation, n);
}

/// `translate` estilo Qt: contexto EXPLÍCITO. `translate("Contexto", "foo")` — igual ao que o
/// lupdate-d reconhece como `[QCoreApplication.]translate("Ctx","src")`.
string translate(string context, string source, string disambiguation = null, int n = -1) {
    return trImpl(context, source, disambiguation, n);
}

/// Instala um tradutor SEM `_new`: `QTranslator.install("app_pt")`. O QTranslator (e um
/// QCoreApplication, se ainda não houver) são construídos no lado C++ — o usuário nunca
/// constrói nada à mão. `.qm` vazio -> tradutor vazio (identidade). Retorna se o `.qm` carregou.
struct QTranslator {
    static bool install(string qm = "") { return qtd_install_translator((qm ~ "\0").ptr); }
}

/// UDA de classe: marca um QObject D com meta-objeto em runtime (sinais/slots).
struct QObject {}
/// UDA de método: slot (invocável por Qt / conectável a um sinal).
struct Slot {}
/// UDA de campo: expõe o campo como Q_PROPERTY. `notify` = nome do sinal de
/// mudança (opcional), p.ex. @Property("valueChanged") int value;
struct Property { string notify = ""; }

/// Um sinal com os tipos de argumento dados. Emitir chama QMetaObject::activate.
struct Signal(Args...) {
    private void* _owner;   // o QObject (qtd) dono
    private int   _idx;     // índice local do sinal no meta-objeto
    void _bind(void* owner, int idx) { _owner = owner; _idx = idx; }
    void emit(Args args) {
        void*[Args.length + 1] argv;
        void*[Args.length + 1] tofree = null;             // QStrings a liberar depois
        argv[0] = null;                                   // slot de retorno (void)
        static foreach (i; 0 .. Args.length) {
            static if (is(Args[i] == string)) {
                argv[i + 1] = qtd_str_to_qs(args[i].ptr, cast(int) args[i].length);
                tofree[i + 1] = argv[i + 1];
            } else argv[i + 1] = cast(void*) &args[i];
        }
        qtd_moc_activate(_owner, _idx, argv.ptr);
        static foreach (i; 1 .. Args.length + 1)
            if (tofree[i]) qtd_qs_free(tofree[i]);
    }
    void opCall(Args args) { emit(args); }
}

// ---- registro por-objeto (evita injetar membros na classe do usuário) -------
struct MocReg {
    void* qobj;                                    // o QObject subjacente
    void delegate(int, void**) nothrow disp;       // despacho de slots (captura o objeto)
    void delegate(int, int, void**) nothrow prop;  // read/write de propriedades
}
__gshared MocReg[void*] _reg;              // chave = ponteiro do objeto D

extern (C) void __mocGlobalDispatch(void* dobj, int idx, void** args) nothrow {
    if (auto p = dobj in _reg) p.disp(idx, args);
}
extern (C) void __mocGlobalProp(void* dobj, int idx, int write, void** args) nothrow {
    if (auto p = dobj in _reg) p.prop(idx, write, args);
}
// Chamado pelo destrutor do QtdMocObject (C++) -> solta a entrada de `_reg`, fechando o
// side-table quando o objeto morre (não só no caminho QML). Registrado uma vez no init.
extern (C) void __mocGlobalDestroy(void* dobj) nothrow { _reg.remove(dobj); }
private alias MocDestroyCb = extern (C) void function(void*) nothrow;
extern (C) void qtd_moc_set_destroy_cb(MocDestroyCb) nothrow;
shared static this() { qtd_moc_set_destroy_cb(&__mocGlobalDestroy); }

// Vida útil do side-table (_reg + g_moAttach): um objeto criado por `newQObject!T` mantém sua
// entrada de `_reg` enquanto o QtdMocObject C++ existir. Se ele for destruído (parented a um
// QObject cujo pai morre, ou criado pelo engine QML), o destrutor limpa AMBOS os side-tables via
// este callback. Um QtdMocObject sem pai NÃO é auto-deletado (vive até o fim do processo) — é o
// tempo de vida esperado de um hub de sinais/slots top-level, igual a um QObject C++ sem pai.

/// Ponteiro do QObject subjacente: um void* cru passa direto; um @QObject D é
/// resolvido pelo registro (null se não registrado).
void* qobjOf(T)(T o) {
    static if (is(T == void*)) return o;
    else {
        if (auto p = cast(void*) o in _reg) return p.qobj;
        return null;
    }
}

/// qt_metacast por nome sobre o QObject subjacente. Retorna o ponteiro do QObject se `n`
/// bate a própria classe (ou uma base), null caso contrário — o mesmo contrato de
/// qobject_cast. Existe pra provar que o metaobject não mente sobre o objeto (critics r8 #2).
void* metaCast(T)(T o, string n) {
    return qtd_metacast(qobjOf(o), (n ~ "\0").ptr);
}

/// metaObject()->className() do QObject subjacente (pra testar identidade de tipo).
string mocClassName(T)(T o) {
    import core.stdc.string : strlen;
    auto p = qtd_moc_classname(qobjOf(o));
    return p is null ? null : cast(string) p[0 .. strlen(p)].idup;
}

// ---- CTFE: mapeamento tipo D -> assinatura C++ ------------------------------
template cppSig(T) {
         static if (is(T == int))    enum cppSig = "int";
    else static if (is(T == bool))   enum cppSig = "bool";
    else static if (is(T == double)) enum cppSig = "double";
    else static if (is(T == float))  enum cppSig = "float";
    else static if (is(T == uint))   enum cppSig = "uint";
    else static if (is(T == string)) enum cppSig = "QString";
    else static assert(0, "qtmoc: tipo de sinal/slot ainda não suportado: " ~ T.stringof);
}
string sigString(string name, Args...)() {
    string s = name ~ "(";
    static foreach (i, A; Args) s ~= (i ? "," : "") ~ cppSig!A;
    return s ~ ")";
}

// nomes dos sinais (campos Signal!...) e slots (@Slot), na ordem de allMembers.
template signalMembers(T) {
    template isSig(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) enum isSig = true;
        else enum isSig = false;
    }
    enum signalMembers = mocFilter!(T, isSig);
}
template slotMembers(T) {
    template isSlot(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == function))
            enum isSlot = hasUDA!(__traits(getMember, T, m), Slot);
        else enum isSlot = false;
    }
    enum slotMembers = mocFilter!(T, isSlot);
}
string[] mocFilter(T, alias pred)() {
    string[] r;
    static foreach (m; __traits(allMembers, T))
        static if (m.length && pred!m) r ~= m;
    return r;
}

// assinaturas ("nome(tipos)") de sinais/slots.
string[] signalSigs(T)() {
    string[] r;
    static foreach (m; signalMembers!T) {{   // {{ }} => escopo por iteração (A...)
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...))
            r ~= sigString!(m, A);
    }}
    return r;
}
string[] slotSigs(T)() {
    string[] r;
    static foreach (m; slotMembers!T)
        r ~= sigString!(m, Parameters!(__traits(getMember, T, m)));
    return r;
}

// campos marcados com @Property.
template propMembers(T) {
    template isProp(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == function)) enum isProp = false;
        else enum isProp = hasUDA!(__traits(getMember, T, m), Property);
    }
    enum propMembers = mocFilter!(T, isProp);
}
string[] propTypes(T)() {
    string[] r;
    static foreach (m; propMembers!T) r ~= cppSig!(typeof(__traits(getMember, T, m)));
    return r;
}
// nome do sinal de notify de uma @Property (tolera @Property sem parênteses).
template propNote(alias sym) {
    private alias U = getUDAs!(sym, Property);
    static if (is(U[0])) enum propNote = "";          // @Property (tipo) -> sem notify
    else                 enum propNote = U[0].notify;  // @Property()/@Property("x")
}
// índice (na ordem de signalMembers) do sinal de notify de cada propriedade, ou -1.
int[] propNotify(T)() {
    int[] r;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        int idx = -1, i = 0;
        static foreach (s; signalMembers!T) { if (s == note) idx = i; i++; }
        r ~= idx;
    }}
    return r;
}

// ---- contrato de meta-métodos (critics r8 #4) -------------------------------
// O metaobject não pode aceitar uma declaração cuja semântica ele não honra:
//   * um @Slot Qt retorna void. Um método que retorna valor é um INVOKABLE — o
//     runtime não marshala o retorno (ele era descartado em silêncio, e
//     QMetaObject::invokeMethod com Q_RETURN_ARG respondia false). Rejeite.
//   * uma @Property("notifySig") cujo NOTIFY não nomeia um Signal desta classe
//     resolvia pra índice -1 em silêncio (nenhuma notificação jamais dispara).
//     E se nomeia um Signal, a assinatura precisa casar com o que callProp emite
//     (0 args, ou 1 arg do tipo da propriedade) — senão o slot receptor lê lixo.
// Tudo em compile time, com mensagem apontando a correção. É uma função (escopo de
// statement) instanciada por uma chamada no topo de cada caminho de registro — a
// instanciação dispara os static asserts; em runtime é um no-op (otimizado).
void validateMeta(T)() {
    import std.traits : ReturnType;
    static foreach (m; slotMembers!T)
        static assert(is(ReturnType!(__traits(getMember, T, m)) == void),
            "qtmoc: @Slot " ~ T.stringof ~ "." ~ m ~ " deve retornar void. " ~
            "Um método que retorna valor é um invokable, não um slot, e o runtime " ~
            "descartaria o retorno — emita o resultado por um Signal.");
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        static if (note.length) {
            alias PT = typeof(__traits(getMember, T, m));
            enum bool found = () {
                bool f = false;
                static foreach (s; signalMembers!T) if (s == note) f = true;
                return f;
            }();
            static assert(found,
                "qtmoc: @Property " ~ T.stringof ~ "." ~ m ~ " tem NOTIFY \"" ~ note ~
                "\" que não é um Signal desta classe.");
            static foreach (s; signalMembers!T)
                static if (s == note)
                    static if (is(typeof(__traits(getMember, T, s)) == Signal!A, A...))
                        static assert(A.length == 0 || (A.length == 1 && is(A[0] == PT)),
                            "qtmoc: NOTIFY \"" ~ note ~ "\" de " ~ T.stringof ~ "." ~ m ~
                            " deve ser parameterless ou receber um " ~ PT.stringof ~
                            " (callProp emite o novo valor como único argumento).");
        }
    }}
}

// lê/escreve a propriedade `m` de `o` pelo slot do valor a[0]. No write, se o
// valor muda e há sinal de notify, emite-o (pra bindings/QML verem a mudança).
void callProp(T, string m)(T o, void* qobj, int notifyIdx, int write, void** a) {
    alias X = typeof(__traits(getMember, T, m));
    if (write) {
        static if (is(X == string)) X nv = qsToD(a[0]);
        else                        X nv = *cast(X*) a[0];
        if (__traits(getMember, o, m) != nv) {
            __traits(getMember, o, m) = nv;
            if (notifyIdx >= 0) {
                void*[2] argv; argv[0] = null;
                static if (is(X == string)) {
                    auto qs = qtd_str_to_qs(nv.ptr, cast(int) nv.length);
                    argv[1] = qs; qtd_moc_activate(qobj, notifyIdx, argv.ptr); qtd_qs_free(qs);
                } else {
                    argv[1] = cast(void*) &nv; qtd_moc_activate(qobj, notifyIdx, argv.ptr);
                }
            }
        }
    } else {   // ReadProperty: assign the D value into the QVariant/typed slot at a[0]
        static if (is(X == string)) {
            auto s = __traits(getMember, o, m);
            qtd_qs_set(a[0], s.ptr, cast(int) s.length);   // *(QString*)a[0] = s
        }
        else *cast(X*) a[0] = __traits(getMember, o, m);
    }
}

// invoca o slot `m` de `o` lendo os args do array C (args[0] é retorno).
void callSlot(T, string m)(T o, void** args) {
    alias P = Parameters!(__traits(getMember, T, m));
    P vals;
    static foreach (j, X; P) {
        static if (is(X == string)) vals[j] = qsToD(args[j + 1]);
        else vals[j] = *cast(X*) args[j + 1];
    }
    __traits(getMember, o, m)(vals);
}

// ---- factory ----------------------------------------------------------------
/// Cria uma instância de um @QObject D, constrói seu meta-objeto em runtime,
/// liga os campos Signal e registra o despacho de slots.
T newQObject(T, Args...)(Args ctorArgs) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    validateMeta!T();   // @Slot void + NOTIFY existente/compatível (compile time)
    T o = new T(ctorArgs);
    enum sigs  = signalSigs!T;
    enum slts  = slotSigs!T;
    enum pnames = propMembers!T;
    enum ptypes = propTypes!T;
    enum pnotif = propNotify!T;
    // arrays de C-strings (assinaturas com \0 -> .ptr é seguro em C); +1 evita [0]
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    void* qobj = qtd_moc_new((T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        cast(void*) o, &__mocGlobalDispatch, &__mocGlobalProp);
    static if (__traits(hasMember, T, "_adopt")) o._adopt(qobj);   // WRAPPER: _cpp + pin
    wireQObject(o, qobj);
    return o;
}

// Liga os campos Signal ao (qobj, índice) e registra o despacho de slots/props de `o`.
// Compartilhado por newQObject (qobj vem de qtd_moc_new) e pela factory de QML
// (qobj = o QtdMocObject que o engine alocou).
private void wireQObject(T)(T o, void* qobj) {
    enum pnotif = propNotify!T;
    int si = 0;
    static foreach (m; signalMembers!T) {
        __traits(getMember, o, m)._bind(qobj, si);
        si++;
    }
    void delegate(int, void**) nothrow disp = (int idx, void** a) nothrow {
        try {
            static foreach (i, m; slotMembers!T)
                if (idx == i) { callSlot!(T, m)(o, a); return; }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    void delegate(int, int, void**) nothrow prop = (int idx, int write, void** a) nothrow {
        try {
            static foreach (i, m; propMembers!T)
                if (idx == i) { callProp!(T, m)(o, qobj, pnotif[i], write, a); return; }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    _reg[cast(void*) o] = MocReg(qobj, disp, prop);
}

// ---- QML type registration --------------------------------------------------
// Registra um @QObject D como elemento QML: `import <uri> <maj>.<min>; <T> { ... }`.
// O engine instancia o carrier C++ (QtdMocObject) e chama de volta o `create` (C++),
// que por sua vez chama a factory D abaixo pra criar+ligar o T que respalda o objeto.
// Todas as instâncias D compartilham o mesmo typeId C++ (QtdMocObject*), distintas
// pelo QMetaObject de runtime — comprovado por probe que N tipos coexistem.
private __gshared void* delegate(void* qobj) nothrow[void*] _qmlFactories;   // key = QtdQmlType* (C++)

// Callbacks C ÚNICOS (não por-T -> sem colisão de símbolo extern(C)); despacham
// pela QtdQmlType* que o C++ passa de volta como `self`.
private extern (C) void* __qmlMake(void* self, void* qobj) nothrow {
    if (auto f = self in _qmlFactories) return (*f)(qobj);
    return null;
}
private extern (C) void __qmlDestroy(void* self, void* dobj) nothrow {
    _reg.remove(dobj);   // solta o T do registro -> o GC pode recolhê-lo
}

// publicKey ("uri/name maj.min", o que o engine QML enxerga) -> identidade D do tipo registrado.
// A identidade é T.mangleof (nome mangled totalmente-qualificado): dois @QObject D homônimos
// (mesmo T.stringof, módulos diferentes) têm mangleof DISTINTO. Assim o mesmo (T, uri, nome,
// versão) é no-op idempotente, mas dois tipos DIFERENTES na mesma chave pública são um conflito
// observável — não um "já registrado" silencioso (critics r8 #3).
private __gshared string[string] _qmlRegistered;

/// Registra o tipo `T` (@QObject D) como elemento QML instanciável. Chame antes de carregar o
/// .qml. Contrato de erro (critics r7 #2): **THROWS** se o registro falhar no backend (pool Qt5
/// esgotado ou `qmlregister` recusado) — a falha C++ NÃO vira sucesso silencioso. Registrar o
/// MESMO (T, uri, nome, versão) de novo é idempotente (não consome outro slot do pool Qt5).
void qmlRegisterType(T)(string uri, int vmaj, int vmin, string qmlName) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    static assert(__traits(compiles, new T()),
        "qtmoc: " ~ T.stringof ~ " precisa de construtor sem argumentos (o QML instancia sem args)");
    validateMeta!T();   // @Slot void + NOTIFY existente/compatível (compile time)
    import std.conv : to;
    enum typeId = T.mangleof;   // identidade D inequívoca (homônimos diferem no mangle)
    auto pubKey = uri ~ "/" ~ qmlName ~ " " ~ vmaj.to!string ~ "." ~ vmin.to!string;
    if (auto prev = pubKey in _qmlRegistered) {
        if (*prev == typeId) return;   // MESMO tipo, mesma versão -> no-op (não reconsome pool Qt5)
        throw new Exception("qmlRegisterType conflict: " ~ pubKey ~ " já está registrado para outro "
            ~ "tipo D (" ~ *prev ~ " != " ~ typeId ~ "). Use um nome/URI/versão distinto.");
    }
    enum sigs = signalSigs!T;
    enum slts = slotSigs!T;
    enum pnames = propMembers!T;
    enum ptypes = propTypes!T;
    enum pnotif = propNotify!T;
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    void* key = qtd_qml_register_type(
        (uri ~ "\0").ptr, vmaj, vmin, (qmlName ~ "\0").ptr,
        (T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        &__qmlMake, &__qmlDestroy, &__mocGlobalDispatch, &__mocGlobalProp);
    if (key is null)   // backend refused (Qt5 pool exhausted / qmlregister failed) -> OBSERVABLE
        throw new Exception("qmlRegisterType failed for " ~ T.stringof ~ " as " ~ pubKey
            ~ " (backend returned null; see stderr)");
    // factory por-T: o engine chama isto (via __qmlMake) por instância criada no QML.
    _qmlFactories[key] = (void* qobj) nothrow {
        try {
            T o = new T();
            wireQObject(o, qobj);
            return cast(void*) o;
        } catch (Exception e) { qtdOnCallbackError(e); return null; }
    };
    _qmlRegistered[pubKey] = typeId;
}

// ---- .qmltypes emission (type description for tooling) ----------------------
// Emits the QQmlJSTypeDescriptionReader-format block a `@QObject` D type would have
// if it were registered via qmlRegisterType — so qmllint / Qt Creator / qmltc can
// see D-defined QML types. This is qmltyperegistrar's `.qmltypes` output, produced
// by CTFE from the same __traits info the runtime meta-object is built from (no moc
// JSON). Pure compile-time string building; a tiny driver writes the result to disk.

/// The `.qmltypes` `Component { ... }` block describing `T` exported as `uri/qmlName vmaj.vmin`.
string qmlTypeComponent(T)(string uri, int vmaj, int vmin, string qmlName) {
    import std.traits : Parameters, ParameterIdentifierTuple;
    static assert(hasUDA!(T, QObject), "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    // qmltyperegistrar encodes the export version as a metaobject revision (major<<8 | minor).
    immutable rev = (vmaj << 8) | vmin;
    string s = "    Component {\n";
    s ~= "        name: \"" ~ T.stringof ~ "\"\n";
    s ~= "        accessSemantics: \"reference\"\n";
    s ~= "        prototype: \"QObject\"\n";
    s ~= "        exports: [\"" ~ uri ~ "/" ~ qmlName ~ " " ~ itoa(vmaj) ~ "." ~ itoa(vmin) ~ "\"]\n";
    s ~= "        exportMetaObjectRevisions: [" ~ itoa(rev) ~ "]\n";
    int pidx = 0;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        s ~= "        Property { name: \"" ~ m ~ "\"; type: \""
            ~ cppSig!(typeof(__traits(getMember, T, m))) ~ "\"";
        if (note.length) s ~= "; notify: \"" ~ note ~ "\"";
        s ~= "; index: " ~ itoa(pidx) ~ " }\n";
        pidx++;
    }}
    static foreach (m; signalMembers!T) {{
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) {
            s ~= "        Signal { name: \"" ~ m ~ "\"";
            static if (A.length) {
                s ~= "\n";
                static foreach (i, X; A)
                    s ~= "            Parameter { name: \"arg" ~ itoa(cast(int) i)
                        ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
                s ~= "        }\n";
            } else s ~= " }\n";
        }
    }}
    static foreach (m; slotMembers!T) {{
        alias P = Parameters!(__traits(getMember, T, m));
        alias PN = ParameterIdentifierTuple!(__traits(getMember, T, m));
        s ~= "        Method { name: \"" ~ m ~ "\"";
        static if (P.length) {
            s ~= "\n";
            static foreach (i, X; P)
                s ~= "            Parameter { name: \"" ~ (PN[i].length ? PN[i] : "arg" ~ itoa(cast(int) i))
                    ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
            s ~= "        }\n";
        } else s ~= " }\n";
    }}
    s ~= "    }\n";
    return s;
}

/// Wrap one or more `qmlTypeComponent` blocks into a complete `.qmltypes` document.
string qmlTypesModule(string[] components) {
    string s = "import QtQuick.tooling 1.2\n\n";
    s ~= "// This file describes D @QObject types registered for QML (qmlRegisterType).\n";
    s ~= "// Generated by qt-dlang-gen from the CTFE meta-object. For tooling only.\n\n";
    s ~= "Module {\n";
    foreach (c; components) s ~= c;
    s ~= "}\n";
    return s;
}

// ---- widget subclass + moc (merge trampolim + meta-objeto) ------------------
// (helpers públicos: o mixin abaixo é instanciado no módulo do usuário e resolve
//  nesse escopo, então precisa enxergar os helpers/internos do qtmoc.)
/// UDA opcional/documentativa: marca um método como override de um virtual da base.
struct Override {}

string itoa(int n) {   // CTFE simples
    if (n == 0) return "0";
    string s; bool neg = n < 0; if (neg) n = -n;
    while (n) { s = cast(char)('0' + n % 10) ~ s; n /= 10; }
    return neg ? "-" ~ s : s;
}
template __qtdIsFn(T, string m) {
    static if (is(typeof(__traits(getMember, T, m)) == function)) enum __qtdIsFn = true;
    else enum __qtdIsFn = false;
}
// gera o trampolim extern(C) que adapta o virtual do C++ ao método D `vn`. Nome
// único por classe (__ov_<Classe>_<idx>) pra não colidir na linkagem C.
string __ovTramp(T, string vn, size_t idx)() {
    import std.traits : ReturnType, Parameters;
    alias R = ReturnType!(__traits(getMember, T, vn));
    alias P = Parameters!(__traits(getMember, T, vn));
    string ps, as;
    static foreach (j, X; P) {
        ps ~= (j ? ", " : "") ~ X.stringof ~ " a" ~ itoa(cast(int) j);
        as ~= (j ? ", " : "") ~ "a" ~ itoa(cast(int) j);
    }
    auto nm = "__ov_" ~ T.stringof ~ "_" ~ itoa(cast(int) idx);
    auto call = "(cast(" ~ T.stringof ~ ") d)." ~ vn ~ "(" ~ as ~ ")";
    // A D exception can't unwind across the C++ virtual-call frame -> route it through the
    // callback error policy (counted/recorded/hooked), never silently swallowed.
    static if (is(R == void))
        return "extern(C) static void " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { try { " ~ call ~ "; } catch (Exception e) { qtdOnCallbackError(e); } }\n";
    else
        return "extern(C) static " ~ R.stringof ~ " " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { try { return " ~ call ~ "; } catch (Exception e) { qtdOnCallbackError(e); return "
            ~ R.stringof ~ ".init; } }\n";
}

/// Mixin pra uma classe Qt subclassada em D que TAMBÉM é @QObject: sobrescreve
/// virtuais (métodos com nome de virtual da base, ex. paintEvent) E tem
/// sinais/slots/props próprios.
mixin template QtdWidget(Base) {
    void* _qobj;
    private alias _Self = typeof(this);
    final void* __qtdObj() { return _qobj; }
    private enum string[] __vn = mixin("__" ~ Base.stringof ~ "_vnames");  // virtuais da base (qtvirt)

    // trampolines extern(C) pros virtuais que a classe sobrescreve (nome bate).
    static foreach (i, vn; __vn)
        static if (__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
            mixin(__ovTramp!(_Self, vn, i));

    this() {
        // 1. cria o trampolim de subclasse, plugando os cbs sobrescritos (resto null)
        enum __callArgs = () {
            string a;
            static foreach (i, vn; __vn)
                a ~= ", " ~ ((__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
                    ? "&__ov_" ~ _Self.stringof ~ "_" ~ itoa(cast(int) i) : "null");
            return a;
        }();
        mixin("_qobj = cast(void*) " ~ Base.stringof ~ "_subclass(cast(void*) this" ~ __callArgs ~ ");");
        // WRAPPER mode: adopt the C++ trampoline as our _cpp + pin (C++ holds a raw dself).
        static if (__traits(hasMember, _Self, "_adopt")) this._adopt(_qobj);

        // 2. anexa o meta-objeto runtime (sinais/slots/props próprios)
        enum sigs = signalSigs!_Self; enum slts = slotSigs!_Self;
        enum pnames = propMembers!_Self; enum ptypes = propTypes!_Self; enum pnotif = propNotify!_Self;
        const(char)*[sigs.length + 1] sigp; const(char)*[slts.length + 1] sltp;
        const(char)*[pnames.length + 1] pnp; const(char)*[ptypes.length + 1] ptp; int[pnotif.length + 1] pnt;
        static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
        static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
        static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
        mixin("qtd_sub_" ~ Base.stringof ~ "_attach")(_qobj, (_Self.stringof ~ "\0").ptr,
            sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
            pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
            cast(void*) this, &__mocGlobalDispatch, &__mocGlobalProp);

        // 3. liga os sinais + registra o despacho de slots/props (como newQObject)
        int __si = 0;
        static foreach (m; signalMembers!_Self) { __traits(getMember, this, m)._bind(_qobj, __si); __si++; }
        auto __self = this;
        void delegate(int, void**) nothrow __disp = (int idx, void** a) nothrow {
            try { static foreach (i, m; slotMembers!_Self) if (idx == i) { callSlot!(_Self, m)(__self, a); return; } }
            catch (Exception e) { qtdOnCallbackError(e); }
        };
        void delegate(int, int, void**) nothrow __prp = (int idx, int write, void** a) nothrow {
            try {
                static foreach (i, m; propMembers!_Self)
                    if (idx == i) { callProp!(_Self, m)(__self, _qobj, pnotif[i], write, a); return; }
            } catch (Exception e) { qtdOnCallbackError(e); }
        };
        _reg[cast(void*) this] = MocReg(_qobj, __disp, __prp);
    }
}

// ---- propriedades (acesso por nome via QVariant) ----------------------------
/// Lê uma propriedade int por nome (custom @Property ou built-in).
int propInt(T)(T o, string name) { return qtd_prop_get_int(qobjOf(o), (name ~ "\0").ptr); }
/// Escreve uma propriedade int por nome (dispara o notify, se houver).
void setProp(T)(T o, string name, int v) { qtd_prop_set_int(qobjOf(o), (name ~ "\0").ptr, v); }
/// Lê uma propriedade QString por nome como string D.
string propStr(T)(T o, string name) {
    auto qs = qtd_prop_get_qs(qobjOf(o), (name ~ "\0").ptr);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// Escreve uma propriedade QString por nome (dispara o notify, se houver).
void setProp(T)(T o, string name, string v) {
    qtd_prop_set_qs(qobjOf(o), (name ~ "\0").ptr, v.ptr, cast(int) v.length);
}

// ---- conexão ----------------------------------------------------------------
/// Conecta sinal->slot por assinatura ("valueChanged(int)"). Simétrico: cada
/// ponta pode ser um @QObject D ou um QObject built-in cru (void*), em qualquer
/// combinação — ambos têm meta-objeto.
void connectMeta(A, B)(A sender, string sig, B receiver, string slot) {
    qtd_connect_meta(qobjOf(sender), (sig ~ "\0").ptr,
                     qobjOf(receiver), (slot ~ "\0").ptr);
}
