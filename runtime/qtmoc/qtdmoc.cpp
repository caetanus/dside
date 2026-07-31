// Generic meta-object runtime for QObjects defined in D (without moc).
// A single QtdMocObject trampoline builds its QMetaObject at runtime
// via QMetaObjectBuilder from signatures the D side provides (extracted
// by CTFE). qt_metacall maps: signal indices -> activate; slot indices -> D.
#include <QObject>
#ifdef QT_QML_LIB
#include <QtQml/QQmlPropertyValueSource>
#include <QtQml/QQmlProperty>
#endif
#include <QString>
#include <QMetaProperty>
#include <QMetaEnum>
#include <QMetaMethod>
#ifdef QT_GUI_LIB
// QGuiApplication alone: the result is handed out as an opaque void* and every member below it is
// reached through the meta-object, so neither QStyleHints nor QAccessibilityHints needs to be a
// complete type here. Including them would also have pinned this file to Qt 6.10+, where
// qaccessibilityhints.h first exists — Qt5 has no such header and the whole binding stopped
// compiling.
#  include <QGuiApplication>
#endif
#include <QMetaType>
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
#  include <QtQml/qqmlparserstatus.h>
#  include <QtQml/QQmlEngine>
#  include <QtQml/QQmlContext>
#  include <QtQml/QQmlComponent>
#  if QT_VERSION >= 0x060000
#    include <QtQml/private/qqmlmetatype_p.h>
#    include <QtQml/qqml.h>
#  endif
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
        // Guarded exactly like QtdMocObject::qt_metacall above: a QML instance whose D
        // constructor threw has no backing object, and dispatching into it crashes (r8 #5). This
        // copy was missing both guards while the other had them — the two had drifted, which is
        // the hazard of keeping two demuxes. They stay separate on purpose (that one reads the
        // object's own fields on the hot path; this one serves trampolines, which have none), so
        // ANY change to one belongs in the other.
        else if (mi.slotcb && mi.dobj) mi.slotcb(mi.dobj, id - mi.nsig, a);
        id -= (mi.nsig + mi.nslot);
    } else if (c == QMetaObject::ReadProperty || c == QMetaObject::WriteProperty) {
        if (mi.propcb && mi.dobj && id < mi.nprop) mi.propcb(mi.dobj, id, c == QMetaObject::WriteProperty, a);
        id -= mi.nprop;
    }
    return id;
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
// Every property helper below is NULL-GUARDED. These are reached through propObj, which returns
// null whenever a property does not actually hold an object; a null there must be a visible
// no-op/zero, never a crash inside QObject::setProperty.
int  qtd_prop_get_int(void* o, const char* n) { return o ? static_cast<QObject*>(o)->property(n).toInt() : 0; }
// A property write REPORTS whether it landed. QObject::setProperty returns false both when the
// name is not a declared Q_PROPERTY (it then creates a DYNAMIC property, so the write "succeeds"
// while nothing the meta-object knows about changed) and when the QVariant conversion fails.
// Both were indistinguishable from success across ~1400 generated call sites — the same silent
// failure connectMeta was fixed for. The declared-property test comes first so that creating a
// dynamic property is reported as the miss it is.
static int qtd_prop_write(void* o, const char* n, const QVariant& v) {
    if (!o) return 0;
    auto* obj = static_cast<QObject*>(o);
    if (obj->metaObject()->indexOfProperty(n) < 0) return 0;
    return obj->setProperty(n, v) ? 1 : 0;
}

