// qmltc-d differential ORACLE (analog of tests/uic/qtd_uidump.cpp for uic). Loads a .qml with the
// REAL QML engine (QQmlComponent), instantiates the root object, and prints each QML-declared
// scalar property as `name\tvalue`, SORTED by name. qmltc-d --dump prints the same lines from the
// generated D; equal output proves the compiled-to-D object reproduces what the engine produces.
// Formatting is chosen to match D's writefln("%s", v): int as-is, bool true/false, double via a
// minimal round-trippable form, string raw.
#include <QGuiApplication>
// Resolving an ATTACHED path segment (`TestType.attachedCount`) needs the QML type registry.
// Only the app-type oracle is compiled with Qt's private include dirs; the plain one keeps
// working without this.
#if __has_include(<QtQml/private/qqmlmetatype_p.h>)
#  include <QtQml/private/qqmlmetatype_p.h>
#  include <QtQml/qqml.h>
#  define QTD_HAVE_ATTACHED 1
#endif
#include <QQmlEngine>
#include <QQmlComponent>
#include <QQmlProperty>
#include <QQmlContext>
#include <QQmlListReference>
#include <QJSValue>
#include <QMetaProperty>

// Qt5 spells the same three questions differently: a QVariant's type id, whether it holds a
// QObject*, and the meta-object of a gadget value. Naming them keeps the version check out of the
// walking code, which is identical on both.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
static int vTypeId(const QVariant &v)            { return v.typeId(); }
static bool vIsQObject(const QVariant &v)        { return v.metaType().flags() & QMetaType::PointerToQObject; }
static const QMetaObject *vGadgetMeta(const QVariant &v) { return v.metaType().metaObject(); }
#else
static int vTypeId(const QVariant &v)            { return v.userType(); }
static bool vIsQObject(const QVariant &v)        { return QMetaType::typeFlags(v.userType()) & QMetaType::PointerToQObject; }
static const QMetaObject *vGadgetMeta(const QVariant &v) { return QMetaType::metaObjectForType(v.userType()); }
#endif
#include <QVariant>
#include <QByteArray>
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <QMetaEnum>
#include <string>
#include <vector>
#include <set>

// Recurse the object tree: dump each QML-declared scalar property as `<prefix>name\tvalue`, and
// descend into QObject* properties (a child object) with a dotted prefix — matching qmltc-d's
// generated dump, which reads o.kid.y directly.
static void dumpObj(QObject *obj, const std::string &prefix, std::vector<std::string> &lines);
static void enumPaths(QObject *obj, const std::string &prefix, std::vector<std::string> &out, int depth);

static std::string qs(const QString &s) { return s.toStdString(); }

static std::string fmt(const QVariant &v) {
    switch (vTypeId(v)) {
    case QMetaType::Bool:   return v.toBool() ? "true" : "false";
    case QMetaType::Int:
    case QMetaType::LongLong: return std::to_string(v.toLongLong());
    case QMetaType::Double:
    case QMetaType::Float: {
        // %.17g on both sides. The two shortest-round-trip renderings disagree on a value sitting
        // exactly between two 6-digit forms (3.765625 -> D 3.76562, Qt 3.76563), which surfaced as
        // a value mismatch on a font metric that was in fact identical.
        // `+ 0.0` normalises a negative zero: -0 and 0 are the same value and differ only in
        // how %.17g prints them. The generated dump does the same.
        return QString::asprintf("%.17g", v.toDouble() + 0.0).toStdString();
    }
    default:
        // A `list<int>`-style value list has no useful toString (it yields ""), which would have
        // silently matched an empty D side. Serialize the elements joined by "," — the same shape
        // the compiled D side prints — so the comparison is real.
        if (v.canConvert<QVariantList>() && vTypeId(v) != QMetaType::QString) {
            const QVariantList l = v.toList();
            std::string out;
            for (const QVariant &e : l) { if (!out.empty()) out += ","; out += fmt(e); }
            return out;
        }
        return v.toString().toStdString();
    }
}

