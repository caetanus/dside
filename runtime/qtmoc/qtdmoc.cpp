// Runtime genérico de meta-objeto para QObjects definidos em D (sem moc).
// Um único trampolim QtdMocObject constrói seu QMetaObject em tempo de execução
// via QMetaObjectBuilder a partir de assinaturas que o lado D fornece (extraídas
// por CTFE). qt_metacall relaciona: índices de sinal -> activate; de slot -> D.
#include <QObject>
#include <QString>
#include <QtCore/private/qmetaobjectbuilder_p.h>
#include <cstring>
#include <string>
#include <unordered_map>

extern "C" {

// callback D que despacha um slot: (objeto D, índice-local-do-slot, args de Qt)
typedef void (*QtdSlotCb)(void* dobj, int slotIdx, void** args);
// callback D de propriedade: (objeto D, índice-local, write?, slot do valor a[0])
typedef void (*QtdPropCb)(void* dobj, int propIdx, int write, void** args);

namespace {
struct QtdMocObject : QObject {
    const QMetaObject* mo;
    void* dobj;
    QtdSlotCb slotcb;
    QtdPropCb propcb;
    int nsig, nslot, nprop;
    ~QtdMocObject() override {}
    const QMetaObject* metaObject() const override { return mo; }
    void* qt_metacast(const char* n) override { return QObject::qt_metacast(n); }
    int qt_metacall(QMetaObject::Call c, int id, void** a) override {
        id = QObject::qt_metacall(c, id, a);
        if (id < 0) return id;
        if (c == QMetaObject::InvokeMetaMethod) {
            if (id < nsig) QMetaObject::activate(this, mo, id, a);   // relay do sinal
            else slotcb(dobj, id - nsig, a);                          // slot -> D
            id -= (nsig + nslot);
        } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
            if (propcb && id < nprop)                                 // prop <-> D
                propcb(dobj, id, c == QMetaObject::WriteProperty, a);
            id -= nprop;
        }
        return id;
    }
};

// meta-objeto construído uma vez por classe (cache por nome). `super` = meta da
// superclasse (QObject pro QtdMocObject; QWidget/etc. pros trampolins de subclasse).
std::unordered_map<std::string, const QMetaObject*> g_moCache;
const QMetaObject* buildMo(const char* cn, const QMetaObject* super,
                           const char** sigs, int nsig,
                           const char** slotSigs, int nslot,
                           const char** propNames, const char** propTypes,
                           const int* propNotify, int nprop) {
    auto it = g_moCache.find(cn);
    if (it != g_moCache.end()) return it->second;
    QMetaObjectBuilder b;
    b.setClassName(cn);
    b.setSuperClass(super);
    for (int i = 0; i < nsig; ++i)  b.addSignal(sigs[i]);
    for (int i = 0; i < nslot; ++i) b.addSlot(slotSigs[i]);
    for (int i = 0; i < nprop; ++i) {
        QMetaPropertyBuilder p = b.addProperty(propNames[i], propTypes[i]);
        p.setReadable(true); p.setWritable(true);
        if (propNotify[i] >= 0) p.setNotifySignal(b.method(propNotify[i]));  // sinais são os 1ºs métodos
    }
    const QMetaObject* mo = b.toMetaObject();
    g_moCache[cn] = mo;
    return mo;
}

// moc GENÉRICO anexável a um trampolim de subclasse (qtvirt): a lógica do
// meta-objeto fica aqui (side-table por objeto), então o trampolim por-classe só
// delega metaObject/qt_metacall. Usado quando uma classe D é subclasse de um
// widget Qt E @QObject (sinais/slots/props próprios) — ex.: CannonField.
struct MocInfo {
    const QMetaObject* mo; void* dobj; QtdSlotCb slotcb; QtdPropCb propcb;
    int nsig, nslot, nprop;
};
std::unordered_map<void*, MocInfo> g_moAttach;   // chave = o QObject* (self do trampolim)
} // namespace