int qtd_prop_set_int(void* o, const char* n, int v) { return qtd_prop_write(o, n, v); }
double qtd_prop_get_double(void* o, const char* n) { if (!o) return 0; return static_cast<QObject*>(o)->property(n).toDouble(); }
int qtd_prop_set_double(void* o, const char* n, double v) { return qtd_prop_write(o, n, v); }
bool qtd_prop_get_bool(void* o, const char* n) { if (!o) return false; return static_cast<QObject*>(o)->property(n).toBool(); }
int qtd_prop_set_bool(void* o, const char* n, bool v) { return qtd_prop_write(o, n, v); }
// A QObject*-valued property — a GROUPED property (`group.count: 42` in QML) is one of these:
// the group is a real child object reached through the parent's meta-object, and its members are
// ordinary properties on it. Returns null if the property is absent or not an object.
void* qtd_prop_get_obj(void* o, const char* n) {
    if (!o) return nullptr;
    return static_cast<QObject*>(o)->property(n).value<QObject*>();
}
// ---- generic property access by TYPE NAME -------------------------------------
// The typed helpers below (int/double/bool/QString) can only reach a value type that happens to
// have a registered QString conversion: QColor does, QSize does not, so `@Property QSize` was
// unreachable THROUGH the meta-object even though the property was registered correctly. The
// meta-object records a property by type NAME and QMetaType resolves it, so one pair keyed by
// that name serves every registered type — which is what principle 1 of the moc says.
//
// `data`/`out` point at the caller's value of that exact type; QVariant(QMetaType, const void*)
// copies it in, and QMetaType::destruct/construct handle the lifetime.
extern "C" int qtd_prop_set_var(void* o, const char* n, const char* typeName, const void* data) {
    if (!o || !typeName) return 0;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QMetaType mt = QMetaType::fromName(typeName);
    if (!mt.isValid()) return 0;
    return static_cast<QObject*>(o)->setProperty(n, QVariant(mt, data)) ? 1 : 0;
#else
    // Qt5 names the same operations differently: QMetaType::type() for the id, and the
    // (typeId, copy) QVariant constructor. The mechanism is identical.
    int id = QMetaType::type(typeName);
    if (id == QMetaType::UnknownType) return 0;
    return static_cast<QObject*>(o)->setProperty(n, QVariant(id, data)) ? 1 : 0;
#endif
}

// Reads into `out` (already default-constructed by the caller). Returns 0 when the property is
// absent, or holds something that cannot convert to the requested type — both of which used to
// be indistinguishable from a zero value.
extern "C" int qtd_prop_get_var(void* o, const char* n, const char* typeName, void* out) {
    if (!o || !typeName) return 0;
    QVariant v = static_cast<QObject*>(o)->property(n);
    if (!v.isValid()) return 0;
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    QMetaType mt = QMetaType::fromName(typeName);
    if (!mt.isValid()) return 0;
    if (v.metaType() != mt && !v.convert(mt)) return 0;
    mt.destruct(out);
    mt.construct(out, v.constData());
#else
    int id = QMetaType::type(typeName);
    if (id == QMetaType::UnknownType) return 0;
    if (v.userType() != id && !v.convert(id)) return 0;
    QMetaType::destruct(id, out);
    QMetaType::construct(id, out, v.constData());
#endif
    return 1;
}

// ---- default children go through the type's DEFAULT PROPERTY -------------------------------
// The engine appends a default child to the type's default list property, and each type decides
// what that MEANS: QQuickItem's `data` sets the QObject parent and parentItem, QQuickFlickable's
// `flickableData` reparents into the flickable's contentItem, QQuickPopup/Control's `contentData`
// into theirs. Doing it by hand (setQtParent + parent) put the child somewhere the engine never
// has it. QQmlListReference is the generic channel -- one call, every type's own rule.
extern "C" int qtd_list_append(void* ownerV, const char* prop, void* childV) {
#ifdef QTD_HAVE_QML
    if (!ownerV || !childV || !prop) return 0;
    QQmlListReference ref(static_cast<QObject*>(ownerV), prop);
    if (!ref.isValid() || !ref.canAppend()) return 0;
    return ref.append(static_cast<QObject*>(childV)) ? 1 : 0;
#else
    (void) ownerV; (void) prop; (void) childV; return 0;
#endif
}

#ifdef QTD_HAVE_QML
// Guarded because this SAME unit is compiled for bindings with no QtQml at all (QtWidgets,
// libsample): an unguarded QQmlEngine here broke the default build, which is a feature-isolation
// defect, not a QML one. qtd_probe_noqml.cpp compiles this file without QtQml so it cannot recur.
static QQmlEngine* qtd_qml_engine();   // defined with the QQmlContext helpers below
#endif

