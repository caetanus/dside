// Runtime genérico de meta-objeto para QObjects definidos em D (sem moc).
// Um único trampolim QtdMocObject constrói seu QMetaObject em tempo de execução
// via QMetaObjectBuilder a partir de assinaturas que o lado D fornece (extraídas
// por CTFE). qt_metacall relaciona: índices de sinal -> activate; de slot -> D.
#include <QObject>
#include <QString>
#include <QCoreApplication>
#include <QTranslator>
#include <QtCore/private/qmetaobjectbuilder_p.h>
#include <cstring>
#include <new>
#include <string>
#include <unordered_map>

// QML type registration is compiled in ONLY when reggae defines QTD_ENABLE_QML — i.e. the
// binding's pkg-config modules include Qt5Qml or Qt6Qml. (An __has_include probe does NOT work:
// the base `-I…/qt6` exposes QtQml headers to EVERY binding, so a widgets binding would wrongly
// pull in QQmlPrivate::qmlregister and fail to link against QtQml.) Widgets/core stay QtQml-free.
// The QQmlPrivate::RegisterType layout differs between Qt5 and Qt6 — handled below via QT_VERSION.
#ifdef QTD_ENABLE_QML
#  define QTD_HAVE_QML 1
#  include <QtQml/qqmlprivate.h>
#  include <QtQml/qqmllist.h>
#  include <array>
#  include <utility>
#endif

