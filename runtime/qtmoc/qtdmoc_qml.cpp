// QMLTC RUNTIME (critics r9 #2 / r11 #5) — the first code across the boundary the audit has asked
// for since round 9.
//
// `qtdmoc.cpp` is the SHARED meta-object runtime, compiled into every binding including the ones
// with no QtQml at all, and half of its exported functions exist only for compiled QML documents.
// That is what the audit meant by a QML compiler's "estado e lifecycle" living in the base product.
// This unit is where that half goes, one batch at a time.
//
// The criterion for this batch, and it is measurable: an exported function that touches
// QQml/QQuick, depends on NO file-scope state and NO helper defined in qtdmoc.cpp, and whose block
// is preprocessor-BALANCED on its own. The last clause is not pedantry — it is the thing that broke
// the first attempt. `qtd_attach_value_source` is written as two definitions (`#ifdef` … `#else` …
// `#endif`), a per-function scan took the first half, and qtdmoc.cpp was left one `#endif` deep:
// broken in a way only the compiler sees. It stays behind until it is moved WITH its twin.
//
// SECOND BATCH: the LEAF TABLE and everything that touches it. This one is not extraction, it is
// the decision the audit said each shared table needs — and for this table the answer is easy once
// asked: `g_leafConn` exists so that a compiled document's deep binding can re-subscribe when the
// object behind a property changes. Nothing outside QML has a deep binding. Measured before moving:
// no function outside the cluster calls `qtd_leaf_forget`, `qtd_leaf_watch` or `qtd_leaf_key`, so
// the table travels WITH its five functions and the shared unit loses the state, not just the code.
//
// What is still in the shared unit: the functions around `qtd_qml_engine()` (the engine singleton,
// nine of them) and `g_moAttach`, which is genuinely shared — the moc runtime uses it for
// D-defined QObjects with no QML anywhere.
//
// The whole file is QTD_HAVE_QML-guarded, so a binding without QtQml compiles it to nothing rather
// than failing to compile it — the shape `qtmoc-probe-noqml` already guards for the shared unit.

#include <QtCore/QObject>
#include <QtCore/QMetaObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QVariant>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtCore/QList>
#include <QtCore/QUrl>
#include <unordered_map>
#include <vector>
#include <mutex>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>

#if defined(QTD_ENABLE_QML)
#  if __has_include(<QtQml/QQmlEngine>)
#    define QTD_HAVE_QML 1
#  endif
#endif

#ifdef QTD_HAVE_QML
#include <QtQml/QQmlEngine>
#include <QtQml/QQmlContext>
#include <QtQml/QQmlComponent>
#include <QtQml/QQmlProperty>
#include <QtQml/QQmlExpression>
#include <QtQml/QQmlListReference>
#include <QtQml/QQmlParserStatus>
#include <QtQml/QJSValue>
#endif

// One helper from the shared unit, taken through the C ABI rather than by including anything: the
// object-path walk needs a property read, and `qtd_prop_get_obj` is already an exported symbol. A
// forward declaration is the whole dependency, which is what makes this a boundary and not a split.
extern "C" void* qtd_prop_get_obj(void* o, const char* n);

extern "C" void* qtd_context_object(void* o) {
#ifdef QTD_HAVE_QML
    if (!o) return nullptr;
    // ...found by walking UP, which is what `contextProperty` does implicitly and what a delegate's
    // CHILD needs: its own context nests inside the delegate root's and carries no object of its
    // own, so asking only the nearest one would answer null and the notify would never connect.
    for (QQmlContext* c = qmlContext(static_cast<QObject*>(o)); c; c = c->parentContext())
        if (QObject* co = c->contextObject()) return co;
    return nullptr;
#else
    (void) o; return nullptr;
#endif
}