// ---- QML module bootstrap -------------------------------------------------------------------
// A compiled Control reads its palette from the QQuickTheme the STYLE module installs, and that
// module is only initialised when the engine IMPORTS it. Without it, Qt's own Pane.qml compiled
// to `background.color = #efefef` where the engine gives #ffffff -- no diagnostic, no crash, just
// a different colour. Measured: importing QtQuick.Templates or QtQuick.Controls does NOT do it;
// the style module (QtQuick.Controls.Basic) does. Palette resolution is lazy, so a control built
// BEFORE this still picks the theme up -- what matters is only that it precedes the first READ.
// Cost: ~1.8 ms, once per module. The URI comes from the document's own qmldir, so nothing here
// knows anything about Controls.
extern "C" void qtd_ensure_module(const char* uri) {
#ifdef QTD_HAVE_QML
    if (!uri || !*uri || !QCoreApplication::instance()) return;
    static std::unordered_map<std::string, bool> done;
    if (!done.emplace(uri, true).second) return;
    QQmlComponent c(qtd_qml_engine());
    c.setData(QByteArray("import ") + uri + "\nimport QtQml\nQtObject {}",
              QUrl(QStringLiteral("file:///qtd_module_bootstrap.qml")));
    if (QObject* o = c.create()) delete o;
#else
    (void) uri;
#endif
}

// ---- dependencies reached THROUGH an object property ------------------------------------------
// `x: (parent.width - width) / 2` depends on an object our constructor cannot see: a root's
// `parent` (and HeaderView's `syncView`) is assigned by whoever instantiates it, AFTER the wire
// runs, so a one-shot connect to propObj(this,"parent") connected to null and threw. QML re-binds
// such a dependency when the property changes, and that is what these two do:
//   qtd_connect_notify  - follow the PROPERTY (parentChanged -> re-evaluate the binding)
//   qtd_bind_leaf       - (re)subscribe to the leaf signal on whatever object it now holds
// The slot calls bind_leaf on every run, so a new parent is subscribed and the old one dropped.
static std::unordered_map<std::string, QMetaObject::Connection> g_leafConn;
static std::mutex g_leafMx;

static std::string qtd_leaf_key(void* recv, const char* slot, const char* prop, const char* sig) {
    char b[32]; std::snprintf(b, sizeof b, "%p|", recv);
    return std::string(b) + slot + "|" + prop + "|" + sig;
}

extern "C" int qtd_bind_leaf(void* ownerV, const char* prop, const char* sig, void* recvV,
                             const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QObject* cur = qvariant_cast<QObject*>(owner->metaObject()->property(pi).read(owner));
    std::string k = qtd_leaf_key(recv, slot, prop, sig);
    std::lock_guard<std::mutex> g(g_leafMx);
    auto it = g_leafConn.find(k);
    if (it != g_leafConn.end()) { QObject::disconnect(it->second); g_leafConn.erase(it); }
    if (!cur) return 0;                       // not assigned yet: the notify connect will come back
    std::string s = std::string("2") + sig, m = std::string("1") + slot;
    auto c = QObject::connect(cur, s.c_str(), recv, m.c_str());
    if (c) g_leafConn[k] = c;
    return c ? 1 : 0;
}

extern "C" int qtd_connect_notify(void* ownerV, const char* prop, void* recvV, const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QMetaProperty mp = owner->metaObject()->property(pi);
    if (!mp.hasNotifySignal()) return 0;
    std::string s = std::string("2") + mp.notifySignal().methodSignature().constData();
    std::string m = std::string("1") + slot;
    return QObject::connect(owner, s.c_str(), recv, m.c_str(),
                            Qt::UniqueConnection) ? 1 : 0;
}

