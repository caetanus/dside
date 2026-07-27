// Generic meta-object runtime for QObjects defined in D (without moc).
// A single QtdMocObject trampoline builds its QMetaObject at runtime
// via QMetaObjectBuilder from signatures the D side provides (extracted
// by CTFE). qt_metacall maps: signal indices -> activate; slot indices -> D.
#include <QObject>
#include <QString>
#include <QCoreApplication>
#include <QTranslator>
#include <QtCore/private/qmetaobjectbuilder_p.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <string>
#include <unordered_map>
#include <thread>
#include <mutex>

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

// D callback that dispatches a slot: (D object, slot-local-index, Qt args)
typedef void (*QtdSlotCb)(void* dobj, int slotIdx, void** args);
// D property callback: (D object, local-index, write?, value slot a[0])
typedef void (*QtdPropCb)(void* dobj, int propIdx, int write, void** args);
// D callback invoked when a moc object is destroyed -> drops the D registry entry (_reg).
typedef void (*QtdMocDestroyCb)(void* dobj);

namespace {
QtdMocDestroyCb g_mocDestroy = nullptr;   // set once by D (qtd_moc_set_destroy_cb) at module init
static void qtd_moc_teardown(void* self, void* dobj);   // side-table cleanup (defined below)

// ---- thread affinity (critics r8 #6) ---------------------------------------
// Every runtime side-table is unsynchronized global mutable state: g_moCache/g_moAttach here,
// _reg/_qmlFactories/_qmlRegistered on the D side, _pinned in the holder. The runtime is
// single-threaded BY DESIGN (as holder.d already declares). Rather than silent UB when a second
// thread mutates a map (rehash mid-read = memory corruption), the FIRST mutation pins an owner
// thread and any mutation from another thread aborts LOUDLY with the offending op. Deterministic,
// never a corrupted map. Reads on the hot dispatch path stay lock-free. Real per-thread/locked
// tables for worker QObjects (QThread/networking/timers) are a tracked STRUCTURAL follow-up — this
// makes the current limitation explicit and ENFORCED instead of assumed.
std::mutex g_ownerMx;
std::thread::id g_ownerThread;
bool g_ownerSet = false;
static void qtd_thread_guard(const char* op) {
    std::lock_guard<std::mutex> lk(g_ownerMx);
    auto self = std::this_thread::get_id();
    if (!g_ownerSet) { g_ownerThread = self; g_ownerSet = true; return; }
    if (self != g_ownerThread) {
        std::fprintf(stderr, "qtd FATAL: meta-object runtime mutated off its owner thread "
            "(op=%s). The qtd moc/QML runtime is single-threaded — create and destroy D "
            "@QObjects only on the thread that first used it.\n", op);
        std::abort();
    }
}
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
    // A DYNAMIC meta-object installed on us wins — that is what QObject::metaObject() itself does.
    // QML installs a QQmlVMEMetaObject whenever a .qml declares members on an instance
    // (`property int doubled: value * 2`); it chains OUR `mo` as its parent. Returning `mo`
    // unconditionally made those QML-declared members invisible: they were never created, and
    // reading one gave an empty QVariant instead of its bound value.
    const QMetaObject* metaObject() const override {
        return d_ptr->metaObject ? d_ptr->dynamicMetaObject() : mo;
    }
    // A Qt moc first matches the class's OWN name (returns this), THEN delegates to base.
    // The old body skipped step 1 -> qt_metacast("Dup") on a runtime `Dup` returned null even
    // though metaObject()->className() is "Dup" (critics r8 #2). qobject_cast/interfaces/name
    // discovery all depend on this. mocClassName() is a strcmp-normalized className.
    void* qt_metacast(const char* n) override {
        if (n && mo && std::strcmp(n, mo->className()) == 0) return this;
        return QObject::qt_metacast(n);
    }
    int qt_metacall(QMetaObject::Call c, int id, void** a) override {
        id = QObject::qt_metacall(c, id, a);
        if (id < 0) return id;
        if (c == QMetaObject::InvokeMetaMethod) {
            if (id < nsig) QMetaObject::activate(this, mo, id, a);   // signal relay
            else if (dobj) slotcb(dobj, id - nsig, a);               // slot -> D (guard: failed QML
                                                                     // instance has no backing obj, r8 #5)
            id -= (nsig + nslot);
        } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
            if (propcb && dobj && id < nprop)                        // prop <-> D (dobj-guarded)
                propcb(dobj, id, c == QMetaObject::WriteProperty, a);
            id -= nprop;
        }
        return id;
    }
};