// anexa um meta-objeto a `self` (o trampolim já construído). `super` = &Base::staticMetaObject.
void qtd_moc_attach(void* self, const char* cn, const void* super,
                    const char** sigs, int nsig, const char** slotSigs, int nslot,
                    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                    void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    MocInfo mi;
    mi.mo = buildMo(cn, static_cast<const QMetaObject*>(super),
                    sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    mi.dobj = dobj; mi.slotcb = slotcb; mi.propcb = propcb;
    mi.nsig = nsig; mi.nslot = nslot; mi.nprop = nprop;
    g_moAttach[self] = mi;
}
// pro override metaObject() do trampolim: o mo anexado, ou null se não anexado.
const void* qtd_moc_meta(void* self) {
    auto it = g_moAttach.find(self);
    return it != g_moAttach.end() ? it->second.mo : nullptr;
}
// pro override qt_metacall() do trampolim (chamado DEPOIS de Base::qt_metacall).
int qtd_moc_metacall(void* self, int c, int id, void** a) {
    auto it = g_moAttach.find(self);
    if (it == g_moAttach.end()) return id;
    MocInfo& mi = it->second;
    if (c == QMetaObject::InvokeMetaMethod) {
        if (id < mi.nsig) QMetaObject::activate(static_cast<QObject*>(self), mi.mo, id, a);
        else mi.slotcb(mi.dobj, id - mi.nsig, a);
        id -= (mi.nsig + mi.nslot);
    } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
        if (mi.propcb && id < mi.nprop) mi.propcb(mi.dobj, id, c == QMetaObject::WriteProperty, a);
        id -= mi.nprop;
    }
    return id;
}
// emite o sinal de índice `idx` de um trampolim anexado.
void qtd_moc_activate2(void* self, int idx, void** a) {
    auto it = g_moAttach.find(self);
    if (it != g_moAttach.end()) QMetaObject::activate(static_cast<QObject*>(self), it->second.mo, idx, a);
}

// cria um QObject cujo meta-objeto tem os sinais/slots/propriedades dados.
void* qtd_moc_new(const char* cn, const char** sigs, int nsig,
                  const char** slotSigs, int nslot,
                  const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                  void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    auto* o = new QtdMocObject();
    o->mo = buildMo(cn, &QObject::staticMetaObject, sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    o->dobj = dobj; o->slotcb = slotcb; o->propcb = propcb;
    o->nsig = nsig; o->nslot = nslot; o->nprop = nprop;
    g_moAttach[o] = MocInfo{o->mo, dobj, slotcb, propcb, nsig, nslot, nprop};  // pro activate unificado
    return o;
}

// emite o sinal de índice sigIdx (args[0]=retorno, depois valores). Unificado via
// g_moAttach, então serve pro QtdMocObject E pros trampolins de subclasse.
void qtd_moc_activate(void* self, int sigIdx, void** args) {
    auto it = g_moAttach.find(self);
    if (it != g_moAttach.end()) QMetaObject::activate(static_cast<QObject*>(self), it->second.mo, sigIdx, args);
}

// marshaling de QString para args de sinal/slot (o lado D é runtime fixo e não
// pode importar os helpers de QString gerados; aqui já linkamos QtCore).
void* qtd_str_to_qs(const char* p, int n) { return new QString(QString::fromUtf8(p, n)); }
void  qtd_qs_free(void* qs) { delete static_cast<QString*>(qs); }
// ReadProperty metacall: a[0] points to an existing QString to assign the value INTO.
void  qtd_qs_set(void* dest, const char* p, int n) { *static_cast<QString*>(dest) = QString::fromUtf8(p, n); }
int   qtd_qs_utf8len(void* qs) { return (int) static_cast<QString*>(qs)->toUtf8().size(); }
void  qtd_qs_utf8(void* qs, char* dst) {
    QByteArray b = static_cast<QString*>(qs)->toUtf8();
    memcpy(dst, b.constData(), b.size());
}

// acesso a propriedades por nome via QVariant (roda ReadProperty/WriteProperty no
// meta-objeto -> propcb no lado D). Funciona pra custom E built-in.
int  qtd_prop_get_int(void* o, const char* n) { return static_cast<QObject*>(o)->property(n).toInt(); }
void qtd_prop_set_int(void* o, const char* n, int v) { static_cast<QObject*>(o)->setProperty(n, v); }
void* qtd_prop_get_qs(void* o, const char* n) { return new QString(static_cast<QObject*>(o)->property(n).toString()); }
void qtd_prop_set_qs(void* o, const char* n, const char* p, int len) {
    static_cast<QObject*>(o)->setProperty(n, QString::fromUtf8(p, len));
}

// conecta sinal->slot por assinatura (funciona para custom E built-in: ambos têm
// meta-objeto). Retorna uma QMetaObject::Connection* (ou null se não achou).
void* qtd_connect_meta(void* s, const char* sig, void* r, const char* slot) {
    auto* so = static_cast<QObject*>(s);
    auto* ro = static_cast<QObject*>(r);
    int si = so->metaObject()->indexOfSignal(QMetaObject::normalizedSignature(sig));
    int ri = ro->metaObject()->indexOfMethod(QMetaObject::normalizedSignature(slot));
    if (si < 0 || ri < 0) return nullptr;
    auto c = QObject::connect(so, so->metaObject()->method(si), ro, ro->metaObject()->method(ri));
    return new QMetaObject::Connection(std::move(c));
}

} // extern "C"