// ---- QQmlContext --------------------------------------------------------------------------
// A compiled object still needs a QQmlContext. Types that build their children THROUGH the engine
// -- QQmlDelegateModel behind every view, Loader, anything instantiating a QQmlComponent -- call
// QQmlContext::engine() from componentComplete() and segfault on a null context (ComboBox's popup
// contentItem is a ListView: that is the crash). Qt's own qmltc takes a QQmlEngine* in every
// generated constructor for exactly this reason; the win is not parsing QML, not doing without an
// engine. This engine parses nothing -- it exists so those internals have a context to reach.
#ifdef QTD_HAVE_QML
static QQmlEngine* qtd_qml_engine() {
    static QQmlEngine* eng = nullptr;
    if (!eng) eng = new QQmlEngine;   // leaked on purpose: it outlives every object pointing at it
    return eng;
}
#endif
// A QML SINGLETON's one instance, and a call on it. Qt's own controls compute colours with
// `Color.blend(a, b, f)` — a method on a C++ singleton the ENGINE owns, so there is no way to
// reach it by name from any object we hold and no honest way to fake it (constructing our own
// would be a different object with different state). The engine we already keep for contexts owns
// this one too.
extern "C" void qtd_ensure_module(const char* uri);
extern "C" void* qtd_qml_singleton(const char* uri, const char* name, int major, int minor) {
#ifdef QTD_HAVE_QML
    if (!QCoreApplication::instance()) return nullptr;
    // The module has to be LOADED before its types have ids: a compiled document imports nothing
    // by itself, so without this qmlTypeId answers -1, the instance comes back null, the call
    // returns an empty string and the write fails — loudly, which is how this was found.
    qtd_ensure_module(uri);
    int id = qmlTypeId(uri, major, minor, name);
    if (id < 0) return nullptr;
    return qtd_qml_engine()->singletonInstance<QObject*>(id);
#else
    (void) uri; (void) name; (void) major; (void) minor; return nullptr;
#endif
}
// ...and the call itself, by NAME, with every argument passed as text and converted to the
// parameter's own type by QMetaType — the same principle as every property here: the meta-object
// says what the types are, so one function serves every method of every singleton.
extern "C" void* qtd_invoke_str(void* o, const char* method, const char** args, int n) {
    if (!o) return new QString();
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    QByteArray want(method);
    for (int i = 0; i < mo->methodCount(); ++i) {
        QMetaMethod m = mo->method(i);
        if (m.name() != want || m.parameterCount() != n || n > 8) continue;
        QVariant vals[8];
        QGenericArgument ga[8];
        for (int k = 0; k < n; ++k) {
            vals[k] = QVariant(QString::fromUtf8(args[k]));
#if QT_VERSION >= 0x060000
            if (!vals[k].convert(m.parameterMetaType(k))) return new QString();
#else
            if (!vals[k].convert(m.parameterType(k))) return new QString();
#endif
            ga[k] = QGenericArgument(vals[k].typeName(), vals[k].constData());
        }
#if QT_VERSION >= 0x060000
        QMetaType rt = m.returnMetaType();
        void* rd = rt.create();
#else
        int rtId = m.returnType();
        void* rd = QMetaType::create(rtId);
#endif
        bool ok = m.invoke(q, Qt::DirectConnection,
#if QT_VERSION >= 0x060000
                           QGenericReturnArgument(rt.name(), rd),
#else
                           QGenericReturnArgument(QMetaType::typeName(rtId), rd),
#endif
                           ga[0], ga[1], ga[2], ga[3], ga[4], ga[5], ga[6], ga[7]);
#if QT_VERSION >= 0x060000
        QVariant rv(rt, rd);
        QString out = ok ? rv.toString() : QString();
        rt.destroy(rd);
#else
        QVariant rv(rtId, rd);
        QString out = ok ? rv.toString() : QString();
        QMetaType::destroy(rtId, rd);
#endif
        return new QString(out);
    }
    return new QString();
}
extern "C" void qtd_attach_context(void* o);
// ...with the DOCUMENT the object was written in. The engine gives each component a context whose
// baseUrl is its own document; sharing the engine's root context gave every compiled object an
// empty baseUrl, so a relative `source:`/`font.source` resolved against the process's working
// directory rather than against the .qml file. One context per document, cached: they are
// long-lived by construction and there is one per file, not per object.
extern "C" void qtd_attach_context_url(void* o, const char* docUrl) {
#ifdef QTD_HAVE_QML
    if (!o) return;
    if (!docUrl || !*docUrl) { qtd_attach_context(o); return; }
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlEngine::contextForObject(obj)) return;
    if (!QCoreApplication::instance()) return;
    static QHash<QString, QQmlContext*> cache;
    QString key = QString::fromUtf8(docUrl);
    QQmlContext*& ctx = cache[key];
    if (!ctx) {
        ctx = new QQmlContext(qtd_qml_engine()->rootContext(), qtd_qml_engine());
        ctx->setBaseUrl(QUrl(key));
    }
    QQmlEngine::setContextForObject(obj, ctx);
#else
    (void) o; (void) docUrl;
#endif
}
extern "C" void qtd_attach_context(void* o) {
#ifdef QTD_HAVE_QML
    if (!o) return;
    QObject* obj = static_cast<QObject*>(o);
    if (QQmlEngine::contextForObject(obj)) return;   // engine-created objects already have one
    // A QQmlEngine cannot exist before the application object, and it qFatals rather than fail:
    // a program with no QCoreApplication is one that cannot need a context anyway, so leave it be.
    if (!QCoreApplication::instance()) return;
    QQmlEngine::setContextForObject(obj, qtd_qml_engine()->rootContext());
#else
    (void) o;
#endif
}

