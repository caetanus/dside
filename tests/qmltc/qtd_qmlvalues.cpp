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
#include <QQmlListReference>
#include <QMetaProperty>
#include <QVariant>
#include <QByteArray>
#include <algorithm>
#include <cstdio>
#include <fstream>
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
    switch (v.typeId()) {
    case QMetaType::Bool:   return v.toBool() ? "true" : "false";
    case QMetaType::Int:
    case QMetaType::LongLong: return std::to_string(v.toLongLong());
    case QMetaType::Double:
    case QMetaType::Float: {
        // Match D's default `%s` float text (shortest round-trip). %g is close for the corpus'
        // simple values; QString::number(d) gives the same shortest form D uses here.
        return QString::number(v.toDouble()).toStdString();
    }
    default:
        // A `list<int>`-style value list has no useful toString (it yields ""), which would have
        // silently matched an empty D side. Serialize the elements joined by "," — the same shape
        // the compiled D side prints — so the comparison is real.
        if (v.canConvert<QVariantList>() && v.typeId() != QMetaType::QString) {
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
    std::string propsFile, verifyFile;
    QString attachedUri;
    std::vector<QString> muts;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--props" && i + 1 < argc) { propsFile = argv[++i]; continue; }
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
                if (gv.isValid() && !gv.metaType().flags().testFlag(QMetaType::PointerToQObject)) {
                    if (const QMetaObject *gmo = gv.metaType().metaObject()) {
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
                    if (gv.isValid() && !gv.metaType().flags().testFlag(QMetaType::PointerToQObject)) {
                        if (const QMetaObject *gmo = gv.metaType().metaObject()) {
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
        if (v.metaType().flags() & QMetaType::PointerToQObject) {
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
        if (v.metaType().flags() & QMetaType::PointerToQObject) {
            if (auto *child = v.value<QObject *>()) dumpObj(child, prefix + p.name() + ".", lines);
        } else {
            lines.push_back(prefix + std::string(p.name()) + "\t" + fmt(v));
        }
    }
}