extern "C" int qtd_context_prop_int(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (!o || !name) return 0;
    if (QQmlContext* c = qmlContext(static_cast<QObject*>(o)))
        return c->contextProperty(QString::fromUtf8(name)).toInt();
    return 0;
#else
    (void) o; (void) name; return 0;
#endif
}

extern "C" double qtd_context_prop_double(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (!o || !name) return 0;
    if (QQmlContext* c = qmlContext(static_cast<QObject*>(o)))
        return c->contextProperty(QString::fromUtf8(name)).toDouble();
    return 0;
#else
    (void) o; (void) name; return 0;
#endif
}

extern "C" void* qtd_context_prop_qs(void* o, const char* name) {
#ifdef QTD_HAVE_QML
    if (o && name)
        if (QQmlContext* c = qmlContext(static_cast<QObject*>(o)))
            return new QString(c->contextProperty(QString::fromUtf8(name)).toString());
#else
    (void) o; (void) name;
#endif
    return new QString();
}

extern "C" int qtd_bind_js(void* o, const char* prop, const char* src,
                           const char** names, void** objs, int n) {
#ifdef QTD_HAVE_QML
    if (!o || !prop || !src) return 0;
    QObject* obj = static_cast<QObject*>(o);
    QQmlContext* base = qmlContext(obj);
    // LOUD, not silent. A delegated binding that quietly does nothing is the worst outcome of the
    // three: the property keeps its default and nothing anywhere says why. Measured exactly once,
    // and that was enough -- a QtQml-only harness with no application object has no engine, so
    // there was no context and the value simply stayed empty against the engine's.
    if (!base) {
        std::fprintf(stderr, "qtd_bind_js: '%s' on %s has no QQmlContext — binding not installed\n",
                     prop, obj->metaObject()->className());
        return 0;
    }
    QQmlContext* ctx = base;
    if (n > 0) {
        ctx = new QQmlContext(base, obj);   // owned by the object, like the engine's per-item one
        for (int i = 0; i < n; ++i)
            if (names[i])
                ctx->setContextProperty(QString::fromUtf8(names[i]),
                                        static_cast<QObject*>(objs[i]));
    }
    QString p = QString::fromUtf8(prop);
    auto* e = new QQmlExpression(ctx, obj, QString::fromUtf8(src), obj);
    // Read ONCE: this runs on every re-evaluation of every delegated binding.
    static const bool trace = std::getenv("QTD_JS_TRACE") != nullptr;
    // A delegated binding that THROWS leaves the property at its default and, counted as a
    // delegation, looked like neither a refusal nor a defect. It is a defect: Qt's Material Button
    // paints white instead of #d6d7d7 because `control.Material.buttonColor(…)` throws, and the
    // census said "delegated" with no hint that anything was wrong. Reported ONCE per binding —
    // the first evaluation is where the cause is, and a binding that recovers later says so by not
    // repeating.
    auto reported = std::make_shared<bool>(false);
    auto eval = [e, obj, p, reported]() {
        QVariant v = e->evaluate();
        if (trace)
            std::fprintf(stderr, "qtd_bind_js: %s = %s%s\n", qPrintable(p), qPrintable(v.toString()),
                         e->hasError() ? qPrintable(" ERROR: " + e->error().toString()) : "");
        if (e->hasError()) {
            if (!*reported) {
                *reported = true;
                std::fprintf(stderr, "qtd_bind_js: delegated binding for '%s' on %s threw: %s\n",
                             qPrintable(p), obj->metaObject()->className(),
                             qPrintable(e->error().description()));
            }
            e->clearError();
            return;
        }
        QQmlProperty(obj, p, qmlContext(obj)).write(v);
    };
    e->setNotifyOnValueChanged(true);
    QObject::connect(e, &QQmlExpression::valueChanged, obj, eval);
    eval();
    return 1;
#else
    (void) o; (void) prop; (void) src; (void) names; (void) objs; (void) n; return 0;
#endif
}