// ---- QQmlParserStatus ---------------------------------------------------------
// The engine calls classBegin() before setting a component's properties and componentComplete()
// once the whole tree is built; a type that implements QQmlParserStatus does real initialisation
// there (QQuickControl computes hoverEnabled in componentComplete). A compiler that only
// constructs objects and assigns properties produces something that is built but NOT complete,
// which differs from the engine in ways no individual assignment explains.
//
// dynamic_cast because QQmlParserStatus is a secondary base: the interface pointer needs the
// correct offset, and a type that does not implement it must be left alone rather than called
// through a wrong vtable.
extern "C" void qtd_parser_status(void* o, int complete) {
#ifdef QTD_HAVE_QML
    if (!o) return;
    if (auto* ps = dynamic_cast<QQmlParserStatus*>(static_cast<QObject*>(o))) {
        if (complete) ps->componentComplete();
        else ps->classBegin();
    }
#else
    (void) o; (void) complete;
#endif
}

// ---- value-type ("gadget") grouped properties --------------------------------
// `Q_PROPERTY(ValueTypeGroup vt ...)` where ValueTypeGroup is a Q_GADGET: `vt.count` in QML does
// NOT go through an object, because there is no object — the property holds a VALUE. Reading is
// read-then-extract, and writing is read-modify-WRITE-BACK: changing a member of the temporary
// alone would be discarded, which is the difference from a QObject group (a reference, where the
// member write lands directly). Qt exposes exactly this via QMetaProperty's gadget overloads.
static const QMetaObject* gadgetMeta(const QVariant& v) {
    // Qt6 reaches the gadget's meta-object through QMetaType; Qt5 has no QVariant::metaType(),
    // but QMetaType::metaObjectForType(userType) answers the same question. readOnGadget /
    // writeOnGadget themselves exist in both.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    return v.metaType().metaObject();
#else
    return QMetaType::metaObjectForType(v.userType());
#endif
}
static bool gadgetProp(const QVariant& v, const char* member, QMetaProperty& out) {
    const QMetaObject* mo = gadgetMeta(v);
    if (!mo) return false;
    int i = mo->indexOfProperty(member);
    if (i < 0) return false;
    out = mo->property(i);
    return true;
}

// Attach a PROPERTY VALUE SOURCE (`NumberAnimation on width`, `Behavior on x`) to its target.
// QQmlPropertyValueSource is one generic interface: the object says "I drive this property", Qt
// hands it a QQmlProperty and the object takes it from there. So this one entry point covers every
// animation type, Behavior, and anything else that implements it — no per-type mechanism, and no
// need for the compiler to know what a NumberAnimation is.
// Only where QtQml is actually LINKED. This file is compiled into every binding's shims, and the
// widgets binding has no QtQml: the symbols exist in the headers but not in the link, so an
// unconditional definition broke every widgets test with undefined references. QT_QML_LIB is what
// pkg-config defines for Qt6Qml, so it marks exactly the bindings that can satisfy them.
#ifdef QT_QML_LIB
extern "C" int qtd_attach_value_source(void *src, void *target, const char *prop) {
    if (!src || !target) return 0;
    auto *vs = dynamic_cast<QQmlPropertyValueSource *>(static_cast<QObject *>(src));
    if (!vs) return 0;
    QQmlProperty p(static_cast<QObject *>(target), QString::fromUtf8(prop));
    if (!p.isValid()) return 0;
    vs->setTarget(p);
    return 1;
}
#else
extern "C" int qtd_attach_value_source(void *, void *, const char *) { return 0; }
#endif

// Does the object's meta-object declare this property at all? Only an Item has `parent`, so a
// linkage check can ask before asserting instead of assuming every child is visual.
extern "C" int qtd_has_prop(void* o, const char* n) {
    if (!o) return 0;
    return static_cast<QObject*>(o)->metaObject()->indexOfProperty(n) >= 0 ? 1 : 0;
}