// meta-object built once per SHAPE. `super` = the superclass meta (QObject for
// QtdMocObject; QWidget/etc. for subclass trampolines). The cache key is the class name PLUS
// the super's name PLUS every signal/slot/property signature — NOT the name alone (critics r6 #6:
// two homonymous D classes with different shapes would otherwise share, and get, the wrong
// metaobject). Two identically-shaped homonyms still share (harmless — they ARE the same shape).
std::unordered_map<std::string, const QMetaObject*> g_moCache;
const QMetaObject* buildMo(const char* cn, const QMetaObject* super,
                           const char** sigs, int nsig,
                           const char** slotSigs, int nslot,
                           const char** propNames, const char** propTypes,
                           const int* propNotify, int nprop) {
    qtd_thread_guard("buildMo");   // mutates g_moCache
    std::string key(cn);
    key += '\x1'; key += (super ? super->className() : "");
    for (int i = 0; i < nsig; ++i)  { key += '\x2'; key += sigs[i]; }
    for (int i = 0; i < nslot; ++i) { key += '\x3'; key += slotSigs[i]; }
    for (int i = 0; i < nprop; ++i) {   // name:type@notify — NOTIFY participates too (critics r7 #3)
        key += '\x4'; key += propNames[i]; key += ':'; key += propTypes[i];
        key += '@'; key += std::to_string(propNotify[i]);
    }
    auto it = g_moCache.find(key);
    if (it != g_moCache.end()) return it->second;
    QMetaObjectBuilder b;
    b.setClassName(cn);
    b.setSuperClass(super);
    for (int i = 0; i < nsig; ++i)  b.addSignal(sigs[i]);
    for (int i = 0; i < nslot; ++i) b.addSlot(slotSigs[i]);
    for (int i = 0; i < nprop; ++i) {
        QMetaPropertyBuilder p = b.addProperty(propNames[i], propTypes[i]);
        p.setReadable(true); p.setWritable(true);
        if (propNotify[i] >= 0) p.setNotifySignal(b.method(propNotify[i]));  // signals are the first methods
    }
    const QMetaObject* mo = b.toMetaObject();
    g_moCache[key] = mo;
    return mo;
}

// GENERIC moc attachable to a subclass trampoline (qtvirt): the meta-object
// logic lives here (per-object side-table), so the per-class trampoline only
// delegates metaObject/qt_metacall. Used when a D class subclasses a Qt
// widget AND is @QObject (its own signals/slots/props) — e.g.: CannonField.
struct MocInfo {
    const QMetaObject* mo; void* dobj; QtdSlotCb slotcb; QtdPropCb propcb;
    int nsig, nslot, nprop;
};
std::unordered_map<void*, MocInfo> g_moAttach;   // key = the QObject* (the trampoline's self)
// Drop both side-tables for a destroyed moc object (the D _reg via g_mocDestroy, g_moAttach here).
static void qtd_moc_teardown(void* self, void* dobj) {
    qtd_thread_guard("teardown");   // erases g_moAttach (+ D _reg via g_mocDestroy)
    g_moAttach.erase(self);
    if (g_mocDestroy && dobj) g_mocDestroy(dobj);
}
} // namespace