extern "C" {

// callback D que despacha um slot: (objeto D, índice-local-do-slot, args de Qt)
typedef void (*QtdSlotCb)(void* dobj, int slotIdx, void** args);
// callback D de propriedade: (objeto D, índice-local, write?, slot do valor a[0])
typedef void (*QtdPropCb)(void* dobj, int propIdx, int write, void** args);
// callback D chamado na destruição de um objeto moc -> solta a entrada do registro D (_reg).
typedef void (*QtdMocDestroyCb)(void* dobj);

namespace {
QtdMocDestroyCb g_mocDestroy = nullptr;   // set once by D (qtd_moc_set_destroy_cb) at module init
static void qtd_moc_teardown(void* self, void* dobj);   // side-table cleanup (defined below)
#ifdef QTD_HAVE_QML
static void qtd_qml_on_destroy(void* self);   // QML-created instance teardown (defined below)
#endif
struct QtdMocObject : QObject {
    const QMetaObject* mo;
    void* dobj;
    QtdSlotCb slotcb;
    QtdPropCb propcb;
    int nsig, nslot, nprop;
#ifdef QTD_HAVE_QML
    void* qmlUserdata = nullptr;   // non-null iff QML created this instance (QtdQmlType*)
#endif
    ~QtdMocObject() override {
#ifdef QTD_HAVE_QML
        if (qmlUserdata) { qtd_qml_on_destroy(this); return; }   // QML path cleans both side-tables
#endif
        // Non-QML (newQObject): drop both side-tables so a destroyed object doesn't leak an
        // entry (nor let a reused pointer alias a stale one). g_mocDestroy clears the D _reg.
        qtd_moc_teardown(this, dobj);
    }
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
// Drop both side-tables for a destroyed moc object (the D _reg via g_mocDestroy, g_moAttach here).
static void qtd_moc_teardown(void* self, void* dobj) {
    g_moAttach.erase(self);
    if (g_mocDestroy && dobj) g_mocDestroy(dobj);
}
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

// D registra aqui (uma vez, no init do módulo) o callback que limpa o registro D na destruição.
void qtd_moc_set_destroy_cb(QtdMocDestroyCb cb) { g_mocDestroy = cb; }
// diagnóstico/teste: entradas vivas no side-table; e deleta um QtdMocObject (seu dtor limpa tudo).
size_t qtd_moc_attach_count() { return g_moAttach.size(); }
void qtd_moc_delete(void* o) { delete static_cast<QtdMocObject*>(o); }

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

// tr(): QCoreApplication::translate(context, source[, disambiguation[, n]]). Returns a heap
// QString* (freed by qtd_qs_free on the D side, like qtd_str_to_qs). No translator installed
// -> Qt returns `source` unchanged, so tr() is always safe to call.
void* qtd_tr(const char* ctx, const char* src, const char* disambig, int n) {
    return new QString(QCoreApplication::translate(ctx, src, disambig, n));
}

// Install a translator that loaded `qmBase` (.qm; empty -> an empty translator). Ensures a
// QCoreApplication exists first (installTranslator needs the app singleton), so it works even
// before the user builds one. Everything is heap-constructed in C++ — no D-side _new/factory.
bool qtd_install_translator(const char* qmBase) {
    if (!QCoreApplication::instance()) {
        static int argc = 1;
        static char arg0[] = "qtd";
        static char* argv[] = { arg0, nullptr };
        new QCoreApplication(argc, argv);
    }
    auto* t = new QTranslator();
    bool ok = (qmBase && *qmBase) ? t->load(QString::fromUtf8(qmBase)) : true;
    QCoreApplication::installTranslator(t);
    return ok;
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

// ---- QML type registration (qmlRegisterType for D @QObject types) -------------
// A D @QObject registered as a QML element instantiates the SAME C++ carrier
// (QtdMocObject), differentiated by its runtime QMetaObject. When QML creates
// `MyType {}`, QQmlPrivate calls qtd_qml_create with pre-allocated memory: we
// placement-new a QtdMocObject, wire its dynamic meta-object, and call back into
// D to create + bind the backing T instance (makeInstance). Verified viable by a
// standalone probe (runtime QMetaObject + shared typeId works for N distinct types).
#ifdef QTD_HAVE_QML
namespace {
struct QtdQmlType {
    const QMetaObject* mo;
    int nsig, nslot, nprop;
    QtdSlotCb slotcb; QtdPropCb propcb;
    void* (*makeInstance)(void*, void*);   // (self=QtdQmlType*, qobj) -> D backing object
    void  (*destroyInstance)(void*, void*); // (self, dobj) -> unregister on the D side
};
// Shared creation: placement-new the carrier in QML-owned memory, wire its meta-object, and
// call back into D to build + bind the backing T instance.
static void qtd_qml_construct(void* mem, QtdQmlType* t) {
    auto* o = new (mem) QtdMocObject();
    o->mo = t->mo; o->slotcb = t->slotcb; o->propcb = t->propcb;
    o->nsig = t->nsig; o->nslot = t->nslot; o->nprop = t->nprop;
    o->qmlUserdata = t;
    g_moAttach[o] = MocInfo{o->mo, nullptr, t->slotcb, t->propcb, t->nsig, t->nslot, t->nprop};
    void* dobj = t->makeInstance(t, o);   // D: new T, bind signals to `o`, register dispatch
    o->dobj = dobj;
    g_moAttach[o].dobj = dobj;
}
// ~QtdMocObject for a QML-created instance: drop the side-tables (D side + g_moAttach).
static void qtd_qml_on_destroy(void* self) {
    auto* o = static_cast<QtdMocObject*>(self);
    auto* t = static_cast<QtdQmlType*>(o->qmlUserdata);
    g_moAttach.erase(self);
    if (t && o->dobj && t->destroyInstance) t->destroyInstance(t, o->dobj);
}
#if QT_VERSION >= 0x060000
// Qt6: RegisterType.create carries userdata (the QtdQmlType*).
static void qtd_qml_create6(void* mem, void* udata) { qtd_qml_construct(mem, static_cast<QtdQmlType*>(udata)); }
#else
// Qt5: RegisterType.create is `void(*)(void*)` with NO userdata field. Give each registered type
// its own create trampoline from a fixed pool, each hardwired (compile-time) to a slot that holds
// the QtdQmlType*. Caps registrable D QML types at the pool size — plenty for a real app.
// (extern "C++": this whole file is inside `extern "C"`, but templates need C++ linkage.)
extern "C++" {
static QtdQmlType* g_qt5Types[256];
static int g_qt5Count = 0;
template<size_t N> static void qt5_create(void* mem) { qtd_qml_construct(mem, g_qt5Types[N]); }
template<size_t... Is>
static std::array<void(*)(void*), sizeof...(Is)> mkCreators(std::integer_sequence<size_t, Is...>) {
    return {{ &qt5_create<Is>... }};
}
static const auto g_qt5Creators = mkCreators(std::make_index_sequence<256>());
}
#endif
} // namespace

// Register a D @QObject type `cn` as the QML element `uri/qmlName vmaj.vmin`. Same
// sig/slot/prop arrays as qtd_moc_new. Returns the QtdQmlType* (the D side keys its
// per-type factory on it). All QString/QMetaType/QVariant handling stays in C++.
void* qtd_qml_register_type(
    const char* uri, int vmaj, int vmin, const char* qmlName,
    const char* cn, const char** sigs, int nsig, const char** slotSigs, int nslot,
    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
    void* (*makeInstance)(void*, void*), void (*destroyInstance)(void*, void*),
    QtdSlotCb slotcb, QtdPropCb propcb) {
    const QMetaObject* mo = buildMo(cn, &QObject::staticMetaObject,
        sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    auto* t = new QtdQmlType{mo, nsig, nslot, nprop, slotcb, propcb, makeInstance, destroyInstance};
    QQmlPrivate::RegisterType rt{};
    rt.objectSize = int(sizeof(QtdMocObject));
    rt.uri = uri;
    rt.elementName = qmlName;
    rt.metaObject = mo;
    rt.parserStatusCast = -1;
    rt.valueSourceCast = -1;
    rt.valueInterceptorCast = -1;
#if QT_VERSION >= 0x060000
    rt.structVersion = int(QQmlPrivate::RegisterType::CurrentVersion);
    rt.typeId = QMetaType::fromType<QtdMocObject*>();
    rt.listId = QMetaType::fromType<QQmlListProperty<QtdMocObject>>();
    rt.create = &qtd_qml_create6;   // userdata carries the QtdQmlType*
    rt.userdata = t;
    rt.version = QTypeRevision::fromVersion(vmaj, vmin);
    rt.finalizerCast = -1;
    rt.revision = QTypeRevision::fromVersion(vmaj, vmin);
#else
    rt.version = 0;   // Qt5 RegisterType struct version
    // Built-in QObject* metatype (id 39): every carrier is a QObject subclass, and QML keys the
    // element on the metaObject, not the metatype. Avoids qRegisterMetaType<QtdMocObject*>, which
    // in Qt5 pulls a sizeof(QWidget) probe (QtWidgets isn't included here).
    rt.typeId = int(QMetaType::QObjectStar);
    rt.listId = 0;
    rt.create = (g_qt5Count < 256) ? g_qt5Creators[g_qt5Count] : nullptr;   // per-type trampoline
    if (g_qt5Count < 256) g_qt5Types[g_qt5Count++] = t;
    rt.versionMajor = vmaj;
    rt.versionMinor = vmin;
    rt.revision = 0;
#endif
    QQmlPrivate::qmlregister(QQmlPrivate::TypeRegistration, &rt);
    return t;
}
#endif // QTD_HAVE_QML

} // extern "C"