// Copy a property from one object to another WITHOUT naming its type. The QVariant carries the
// type and QMetaType converts on write, so this reaches QColor, QFont, an enum, a model — every
// value type at once. The typed helpers each need the D type spelled out, which is exactly what a
// generated binding does not have for `font: control.font`.
extern "C" int qtd_prop_copy(void* src, const char* sname, void* dst, const char* dname) {
    if (!src || !dst) return 0;
    QVariant v = static_cast<QObject*>(src)->property(sname);
    if (!v.isValid()) return 0;
    return qtd_prop_write(dst, dname, v);
}

// Reads <obj>.<group>.<member> into a QVariant. Returns an invalid QVariant when anything in the
// chain is absent, which the typed wrappers below turn into the type's default.
static QVariant qtd_valuegroup_read(void* o, const char* group, const char* member) {
    if (!o) return QVariant();
    QVariant v = static_cast<QObject*>(o)->property(group);
    QMetaProperty p;
    if (!v.isValid() || !gadgetProp(v, member, p)) return QVariant();
    return p.readOnGadget(v.constData());
}

// Writes <obj>.<group>.<member>, preserving every other member of the value.
static int qtd_valuegroup_write(void* o, const char* group, const char* member, const QVariant& val) {
    if (!o) return 0;
    auto* obj = static_cast<QObject*>(o);
    QVariant v = obj->property(group);
    QMetaProperty p;
    if (!v.isValid() || !gadgetProp(v, member, p)) return 0;
    if (!p.writeOnGadget(v.data(), val)) return 0;
    return obj->setProperty(group, v) || true;   // setProperty is false for a non-Q_PROPERTY name
}