// The oracle body is a callable ENTRY POINT, not `main`, so a D driver can register the app's
// D-defined QML types (qmlRegisterType!T) and THEN hand over to exactly this code — the same
// walk/format/dump the C++-only oracle has been running. `main` below keeps the plain C++ use.
extern "C" int qtd_qmlvalues_main(int argc, char **argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <file.qml>\n", argv[0]); return 2; }
    QGuiApplication app(argc, argv);
    QQmlEngine engine;
    QQmlComponent comp(&engine, QUrl::fromLocalFile(argv[1]));
    if (comp.isError()) {
        for (const auto &e : comp.errors()) std::fprintf(stderr, "%s\n", qPrintable(e.toString()));
        return 1;
    }
    QObject *obj = comp.create();
    if (!obj) {
        // create() can fail AFTER a clean compile (a type that refuses to instantiate, a failing
        // required property, ...); its reason is only in the component's errors, so print them.
        std::fprintf(stderr, "qmlvalues: create() failed for %s\n", argv[1]);
        for (const auto &e : comp.errors()) std::fprintf(stderr, "  %s\n", qPrintable(e.toString()));
        return 1;
    }

    // Args after the .qml: `name=value` mutations, and an optional `--props <file>` listing the
    // exact property PATHS to dump (one per line). With --props we read those (incl. base C++
    // Q_PROPERTYs the QML file set, which auto-discovery misses); without it we auto-discover the
    // QML-declared properties.
    std::string propsFile, verifyFile, objPathsFile;
    QString attachedUri;
    std::vector<QString> muts;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--props" && i + 1 < argc) { propsFile = argv[++i]; continue; }
        if (a == "--dumpall" && i + 1 < argc) { objPathsFile = argv[++i]; continue; }
        // Cross-check a label file against what the engine actually built (see enumPaths).
        if (a == "--verify-props" && i + 1 < argc) { verifyFile = argv[++i]; continue; }
        // The module whose types may appear as ATTACHED path segments.
        if (a == "--attached-uri" && i + 1 < argc) { attachedUri = QString::fromUtf8(argv[++i]); continue; }
        muts.push_back(QString::fromUtf8(argv[i]));
    }
    // Walk a dotted path to the object holding the leaf property; returns null if a hop is missing.
    // A `@N` segment is the Nth default child (QObject child, declaration order).
    auto walk = [&](QObject *root, const QStringList &parts) -> QObject * {
        QObject *cur = root;
        for (int j = 0; j < parts.size() - 1 && cur; ++j) {
            const QString &p = parts[j];
            if (p.startsWith('@')) {
                int idx = p.mid(1).toInt();
                auto ch = cur->children();
                cur = (idx >= 0 && idx < ch.size()) ? ch[idx] : nullptr;
                continue;
            }
            // `name[i]` — an element of a list property (what a `default property list<>` holds).
            if (p.endsWith(u']')) {
                int br = p.indexOf(u'[');
                QQmlListReference ref(cur, p.left(br).toUtf8().constData());
                int idx = p.mid(br + 1, p.size() - br - 2).toInt();
                cur = (ref.isValid() && idx >= 0 && idx < ref.count()) ? ref.at(idx) : nullptr;
                continue;
            }
            QVariant v = cur->property(p.toUtf8().constData());
            // A property the engine exposes as a QJSValue still HOLDS an object: `Rectangle.gradient`
            // is one (it takes either a Gradient or a preset name), and reading it as QObject* gave
            // null — so the oracle answered `<missing>` for the gradient and for every stop under
            // it, the two GradientStops decided the whole frame, and nothing compared them. Unwrap
            // it; QJSValue::toQObject is public API and returns null for a non-object, which lands
            // on the same failure path as before.
            if (v.isValid() && v.canConvert<QJSValue>() && !v.value<QObject *>()) {
                if (QObject *jo = v.value<QJSValue>().toQObject()) { cur = jo; continue; }
            }
            if (v.isValid()) { cur = v.value<QObject *>(); continue; }
#ifdef QTD_HAVE_ATTACHED
            // Not a property: it may name a TYPE whose attached object is meant
            // (`TestType.attachedCount`). Read the one the engine already created.
            if (!attachedUri.isEmpty()) {
                auto t = QQmlMetaType::qmlType(p, attachedUri, QTypeRevision());
                if (t.isValid())
                    if (auto fn = t.attachedPropertiesFunction(nullptr)) {
                        cur = qmlAttachedPropertiesObject(cur, fn, /*createIfMissing*/ false);
                        continue;
                    }
            }
#endif
            cur = nullptr;
        }
        return cur;
    };
    for (auto &a : muts) {
        // `name()` invokes a no-arg method on the root — the engine side of the same protocol.
        if (a.endsWith(QLatin1String("()"))) {
            QMetaObject::invokeMethod(obj, a.chopped(2).toUtf8().constData(), Qt::DirectConnection);
            continue;
        }
        int eq = a.indexOf('=');
        if (eq < 0) continue;
        QStringList parts = a.left(eq).split('.');
        // A VALUE-group member has no object to set on: read the value, change the member, write
        // the value back — the same read-modify-write the compiled side does. Without this the
        // mutation was silently DROPPED here, so the engine kept the old value while the D side
        // changed, and the differential blamed the compiler for the harness's gap.
        if (parts.size() >= 2) {
            QObject *owner = obj;
            QStringList head = parts.mid(0, parts.size() - 2);
            if (!head.isEmpty()) { QStringList h = head; h << head.last(); owner = walk(obj, h); }
            if (owner) {
                QByteArray gname = parts[parts.size() - 2].toUtf8();
                QVariant gv = owner->property(gname.constData());
                if (gv.isValid() && !vIsQObject(gv)) {
                    if (const QMetaObject *gmo = vGadgetMeta(gv)) {
                        int gi = gmo->indexOfProperty(parts.last().toUtf8().constData());
                        if (gi >= 0) {
                            gmo->property(gi).writeOnGadget(gv.data(), QVariant(a.mid(eq + 1)));
                            owner->setProperty(gname.constData(), gv);
                            continue;
                        }
                    }
                }
            }
        }
        if (QObject *cur = walk(obj, parts)) cur->setProperty(parts.last().toUtf8().constData(), QVariant(a.mid(eq + 1)));
    }
    // `--dumpall <file>`: enumerate EVERY property each listed object declares, instead of the
    // labels the compiler recorded. The compiler records exactly what it also translated, so a
    // divergence in any property no binding mentioned was invisible by construction.
    //
    // The enumeration is written HERE rather than shared with the runtime under test: the oracle
    // uses only public Qt API on purpose, and a formatter shared with the compiled side could
    // agree with it while both were wrong. The rules must match the runtime's by INTENT — enum as
    // its key, an object slot as filled/empty, anything else as its QString form, and whatever has
    // no text form skipped rather than faked.
    if (!objPathsFile.empty()) {
        std::ifstream pf(objPathsFile);
        std::string ln;
        while (std::getline(pf, ln)) {
            while (!ln.empty() && (ln.back() == '\r' || ln.back() == '.')) ln.pop_back();
            QObject *tgt = obj;
            if (!ln.empty()) {
                QStringList parts = QString::fromStdString(ln).split('.');
                parts << parts.last();          // walk() stops one short: give it a dummy leaf
                tgt = walk(obj, parts);
            }
            // ...and if the dotted walk cannot get there, ask QQmlProperty, which resolves an
            // ATTACHED path by NAME and is public API — the walk's attached branch needs private
            // QtQml headers this oracle deliberately does not compile with.
            if (!tgt && !ln.empty()) {
                QQmlProperty qp(obj, QString::fromStdString(ln), qmlContext(obj));
                if (qp.isValid()) tgt = qp.read().value<QObject *>();
                // ...and for a path that goes THROUGH an attached object
                // (`ScrollBar.vertical.contentItem`), resolve the longest prefix QQmlProperty can
                // answer and walk the rest the ordinary way. Without this the comparison reported
                // <missing> for every deep path under an attached object — which is the compiler
                // being unmeasurable, not wrong, and it would have been read as the compiler
                // producing objects the engine does not have.
                if (!tgt) {
                    QStringList ps = QString::fromStdString(ln).split('.');
                    for (int cut = ps.size() - 1; cut >= 2 && !tgt; --cut) {
                        QQmlProperty pre(obj, ps.mid(0, cut).join('.'), qmlContext(obj));
                        if (!pre.isValid()) continue;
                        QObject *base = pre.read().value<QObject *>();
                        if (!base) continue;
                        QStringList rest = ps.mid(cut);
                        rest << rest.last();          // walk() stops one short
                        tgt = walk(base, rest);
                    }
                }
            }
            if (!tgt) { std::printf("%s.<missing>\t<missing>\n", ln.c_str()); continue; }
            std::string pre = ln.empty() ? "" : ln + ".";
            const QMetaObject *mo = tgt->metaObject();
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
                const QMetaObject *c = mo;
                while (c && (c->className()[0] != 'Q'
                             || c->propertyCount() <= c->propertyOffset())) c = c->superClass();
                // Qt generates a subclass per QML type (`QQuickRectangle_QML_2`); it IS that type, so the
                // suffix is normalised away — otherwise every object the document declares would read as a
                // type mismatch and the real ones would be lost in it.
                QByteArray cn(c ? c->className() : mo->className());
                int cut = cn.indexOf("_QML");
                if (cut > 0) cn.truncate(cut);
                std::printf("%s__class\t%s\n", pre.c_str(), cn.constData());
            }
            for (int i = 0; i < mo->propertyCount(); ++i) {
                QMetaProperty mp = mo->property(i);
                if (!mp.isReadable()) continue;
                QVariant v = mp.read(tgt);
                QString outv;
                if (mp.isEnumType()) {
                    const char *k = mp.enumerator().valueToKey(v.toInt());
                    outv = k ? QString::fromUtf8(k) : QString::number(v.toInt());
                } else if (v.canConvert<QObject *>()) {   // Qt5 has no QVariant::metaType()
                    outv = v.value<QObject *>() ? QStringLiteral("<object>") : QStringLiteral("<null>");
                } else if (v.canConvert<QJSValue>()) {
                    // ...and a QJSValue that HOLDS an object is an object slot too. Same rule as
                    // above, reached independently — `Rectangle.gradient` printed empty on both
                    // sides whether it held a Gradient or null, so a binding that stopped switching
                    // it had nothing in the differential to show for it.
                    QJSValue jv = v.value<QJSValue>();
                    // ...only when it HOLDS a QObject, for the reason written on the other side:
                    // a plain JS object has no comparable text, and one side having `fontInfo` and
                    // the other not is a spelling difference, not a defect.
                    if (!jv.toQObject()) continue;
                    outv = QStringLiteral("<object>");
                } else if (v.canConvert<QString>()) {
                    outv = v.toString();
                } else continue;
                std::printf("%s%s\t%s\n", pre.c_str(), mp.name(), outv.toUtf8().constData());
            }
        }
        return 0;
    }

    // QTD_QMLVALUES_DEBUG=1 -> describe the meta-object chain the engine actually built. Answers
    // "did QML install a QQmlVMEMetaObject for the members this .qml declares, and on which class?"
    if (qEnvironmentVariableIsSet("QTD_QMLVALUES_DEBUG"))
        for (const QMetaObject *m = obj->metaObject(); m; m = m->superClass())
            std::fprintf(stderr, "[dbg] %s: properties [%d,%d)%s\n", m->className(),
                         m->propertyOffset(), m->propertyCount(),
                         m == obj->metaObject() ? "  <- metaObject()" : "");

    if (!verifyFile.empty()) {
        // Compare COVERAGE, not spelling. The same object is reachable by several routes — a
        // property-held child is also a QObject child, an attached object is a child too — so
        // requiring the label's PATH to match the enumerator's would report divergences that are
        // only naming. What has to hold is that every declared (object, property) the engine
        // built is named by SOME label.
        std::vector<std::string> have;
        enumPaths(obj, "", have, 0);
        std::set<std::pair<QObject *, std::string>> covered;
        std::ifstream f(verifyFile);
        std::vector<std::string> labels;
        for (std::string l; std::getline(f, l);) if (!l.empty()) labels.push_back(l);
        for (const auto &l : labels) {
            QStringList parts = QString::fromStdString(l).split('.');
            if (QObject *cur = walk(obj, parts)) covered.insert({cur, qs(parts.last())});
        }
        int missing = 0;
        for (const auto &pth : have) {
            auto dot = pth.rfind('.');
            QStringList parts = QString::fromStdString(pth).split('.');
            QObject *owner = walk(obj, parts);
            std::string leaf = dot == std::string::npos ? pth : pth.substr(dot + 1);
            if (owner && covered.count({owner, leaf})) continue;
            std::fprintf(stderr, "qmlvalues: engine has '%s', no label\n", pth.c_str());
            ++missing;
        }
        if (have.empty() && labels.empty())
            std::fprintf(stderr, "qmlvalues: nothing to compare — the engine built no QML-declared scalar\n");
        return missing ? 4 : 0;
    }

    std::vector<std::string> lines;
    if (!propsFile.empty()) {
        std::ifstream f(propsFile);
        std::string label;
        while (std::getline(f, label)) {
            if (label.empty()) continue;
            QStringList parts = QString::fromStdString(label).split('.');
            // A VALUE-type ("gadget") group: `vt.count` has no object behind `vt` — the property
            // holds a value, and its members live in that value's own meta-object. walk() only
            // knows how to follow objects, so this is resolved before it is asked.
            if (parts.size() >= 2) {
                QObject *owner = obj;
                QStringList head = parts.mid(0, parts.size() - 2);
                if (!head.isEmpty()) {
                    QStringList h = head; h << head.last();   // walk() consumes the leaf
                    owner = walk(obj, h);
                }
                if (owner) {
                    QVariant gv = owner->property(parts[parts.size() - 2].toUtf8().constData());
                    if (gv.isValid() && !vIsQObject(gv)) {
                        if (const QMetaObject *gmo = vGadgetMeta(gv)) {
                            int gi = gmo->indexOfProperty(parts.last().toUtf8().constData());
                            if (gi >= 0) {
                                lines.push_back(label + "\t"
                                                + fmt(gmo->property(gi).readOnGadget(gv.constData())));
                                continue;
                            }
                        }
                    }
                }
            }
            // An ATTACHED path (`Overlay.modal.implicitWidth`) is not reachable by walking
            // properties: `Overlay` is not a property of anything. QQmlProperty resolves it by
            // NAME against the engine's context, which is public API and is how the engine itself
            // reads such a path — without this the oracle simply could not verify the family.
            QObject *cur = walk(obj, parts);
            // A label the engine cannot resolve used to be OMITTED, which makes a mismatch look
            // like agreement whenever the other side also prints nothing — and an unchecked leaf
            // read returns an invalid QVariant that formats as "", matching any empty string.
            // Both are now hard errors: the differential must compare, or fail.
            if (!cur) {
                std::fprintf(stderr, "qmlvalues: no object at path '%s'\n", label.c_str());
                return 3;
            }
            auto leaf = parts.last().toUtf8();
            if (cur->metaObject()->indexOfProperty(leaf.constData()) < 0) {
                std::fprintf(stderr, "qmlvalues: '%s' has no property '%s' (class %s)\n",
                             label.c_str(), leaf.constData(), cur->metaObject()->className());
                return 3;
            }
            lines.push_back(label + "\t" + fmt(cur->property(leaf.constData())));
        }
    } else {
        dumpObj(obj, "", lines);
    }
    std::sort(lines.begin(), lines.end());
    for (const auto &l : lines) std::printf("%s\n", l.c_str());
    return 0;
}