// A MEMBER OF A VALUE-TYPED PROPERTY: `color.a`, `font.pixelSize`, `size.width`. QColor is neither a
// QObject nor a Q_GADGET, so no meta-object of its own answers for `a` — QML reaches it through a
// VALUE TYPE, and QQmlProperty resolves a dotted path straight through it — the same route QML
// itself takes, so the set of readable members is EXACTLY QML's. Nothing here knows what a colour
// is, which is the point.
//
// `layer.enabled: control.enabled && color.a > 0 && !control.flat` is Qt's Material Button, and
// `color.a` is the whole reason that line could not compile — so the background was never put in a
// layer, and seven of Material's documents drew a shape the engine does not draw at all.
extern "C" int qtd_prop_value_member(void* o, const char* prop, const char* member, double* out) {
#ifdef QTD_HAVE_QML
    if (!o || !prop || !member || !out) return 0;
    QObject* q = static_cast<QObject*>(o);
    // QQmlProperty resolves a DOTTED path through a value type — it is what QML itself uses for
    // `color.a`, and it is public, where the value-type registry is not.
    QQmlProperty p(q, QString::fromUtf8(prop) + QLatin1Char('.') + QString::fromUtf8(member));
    if (!p.isValid()) return 0;
    const QVariant got = p.read();
    if (!got.isValid() || !got.canConvert<double>()) return 0;
    *out = got.toDouble();
    return 1;
#else
    (void) o; (void) prop; (void) member; (void) out;
    return 0;
#endif
}