// attaches a meta-object to `self` (the already-built trampoline). `super` = &Base::staticMetaObject.
void qtd_moc_attach(void* self, const char* cn, const void* super,
                    const char** sigs, int nsig, const char** slotSigs, int nslot,
                    const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                    void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    qtd_thread_guard("moc_attach");   // inserts g_moAttach
    MocInfo mi;
    mi.mo = buildMo(cn, static_cast<const QMetaObject*>(super),
                    sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    mi.dobj = dobj; mi.slotcb = slotcb; mi.propcb = propcb;
    mi.nsig = nsig; mi.nslot = nslot; mi.nprop = nprop;
    g_moAttach[self] = mi;
}
// for the trampoline's metaObject() override: the attached mo, or null if not attached.
const void* qtd_moc_meta(void* self) {
    auto it = g_moAttach.find(self);
    return it != g_moAttach.end() ? it->second.mo : nullptr;
}
// for the trampoline's qt_metacast(): matches the attached metaobject's className before
// delegating to the base. Without it, qt_metacast("Sub") on a QtdWidget!Sub returned null even with
// metaObject()->className()=="Sub" (critics r8 #2), breaking qobject_cast and type discovery.
bool qtd_moc_classmatch(void* self, const char* n) {
    if (!n) return false;
    auto it = g_moAttach.find(self);
    return it != g_moAttach.end() && it->second.mo &&
           std::strcmp(n, it->second.mo->className()) == 0;
}
// Identity probes (for the r8 #2 test): qt_metacast by name and the metaobject's className.
extern "C" void* qtd_metacast(void* qobj, const char* n) {
    return qobj ? static_cast<QObject*>(qobj)->qt_metacast(n) : nullptr;
}
extern "C" const char* qtd_moc_classname(void* qobj) {
    return qobj ? static_cast<QObject*>(qobj)->metaObject()->className() : nullptr;
}
// for the trampoline's qt_metacall() override (called AFTER Base::qt_metacall).
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
// emits signal index `idx` of an attached trampoline.
void qtd_moc_activate2(void* self, int idx, void** a) {
    auto it = g_moAttach.find(self);
    if (it != g_moAttach.end()) QMetaObject::activate(static_cast<QObject*>(self), it->second.mo, idx, a);
}

// D registers here (once, at module init) the callback that clears the D registry on destruction.
void qtd_moc_set_destroy_cb(QtdMocDestroyCb cb) { g_mocDestroy = cb; }
// Called by the subclass trampoline's destructor (Qtd_<Base>, generated) when Qt destroys it:
// drops g_moAttach[self] AND the D object's _reg entry. Closes the QtdWidget path (not just the
// QtdMocObject from newQObject).
void qtd_moc_detach(void* self, void* dobj) { qtd_moc_teardown(self, dobj); }
// diagnostic/test: live entries in the side-table; and deletes a QtdMocObject (its dtor cleans everything).
size_t qtd_moc_attach_count() { return g_moAttach.size(); }
// Owner-thread inspection for tests (does NOT abort): 1 = current thread IS the owner,
// 0 = an owner is set and current thread is NOT it, -1 = no owner pinned yet (critics r8 #6).
int qtd_moc_owner_check() {
    std::lock_guard<std::mutex> lk(g_ownerMx);
    if (!g_ownerSet) return -1;
    return std::this_thread::get_id() == g_ownerThread ? 1 : 0;
}
void qtd_moc_delete(void* o) { delete static_cast<QtdMocObject*>(o); }
// deletes ANY QObject via the virtual dtor (works for the Qtd_<Base> trampoline — its ~ calls detach).
void qtd_qobject_delete(void* o) { delete static_cast<QObject*>(o); }

// creates a QObject whose meta-object has the given signals/slots/properties.
void* qtd_moc_new(const char* cn, const char** sigs, int nsig,
                  const char** slotSigs, int nslot,
                  const char** propNames, const char** propTypes, const int* propNotify, int nprop,
                  void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {
    auto* o = new QtdMocObject();
    o->mo = buildMo(cn, &QObject::staticMetaObject, sigs, nsig, slotSigs, nslot, propNames, propTypes, propNotify, nprop);
    o->dobj = dobj; o->slotcb = slotcb; o->propcb = propcb;
    o->nsig = nsig; o->nslot = nslot; o->nprop = nprop;
    g_moAttach[o] = MocInfo{o->mo, dobj, slotcb, propcb, nsig, nslot, nprop};  // for the unified activate
    return o;
}

// emits signal index sigIdx (args[0]=return, then values). Unified via
// g_moAttach, so it works for the QtdMocObject AND for subclass trampolines.
void qtd_moc_activate(void* self, int sigIdx, void** args) {
    auto it = g_moAttach.find(self);
    if (it != g_moAttach.end()) QMetaObject::activate(static_cast<QObject*>(self), it->second.mo, sigIdx, args);
}

// QString marshaling for signal/slot args (the D side is fixed runtime and can't
// import the generated QString helpers; here we already link QtCore).
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

// property access by name via QVariant (runs ReadProperty/WriteProperty on the
// meta-object -> propcb on the D side). Works for custom AND built-in.
int  qtd_prop_get_int(void* o, const char* n) { return static_cast<QObject*>(o)->property(n).toInt(); }
void qtd_prop_set_int(void* o, const char* n, int v) { static_cast<QObject*>(o)->setProperty(n, v); }
double qtd_prop_get_double(void* o, const char* n) { return static_cast<QObject*>(o)->property(n).toDouble(); }
void qtd_prop_set_double(void* o, const char* n, double v) { static_cast<QObject*>(o)->setProperty(n, v); }
bool qtd_prop_get_bool(void* o, const char* n) { return static_cast<QObject*>(o)->property(n).toBool(); }
void qtd_prop_set_bool(void* o, const char* n, bool v) { static_cast<QObject*>(o)->setProperty(n, v); }
void* qtd_prop_get_qs(void* o, const char* n) { return new QString(static_cast<QObject*>(o)->property(n).toString()); }
void qtd_prop_set_qs(void* o, const char* n, const char* p, int len) {
    static_cast<QObject*>(o)->setProperty(n, QString::fromUtf8(p, len));
}

// connects signal->slot by signature (works for custom AND built-in: both have a
// meta-object). Returns a QMetaObject::Connection* (or null if not found).
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
    qtd_thread_guard("qml_construct");   // inserts g_moAttach (QML engine thread must be the owner)
    auto* o = new (mem) QtdMocObject();
    o->mo = t->mo; o->slotcb = t->slotcb; o->propcb = t->propcb;
    o->nsig = t->nsig; o->nslot = t->nslot; o->nprop = t->nprop;
    o->qmlUserdata = t;
    g_moAttach[o] = MocInfo{o->mo, nullptr, t->slotcb, t->propcb, t->nsig, t->nslot, t->nprop};
    void* dobj = t->makeInstance(t, o);   // D: new T, bind signals to `o`, register dispatch
    if (!dobj) {
        // The D constructor threw (the factory caught it, recorded it via qtdOnCallbackError, and
        // returned null). Qt's QML create() has no failure channel, so we can't unwind the
        // placement-new — but we MUST NOT hand back a carrier with a null backing object and a
        // stale side-table entry (critics r8 #5). Complete the cleanup: drop the half-attached
        // g_moAttach entry, leave dobj==null (qt_metacall is guarded to no-op on it), and emit a
        // visible error. The element degrades to an inert QObject; its bindings do nothing instead
        // of dispatching into null. qmlUserdata stays set so ~QtdMocObject takes the QML teardown.
        g_moAttach.erase(o);
        qWarning("qtd: QML instantiation of '%s' failed (D constructor threw); the element has no "
                 "backing object — its properties/slots are inert", t->mo->className());
        return;
    }
    o->dobj = dobj;
    g_moAttach[o].dobj = dobj;
}
// ~QtdMocObject for a QML-created instance: drop the side-tables (D side + g_moAttach).
static void qtd_qml_on_destroy(void* self) {
    qtd_thread_guard("qml_destroy");   // erases g_moAttach (+ D _reg via destroyInstance)
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
    if (g_qt5Count >= 256) {   // pool exhausted -> HONEST failure, not apparent success (critics r6 #6)
        fprintf(stderr, "qtd: qmlRegisterType Qt5 create-pool exhausted (>256 D QML types); '%s' NOT registered\n", qmlName);
        delete t; return nullptr;
    }
    rt.create = g_qt5Creators[g_qt5Count];   // per-type trampoline
    g_qt5Types[g_qt5Count++] = t;
    rt.versionMajor = vmaj;
    rt.versionMinor = vmin;
    rt.revision = 0;
#endif
    int tid = QQmlPrivate::qmlregister(QQmlPrivate::TypeRegistration, &rt);
    if (tid < 0) {   // the registration itself failed -> clean up, roll back, don't pretend it worked
        fprintf(stderr, "qtd: qmlRegisterType failed for '%s' (qmlregister returned %d)\n", qmlName, tid);
#if QT_VERSION < 0x060000
        if (g_qt5Count > 0 && g_qt5Types[g_qt5Count - 1] == t) g_qt5Types[--g_qt5Count] = nullptr;  // roll back the pool slot
#endif
        delete t;
        return nullptr;
    }
    return t;
}
#endif // QTD_HAVE_QML

} // extern "C"