extern "C" {
// ...and the same copy for a member of a value-typed GROUP: `color: control.palette.text`.
extern "C" int qtd_prop_copy_group(void* src, const char* g, const char* m, void* dst, const char* dname) {
    if (!src || !dst) return 0;
    // A "group" is either a Q_GADGET VALUE (QFont -> readOnGadget) or a QObject (QQuickPalette,
    // which is what `control.palette` actually is). Reading an object with readOnGadget reads
    // through a pointer as if it were the value and yields nothing usable, so the object case is
    // dispatched on what the QVariant really holds.
    QVariant gv = static_cast<QObject*>(src)->property(g);
    QVariant v;
    if (gv.canConvert<QObject*>()) {
        QObject* go = gv.value<QObject*>();
        if (!go) return 0;
        v = go->property(m);
    } else {
        v = qtd_valuegroup_read(src, g, m);
    }
    if (!v.isValid()) return 0;
    return qtd_prop_write(dst, dname, v);
}

int  qtd_vgroup_get_int(void* o, const char* g, const char* m)    { return qtd_valuegroup_read(o, g, m).toInt(); }
bool qtd_vgroup_get_bool(void* o, const char* g, const char* m)   { return qtd_valuegroup_read(o, g, m).toBool(); }
double qtd_vgroup_get_double(void* o, const char* g, const char* m){ return qtd_valuegroup_read(o, g, m).toDouble(); }
// Same string convention as the scalar helpers: hand back a QString the D side frees.
void* qtd_vgroup_get_qs(void* o, const char* g, const char* m) {
    return new QString(qtd_valuegroup_read(o, g, m).toString());
}
int qtd_vgroup_set_int(void* o, const char* g, const char* m, int v)    { return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_bool(void* o, const char* g, const char* m, bool v)  { return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_double(void* o, const char* g, const char* m, double v){ return qtd_valuegroup_write(o, g, m, v); }
int qtd_vgroup_set_qs(void* o, const char* g, const char* m, const char* s, int n) {
    return qtd_valuegroup_write(o, g, m, QString::fromUtf8(s, n));
}
}

// Attached-property lookup needs QQmlMetaType::qmlType(QString, QString, QTypeRevision) and
// qmlAttachedPropertiesObject — QTypeRevision is Qt6-only and Qt5's QQmlMetaType has no
// (QString, QString, …) overload at all. Qt5 gets the stub; a Qt5 document using an attached
// property fails to resolve it rather than failing to build. (Same shape as the QT_VERSION
// branch in the RegisterType block below.)
#if defined(QTD_HAVE_QML) && QT_VERSION >= 0x060000
// The ATTACHED-properties object a QML type provides for `obj` (`TestType.attachedCount` in QML).
// The type is looked up BY NAME in Qt's own QML type registry, so this works for any registered
// type without the D side knowing it at compile time. Returns null when the type is unknown or
// attaches nothing — the callers null-guard, so that stays a visible no-op.
void* qtd_attached_obj(void* obj, const char* uri, const char* typeName) {
    if (!obj) return nullptr;
    auto t = QQmlMetaType::qmlType(QString::fromUtf8(typeName), QString::fromUtf8(uri), QTypeRevision());
    if (!t.isValid()) return nullptr;
    auto fn = t.attachedPropertiesFunction(nullptr);
    if (!fn) return nullptr;
    // Go through qmlAttachedPropertiesObject, NOT the raw function: the raw one CONSTRUCTS an
    // attached object every time it is called. The public entry point caches per (object, type),
    // which is what QML semantics require — `Type.x: 1` then reading `Type.x` must see the same
    // object. Calling the raw function gave a fresh, empty attachment on every access.
    return qmlAttachedPropertiesObject(static_cast<QObject*>(obj), fn, /*create*/ true);
}
#else
void* qtd_attached_obj(void*, const char*, const char*) { return nullptr; }
#endif

// Reset a property to its default — what `prop: undefined` means in QML. It must go through
// QMetaProperty::reset: the RESET method named by Q_PROPERTY is an ordinary member, not a slot or
// Q_INVOKABLE, so invoking it BY NAME finds nothing and silently does nothing.
bool qtd_prop_reset(void* o, const char* n) {
    if (!o) return false;
    auto* obj = static_cast<QObject*>(o);
    int i = obj->metaObject()->indexOfProperty(n);
    return i >= 0 && obj->metaObject()->property(i).reset(obj);
}
// Parent a QObject to another — Qt then OWNS the child and destroys it with the parent, which is
// what closes the side-table entry (~QtdMocObject -> qtd_moc_teardown -> the D registry drops it).
// A compiled QML document nests objects; without a parent each one would keep its registry entry,
// and therefore its D object, alive for the life of the process.
void qtd_set_parent(void* child, void* parent) {
    if (!child) return;
    static_cast<QObject*>(child)->setParent(static_cast<QObject*>(parent));
}
// Write a QObject* into a property — how a child object built in D is attached to a member of a
// GROUPED property (`group.object: QtObject { … }`).
void qtd_prop_set_obj(void* o, const char* n, void* v) {
    if (!o) return;
    static_cast<QObject*>(o)->setProperty(n, QVariant::fromValue(static_cast<QObject*>(v)));
}
// Invoke a parameterless member (a signal or an invokable) by name on any QObject — how a QML
// handler emits a signal that belongs to a GROUPED property's object rather than to itself.
// Returns false if there is no such member.
bool qtd_invoke0(void* o, const char* member) {
    if (!o) return false;
    return QMetaObject::invokeMethod(static_cast<QObject*>(o), member, Qt::DirectConnection);
}
// `Qt.styleHints` in QML is QGuiApplication::styleHints() — an ORDINARY QObject whose members
// are ordinary properties (`accessibility` is a CONSTANT QObject property, `contrastPreference`
// an enum one with a notify). So the generic channel already reaches all of it; the only thing
// missing was the ROOT, which cannot be reached by name from any object we hold. Guarded on
// QT_GUI_LIB — a define pkg-config supplies exactly when Gui is one of the binding's modules,
// so a core-only binding neither compiles nor links QtGui for it (see the QTD_ENABLE_QML note).
extern "C" void* qtd_style_hints() {
#ifdef QT_GUI_LIB
    return QGuiApplication::styleHints();
#else
    return nullptr;
#endif
}
// Dumps EVERY property an object's meta-object declares, as `<path>.<name>\t<value>`. Both the
// compiled side and the QQmlComponent oracle call THIS function, so the comparison covers what
// the objects actually are rather than what the compiler chose to record — and no difference can
// come from the two sides formatting a value differently, since there is only one formatter.
extern "C" void qtd_dump_object(void* o, const char* path) {
    if (!o) return;
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    // The C++ class each object actually IS, so comparing two DIFFERENT objects shows up as one
    // clear difference instead of a scattered set of property mismatches. Our objects are D
    // subclasses whose own className is generated, so the chain is walked to the first Qt class —
    // which is the bound base for ours and the class itself for the engine's, and therefore
    // comparable. Qt's Flickable reparents visual children into its contentItem, so `data[0]` on a
    // ListView is NOT the child the document wrote there: without this the two sides quietly
    // compared a Rectangle against an internal content item.
    {
// ...skipping any class that declares no properties of its own. Qt puts pure enum-holders in the
        // chain (QQuickDialogButtonBox's is DialogButtonBox_QMLTYPE < QPlatformDialogHelper <
        // QQuickDialogButtonBox), and stopping at the first Qt name picked the holder instead of the type.
        const QMetaObject* c = mo;
        while (c && (c->className()[0] != 'Q'
                     || c->propertyCount() <= c->propertyOffset())) c = c->superClass();
        // Qt generates a subclass per QML type (`QQuickRectangle_QML_2`); it IS that type, so the
        // suffix is normalised away — otherwise every object the document declares would read as a
        // type mismatch and the real ones would be lost in it.
        QByteArray cn(c ? c->className() : mo->className());
        int cut = cn.indexOf("_QML");
        if (cut > 0) cn.truncate(cut);
        std::printf("%s__class\t%s\n", path, cn.constData());
    }
    for (int i = 0; i < mo->propertyCount(); ++i) {
        QMetaProperty mp = mo->property(i);
        if (!mp.isReadable()) continue;
        QVariant v = mp.read(q);
        QString out;
        if (mp.isEnumType()) {
            const char* k = mp.enumerator().valueToKey(v.toInt());
            out = k ? QString::fromUtf8(k) : QString::number(v.toInt());
        } else if (v.canConvert<QObject *>()) {   // Qt5 has no QVariant::metaType()
            // The ADDRESS differs between the two runs by construction; what is comparable is
            // whether the slot is filled at all.
            out = v.value<QObject*>() ? QStringLiteral("<object>") : QStringLiteral("<null>");
        } else if (v.canConvert<QString>()) {
            out = v.toString();
        } else {
            continue;   // a list or an opaque gadget: not comparable as text, and not faked as one
        }
        std::printf("%s%s\t%s\n", path, mp.name(), out.toUtf8().constData());
    }
}
// Reads an ENUM property as its KEY — the same spelling the SETTER already takes, so a value
// read here compares against the key a `Qt.HighContrast` literal compiles to. QVariant::toString
// on an enum gives nothing useful; the key lives in the QMetaEnum, which the meta-object carries
// for every registered enum property. Non-enum properties fall back to the string form rather
// than reporting a failure the caller cannot act on.
extern "C" void* qtd_prop_get_enum_key(void* o, const char* n) {
    if (!o) return new QString();
    QObject* q = static_cast<QObject*>(o);
    const QMetaObject* mo = q->metaObject();
    int i = mo->indexOfProperty(n);
    if (i < 0) return new QString();
    QMetaProperty mp = mo->property(i);
    QVariant v = mp.read(q);
    if (!mp.isEnumType()) return new QString(v.toString());
    const char* k = mp.enumerator().valueToKey(v.toInt());
    return new QString(k ? QString::fromUtf8(k) : QString());
}
void* qtd_prop_get_qs(void* o, const char* n) { return new QString(o ? static_cast<QObject*>(o)->property(n).toString() : QString()); }
int qtd_prop_set_qs(void* o, const char* n, const char* p, int len) {
    return qtd_prop_write(o, n, QString::fromUtf8(p, len));
}

// connects signal->slot by signature (works for custom AND built-in: both have a
// meta-object). Returns a QMetaObject::Connection* (or null if not found).
// Returns 1 on success, 0 if either side is null or a signature does not resolve. It used to
// return a heap-allocated QMetaObject::Connection that no caller ever freed or used; the
// connection is owned by the two QObjects anyway, so nothing is allocated now. The D side turns
// a 0 into a thrown error — a mistyped signature must not be a connection that silently never
// fires (qmltc-d emits hundreds of these).
int qtd_connect_meta(void* s, const char* sig, void* r, const char* slot) {
    if (!s || !r) return 0;
    auto* so = static_cast<QObject*>(s);
    auto* ro = static_cast<QObject*>(r);
    int si = so->metaObject()->indexOfSignal(QMetaObject::normalizedSignature(sig));
    int ri = ro->metaObject()->indexOfMethod(QMetaObject::normalizedSignature(slot));
    if (si < 0 || ri < 0) return 0;
    return QObject::connect(so, so->metaObject()->method(si),
                            ro, ro->metaObject()->method(ri)) ? 1 : 0;
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