// The Nth element of a list property, THROUGH the meta-object — the same walk the oracle does.
// A default child is appended with qtd_list_append and Qt may reparent it (a Flickable moves visual
// children into its content item), so the D field that holds it and `<prop>[N]` on the object are
// not the same thing. Dumping the field under that label compared two different objects.
extern "C" void* qtd_list_at(void* o, const char* prop, int i) {
#ifdef QTD_HAVE_QML
    if (!o) return nullptr;
    QQmlListReference ref(static_cast<QObject*>(o), prop);
    if (!ref.isValid() || !ref.canAt() || i < 0 || i >= ref.count()) return nullptr;
    return ref.at(i);
#else
    (void) o; (void) prop; (void) i; return nullptr;
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

// ---- QQmlFinalizerHook --------------------------------------------------------
// Qt 6 gives a bound type a THIRD construction phase, after classBegin and componentComplete:
// QQmlFinalizerHook::componentFinalized(), which QQmlComponent::completeCreate() runs once the
// WHOLE component is built. Nothing in QQmlParserStatus stands in for it — measured on Qt's own
// HorizontalHeaderView: after classBegin + componentComplete (twice, and an event-loop turn) the
// object still reports rows/columns/contentWidth/contentHeight all -1 and `model` unset, where the
// engine reports 1/0/0/0 and `model` int 0. One call to componentFinalized() reproduces the
// engine's state exactly.
//
// It is not a per-type mechanism: the registry publishes it (`interfaces: ["QQmlFinalizerHook"]`
// on QQuickTableView and friends) and Q_INTERFACES puts it in the meta-object, so a cast by IID
// finds it for any type that has one.
//
// The interface is DECLARED here rather than included from QtQml/private: it is a virtual
// destructor followed by one pure virtual, and the cast resolves it by IID string, so a matching
// declaration is ABI-compatible without making the runtime depend on a private header that "may
// change from version to version without notice". Qt5 has no such phase at all — its engine never
// calls one — so doing nothing there IS the parity.
// `extern "C++"` because this file is compiled inside an `extern "C"` region: a class with virtual
// members and the template Q_DECLARE_INTERFACE generates are both C++-linkage-only, and the
// compiler says so rather than silently mis-linking.
#if defined(QTD_HAVE_QML) && QT_VERSION >= QT_VERSION_CHECK(6, 2, 0)
extern "C++" {
class QQmlFinalizerHook
{
public:
    virtual ~QQmlFinalizerHook();
    virtual void componentFinalized() = 0;
};
#define QQmlFinalizerHook_iid "org.qt-project.Qt.QQmlFinalizerHook"
Q_DECLARE_INTERFACE(QQmlFinalizerHook, QQmlFinalizerHook_iid)
}
#endif

extern "C" void qtd_component_finalized(void* o) {
#if defined(QTD_HAVE_QML) && QT_VERSION >= QT_VERSION_CHECK(6, 2, 0)
    if (!o) return;
    // qobject_cast, not dynamic_cast: the hook is reached through qt_metacast by IID, which is what
    // makes the locally-declared interface work at all.
    if (auto* fh = qobject_cast<QQmlFinalizerHook*>(static_cast<QObject*>(o)))
        fh->componentFinalized();
#else
    (void) o;
#endif
}

// Dumps EVERY property an object's meta-object declares, as `<path>.<name>\t<value>`. Both the
// compiled side and the QQmlComponent oracle call THIS function, so the comparison covers what
// the objects actually are rather than what the compiler chose to record — and no difference can
// come from the two sides formatting a value differently, since there is only one formatter.
// ...and the same dump with the `__class` decided by the CALLER. The walk below cannot tell our
// generated class from a Qt one — both are just names, and ours is named after the document exactly
// as the engine names a document-defined type — so for a NESTED child the compiler passes the C++
// base it built the object on. An empty hint keeps the walk, which is what the root wants.
extern "C" void qtd_dump_object_as(void* o, const char* path, const char* cls);
extern "C" void qtd_dump_object(void* o, const char* path) { qtd_dump_object_as(o, path, nullptr); }

// Dump ONE object named by a PATH from a root — `contentItem.effect.data[1]`, resolved segment by
// segment through the meta-object. A document handed to the engine wholesale has no D fields to
// walk, so the dump cannot be a chain of field accesses the way a compiled one is; the paths are
// the same ones `--objpaths` already hands the oracle, so both sides walk the same tree by the same
// names. LOUD when a segment does not resolve: a path silently skipped would read as agreement.
extern "C" void qtd_dump_path(void* root, const char* path) {
    if (!root || !path || !*path) return;
    QByteArray p(path);
    QObject* cur = static_cast<QObject*>(root);
    int at = 0;
    while (at < p.size() && cur) {
        int dot = p.indexOf('.', at);
        QByteArray seg = p.mid(at, dot < 0 ? -1 : dot - at);
        at = dot < 0 ? p.size() : dot + 1;
        int br = seg.indexOf('[');
        if (br < 0) {
            cur = static_cast<QObject*>(qtd_prop_get_obj(cur, seg.constData()));
        } else {
            QByteArray nm = seg.left(br);
            int idx = seg.mid(br + 1, seg.size() - br - 2).toInt();
            cur = static_cast<QObject*>(qtd_list_at(cur, nm.constData(), idx));
        }
    }
    if (!cur) {
        std::fprintf(stderr, "qtd_dump_path: '%s' resolves to nothing\n", path);
        return;
    }
    qtd_dump_object_as(cur, (p + ".").constData(), "");
}

extern "C" void qtd_dump_object_as(void* o, const char* path, const char* cls) {
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
        // A hint is where the walk STARTS, not what it answers: the engine applies the same
        // "skip a class that declares no properties of its own" rule above whatever it found, and a
        // QQuickMenuSeparator declares none — its answer is QQuickControl. Starting at the hinted
        // class and then walking gives the engine's answer for the same object.
        const QMetaObject* c = mo;
        bool named = false;   // the caller pointed AT this class, so it is not one to skip past
        if (cls && *cls)
            for (const QMetaObject* k = mo; k; k = k->superClass())
                if (std::strcmp(k->className(), cls) == 0) { c = k; named = true; break; }
        auto qtdGenerated = [](const QMetaObject* k) {
            for (int i = k->classInfoOffset(); i < k->classInfoCount(); ++i)
                if (std::strcmp(k->classInfo(i).name(), "qtdGenerated") == 0) return true;
            return false;
        };
        // The leading-Q test applies to the NAMED class too, and that is not a detail: the oracle
        // runs this same walk over the ENGINE's chain, where a document type is `<Document>_QML_n`.
        // `Locals.qml` produces `Locals_QML_0`, which fails the test there and answers QObject --
        // so our `Locals` has to fail it here for the same reason, or the two sides disagree about
        // a document whose name simply does not begin with Q. Being NAMED exempts a class only from
        // being skipped for being ours, which is what an inline component needs and a document root
        // must not have.
        while (c && (c->className()[0] != 'Q' || (qtdGenerated(c) && !named)
                     || c->propertyCount() <= c->propertyOffset())) { c = c->superClass(); named = false; }
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
        // A property whose metatype the type system does not know cannot be read into a QVariant
        // safely: QMetaType::canConvert walks a null interface and the process dies there (gdb, on
        // a `QQmlListProperty<QObject>` property added before its metatype was registered).
        // Skipping is what every other untextable property here already does; crashing the dump is
        // not one of the options.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
        if (!mp.metaType().isValid()) continue;
#endif
        QVariant v = mp.read(q);
        QString out;
        if (mp.isEnumType()) {
            const char* k = mp.enumerator().valueToKey(v.toInt());
            out = k ? QString::fromUtf8(k) : QString::number(v.toInt());
        } else if (v.canConvert<QObject *>()) {   // Qt5 has no QVariant::metaType()
            // The ADDRESS differs between the two runs by construction; what is comparable is
            // whether the slot is filled at all.
            out = v.value<QObject*>() ? QStringLiteral("<object>") : QStringLiteral("<null>");
#ifdef QTD_HAVE_QML
        } else if (v.canConvert<QJSValue>()) {
            // A QJSValue-typed property that HOLDS an object is an object slot like any other, and
            // saying so is the difference between a comparison and a blank. `Rectangle.gradient` is
            // one, and both sides printed empty for it whether it held a Gradient or null — which is
            // precisely how `gradient: control.down ? null : buttonGradient` stayed a one-shot with
            // nothing in the value differential to show for it.
            QJSValue jv = v.value<QJSValue>();
            // ONLY when it holds a QObject. A plain JS object has no text form worth comparing —
            // `[object Object]` says nothing, and Text.fontInfo is one on the engine's side and
            // nothing on ours, which would have added eleven differences that are a spelling, not
            // a defect. Skipped, exactly as a list or a gadget is. A slot filled on one side and
            // empty on the other still shows: the key is present for one and absent for the other.
            if (!jv.toQObject()) continue;
            out = QStringLiteral("<object>");
#endif
        } else if (v.canConvert<QString>()) {
            out = v.toString();
        } else {
            continue;   // a list or an opaque gadget: not comparable as text, and not faked as one
        }
        std::printf("%s%s\t%s\n", path, mp.name(), out.toUtf8().constData());
    }
}