// Plain C++ oracle (no app types to register). Compiled out when a D driver supplies its own
// main and links this file for qtd_qmlvalues_main alone.
#ifndef QTD_QMLVALUES_NO_MAIN
int main(int argc, char **argv) { return qtd_qmlvalues_main(argc, argv); }
#endif

// Every QML-declared SCALAR the engine built, as the dotted path the label protocol would use.
// This is the independent half of the differential: the label list is chosen by the tool under
// test, so on its own it can only prove that what it emitted is right — never that it emitted
// enough. Comparing this set against the labels detects the whole class of "both sides shrank"
// false greens, including a file whose label set is EMPTY.
static void enumPaths(QObject *obj, const std::string &prefix, std::vector<std::string> &out, int depth) {
    // One object is often reachable by two routes — a property-held child is ALSO a QObject child,
    // so `kid.y` and `@0.y` name the same thing. Visit each object once; the first (property)
    // route wins, which is the one the label protocol prefers.
    static std::set<QObject *> seen;
    if (depth == 0) seen.clear();
    if (!obj || depth > 8 || !seen.insert(obj).second) return;
    const QMetaObject *mo = obj->metaObject();
    // Only members the DOCUMENT declared. Qt names the meta-object it builds for a document
    // `<Type>_QML_<n>`, so that marker separates "declared in this .qml" from the C++ properties
    // a bound base contributes — a Text brings ~35 of its own, which are not the document's and
    // are not qmltc-d's to reproduce.
    bool declared = QByteArray(mo->className()).contains("_QML");
    // Walk EVERY property, but only report a SCALAR when the document declared it. An
    // object- or list-valued property must be followed regardless of where it was declared —
    // a base type's `default property QtObject child` is how the document's child is reached,
    // and skipping it would make that child look unreachable except as a bare `@N`.
    for (int i = 0; i < mo->propertyCount(); ++i) {
        QMetaProperty p = mo->property(i);
        std::string path = prefix + p.name();
        QVariant v = p.read(obj);
        if (vIsQObject(v)) {
            // An object-valued property carries no scalar of its own; recurse for its members.
            enumPaths(v.value<QObject *>(), path + ".", out, depth + 1);
            continue;
        }
        // A list property holds objects, never a scalar of its own — recurse per element. An
        // EMPTY list must still not be reported as a missing scalar, so test the declared type
        // rather than whether the value happens to convert.
        if (QByteArray(p.typeName()).startsWith("QQmlListProperty")) {
            QQmlListReference ref(obj, p.name());
            for (int k = 0; ref.isValid() && k < ref.count(); ++k)
                enumPaths(ref.at(k), path + "[" + std::to_string(k) + "].", out, depth + 1);
            continue;
        }
        if (declared && i >= mo->propertyOffset()) out.push_back(path);
    }
    // Bare children the document declared. A bound C++ type also creates children of its own
    // (a TextEdit makes a QTextDocument); those carry no QML-declared property, so the
    // propertyOffset test below skips them — which is also why `@N` indices can disagree.
    int n = 0;
    for (QObject *c : obj->children()) {
        const QMetaObject *cm = c->metaObject();
        if (cm->propertyOffset() < cm->propertyCount())
            enumPaths(c, prefix + "@" + std::to_string(n) + ".", out, depth + 1);
        ++n;
    }
}

void dumpObj(QObject *obj, const std::string &prefix, std::vector<std::string> &lines) {
    // QML-declared properties live at [propertyOffset, propertyCount) — above everything the C++
    // base (QObject/QtObject) contributes. That's exactly the set qmltc-d emits.
    const QMetaObject *mo = obj->metaObject();
    for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
        QMetaProperty p = mo->property(i);
        QVariant v = p.read(obj);
        if (vIsQObject(v)) {
            if (auto *child = v.value<QObject *>()) dumpObj(child, prefix + p.name() + ".", lines);
        } else {
            lines.push_back(prefix + std::string(p.name()) + "\t" + fmt(v));
        }
    }
}