// ---- dependencies reached THROUGH an object property ------------------------------------------
// `x: (parent.width - width) / 2` depends on an object our constructor cannot see: a root's
// `parent` (and HeaderView's `syncView`) is assigned by whoever instantiates it, AFTER the wire
// runs, so a one-shot connect to propObj(this,"parent") connected to null and threw. QML re-binds
// such a dependency when the property changes, and that is what these two do:
//   qtd_connect_notify  - follow the PROPERTY (parentChanged -> re-evaluate the binding)
//   qtd_bind_leaf       - (re)subscribe to the leaf signal on whatever object it now holds
// The slot calls bind_leaf on every run, so a new parent is subscribed and the old one dropped.
// An entry knows EVERY index it sits in (critics r13 #4). It used to be `key -> Connection` with a
// separate reverse index per object, and `qtd_leaf_forget(o)` dropped the key from o's vector only
// — the same key stayed in the OTHER endpoint's vector for ever. With a long-lived receiver and
// transient owners, that vector grows without bound, and the probe could not see it because
// `qtd_leaf_table_size()` reported the main table alone.
//
// Three endpoints, not two: the real connection is `cur -> recv`, and `cur` (the object the
// property currently holds) can die on its own. Qt invalidates the Connection and the entry used to
// survive until some other event touched it.
struct QtdLeafEntry {
    QMetaObject::Connection c;
    QObject* ends[3];        // owner, recv, cur — any of them may be null
};
static std::unordered_map<std::string, QtdLeafEntry> g_leafConn;

static std::unordered_map<QObject*, std::vector<std::string>> g_leafByObj;

static std::mutex g_leafMx;

// The key carries the OWNER, and it must. It did not, and the receiving slot is emitted once per
// BINDING (`__rc_<prop>()`), so an expression reading the same property name through two different
// objects — `a.parent.width + b.parent.width` — registered both dependencies under one key. The
// second call disconnected the first and BOTH returned success. A reactive dependency that stops
// updating without saying so is the worst failure this runtime can have, because nothing observes
// it: the frame is merely stale, never wrong-looking.
static std::string qtd_leaf_key(void* owner, void* recv, const char* slot, const char* prop,
                                const char* sig) {
    char b[48]; std::snprintf(b, sizeof b, "%p|%p|", owner, recv);
    return std::string(b) + slot + "|" + prop + "|" + sig;
}

// ...and the table must not outlive the objects it keys on. Qt invalidates the Connection when
// either end dies, but the ENTRY survives until that exact key is reused — and with a dynamic tree
// the addresses are recycled, so a stale entry is not merely a leak: it can be found by a later
// object that lands on the same address. Both ends are watched; the first key an object registers
// arms its watch.
static void qtd_leaf_watch(QObject* o, const std::string& k);   // below

// Drop ONE key from every index that holds it, then the entry. This is the half that was missing.
static void qtd_leaf_drop(const std::string& k) {             // g_leafMx HELD
    auto e = g_leafConn.find(k);
    if (e == g_leafConn.end()) return;
    for (QObject* o : e->second.ends) {
        if (!o) continue;
        auto it = g_leafByObj.find(o);
        if (it == g_leafByObj.end()) continue;
        auto& v = it->second;
        v.erase(std::remove(v.begin(), v.end(), k), v.end());
        if (v.empty()) g_leafByObj.erase(it);
    }
    g_leafConn.erase(k);
}

static void qtd_leaf_forget(QObject* o) {                    // g_leafMx HELD
    auto it = g_leafByObj.find(o);
    if (it == g_leafByObj.end()) return;
    const std::vector<std::string> keys = it->second;   // by value: drop mutates the map
    for (auto& k : keys) qtd_leaf_drop(k);
    g_leafByObj.erase(o);                               // no-op if drop already emptied it
}

// How many entries the REVERSE index holds, summed over objects. The main table returning to its
// baseline says nothing about this one — which is exactly how the one-sided cleanup stayed
// invisible — so the probe gets to see both.
extern "C" int qtd_leaf_index_size() {
    std::lock_guard<std::mutex> g(g_leafMx);
    size_t n = 0;
    for (auto& kv : g_leafByObj) n += kv.second.size();
    return (int) n;
}

static void qtd_leaf_watch(QObject* o, const std::string& k) {   // g_leafMx HELD
    if (!o) return;                                          // `cur` may be null
    auto& keys = g_leafByObj[o];
    if (keys.empty())
        QObject::connect(o, &QObject::destroyed, o, [o] {
            std::lock_guard<std::mutex> g(g_leafMx);
            qtd_leaf_forget(o);
        });
    if (std::find(keys.begin(), keys.end(), k) == keys.end()) keys.push_back(k);
}

extern "C" int qtd_bind_leaf(void* ownerV, const char* prop, const char* sig, void* recvV,
                             const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QObject* cur = qvariant_cast<QObject*>(owner->metaObject()->property(pi).read(owner));
    std::string k = qtd_leaf_key(owner, recv, slot, prop, sig);
    std::lock_guard<std::mutex> g(g_leafMx);
    if (auto it = g_leafConn.find(k); it != g_leafConn.end()) {
        QObject::disconnect(it->second.c);
        qtd_leaf_drop(k);                       // every index, not just this one
    }
    if (!cur) return 0;                       // not assigned yet: the notify connect will come back
    std::string s = std::string("2") + sig, m = std::string("1") + slot;
    auto c = QObject::connect(cur, s.c_str(), recv, m.c_str());
    if (!c) return 0;
    g_leafConn[k] = QtdLeafEntry{c, {owner, recv, cur}};
    qtd_leaf_watch(owner, k);
    qtd_leaf_watch(recv, k);
    qtd_leaf_watch(cur, k);                     // the connection's real sender (critics r13 #4)
    return 1;
}

// THE SAME SUBSCRIPTION, WITH THE SIGNAL RESOLVED FROM THE OBJECT instead of named by the caller.
// `background.topPadding` is written all over Qt's Imagine style, and `background` is declared as an
// `Item` — which has no topPadding. The member belongs to the NinePatchImage that is actually there,
// so no static table can name its notify, and the compiler refused the read outright rather than
// wire something it could not see. The meta-object of the object in hand can name it, which is the
// same channel the rest of this file already travels on.
extern "C" int qtd_bind_leaf_prop(void* ownerV, const char* prop, const char* leafProp, void* recvV,
                                  const char* slot) {
    QObject* owner = static_cast<QObject*>(ownerV);
    QObject* recv  = static_cast<QObject*>(recvV);
    if (!owner || !recv) return 0;
    int pi = owner->metaObject()->indexOfProperty(prop);
    if (pi < 0) return 0;
    QObject* cur = qvariant_cast<QObject*>(owner->metaObject()->property(pi).read(owner));
    // The key is the PROPERTY, not the signal: the signal is whatever the object currently there
    // answers with, and a re-subscription after that object is replaced must find the same entry.
    std::string kk = std::string("#") + leafProp;
    std::string k = qtd_leaf_key(owner, recv, slot, prop, kk.c_str());
    std::lock_guard<std::mutex> g(g_leafMx);
    if (auto it = g_leafConn.find(k); it != g_leafConn.end()) {
        QObject::disconnect(it->second.c);
        qtd_leaf_drop(k);                       // every index, not just this one
    }
    if (!cur) return 0;                       // not assigned yet: the notify connect will come back
    int li = cur->metaObject()->indexOfProperty(leafProp);
    if (li < 0) return 0;                     // the object there does not have it either
    QMetaMethod ns = cur->metaObject()->property(li).notifySignal();
    if (!ns.isValid()) return 0;              // a constant property never changes; nothing to wire
    std::string s = std::string("2") + ns.methodSignature().constData(), m = std::string("1") + slot;
    auto c = QObject::connect(cur, s.c_str(), recv, m.c_str());
    if (!c) return 0;
    g_leafConn[k] = QtdLeafEntry{c, {owner, recv, cur}};
    qtd_leaf_watch(owner, k);
    qtd_leaf_watch(recv, k);
    qtd_leaf_watch(cur, k);                     // the connection's real sender (critics r13 #4)
    return 1;
}

// How many leaf connections the table holds. A probe cannot prove the cleanup above from the
// outside — the entries are invisible — so the count is exported for exactly that: build a tree,
// destroy it, and require the table back at its baseline.
extern "C" int qtd_leaf_table_size() {
    std::lock_guard<std::mutex> g(g_leafMx);
    return (int) g_leafConn.size();
}
