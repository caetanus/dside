// qmltc-d — compile a .qml document into D (our analog of Qt's qmltc, which emits C++).
// Frontend = Qt's OWN QQmlJS parser (one unified QML+JS AST, dual-Qt, no new toolchain dep);
// backend emits a D @QObject class that uses the qtmoc runtime, so instantiating the generated
// type reproduces the QML object WITHOUT the QML engine interpreting the document at runtime.
//
// Supported so far (root object only): `property <type>: <literal>` -> @Property field;
// `property <type>: <expr>` bindings (identifiers, literals, unary -/!, parens, + - * / %,
// comparisons, ternary, && ||) evaluated live (NOTIFY + recompute slot + connect); and
// `on<Prop>Changed: <assignment(s)>` signal handlers. Everything else — child objects, ids,
// aliases, methods, calls/member-access in expressions — is reported on stderr and skipped, and
// the file is flagged PARTIAL (exit 3) so nothing is silently dropped.
#include <QtQml/private/qqmljsengine_p.h>
#include <QtQml/private/qqmljslexer_p.h>
#include <QtQml/private/qqmljsparser_p.h>
#include <QtQml/private/qqmljsast_p.h>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <map>
#include <set>
#include <functional>
#include <cctype>
#include <fstream>

using namespace QQmlJS;
using namespace QQmlJS::AST;

static std::string qs(const QString &s) { return s.toStdString(); }

// A QML name is not necessarily a valid D IDENTIFIER: `delegate` and `scope` are ordinary QML
// property names and both are D keywords, and they are not rare — 138 of the 944 .qml files Qt
// ships use one. Emitting them verbatim produced D that does not compile, which no diagnostic
// could show because the compiler was happy: the file was reported clean and the output was
// unbuildable. Only the D side is renamed; the QML NAME (dump labels, setProp/propObj strings)
// must stay exactly as written or it stops naming the property Qt knows.
static const std::set<std::string> &dKeywords() {
    static const std::set<std::string> kw = {
        "abstract","alias","align","asm","assert","auto","body","bool","break","byte","case","cast",
        "catch","cdouble","cent","cfloat","char","class","const","continue","creal","dchar","debug",
        "default","delegate","delete","deprecated","do","double","else","enum","export","extern",
        "false","final","finally","float","for","foreach","foreach_reverse","function","goto",
        "idouble","if","ifloat","immutable","import","in","inout","int","interface","invariant",
        "ireal","is","lazy","long","macro","mixin","module","new","nothrow","null","out","override",
        "package","pragma","private","protected","public","pure","real","ref","return","scope",
        "shared","short","static","struct","super","switch","synchronized","template","this","throw",
        "true","try","typeid","typeof","ubyte","ucent","uint","ulong","union","unittest","ushort",
        "version","void","wchar","while","with","__gshared","__traits","__vector","__parameters" };
    return kw;
}
static std::string dIdent(const std::string &n) {
    return dKeywords().count(n) ? n + "_" : n;
}

// The root object's `id:` (e.g. `id: root`), so a self-reference `root.x` in an expression
// resolves to the property `x`. Set once in main before any expression is compiled.
// The parser engine whose POOL owns the AST, so a script binding can be rewritten into nodes.
static Engine *g_astEngine = nullptr;
// True when `n` is one of the ids the object being compiled answers to. A local `.qml` type spliced
// at a use site has TWO — the definition's and the use site's — and they name the same object.
static bool isSelfId(const std::string &n);
static std::string g_selfId;

// QML type name of the object being compiled (its BOUND type, e.g. "Item"), so a binding that
// depends on a base property can find that property's real notify in g_qmlNotify. Saved/restored
// across compileObject like the other per-object state.
static std::string g_selfQmlType;

// Return types of this object's no-arg functions (name -> "int"/"double"/"string"/"bool"), so a
// call `f()` in a binding can be coerced to the target property's type. Scoped per object.
static std::map<std::string, std::string> g_funcRet;

// Property names a no-arg function reads, so a binding calling `f()` becomes reactive to them
// (transitive dependency). Scoped per object.
static std::map<std::string, std::vector<std::string>> g_funcReads;

// The D return type of the function currently being compiled, so a `return <expr>` in a
// multi-statement body formats its expression for that type. Empty outside a return-typed function.
static std::string g_returnType;

// Extra `import` lines the generated module needs (e.g. a bound base type's module). Accumulated.
static std::string g_extraImports;

// QML element name -> (bound D type, its import module). This table is DATA, loaded from the
// binding's qmlmap.tsv (which the generator produces from Qt's own plugins.qmltypes, restricted to
// the classes it subclasses) — NOT a hand-coded map. `--qmlmap <file>` populates it; without it,
// only QtObject/local types compile (no bound visual types).
static std::map<std::string, std::pair<std::string, std::string>> g_qmlMap;
// QML name -> its module URI, which is what attachedObj needs to resolve an ATTACHED type of a
// bound module (`Overlay.modal` lives in QtQuick.Templates, not in this document's own uri).
static std::map<std::string, std::string> g_qmlTypeUri;
// ...and every OTHER module that exports the same name. Each Controls style ships its own
// `BusyIndicatorImpl`, `SliderGroove` and so on, so a single answer is right for at most one style:
// Qt's Fusion BusyIndicator was built from the BASIC impl. The document's own imports decide.
static std::map<std::string, std::vector<std::string>> g_qmlTypeUris;
// <QML type of a document-defined class> -> its declared OBJECT properties -> their QML type.
static std::map<std::string, std::map<std::string, std::string>> g_declObjProps;
// Declared properties whose value type crosses as TEXT through the meta-object (a colour): reading
// the D field would hand an expression a QColor where it wants a string.
static std::set<std::string> g_metaTextProps;

// A type defined by a .qml FILE has no rows of its own: the registry only knows the type it DERIVES
// from. Copying that type's rows under the local name makes every lookup that carries a QML type
// name work for it too — a frame typed `ButtonPanel` could not answer `enabled`, so a binding on
// `panel.enabled` two levels down was refused for want of a notify the registry does publish (under
// `Rectangle`). Copied, not aliased, so the local type's own declarations can be added later
// without touching the base.
static void adoptLocalTypeRows(const std::string &localName, const std::string &baseQmlType);
// The URI for `typeName` that THIS document imports, or the registry's first answer.
// (defined below g_bareImports, which it consults)
static std::string uriForType(const std::string &typeName);

// Scalar properties of each bound QML type, and each one's notify signature, from qmlprops.tsv
// (written next to qmlmap.tsv by the same generator pass, so the two cannot drift). qmlmap says
// which class backs a name — enough to CONSTRUCT one; this is what lets a member be read.
static std::map<std::string, std::map<std::string, std::string>> g_qmlProps, g_qmlNotify;
// Properties marked CONSTANT by the registry. A dependency on one is SATISFIED by the initial
// read: it cannot change, so "no notify" is not a gap to report but the whole story.
static std::map<std::string, std::set<std::string>> g_qmlConst;
static bool isConstProp(const std::string &qmlType, const std::string &prop) {
    auto it = g_qmlConst.find(qmlType);
    return it != g_qmlConst.end() && it->second.count(prop) != 0;
}
// Raw C++ type name of every property, including those with no D scalar mapping — so a
// diagnostic can say WHICH type is unsupported instead of just "unsupported".
static std::map<std::string, std::map<std::string, std::string>> g_qmlCxxType;

// Properties that hold a LIST (5th qmlprops column ends in `[]`). QML lets a single object be
// assigned to one — `transitions: Transition {}` — and the engine appends it, so it lives at
// index 0 and NOT at the property itself.
static std::map<std::string, std::set<std::string>> g_qmlListProp;

static bool isListProp(const std::string &qmlType, const std::string &prop) {
    auto it = g_qmlListProp.find(qmlType);
    return it != g_qmlListProp.end() && it->second.count(prop) > 0;
}

static void loadQmlProps(const char *path) {
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        auto t1 = line.find('\t');
        auto t2 = line.find('\t', t1 + 1);
        if (t1 == std::string::npos || t2 == std::string::npos) continue;
        auto t3 = line.find('\t', t2 + 1);
        std::string qml = line.substr(0, t1), prop = line.substr(t1 + 1, t2 - t1 - 1);
        if (t3 == std::string::npos) { g_qmlProps[qml][prop] = line.substr(t2 + 1); continue; }
        std::string dty = line.substr(t2 + 1, t3 - t2 - 1);
        auto t4 = line.find('\t', t3 + 1);
        std::string nsig = t4 == std::string::npos ? line.substr(t3 + 1)
                                                   : line.substr(t3 + 1, t4 - t3 - 1);
        // The D type is EMPTY for a property whose C++ type has no scalar mapping (QColor,
        // QQuickPen, an enum). Those rows used to be dropped by the generator, taking their
        // notify with them — which is why a binding on such a property could not react and a
        // handler on its notify was refused. The notify is recorded for every property now;
        // only the D-typed ones enter g_qmlProps, since that table types a FIELD.
        if (!dty.empty()) g_qmlProps[qml][prop] = dty;
        // `!const` is not a signature: it says the property is CONSTANT, so a binding that reads
        // it needs no connection and is complete without one. Kept out of g_qmlNotify (there is
        // nothing to connect to) and out of the refusals (there is nothing missing).
        if (nsig == "!const") g_qmlConst[qml].insert(prop);
        else if (!nsig.empty()) g_qmlNotify[qml][prop] = nsig;
        if (t4 != std::string::npos) {
            std::string cxx = line.substr(t4 + 1);
            while (!cxx.empty() && (cxx.back() == '\r' || cxx.back() == '\n')) cxx.pop_back();
            // A trailing `[]` marks a LIST property (`transitions`, `states`): a child assigned to
            // one is APPENDED, and the engine holds it at <prop>[0] — not at <prop>.
            if (cxx.size() > 2 && cxx.compare(cxx.size() - 2, 2, "[]") == 0) {
                g_qmlListProp[qml].insert(prop);
                cxx.resize(cxx.size() - 2);
            }
            g_qmlCxxType[qml][prop] = cxx;
        }
    }
}

// Signals a bound QML type declares, with their FULL signature — what a handler for one of them
// needs in order to connect. Without this table only notify handlers were reachable, which is 147
// of the 373 handlers in the QML Qt ships; the other 226 are plain signals like `clicked`.
static std::map<std::string, std::map<std::string, std::string>> g_qmlSignals;

static void loadQmlSignals(const char *path) {
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        auto t1 = line.find('\t');
        auto t2 = line.find('\t', t1 + 1);
        if (t1 == std::string::npos || t2 == std::string::npos) continue;
        g_qmlSignals[line.substr(0, t1)][line.substr(t1 + 1, t2 - t1 - 1)] = line.substr(t2 + 1);
    }
}

// QML type -> its default property (5th qmlmap column). Empty for a type that declares none.
static std::map<std::string, std::string> g_qmlDefaultProp;

// The default property of the object being compiled, or "data" when the type declares none —
// which is what QQuickItem itself uses, and the only sane fallback for a fresh @QObject.
static std::string defaultPropOf(const std::string &qmlType) {
    auto it = g_qmlDefaultProp.find(qmlType);
    return it == g_qmlDefaultProp.end() ? std::string() : it->second;
}

// Module URIs for EVERY exported QML type, including ones we do not bind — an attached read needs the
// attached type's module and `Window` is not a bound type. Loaded beside the qmlmap; a bound type keeps
// the URI its own row carries.
// Properties of ATTACHED types (qmlattached.tsv), keyed by the QML name that carries them: `Window`
// -> {window: "QQuickWindow*"}. Separate from qmlprops because `Window`'s own rows are QQuickWindow's
// instance properties, and an attached read is a different scope.
static std::map<std::string, std::map<std::string, std::string>> g_qmlAttachedCxx;
static std::map<std::string, std::map<std::string, std::string>> g_qmlAttachedNotify;

static void loadQmlAttached(const std::string &mapPath) {
    auto slash = mapPath.find_last_of('/');
    std::string p = (slash == std::string::npos ? std::string() : mapPath.substr(0, slash + 1)) + "qmlattached.tsv";
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        std::vector<std::string> f5; size_t pos = 0;
        while (f5.size() < 5) {
            auto t = line.find('\t', pos);
            if (t == std::string::npos) { f5.push_back(line.substr(pos)); break; }
            f5.push_back(line.substr(pos, t - pos)); pos = t + 1;
        }
        if (f5.size() < 5) continue;
        while (!f5[4].empty() && (f5[4].back() == '\r' || f5[4].back() == '\n')) f5[4].pop_back();
        if (!f5[0].empty() && !f5[1].empty()) {
            g_qmlAttachedCxx[f5[0]][f5[1]] = f5[4];
            if (!f5[3].empty()) g_qmlAttachedNotify[f5[0]][f5[1]] = f5[3];
        }
    }
}

static void loadQmlUris(const std::string &mapPath) {
    auto slash = mapPath.find_last_of('/');
    std::string p = (slash == std::string::npos ? std::string() : mapPath.substr(0, slash + 1)) + "qmluris.tsv";
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        auto t = line.find('\t');
        if (t == std::string::npos) continue;
        std::string name = line.substr(0, t), uri = line.substr(t + 1);
        while (!uri.empty() && (uri.back() == '\r' || uri.back() == '\n')) uri.pop_back();
        if (!name.empty() && !uri.empty()) {
            g_qmlTypeUri.emplace(name, uri);
            auto &v = g_qmlTypeUris[name];
            if (std::find(v.begin(), v.end(), uri) == v.end()) v.push_back(uri);
        }
    }
}

// QML SINGLETONS and their methods: which names are singletons, the module and version their one
// instance is fetched with, and each method's parameter types. All of it published by the registry
// (`isSingleton`, the export string, the Method blocks) — nothing here is a list of known names.
static std::map<std::string, std::pair<std::string, std::pair<int, int>>> g_qmlSingletonUri;
// ...with EVERY overload, not one: Qt's Fusion declares buttonColor four times (one per optional
// argument), and keeping a single row meant a four-argument call was matched against a one-argument
// signature and refused. The call picks the overload whose parameter count it has.
static std::map<std::string,
                std::map<std::string,
                         std::vector<std::pair<std::string, std::vector<std::string>>>>>
    g_qmlMethods;
// C++ class -> QML name for every EXPORTED type, not just the ones we subclass. Without it a
// property typed by an unbound helper class could not be followed to its own properties.
static std::map<std::string, std::string> g_cxxQmlName;
static std::map<std::string, std::string> g_qmlCxxName;   // ...and the reverse
static void loadQmlCxxNames(const std::string &mapPath) {
    auto slash = mapPath.find_last_of('/');
    std::string p = (slash == std::string::npos ? std::string() : mapPath.substr(0, slash + 1))
                  + "qmlcxxnames.tsv";
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        auto t = line.find('\t');
        if (t == std::string::npos) continue;
        std::string cxx = line.substr(0, t), qml = line.substr(t + 1);
        while (!qml.empty() && (qml.back() == '\r' || qml.back() == '\n')) qml.pop_back();
        if (!cxx.empty() && !qml.empty()) {
            g_cxxQmlName.emplace(cxx, qml);
            // ...and the reverse, for a type exported ONLY for its enum: `StandardKey` is
            // QKeySequence, which has no object to read a member from, and the NUMBER behind the
            // key is what QML assigns. The C++ name is what the runtime needs to find the QMetaEnum.
            g_qmlCxxName.emplace(qml, cxx);
        }
    }
}

static void loadQmlSingletons(const std::string &mapPath) {
    auto slash = mapPath.find_last_of('/');
    std::string dir = slash == std::string::npos ? std::string() : mapPath.substr(0, slash + 1);
    {
        std::ifstream f(dir + "qmlsingletons.tsv");
        std::string line;
        while (std::getline(f, line)) {
            std::vector<std::string> c;
            for (size_t i = 0, j; i <= line.size(); i = j + 1) {
                j = line.find('\t', i);
                if (j == std::string::npos) j = line.size();
                c.push_back(line.substr(i, j - i));
                if (j == line.size()) break;
            }
            if (c.size() < 3) continue;
            while (!c[2].empty() && (c[2].back() == '\r' || c[2].back() == '\n')) c[2].pop_back();
            auto dot = c[2].find('.');
            if (dot == std::string::npos) continue;
            g_qmlSingletonUri[c[0]] = {c[1], {std::stoi(c[2].substr(0, dot)),
                                              std::stoi(c[2].substr(dot + 1))}};
        }
    }
    {
        std::ifstream f(dir + "qmlmethods.tsv");
        std::string line;
        while (std::getline(f, line)) {
            std::vector<std::string> c;
            for (size_t i = 0, j; i <= line.size(); i = j + 1) {
                j = line.find('\t', i);
                if (j == std::string::npos) j = line.size();
                c.push_back(line.substr(i, j - i));
                if (j == line.size()) break;
            }
            if (c.size() < 4) continue;
            while (!c[3].empty() && (c[3].back() == '\r' || c[3].back() == '\n')) c[3].pop_back();
            std::vector<std::string> ps;
            for (size_t i = 0, j; !c[3].empty() && i <= c[3].size(); i = j + 1) {
                j = c[3].find(',', i);
                if (j == std::string::npos) j = c[3].size();
                ps.push_back(c[3].substr(i, j - i));
                if (j == c[3].size()) break;
            }
            g_qmlMethods[c[0]][c[1]].push_back({c[2], ps});
        }
    }
}

static void loadQmlMap(const char *path) {
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        auto t1 = line.find('\t');
        auto t2 = line.find('\t', t1 + 1);
        if (t1 == std::string::npos || t2 == std::string::npos) continue;
        std::string qml = line.substr(0, t1);
        std::string cpp = line.substr(t1 + 1, t2 - t1 - 1);
        // A 4th column carries the QML module URI ("QtQuick.Templates"). Reading the module to
        // end-of-line swallowed it and emitted `import qt.controls.qquickbutton QtQuick.Templates;`.
        auto t3 = line.find('\t', t2 + 1);
        std::string mod = t3 == std::string::npos ? line.substr(t2 + 1)
                                                  : line.substr(t2 + 1, t3 - t2 - 1);
        // 5th column: the type's DEFAULT property, resolved up the prototype chain by the
        // generator. `data` for an Item, `flickableData` for a Flickable, `contentData` for a
        // Control -- the engine appends default children THERE, and each type's rule differs.
        if (t3 != std::string::npos) {
            auto t4 = line.find('\t', t3 + 1);
            {
                std::string u9 = t4 == std::string::npos ? line.substr(t3 + 1)
                                                        : line.substr(t3 + 1, t4 - t3 - 1);
                auto &v = g_qmlTypeUris[qml];
                if (std::find(v.begin(), v.end(), u9) == v.end()) v.push_back(u9);
            }
            g_qmlTypeUri[qml] = t4 == std::string::npos ? line.substr(t3 + 1)
                                                        : line.substr(t3 + 1, t4 - t3 - 1);
            if (t4 != std::string::npos) {
                std::string dp = line.substr(t4 + 1);
                while (!dp.empty() && (dp.back() == '\r' || dp.back() == '\n')) dp.pop_back();
                if (!dp.empty()) g_qmlDefaultProp[qml] = dp;
            }
        }
        // A QML name can export more than one C++ class across import versions (e.g. TextEdit ->
        // QQuickTextEdit and the legacy QQuickPre64TextEdit). `import QtQuick` (latest) resolves to
        // the modern one, so prefer a non-"Pre64" class when a name repeats.
        auto it = g_qmlMap.find(qml);
        if (it != g_qmlMap.end() && cpp.find("Pre64") != std::string::npos) continue;
        g_qmlMap[qml] = {cpp, mod};
    }
}

// Modules imported WITHOUT an alias, and names that ARRIVED qualified — both filled while the
// document's headers are read, and both needed here (see boundTypeFor).
static std::set<std::string> g_bareImports;
static std::string uriForType(const std::string &typeName) {
    if (auto it = g_qmlTypeUris.find(typeName); it != g_qmlTypeUris.end())
        for (auto &u : it->second)
            if (g_bareImports.count(u)) return u;
    auto it = g_qmlTypeUri.find(typeName);
    return it == g_qmlTypeUri.end() ? std::string() : it->second;
}
static std::set<std::string> g_qualifiedTypes;

// Empty D type = not a mapped bound type (a fresh @QObject / local type / unsupported).
static std::pair<std::string, std::string> boundTypeFor(const std::string &qmlType) {
    auto it = g_qmlMap.find(qmlType);
    if (it == g_qmlMap.end()) return {"", ""};
    // A module brought in only under an alias does NOT put its types in scope by bare name. Qt's
    // Controls files write `import QtQuick.Templates as T`, so a bare `DialogButtonBox` there is
    // the styled .qml next to the document — resolving it to the Templates type built an unstyled
    // control whose every padding and size read zero, silently. A name that arrived qualified is
    // exempt: typeName() strips the alias and records it, and that IS the imported type.
    auto u = g_qmlTypeUri.find(qmlType);
    if (u != g_qmlTypeUri.end() && !g_bareImports.count(u->second)
            && !g_qualifiedTypes.count(qmlType))
        return {"", ""};
    return it->second;
}

// dotted name of a UiQualifiedId (e.g. a handler id `onCountChanged`, or `a.b.c`).
static std::string qname(UiQualifiedId *id) {
    std::string s;
    for (auto *p = id; p; p = p->next) { if (!s.empty()) s += '.'; s += qs(p->name.toString()); }
    return s;
}

// Qt5's parser spells two things differently, and both are mechanical: a parameter's type is a
// UiQualifiedId (which has no toString(); qname walks it), and isDefaultMember is a data member
// rather than an accessor. Naming them here keeps the version check out of the walking code.
#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
static QString paramTypeName(UiParameterList *p) { return p->type->toString(); }
static bool isDefaultMem(UiPublicMember *p) { return p->isDefaultMember(); }
static bool isRequiredMem(UiPublicMember *p) { return p->isRequired(); }
#else
static QString paramTypeName(UiParameterList *p) { return QString::fromStdString(qname(p->type)); }
static bool isDefaultMem(UiPublicMember *p) { return p->isDefaultMember; }
static bool isRequiredMem(UiPublicMember *p) { return p->requiredToken.isValid(); }
#endif

// `import QtQuick.Templates as T` writes the root as `T.Button`. The qualifier names an IMPORT,
// not a scope of the type: the type is still `Button`. Stripped only when the prefix is a
// DECLARED alias, so a genuinely dotted name (`QtQuick.Item` style, or a grouped path) is left
// alone. Qt's own QtQuick.Controls are written this way — without this, all 69 of them fail at
// the root and nothing else in the file is even reached.
static std::set<std::string> g_importAliases;

// Names that appeared IMPORT-QUALIFIED (`T.CheckDelegate`). A qualified name names a type in
// that import's module and can never mean a .qml file sitting next to the document — but once
// the qualifier is stripped it looks exactly like a local type, and in Qt's own Controls the
// local file has the SAME name (Basic/CheckDelegate.qml alongside `T.CheckDelegate`). Resolving
// it locally gave the root no Qt base at all AND suppressed the diagnostic, because a resolved
// local path is what the "not a bound type" check tests for.

// The document's source text, so a diagnostic can quote the expression it refused. Reading a
// cluster of "expression not supported" was guesswork without it: matching a property name back
// to a line picks the FIRST occurrence, which is the root's, even when the failure is in a child.
static QString g_srcText;
// ...and the DOCUMENT's own text, which never changes while it is being compiled. A spliced local
// type puts its own file in g_srcText, and the members it splices come from TWO files: the type's
// and the use site's. An expression written at the use site has offsets into the document, so with
// only the local type's text in hand the range falls outside it and the snippet came out EMPTY --
// which is how six `text: control.model...` refusals in Qt's own header/table delegates ended up
// as `expression for 'string' []`, a diagnostic that does not say what it refused.
static QString g_rootSrcText;
// ...and every document ENCLOSING the one being spliced, innermost last. A local type can splice a
// local type (Qt's HorizontalHeaderView -> HorizontalHeaderViewDelegate -> Label), so the file an
// expression was written in may be neither the current one nor the outermost. This is the chain
// that was actually entered, not a guess at every file on disk -- which is the distinction that
// made an earlier "try them all" quote plausible nonsense.
static std::vector<QString> g_srcStack;

// Every document parsed so far, so a node from a local .qml is quoted from ITS file. One global
// text was wrong the moment a local type was loaded: the offsets belong to another document, and
// the bounds check blanked 78 of the snippets rather than quoting the wrong file.
// The source snippet an AST node came from, single-lined and clipped.
// "line:col" of a node in the document being compiled. The refusals need to be JOINABLE with what
// qmlcachegen's --dump-aot-stats reports per function (which is keyed by line and column), because
// the fallback decision is per EXPRESSION: we translate it, the AOT can compile it, or neither.
// A snippet alone cannot be matched up.
static std::string posOf(Node *n) {
    if (!n) return "";
    auto a = n->firstSourceLocation();
    if (!a.isValid()) return "";
    return std::to_string(a.startLine) + ":" + std::to_string(a.startColumn);
}

static std::string srcOf(Node *n) {
    if (!n) return "";
    auto a = n->firstSourceLocation(), b = n->lastSourceLocation();
    int from = (int)a.offset, to = (int)(b.offset + b.length);
    if (from < 0 || to <= from) return "";
    // Only the document currently being compiled. A "try every parsed file" fallback quoted the
    // WRONG one — the offsets are valid in several files at once, so the snippet came out as
    // plausible nonsense ("ocale.name"), which is worse than no snippet in a diagnostic that
    // exists to be read.
    // The document is the ONE fallback, not "every parsed file": that earlier attempt quoted a
    // plausible nonsense snippet ("ocale.name") because offsets are valid in several files at once.
    // The enclosing document is not an arbitrary candidate -- it is where a use-site expression
    // actually lives.
    const QString *src = nullptr;
    if (to <= g_srcText.size()) src = &g_srcText;
    else for (auto it = g_srcStack.rbegin(); it != g_srcStack.rend(); ++it)
        if (to <= it->size()) { src = &*it; break; }
    if (!src && to <= g_rootSrcText.size()) src = &g_rootSrcText;
    if (!src) return "";
    QString t = src->mid(from, to - from).simplified();
    if (t.size() > 90) t = t.left(87) + "...";
    return qs(t);
}

// The ENCLOSING object, as seen from inside a child. Qt's own Controls are written almost entirely
// in this shape — `id: control` on the root, then `contentItem: Text { color: control.palette.text
// }` — and a child is a separate D class, so it reaches its parent through a back-reference field
// (`__outer`) assigned at wire time. Saved/restored around compileObject like the rest.
static std::string g_outerId, g_outerClass, g_outerQmlType, g_selfClass;
static std::map<std::string, std::string> g_outerPropType, g_outerBaseProps;
static bool g_outerUsed = false;
// ...and the same for a CONTEXT name (`index`, `modelData`, a model role). The engine installs the
// per-item context AFTER the object is constructed, so a body that reads one has to wait exactly as
// a body that reads its enclosing object does -- same hook, same signal.
static bool g_ctxUsed = false;
// Properties the object declares as REQUIRED, and whether it declares any at all. The engine turns
// its per-item context injection OFF for a delegate that declares them -- measured: a delegate with
// `required property int index` answers EMPTY for `model["index"]`, where the same delegate without
// it answers the role. So what the context can be asked for depends on this.
static std::set<std::string> g_requiredDecls;
static bool g_hasRequiredDecl = false;
// True while compiling an object that is a property VALUE SOURCE (`NumberAnimation on v`).
static bool g_isValueSource = false;
// Compiling the body of a `delegate:`/Component property. The class is emitted like any other, but
// nobody CONSTRUCTS it here — the view does, N times — so it cannot be handed its enclosing object
// at construction and must find it once it is parented into the document's tree.
static bool g_isDelegate = false;
// The class currently being compiled AS a delegate body — context names resolve only there.
static std::string g_delegateCls;
// The class being compiled as an ENGINE-CREATED child: a registered QML type with no exported C++
// symbol, so it cannot be subclassed. The class holds the instance and writes it by name.
static std::string g_engineChildCls, g_engineChildType, g_engineChildUri;
// The CALLER will complete this object after it has assigned and parented it, which is the engine's
// order: create, set properties, put it in the tree, then complete the whole tree. An object that
// completes itself at the end of its own wire is complete BEFORE it has a parent — and a QQuickPopup
// resolves its `parent` in componentComplete from the QObject parent it does not have yet.
static bool g_parentCompletes = false;
// This document hands a view a Component, so the view INSERTS objects into a list the document
// also writes to — and where they land is the view's business, not the document's. Static
// `data[N]` labels are then a guess: Qt's Repeater puts its items BEFORE itself. The dump drops
// those labels rather than comparing a guessed index (the object PATHS keep them: there both sides
// resolve the same index through the same list, which is a real comparison).
static bool g_hasComponentBind = false;
// The chain of ENCLOSING objects, innermost first. `__outer` is always the IMMEDIATE parent, so an
// id further up is reached by hopping: `__outer.__outer.gap`. Without this the field was declared
// as the id-bearing ancestor's class while the value published was the immediate parent's — and
// since `cast(T) someVoidPtr` in D is an unchecked reinterpret, that read a different object's
// fields rather than failing. Qt's Controls nest two and three deep routinely.
struct OuterFrame { std::string id, cls, qmlType;
                    // EVERY id that object answers to — see g_selfIds.
                    std::set<std::string> ids;
                    std::map<std::string, std::string> propType, baseProps;
                    // What the DOCUMENT declares each property-bound child to be. The registry types
                    // `background` as QQuickItem* because that is the property's declared type, but
                    // the file says `background: Rectangle {}` — and Item has no `border` while
                    // Rectangle does. Following that hop by NAME instead is not an option: it also
                    // follows model roles, which is how TreeViewDelegate died on `display`.
                    std::map<std::string, std::string> childTypes;
                    // The ids of the enclosing object's CHILDREN — our siblings. QML resolves an
                    // id anywhere in its component, and Qt's Fusion SwitchIndicator reads the
                    // handle next to it (`handle.x + handle.width`) from the groove. Each is a
                    // FIELD of that object, so the hop is the ordinary one. (id -> field, type)
                    std::map<std::string, std::pair<std::string, std::string>> childIds; };
static std::vector<OuterFrame> g_outerChain;
static int g_outerHopsNeeded = -1;   // deepest hop this object used; drained by its parent
// Out-channel: a child that connects to `__outer.<prop>` needs that property to CARRY a notify,
// and only the parent's own emission can create the signal. The child records the name here and
// the parent drains it immediately after compileObject returns.
// (hops-still-to-travel, property). A child that connects to `__outer.__outer.gap` needs the
// GRANDparent to carry gapChanged, so each level drains what is addressed to it and forwards the
// rest one hop further up.
static std::vector<std::pair<int, std::string>> g_outerNeedsNotify;

// Reads made THROUGH an object-valued property (`control.indicator.width`): (object expression,
// inner property, member, the inner object's QML type). The object does not exist while the wire
// runs — a Control creates its indicator during completion — so the connect for these is deferred
// to the LATE phase, which the root triggers once the whole tree is complete. Drained by whichever
// binding compiled the expression.
struct DeepRead { std::string obj, inner, member, innerQmlType; };
static std::vector<DeepRead> g_deepReads;

// The QML module this document BELONGS to, read from the qmldir beside it. Qt's Controls style
// files are part of QtQuick.Controls.Basic, and a Control only gets its theme (hence its palette)
// once that module has been imported -- so the compiled document must ask for it, exactly as the
// engine does when it loads the file from that directory. Empty for an ordinary app document.
static std::string g_docModule;

static void loadDocModule(const char *inPath) {
    QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
    QFile f(dir + "/qmldir");
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return;
    for (const QByteArray &ln : f.readAll().split('\n')) {
        QByteArray t = ln.trimmed();
        if (t.startsWith("module ")) { g_docModule = t.mid(7).trimmed().toStdString(); return; }
    }
}

// The document's ROOT class. Only the root triggers the late pass — it is the only object whose
// wire finishes with the whole tree constructed and completed.
static std::string g_rootClass;

// The QML type name backing a C++ class ("QQuickItem" -> "Item"), so the inner object's own
// property table can type the member.
// Is this the name of a type the registry knows? The registry publishes some types under their
// QML name and some under their C++ class (`Text` is QQuickText), so a check against one table
// alone answers "no" for a type that is perfectly well known — and an enum literal like
// `Text.ElideRight` was refused as an unknown type rather than compiled to its key.
static bool knownTypeName(const std::string &n);
static std::string qmlNameOfCxx(const std::string &cxx) {
    std::string bare = cxx;
    while (!bare.empty() && (bare.back() == '*' || bare.back() == ' ')) bare.pop_back();
    for (auto &kv : g_qmlMap) if (kv.second.first == bare) return kv.first;
    return "";
}

// The `__outer.` prefix that reaches the enclosing object whose id is `name`, and the frame it
// found. Returns false when no enclosing level declares that id.
// Splits a dependency tagged by collectIds ("__outer.__outer.gap") into the object expression and
// the member, and finds the frame it names.
static bool splitOuterDep(const std::string &d, std::string &obj, std::string &mem,
                          const OuterFrame **frame) {
    size_t k = 0, pos = 0;
    while (d.compare(pos, 8, "__outer.") == 0) { ++k; pos += 8; }
    if (k == 0 || k > g_outerChain.size()) return false;
    obj = d.substr(0, pos - 1);          // "__outer.__outer"
    mem = d.substr(pos);
    *frame = &g_outerChain[k - 1];
    return true;
}

// The FILE a class is being compiled from, as a URL. The engine gives every component a context
// whose baseUrl is its document, and that is what a relative URL inside it resolves against — a
// compiled `source: "icon.png"` with no baseUrl resolves against the process's working directory
// instead, which is a different file or none. Saved and restored exactly where g_srcText is,
// because an inlined child comes from ITS OWN document and the engine gives it that one.
static std::string g_docUrl;
// The document being COMPILED, as opposed to the file a local type was read from. Measured against
// the engine: Qt's Dialog instantiates the Basic `Label.qml` as its header, and the engine reports
// that object's context baseUrl as Dialog.qml — the instantiating document — not Label.qml. So a
// relative url inside a local type resolves against the file that USES it.
static std::string g_rootDocUrl;

// One hop of an OBJECT path: is `owner.prop` an object, and of what type? The registry types a
// property by its C++ name, and an object-valued one ends in `*`. It also keys some types by QML
// name and some by C++ class, so the answer is whichever spelling it actually holds — otherwise
// the NEXT hop cannot be typed and the path stops one segment short.
static bool objPropQml(const std::string &owner, const std::string &prop, std::string &outQml);
// A whole object path of any depth (`background.border`, `control.searchIndicator.indicator`),
// resolved to the expression that fetches it and the QML type it has.
static bool objPathExpr(ExpressionNode *x, std::string &oe, std::string &oq);

static bool knownTypeName(const std::string &n) {
    if (g_qmlCxxType.count(n)) return true;
    auto bm = g_qmlMap.find(n);
    return bm != g_qmlMap.end() && g_qmlCxxType.count(bm->second.first);
}

static bool outerHop(const std::string &name, std::string &prefix, const OuterFrame **frame) {
    // An id in the CURRENT scope shadows an enclosing one — every call site here consults the
    // chain first, so an object whose own id collides with an enclosing object's resolved to the
    // wrong one. Qt's own controls collide constantly: Dialog.qml's root is `id: control` and so
    // is the root of the DialogButtonBox.qml it instantiates as its footer, and `control.count`
    // inside the footer means the FOOTER's count. (Deeper frames still resolve by hops, and the
    // walk returns the nearest match, so a child of the footer naming `control` still gets it.)
    if (isSelfId(name)) return false;
    for (size_t k = 0; k < g_outerChain.size(); ++k)
        if (g_outerChain[k].ids.count(name)) {
            prefix.clear();
            for (size_t i = 0; i <= k; ++i) prefix += "__outer.";
            *frame = &g_outerChain[k];
            g_outerUsed = true;
            if ((int)k > g_outerHopsNeeded) g_outerHopsNeeded = (int)k;
            return true;
        }
    return false;
}

static std::string typeName(UiQualifiedId *id) {
    std::string n = qname(id);
    auto dot = n.find('.');
    if (dot != std::string::npos && g_importAliases.count(n.substr(0, dot))) {
        std::string bare = n.substr(dot + 1);
        g_qualifiedTypes.insert(bare);
        return bare;
    }
    return n;
}

// Records `as X` aliases from a document's import headers, and the modules imported WITHOUT one.
// A module brought in only under an alias does not put its types in scope by bare name: Qt's own
// Controls files write `import QtQuick.Templates as T`, so a bare `DialogButtonBox` in Dialog.qml
// is the STYLED local file next to it, never the Templates type. Resolving the bare name to the
// bound Templates type built an unstyled control -- Dialog's footer came out with every padding,
// size and offset at zero against a fully built engine one, and no diagnostic said a word.
static void collectImportAliases(UiProgram *program) {
    for (auto *h = program ? program->headers : nullptr; h; h = h->next)
        if (auto *imp = cast<UiImport *>(h->headerItem)) {
            std::string a = qs(imp->importId.toString());
            if (!a.empty()) g_importAliases.insert(a);
            else if (imp->importUri) g_bareImports.insert(qname(imp->importUri));
        }
}

// ---- app-defined D QML types ------------------------------------------------------------------
// A QML type does not have to come from C++: `@QObject` + qmlRegisterType!T exports a D class as a
// QML element, and the engine sees a meta-object either way. So qmltc-d can compile a .qml rooted
// in a D type — and that case is SIMPLER than the bound-Qt one: plain D inheritance, no C++
// trampoline, no `mixin QtdWidget!Base`, and an inherited @Property is a real D field (direct
// read/write, no meta round-trip).
//
// The registry is the type's own `.qmltypes` — Qt's format, emitted from the D type by CTFE
// (qmlTypeComponent!T) and validated by Qt's own reader. It is itself a QML document, so it is
// parsed with the SAME QQmlJS frontend this tool already uses; no new format, no new parser.
struct DType {
    std::string dClass;                                   // the D (or bound C++) class name
    std::string dModule;                                  // D module declaring it
    bool bound = false;                                   // true: a C++ type reached through the
                                                          // binding (subclass via the trampoline
                                                          // mixin, base props through the meta-
                                                          // object); false: a D class we inherit.
    std::map<std::string, std::string> propType;          // property -> D type (int/string/double/bool)
    std::map<std::string, std::string> propNotify;        // property -> its notify signal
    // property -> its RESET method. `prop: undefined` in QML means "reset", which is a call, not
    // a value: without the resetter there is nothing to emit and the assignment must be refused.
    std::map<std::string, std::string> propReset;
    // Signal name -> its full C++ signature ("dSignal(QString,int)"). A NOTIFY signal does not
    // have to be a parameterless `<prop>Changed`: connecting it needs the real signature, and the
    // registry is the only place that has it.
    std::map<std::string, std::string> signalSig;
    // Properties the registry DECLARES but whose type we do not compile against (QJSValue,
    // QVariant, a gadget, ...). Knowing the name is not enough: falling back to guessing the type
    // from the assigned literal produces a WRONG value silently — `jsvalue: true` on a QJSValue
    // property is not a bool. Assigning or reading one is PARTIAL.
    std::set<std::string> propUnsupported;
    // QML_EXTENDED: the class whose members the engine grafts onto this type. We don't build that
    // object, so those members (and only those) are unusable — see the fold-in below.
    std::string extensionClass;
    std::string attachedClass;                            // registry `attachedType:` (QML_ATTACHED)
    std::string prototype;                                // registry `prototype:` (the base class)
    // Object-valued properties: `Q_PROPERTY(TestTypeGrouped *group ...)`. QML addresses their
    // members with dotted syntax (`group.count: 42`) — a GROUPED property. Maps property -> the
    // C++ class of the group, so its members can be typed from that class's own registry entry.
    std::map<std::string, std::string> groupClass;
    // Value-type ("gadget") groups: `Q_PROPERTY(ValueTypeGroup vt ...)` with isPointer false.
    // name -> the gadget Component's name, whose own Property entries type its members.
    std::map<std::string, std::string> valueGroupClass;
};
static std::map<std::string, DType> g_dTypes;             // QML element name -> registered type
static std::string g_qmlUri;                             // the module those types are registered under

// C++ type spellings as they appear in a .qmltypes -> the D type qmltc-d compiles against.
static const char *dtypeOfCxx(const std::string &t) {
    if (t == "int") return "int";
    if (t == "QString") return "string";
    if (t == "double" || t == "float" || t == "qreal") return "double";
    if (t == "bool") return "bool";
    return "";
}

// `Property { name: "x"; type: "int"; notify: "xChanged" }` -> the string bound to `key`.
static std::string qmltypesField(UiObjectInitializer *init, const char *key) {
    for (auto *m = init ? init->members : nullptr; m; m = m->next)
        if (auto *sb = cast<UiScriptBinding *>(m->member))
            if (qname(sb->qualifiedId) == key)
                if (auto *es = cast<ExpressionStatement *>(sb->statement)) {
                    if (auto *sl = cast<StringLiteral *>(es->expression)) return qs(sl->value.toString());
                    // Not every field is a string: `isPointer: true` is a boolean literal, and it
                    // is the one that distinguishes a QObject*-valued GROUP from a value type.
                    if (cast<TrueLiteral *>(es->expression)) return "true";
                    if (cast<FalseLiteral *>(es->expression)) return "false";
                }
    return "";
}

// Parse a `.qmltypes` registry: Module { Component { name; exports: ["Uri/Name 1.0"]; Property {…} } }.
// The QML element name comes from `exports` (what a .qml actually writes); `name` is the class.
// `bound` selects the backend: false -> the type is a D class and we inherit it directly;
// true -> it is a C++ type bound by the generator, so the generated class subclasses it through
// the trampoline mixin and reads/writes base properties through the meta-object. `dScope` is the
// D module (bound=false, all types share one) or the D PACKAGE (bound=true, one module per class,
// named after it in lower case — the generator's modBase rule).
static bool loadDTypes(const char *path, const char *dScope, bool bound) {
    QFile f(QString::fromUtf8(path));
    if (!f.open(QIODevice::ReadOnly)) { std::fprintf(stderr, "qmltc-d: cannot open %s\n", path); return false; }
    auto *engine = new Engine();                       // leaked: the AST must outlive this call
    g_astEngine = engine;   // ...and its pool, for the nodes a script binding is rewritten into
    auto *lexer = new Lexer(engine);
    lexer->setCode(QString::fromUtf8(f.readAll()), 1, /*qmlMode*/ true);
    auto *parser = new Parser(engine);
    if (!parser->parse()) { std::fprintf(stderr, "qmltc-d: %s is not a parseable .qmltypes\n", path); return false; }
    auto *program = cast<UiProgram *>(parser->ast());
    collectImportAliases(program);   // `import ... as T` -> `T.Button` is `Button`
    auto *mod = program && program->members ? cast<UiObjectDefinition *>(program->members->member) : nullptr;
    if (!mod) { std::fprintf(stderr, "qmltc-d: %s has no Module block\n", path); return false; }
    for (auto *m = mod->initializer ? mod->initializer->members : nullptr; m; m = m->next) {
        auto *comp = cast<UiObjectDefinition *>(m->member);
        if (!comp || typeName(comp->qualifiedTypeNameId) != "Component") continue;
        DType dt;
        std::string uri;
        dt.bound = bound;
        dt.dClass = qmltypesField(comp->initializer, "name");
        dt.prototype = qmltypesField(comp->initializer, "prototype");
        dt.extensionClass = qmltypesField(comp->initializer, "extension");
        dt.attachedClass = qmltypesField(comp->initializer, "attachedType");
        std::string qmlName = dt.dClass;               // fallback if `exports` is absent
        for (auto *c = comp->initializer ? comp->initializer->members : nullptr; c; c = c->next) {
            // exports: ["AppTypes/Backend 1.0"] -> the element name a .qml writes is `Backend`.
            if (auto *sb = cast<UiScriptBinding *>(c->member); sb && qname(sb->qualifiedId) == "exports") {
                if (auto *es = cast<ExpressionStatement *>(sb->statement))
                    if (auto *arr = cast<ArrayPattern *>(es->expression))
                        if (arr->elements && arr->elements->element)
                            if (auto *sl = cast<StringLiteral *>(arr->elements->element->initializer)) {
                                std::string e = qs(sl->value.toString());
                                auto slash = e.find('/'), space = e.find(' ');
                                if (slash != std::string::npos) {
                                    qmlName = e.substr(slash + 1, (space == std::string::npos ? e.size() : space) - slash - 1);
                                    uri = e.substr(0, slash);   // the module these types live in
                                }
                            }
                continue;
            }
            auto *sub = cast<UiObjectDefinition *>(c->member);
            if (!sub) continue;
            if (typeName(sub->qualifiedTypeNameId) == "Signal") {
                std::string sn = qmltypesField(sub->initializer, "name");
                std::string ps;
                for (auto *pm = sub->initializer ? sub->initializer->members : nullptr; pm; pm = pm->next)
                    if (auto *par = cast<UiObjectDefinition *>(pm->member);
                            par && typeName(par->qualifiedTypeNameId) == "Parameter") {
                        std::string pt = qmltypesField(par->initializer, "type");
                        if (!pt.empty()) ps += (ps.empty() ? "" : ",") + pt;
                    }
                if (!sn.empty()) dt.signalSig[sn] = sn + "(" + ps + ")";
                continue;
            }
            if (typeName(sub->qualifiedTypeNameId) != "Property") continue;
            std::string pn = qmltypesField(sub->initializer, "name");
            const char *pd = dtypeOfCxx(qmltypesField(sub->initializer, "type"));
            if (pn.empty()) continue;
            if (!pd[0]) {
                // A non-scalar property naming another type in this registry is a GROUP
                // (`Q_PROPERTY(TestTypeGrouped *group ...)`), addressed as `group.member` in QML.
                // Whether that type is really present is settled below, once every Component is
                // read; anything left over is an unsupported scalar.
                // A GROUP is a property holding another QOBJECT — `isPointer` is what says so.
                // A value type (`Q_PROPERTY(ValueTypeGroup vt ...)`) also names another Component,
                // but there is no object behind it: reaching for one yields null, and writing
                // through that null is a crash, not a wrong value.
                auto raw = qmltypesField(sub->initializer, "type");
                bool ptr = qmltypesField(sub->initializer, "isPointer") == "true";
                if (ptr && !raw.empty() && raw != "QObject") { dt.groupClass[pn] = raw; continue; }
                // NOT a pointer: a value type. Its members are reachable, but only through
                // read-modify-write on the value — there is no object to write into.
                if (!ptr && !raw.empty() && raw != "QObject") { dt.valueGroupClass[pn] = raw; continue; }
                dt.propUnsupported.insert(pn); continue;   // declared, but not a type we compile
            }
            dt.propType[pn] = pd;
            std::string note = qmltypesField(sub->initializer, "notify");
            if (!note.empty()) dt.propNotify[pn] = note;
            std::string rst = qmltypesField(sub->initializer, "reset");
            if (!rst.empty()) dt.propReset[pn] = rst;
        }
        if (dt.dClass.empty()) continue;
        if (g_qmlUri.empty() && !uri.empty()) g_qmlUri = uri;
        std::string low = dt.dClass;
        for (auto &ch : low) ch = (char)std::tolower((unsigned char)ch);
        dt.dModule = bound ? (std::string(dScope) + "." + low) : dScope;
        g_dTypes[qmlName] = dt;
    }
    std::map<std::string, DType *> byClass;
    for (auto &kv : g_dTypes) byClass[kv.second.dClass] = &kv.second;
    // A registry Component lists only the type's OWN members; the engine's object also has its
    // base's. Fold the prototype chain in so a base property is typed from the registry instead of
    // falling through to literal inference.
    for (auto &kv : g_dTypes)
        for (std::string proto = kv.second.prototype; !proto.empty();) {
            auto it = byClass.find(proto);
            if (it == byClass.end()) break;
            for (auto &p : it->second->propType)   kv.second.propType.emplace(p.first, p.second);
            for (auto &p : it->second->propNotify) kv.second.propNotify.emplace(p.first, p.second);
            for (auto &p : it->second->propReset)  kv.second.propReset.emplace(p.first, p.second);
            for (auto &p : it->second->signalSig)  kv.second.signalSig.emplace(p.first, p.second);
            for (auto &p : it->second->groupClass) kv.second.groupClass.emplace(p.first, p.second);
            for (auto &p : it->second->valueGroupClass) kv.second.valueGroupClass.emplace(p.first, p.second);
            for (auto &p : it->second->propUnsupported) kv.second.propUnsupported.insert(p);
            proto = it->second->prototype;
        }
    // QML_EXTENDED grafts ANOTHER object's members onto the type. We don't build that object, so
    // the type is still usable — only its EXTENSION members are not. Marking them unsupported (by
    // name, from the extension's own Component) turns any use into an honest PARTIAL, instead of
    // refusing every .qml rooted in such a type even when it never touches the extension. The
    // extension is inherited down the prototype chain, same as anything else.
    for (auto &kv : g_dTypes) {
        std::vector<std::string> exts;
        if (!kv.second.extensionClass.empty()) exts.push_back(kv.second.extensionClass);
        for (std::string proto = kv.second.prototype; !proto.empty();) {
            auto it = byClass.find(proto);
            if (it == byClass.end()) break;
            if (!it->second->extensionClass.empty()) exts.push_back(it->second->extensionClass);
            proto = it->second->prototype;
        }
        for (auto &e : exts) {
            auto it = byClass.find(e);
            if (it == byClass.end()) continue;
            for (auto &p : it->second->propType) kv.second.propUnsupported.insert(p.first);
            for (auto &p : it->second->propUnsupported) kv.second.propUnsupported.insert(p);
        }
    }
    // A candidate group whose class isn't in the registry can't have its members typed, so it is
    // not a group we can compile — demote it to "declared with an unsupported type".
    for (auto &kv : g_dTypes) {
        for (auto it = kv.second.valueGroupClass.begin(); it != kv.second.valueGroupClass.end();) {
            if (byClass.count(it->second)) { ++it; continue; }
            kv.second.propUnsupported.insert(it->first);
            it = kv.second.valueGroupClass.erase(it);
        }
        for (auto it = kv.second.groupClass.begin(); it != kv.second.groupClass.end();) {
            if (byClass.count(it->second)) { ++it; continue; }
            kv.second.propUnsupported.insert(it->first);
            it = kv.second.groupClass.erase(it);
        }
    }
    return true;
}

// Empty dClass = not an app-defined D type.
static const DType *dTypeFor(const std::string &qmlType) {
    auto it = g_dTypes.find(qmlType);
    return it != g_dTypes.end() ? &it->second : nullptr;
}

// QML accesses an enum member via the TYPE name and flattens members into the type scope
// (`TypeName.Green`), while D keeps them under the enum. g_enumMember maps a member name to its D
// enum name, and g_className is the current type name, so `TypeName.Green` -> `Color.Green` (int).
static std::map<std::string, std::string> g_enumMember;
static std::string g_className;

// The translation CONTEXT QML uses for `qsTr` in this document: the .qml file's base name. Set
// once in main so a compiled `qsTr` resolves against the same context the engine would.
static std::string g_trContext;

// Base C++ properties this object sets/reads (name -> dtype). A reference to one in an expression
// reads it through the meta-object (propInt/propStr(this, name)), as it has no D field.
static std::map<std::string, std::string> g_baseProps;

// True when the base is an app-defined D type rather than a bound C++ one. Then a base property
// is a real D field on the superclass: read and written DIRECTLY by name, with no meta-object
// round-trip. (The value DUMP still goes through the meta-object — that is deliberate: it is the
// same observation path the engine-side oracle uses.)
static bool g_baseIsD;

// Base property -> its RESET method, for `prop: undefined`.
static std::map<std::string, std::string> g_baseReset;

// The base type's GROUPED properties for the object being compiled: group name -> that group
// class's whole registry entry, so its member types, NOTIFY names and signal signatures are all
// reachable. Empty unless the base declares object-valued properties.
struct DType;
static std::map<std::string, const DType *> g_groups;
// Value-type groups in scope (see DType::valueGroupClass).
static std::map<std::string, const DType *> g_vgroups;

// QML types (by element name) whose ATTACHED object this document addresses — `TestType.count`.
// Maps the element name to the registry entry of its attached class, whose members type the
// accesses. The attached object itself is fetched at runtime by name, so nothing is hard-coded.
static std::map<std::string, const DType *> g_attached;

// QML singletons declared in a sibling `.qml` (`pragma Singleton`). A singleton is ONE instance
// per document, reached through a lazy accessor — `SingletonThing.integerProperty` reads off it.
static std::set<std::string> g_singletons;

// Properties that a function REASSIGNS at runtime — with `Qt.binding(...)` (install a new
// binding) or with a plain value (which, in QML, REMOVES the binding). Such a property gets a
// selector so the declarative recompute can stand down. Collected before anything is emitted.
static std::set<std::string> g_rebound;
// Of those, the ones that actually GOT a selector — i.e. that carry a declarative binding for the
// selector to stand down from. A literal-initialised property is just assigned; emitting a
// selector write for it would reference a field that was never declared.
static std::set<std::string> g_hasSelector;
// Imperative bindings found: property -> [(slot index, expression, deps)].
struct ReBind { int idx; std::string expr; std::vector<std::string> deps; };
static std::map<std::string, std::vector<ReBind>> g_rebinds;

// A `pragma Singleton` type is only USABLE if a qmldir declares it — that is how QML resolves the
// name, and a document using an undeclared one does not load at all.
static bool singletonDeclaredInQmldir(const QString &dir, const std::string &name) {
    QFile f(dir + "/qmldir");
    if (!f.open(QIODevice::ReadOnly)) return false;
    for (const auto &line : QString::fromUtf8(f.readAll()).split(u'\n')) {
        auto t = line.trimmed();
        if (!t.startsWith(QLatin1String("singleton "))) continue;
        auto parts = t.split(u' ', Qt::SkipEmptyParts);
        if (parts.size() >= 2 && parts[1] == QString::fromStdString(name)) return true;
    }
    return false;
}

// D type of each in-scope name (declared property, base property, function param, local). Lets
// compileExpr decide COERCIONS — notably JS `+` string concatenation, where QML converts the
// non-string side and D's `~` does not. Maintained alongside g_scope.
static std::map<std::string, std::string> g_propType;

// `property list<int> nums: [3, 1, 4]` — a list of a VALUE type. Unlike list<QtObject>, whose
// elements are separate objects the engine reaches through a QQmlListReference, these live in the
// property itself. They are held as a plain D array field, NOT an @Property: qtmoc's cppSig maps
// only scalars, so exposing one to the meta-object would need a D-slice <-> QList<T> marshalling
// layer in the runtime. Bindings that READ the list (`nums.length`, `nums[0]`) therefore work and
// are compared; the list property itself is not yet dumped. name -> D element type.
static std::map<std::string, std::string> g_valueLists;

// A signal handler, from either of the two spellings QML allows: an inline `onPing: <stmt>` (stmt
// set), or a `function onPing(n) { ... }` inside a Connections element (fn set). Both end up
// connected the same way; `sender` is the D expression for the object whose signal is connected,
// empty meaning `this`.
// A binding's value is CONVERTED to the property's declared type by QML — `property int inner:
// width - pad` on an Item is a double expression truncated into an int. D refuses that narrowing
// implicitly, so the cast is emitted. Only for numeric targets: a string or a value type must not
// be forced this way, and would be a compile error rather than a silent wrong value.
static std::string coerceTo(const std::string &dtype, const std::string &expr) {
    if (dtype == "int" || dtype == "double" || dtype == "float")
        return "cast(" + dtype + ") (" + expr + ")";
    return expr;
}

struct RawHandler { std::string sig; Statement *stmt; FunctionDeclaration *fn; std::string sender; };

// A CHILD object's `id`, so the parent's bindings can read `<id>.<prop>`. The child is compiled
// after the bindings that use it, so its id and declared property types are pre-scanned: `field`
// is the D field holding it, `propType` its declared properties.
static const char *dtypeOf(const QString &qmlType);   // defined below; used by the pre-scan
struct ChildRef {
    std::string field;
    // The child's own QML type, so a path THROUGH it (`searchIndicator.indicator.visible`) can be
    // typed hop by hop instead of stopping at the first member.
    std::string qmlType;
    std::map<std::string, std::string> propType;
    // Members contributed by the child's BOUND type rather than by its .qml declarations. They are
    // not D fields, so a binding reads them through the meta-object; reading them as fields would
    // compile to `kid.checked`, which does not exist on the generated class.
    std::map<std::string, std::string> baseProps;
    std::map<std::string, std::string> baseNotify;   // member -> full notify signature
    // The child's declared signals (name -> parameters) and its no-arg functions, so a parent can
    // connect to `<id>`'s signals and call `<id>.method()`.
    std::map<std::string, std::vector<std::pair<std::string, std::string>>> signalParams;
    std::set<std::string> methods0;
};
static std::map<std::string, ChildRef> g_childIds;
// property name -> type the DOCUMENT declares for the object bound to it (see OuterFrame::childTypes)
static std::map<std::string, std::string> g_childDeclType;

// Properties a PARENT binding depends on, per child id. The child decides which of its properties
// get a change signal, but only the parent knows it reads them — so the requirement is recorded
// here while the parent's bindings compile, and consulted when the child is compiled.
static std::map<std::string, std::set<std::string>> g_forceNotify;

// Collect `id:` and declared property types of every child object bound to a named property, so
// `<id>.<prop>` resolves in this object's bindings.
// Records one child's id, declared property types and BOUND-type members, under `field`.
static void prescanChildBody(UiObjectInitializer *ci, const std::string &field,
                             UiQualifiedId *typeId) {
    std::string cid, ctypeResolved;
    std::map<std::string, std::string> pts, bps, bns;
    {
        std::string ctype = typeId ? typeName(typeId) : std::string();
        // The registry keys some types by their QML name and some by their C++ class (`Text` is
        // published as QQuickText). A lookup by the document's spelling alone therefore came back
        // EMPTY for those, and every `<id>.<prop>` read on such a child was refused — silently, as
        // "expression not supported". qmlmap knows both names; ask it for the other one.
        if (!g_qmlProps.count(ctype))
            if (auto bm = g_qmlMap.find(ctype); bm != g_qmlMap.end() && g_qmlProps.count(bm->second.first))
                ctype = bm->second.first;
        if (auto qp = g_qmlProps.find(ctype); qp != g_qmlProps.end())
            for (auto &pp : qp->second) bps[pp.first] = pp.second;
        if (auto qn2 = g_qmlNotify.find(ctype); qn2 != g_qmlNotify.end())
            for (auto &pp : qn2->second) bns[pp.first] = pp.second;
            ctypeResolved = ctype;
    }
    std::map<std::string, std::vector<std::pair<std::string, std::string>>> sigs;
    std::set<std::string> meths;
    for (auto *cm = ci->members; cm; cm = cm->next) {
        if (auto *sb = cast<UiScriptBinding *>(cm->member)) {
            if (qname(sb->qualifiedId) != "id") continue;
            if (auto *es = cast<ExpressionStatement *>(sb->statement))
                if (auto *idn = cast<IdentifierExpression *>(es->expression))
                    cid = qs(idn->name.toString());
            continue;
        }
        if (auto *cp = cast<UiPublicMember *>(cm->member);
                cp && cp->type == UiPublicMember::Property && cp->memberType) {
            // typeName(), not `->name`: a QUALIFIED declared type (`property T.AbstractButton
            // control`, which is how Qt's own Fusion indicators declare theirs) is a UiQualifiedId
            // whose `name` is only its FIRST segment — the alias. Reading that alone typed the
            // property as "T" and every path through it stopped there.
            const std::string mt = typeName(cp->memberType);
            const char *dt = dtypeOf(QString::fromStdString(mt));
            if (dt[0]) pts[qs(cp->name.toString())] = dt;
            else if (!boundTypeFor(mt).first.empty())
                pts[qs(cp->name.toString())] = "@" + mt;   // see above
            continue;
        }
        if (auto *cp = cast<UiPublicMember *>(cm->member);
                cp && cp->type == UiPublicMember::Signal) {
            std::vector<std::pair<std::string, std::string>> ps;
            bool ok = true;
            for (auto *pp = cp->parameters; pp; pp = pp->next) {
                const char *dt = pp->type ? dtypeOf(paramTypeName(pp)) : "";
                if (!dt[0]) { ok = false; break; }
                ps.push_back({qs(pp->name.toString()), dt});
            }
            if (ok) sigs[qs(cp->name.toString())] = ps;
            continue;
        }
        if (auto *se = cast<UiSourceElement *>(cm->member))
            if (auto *fd = cast<FunctionDeclaration *>(se->sourceElement))
                if (!fd->formals) meths.insert(qs(fd->name.toString()));
    }
    if (!cid.empty()) g_childIds[cid] = {field, ctypeResolved, pts, bps, bns, sigs, meths};
}

static void prescanChildIds(UiObjectInitializer *init) {
    // A DEFAULT child (`Text { id: placeholder }` written bare) is a child with an id like any
    // other, and Qt's own controls read one constantly: TextField sizes itself from
    // `placeholder.implicitHeight`. Only property-bound children were pre-scanned, so every such
    // read was refused — and the refusal left implicitWidth/implicitHeight at 0 where the engine
    // computes 200x40. Counted the same way the compiler names them (`_dc<n>`, source order, only
    // bare object definitions) so the field the pre-scan promises is the field that gets emitted.
    int dcn = 0;
    for (auto *m = init ? init->members : nullptr; m; m = m->next) {
        auto *pub = cast<UiPublicMember *>(m->member);
        UiObjectInitializer *ci = nullptr;
        std::string field, cid, ctypeResolved;
        if (auto *dod = cast<UiObjectDefinition *>(m->member)) {
            ci = dod->initializer;
            field = "_dc" + std::to_string(dcn++);
            if (!ci) continue;
            prescanChildBody(ci, field, dod->qualifiedTypeNameId);
            continue;
        }
        // `background: Rectangle {}` — a property bound to an object, written as a plain member
        // rather than a `property` declaration. Nothing else here records it, so the FILE's word on
        // what `background` is was lost and `background.border` fell back to the property's declared
        // type (QQuickItem, which has no border). Record-only: the child itself is compiled
        // elsewhere, this just remembers its type for the path resolver.
        if (auto *tob = cast<UiObjectBinding *>(m->member); tob && tob->qualifiedTypeNameId) {
            std::string fn = qname(tob->qualifiedId);
            if (!fn.empty() && fn.find('.') == std::string::npos)
                g_childDeclType[fn] = typeName(tob->qualifiedTypeNameId);
        }
        if (!pub || pub->type != UiPublicMember::Property || !pub->binding) continue;
        std::string declTy;
        if (auto *ob = cast<UiObjectBinding *>(pub->binding)) {
            ci = ob->initializer;
            if (ob->qualifiedTypeNameId) declTy = typeName(ob->qualifiedTypeNameId);
        } else if (auto *od = cast<UiObjectDefinition *>(pub->binding)) {
            ci = od->initializer;
            if (od->qualifiedTypeNameId) declTy = typeName(od->qualifiedTypeNameId);
        }
        if (!ci) continue;
        field = qs(pub->name.toString());
        if (!declTy.empty()) g_childDeclType[field] = declTy;
        std::map<std::string, std::string> pts, bps, bns;
        // Seed from the child's bound type (its own properties), then let QML-declared ones win.
        {
            std::string ctype;
            if (auto *ob2 = cast<UiObjectBinding *>(pub->binding); ob2 && ob2->qualifiedTypeNameId)
                ctype = typeName(ob2->qualifiedTypeNameId);
            else if (auto *od2 = cast<UiObjectDefinition *>(pub->binding); od2 && od2->qualifiedTypeNameId)
                ctype = typeName(od2->qualifiedTypeNameId);
            if (auto qp = g_qmlProps.find(ctype); qp != g_qmlProps.end())
                for (auto &pp : qp->second) bps[pp.first] = pp.second;
            if (auto qn2 = g_qmlNotify.find(ctype); qn2 != g_qmlNotify.end())
                for (auto &pp : qn2->second) bns[pp.first] = pp.second;
                ctypeResolved = ctype;
        }
        std::map<std::string, std::vector<std::pair<std::string, std::string>>> sigs;
        std::set<std::string> meths;
        for (auto *cm = ci->members; cm; cm = cm->next) {
            if (auto *sb = cast<UiScriptBinding *>(cm->member)) {
                if (qname(sb->qualifiedId) != "id") continue;
                if (auto *es = cast<ExpressionStatement *>(sb->statement))
                    if (auto *idn = cast<IdentifierExpression *>(es->expression))
                        cid = qs(idn->name.toString());
                continue;
            }
            if (auto *cp = cast<UiPublicMember *>(cm->member);
                    cp && cp->type == UiPublicMember::Property && cp->memberType) {
                const std::string mt = typeName(cp->memberType);   // qualified: see above
                const char *dt = dtypeOf(QString::fromStdString(mt));
                if (dt[0]) pts[qs(cp->name.toString())] = dt;
                // ...and a declared OBJECT property keeps its QML TYPE, so a path THROUGH it can be
                // typed: Qt's Fusion writes `indicator.control.checkState`, where `control` is the
                // CheckIndicator's own `property Item control`. Marked with `@` and recorded as the
                // QML type name — the vocabulary the registry uses — since it has no D type.
                else if (!boundTypeFor(mt).first.empty())
                    pts[qs(cp->name.toString())] = "@" + mt;
                continue;
            }
            if (auto *cp = cast<UiPublicMember *>(cm->member);
                    cp && cp->type == UiPublicMember::Signal) {
                std::vector<std::pair<std::string, std::string>> ps;
                bool ok = true;
                for (auto *pp = cp->parameters; pp; pp = pp->next) {
                    const char *dt = pp->type ? dtypeOf(paramTypeName(pp)) : "";
                    if (!dt[0]) { ok = false; break; }
                    ps.push_back({qs(pp->name.toString()), dt});
                }
                if (ok) sigs[qs(cp->name.toString())] = ps;
                continue;
            }
            if (auto *se = cast<UiSourceElement *>(cm->member))
                if (auto *fd = cast<FunctionDeclaration *>(se->sourceElement))
                    if (!fd->formals) meths.insert(qs(fd->name.toString()));
        }
        if (!cid.empty()) g_childIds[cid] = {field, ctypeResolved, pts, bps, bns, sigs, meths};
    }
}

// `Connections { target: X; function onSig(a) { ... } }` is WIRING, not an object to build, so it
// is desugared into ordinary handlers and reuses the connect machinery. Returns false when the
// element uses a shape not handled yet (a target other than the enclosing object, or a member that
// is not an on<Signal> function) — the caller reports that rather than wiring something wrong.
// `Component { ... }` is a TEMPLATE, not an object: the engine instantiates nothing until
// something asks (Loader.sourceComponent, createObject). Compiling it like an ordinary child
// builds its contents eagerly, which is a different program — and silently, since the
// differential only checks that everything the ENGINE has is covered, never that we built
// something extra. Refused until it can be compiled as a factory.
static bool isComponentType(const std::string &t) { return t == "Component"; }

static bool connectionsHandlers(UiObjectInitializer *init, std::vector<RawHandler> &out) {
    std::vector<RawHandler> found;
    std::string sender;          // "" = this
    const ChildRef *targetChild = nullptr;
    for (auto *cm = init ? init->members : nullptr; cm; cm = cm->next) {
        if (auto *sb = cast<UiScriptBinding *>(cm->member)) {
            if (qname(sb->qualifiedId) != "target") return false;
            auto *es = cast<ExpressionStatement *>(sb->statement);
            auto *idexp = es ? cast<IdentifierExpression *>(es->expression) : nullptr;
            if (!idexp) return false;
            std::string tid = qs(idexp->name.toString());
            if (isSelfId(tid)) continue;      // target: this object
            // target: a CHILD's id — connect to the child's signal instead. This is the shape
            // Connections is actually used in; the enclosing object would just use `onSig:`.
            auto ci = g_childIds.find(tid);
            if (ci == g_childIds.end()) return false;
            sender = ci->second.field;
            targetChild = &ci->second;
            continue;
        }
        auto *se = cast<UiSourceElement *>(cm->member);
        auto *fd = se ? cast<FunctionDeclaration *>(se->sourceElement) : nullptr;
        if (!fd) return false;
        std::string hn = qs(fd->name.toString());
        if (hn.size() <= 2 || hn[0] != 'o' || hn[1] != 'n' || !std::isupper((unsigned char)hn[2])) return false;
        std::string sig = hn.substr(2);
        sig[0] = (char)std::tolower((unsigned char)sig[0]);
        found.push_back({sig, nullptr, fd, ""});
    }
    // `target:` may appear after the handlers, so the sender is applied once the whole element is
    // read. A signal the target does not declare is an error, not a connection to nothing.
    for (auto &h : found) {
        h.sender = sender;
        if (targetChild && !targetChild->signalParams.count(h.sig)) return false;
    }
    for (auto &h : found) out.push_back(h);
    return true;
}

// Aliases resolved for use INSIDE expressions: name -> how to read the target from `this`, and
// the target's own name so a binding through the alias depends on the TARGET (whose reactivity
// already exists). Only targets reachable without the child objects — self, base, group — are
// pre-resolved here, because children are compiled after the bindings that might use them.
static std::map<std::string, std::string> g_aliasRead;
static std::map<std::string, std::string> g_aliasDep;
// Writing THROUGH an alias: (target object expression, target property). `alias: value` in QML
// assigns the target, it does not shadow it.
static std::map<std::string, std::pair<std::string, std::string>> g_aliasWrite;

// Every bare name that RESOLVES in the generated D class: declared properties, base C++
// properties, `function` names, declared signals, plus (pushed while a body compiles) the
// enclosing function's params and `var` locals. An identifier outside it is something QML
// resolves and we do NOT — a Repeater delegate's `index`, a context property, an attached
// property — and emitting it as a bare name would produce D that does not compile. So an
// out-of-scope identifier is a compile FAILURE (-> PARTIAL), never a silent wrong emission.
// Scoped per object, saved/restored across compileObject recursion like the other maps.
static std::set<std::string> g_scope;
// (declared above; defined here beside the scope it belongs to)
// EVERY id this object answers to. A local `.qml` type spliced at a use site has TWO: the
// definition's (`id: control` in Qt's Menu.qml) and the use site's (`id: menu` in the context menu
// that instantiates it). They name the SAME object, and taking only the last one made the same
// document compile standalone and refuse `control.contentModel` when spliced.
static std::set<std::string> g_selfIds;
// ...and the subset that came from a spliced local type's DEFINITION rather than from the use site.
// The two halves of a merged object have two id scopes and the same name can mean different objects
// in them: Qt's `Menu.qml` binds `model: control.contentModel` (control = the Menu) and the document
// that uses it writes `ContextMenu.menu: TextEditingContextMenu { editor: control }` (control = the
// TextField). QML has no conflict there because the two bindings live in two components; merging the
// bodies into one class merges the scopes, so the DEFINITION's ids are taken out of scope for the
// length of a use-site binding — exactly as the local type's declared PROPERTIES already are.
static std::set<std::string> g_selfIdsDefn;
static bool shadowedByLocalType(const std::string &n);
bool isSelfId(const std::string &n) {
    return !n.empty() && g_selfIds.count(n) > 0 && !shadowedByLocalType(n);
}
// The property of the ENCLOSING object that holds the object being compiled, when it is a
// property-bound child. Empty for a default child or a root.
static std::string g_selfBoundProp;

// `Easing.OutCubic`, `Font.DemiBold` — an ENUM MEMBER whose TYPE the registry does not carry.
// `Easing` and `Font` are value-type namespaces: QtQuick registers the enums, not a type with
// properties, so knownTypeName says no and every enum-typed member of a value group was refused.
// Accepting the KEY here is safe because the write is checked: setVgroup/setQmlProp resolve the
// member through the gadget's own meta-object and THROW when the key does not convert, so a wrong
// guess is loud rather than silent. Deliberately not offered to the general expression compiler,
// where a name that is not a type has other meanings.
static std::string enumMemberKeyLoose(ExpressionNode *x) {
    auto *fme = cast<FieldMemberExpression *>(x);
    if (!fme) return "";
    std::string tn, mem = qs(fme->name.toString());
    if (auto *fmq = cast<FieldMemberExpression *>(fme->base)) {          // Alias.Type.Key
        auto *b2 = cast<IdentifierExpression *>(fmq->base);
        if (!b2 || !g_importAliases.count(qs(b2->name.toString()))) return "";
        tn = qs(fmq->name.toString());
    } else if (auto *tb = cast<IdentifierExpression *>(fme->base)) {     // Type.Key
        tn = qs(tb->name.toString());
    } else return "";
    if (tn.empty() || !std::isupper((unsigned char) tn[0])) return "";
    if (mem.empty() || !std::isupper((unsigned char) mem[0])) return "";
    if (g_scope.count(tn) || g_childIds.count(tn) || g_singletons.count(tn)
            || g_vgroups.count(tn)) return "";
    // ...but NOT on a singleton: `Easing` is a real QML singleton (the QML module exports it), so
    // `Easing.InOutCubic` is a property read with a value, and reading it is better than guessing
    // its key. The caller tries that channel first; this is the fallback for a namespace that is
    // not exported at all.
    return mem;
}


// True when `n` names a property of the object's BOUND type (so it lives in the meta-object)
// rather than a property the document declares (a plain D field).
// True when a QML type is an Item — it has QQuickItem's `parent` property. A DEFAULT child of an
// Item is a VISUAL child in QML, and QQuickItem tracks that through parentItem, not through the
// QObject parent: setQtParent alone leaves parentItem null, and an item with no parentItem is not
// in a scene, so writing `visible = true` on it silently does not take (probed directly: set
// false then true and it stays false). Anchors, layout and `parent` reads depend on the same link.
static bool isItemType(const std::string &qmlType) {
    if (auto qc = g_qmlCxxType.find(qmlType); qc != g_qmlCxxType.end()) return qc->second.count("parent") > 0;
    return false;
}

// Same question asked about an explicit type, for the dump's linkage checks (which run outside
// any object's compile scope).
// Resolves a plain property-READ expression to (object expression, group, member). An empty
// object means it is not a plain read and cannot be copied. Shared by the base-property path and
// the object-group path so both agree on what "a read" is.
static void resolveReadSrc(ExpressionNode *e, std::string &obj, std::string &grp, std::string &prp) {
    obj.clear(); grp.clear(); prp.clear();
    auto resolveObj = [&](IdentifierExpression *b) -> std::string {
        std::string bn = qs(b->name.toString()), pre;
        const OuterFrame *fr = nullptr;
        if (outerHop(bn, pre, &fr)) return pre.substr(0, pre.size() - 1);
        if (auto ci = g_childIds.find(bn); ci != g_childIds.end()) return ci->second.field;
        if (isSelfId(bn)) return "this";
        return "";
    };
    auto *fmv = cast<FieldMemberExpression *>(e);
    if (!fmv) return;
    if (auto *b0 = cast<IdentifierExpression *>(fmv->base)) {
        obj = resolveObj(b0);
        if (!obj.empty()) prp = qs(fmv->name.toString());
    } else if (auto *fmb = cast<FieldMemberExpression *>(fmv->base)) {
        if (auto *b1 = cast<IdentifierExpression *>(fmb->base)) {
            obj = resolveObj(b1);
            if (!obj.empty()) { grp = qs(fmb->name.toString()); prp = qs(fmv->name.toString()); }
        }
    }
}

static bool isBoundObjectProp2(const std::string &qmlType, const std::string &n) {
    if (auto qc = g_qmlCxxType.find(qmlType); qc != g_qmlCxxType.end()) return qc->second.count(n) > 0;
    return false;
}

// True when a declared property's type NAMES a QML object type rather than a value/scalar one.
// `QtObject` is not in the bound map (nothing wraps it) and is still an object; anything the
// registry lists is one by construction.
static bool isQmlObjectType(const std::string &t) {
    // A LIST is not one — `default property list<QtObject> items` keeps `list` in the parser's
    // typeModifier and `QtObject` as the member type, so the caller checks that, not this name.
    return t == "QtObject" || t == "QObject" || g_qmlMap.count(t) > 0 || g_qmlCxxType.count(t) > 0;
}
static bool isBoundObjectProp(const std::string &n) {
    if (g_propType.count(n) || g_scope.count(n)) return false;
    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) return qc->second.count(n) > 0;
    return false;
}

// Widens g_scope for the duration of one body compile (a function's params, a handler's signal
// args, `var` locals declared inside), then restores the object-level scope.
struct ScopeGuard {
    std::set<std::string> saved;
    std::map<std::string, std::string> savedTypes;
    ScopeGuard();
    ~ScopeGuard();
};
inline ScopeGuard::ScopeGuard() : saved(g_scope), savedTypes(g_propType) {}
inline ScopeGuard::~ScopeGuard() { g_scope = saved; g_propType = savedTypes; }

// Declared QML signals of this object, so a call `ping()` emits (`ping.emit()`) and a handler
// `onPing` connects to it. g_signalParams holds each signal's (paramName, dtype) list, for typed
// signals and their handler slots. Scoped per object.
static std::set<std::string> g_signals;
static std::map<std::string, std::vector<std::pair<std::string, std::string>>> g_signalParams;

// D scalar type -> the C++ meta type our qtmoc runtime uses in a signal/slot signature.
static std::string cppTypeOf(const std::string &dtype) {
    if (dtype == "string") return "QString";
    return dtype;   // int/double/bool map through unchanged
}

// QML declared type -> D type. Only the scalar literal types Phase 1 emits; anything else
// returns "" so the caller reports it as unsupported rather than guessing.
static const char *dtypeOf(const QString &qmlType) {
    // QML's `color` is a QColor. The meta-object takes it by type name (the moc is generic), so a
    // declared `property color c` is a real QColor field rather than a stringly-typed stand-in.
    if (qmlType == "color")  return "QColor";
    if (qmlType == "int")    return "int";
    if (qmlType == "bool")   return "bool";
    if (qmlType == "string") return "string";
    if (qmlType == "real" || qmlType == "double") return "double";
    return "";
}

// A QML string literal as a D double-quoted literal (escape the few chars that would break it).
static std::string dstr(const QString &v) {
    std::string s = "\"";
    for (QChar c : v) {
        if (c == '"' || c == '\\') s += '\\';
        if (c == '\n') { s += "\\n"; continue; }
        s += qs(QString(c));
    }
    return s + "\"";
}
static std::string dnum(double v, bool isInt, bool neg) {
    char buf[64];
    if (isInt) { std::snprintf(buf, sizeof buf, "%s%lld", neg ? "-" : "", (long long)v); return buf; }
    std::snprintf(buf, sizeof buf, "%s%g", neg ? "-" : "", v);
    std::string s = buf;
    // A double literal MUST keep a decimal point, else D reads it as an int and `13 / 2` becomes
    // integer division (6) instead of QML/JS number division (6.5). %g drops a trailing ".0".
    if (s.find('.') == std::string::npos && s.find('e') == std::string::npos
        && s.find("inf") == std::string::npos && s.find("nan") == std::string::npos)
        s += ".0";
    return s;
}

// If `st` is a pure LITERAL (no identifiers), render it as a D literal into `out`. Only these can
// become a D field INITIALIZER (D field inits must be compile-time constants). Anything with an
// identifier/operator is a binding -> compileExpr + a constructor assignment (Phase 2).
static bool literalOf(Statement *st, const QString &dtype, std::string &out) {
    auto *es = cast<ExpressionStatement *>(st);
    if (!es || !es->expression) return false;
    ExpressionNode *e = es->expression;
    bool neg = false;
    if (auto *u = cast<UnaryMinusExpression *>(e)) { neg = true; e = u->expression; }
    if (auto *num = cast<NumericLiteral *>(e)) { out = dnum(num->value, dtype == "int", neg); return true; }
    if (neg) return false;
    if (auto *str = cast<StringLiteral *>(e)) {
        // A colour literal stays a STRING here. It is written through the meta-object, and
        // QMetaType converts it to the property's declared QColor — calling QColor.fromString
        // would be doing by hand what the type system already does, and it drags the binding's
        // QColor module into every document that mentions a colour.
        out = dstr(str->value.toString());
        return true;
    }
    if (cast<TrueLiteral *>(e))  { out = "true";  return true; }
    if (cast<FalseLiteral *>(e)) { out = "false"; return true; }
    return false;
}

// PHASE 2/3 seed: compile a QML binding expression into a D expression. Handles property/id
// references (as bare names), literals, unary minus, parenthesised groups, and the binary
// operators +,-,*,/ (with `+` -> `~` when the target property is a string, i.e. concatenation).
// `dtype` is the target D type, used to pick the operator and format numeric literals. Returns
// false on anything outside this subset (calls, member access, comparisons, ...) -> the caller
// falls back to PARTIAL, so an uncompilable binding is reported and skipped, never mis-emitted.
static std::string inferType(ExpressionNode *e, const std::map<std::string, std::string> &ptype);
static ExpressionNode *findReturnExpr(StatementList *body);

// The ONE place that turns a property NAME into the D expression that reads it:
//   - a property of this object, a param or a local -> the plain name (a D field/variable);
//   - a BASE property with a D base -> also a plain name (inherited @Property IS a field);
//   - a BASE property with a bound C++ base -> a meta-object read.
// Anything else resolves to nothing the generated class defines, so it is a compile failure
// (PARTIAL), never a bare name emitted on faith.
// A member path may be written through the object's own id: `root.group.str` means the same as
// `group.str`. Returns the group name when `e` is that (or a bare identifier naming a group).
static std::string groupNameOf(ExpressionNode *e) {
    if (auto *id = cast<IdentifierExpression *>(e))
        return g_groups.count(qs(id->name.toString())) ? qs(id->name.toString()) : "";
    if (auto *fm = cast<FieldMemberExpression *>(e))
        if (auto *b = cast<IdentifierExpression *>(fm->base);
                b && isSelfId(qs(b->name.toString()))
                && g_groups.count(qs(fm->name.toString())))
            return qs(fm->name.toString());
    return "";
}

// Same, for a VALUE group. Separate from groupNameOf because the two compile differently.
static std::string valueGroupNameOf(ExpressionNode *e) {
    if (auto *id = cast<IdentifierExpression *>(e))
        return g_vgroups.count(qs(id->name.toString())) ? qs(id->name.toString()) : "";
    if (auto *fm = cast<FieldMemberExpression *>(e))
        if (auto *b = cast<IdentifierExpression *>(fm->base);
                b && isSelfId(qs(b->name.toString()))
                && g_vgroups.count(qs(fm->name.toString())))
            return qs(fm->name.toString());
    return "";
}

// `TestType` or `root.TestType` -> the element name whose attached object is meant.
static std::string attachedNameOf(ExpressionNode *e) {
    if (auto *id = cast<IdentifierExpression *>(e))
        return g_attached.count(qs(id->name.toString())) ? qs(id->name.toString()) : "";
    if (auto *fm = cast<FieldMemberExpression *>(e))
        if (auto *b = cast<IdentifierExpression *>(fm->base);
                b && isSelfId(qs(b->name.toString()))
                && g_attached.count(qs(fm->name.toString())))
            return qs(fm->name.toString());
    return "";
}
// Reaching an attached object goes through Qt's QML type REGISTRY, and a module's registration is
// lazy — nothing materialises it without an engine importing the module. A compiled document has
// no engine, so it must call the module's own registration function itself. qmltyperegistrar
// generates it as `qml_register_types_<uri>`; note this is only needed for attached properties,
// everything else reaches its type directly.
static bool g_needsModuleRegistration;
// True while compiling a root whose members were merged in from a local `.qml` base type.
static bool g_localMerged;
// The attached object of a GIVEN object, not always of `this`: Qt's ComboBox sizes its popup from
// `control.Window.height`, where the window is attached to the enclosing CONTROL. Attaching to the
// popup instead would read a different object (or none), so the target is passed in.
static std::string attachedExprOn(const std::string &target, const std::string &typeName);
static std::string attachedExpr(const std::string &typeName) {
    // A type from a BOUND module carries its own URI (Overlay lives in QtQuick.Templates); only a
    // type this document itself registers falls back to the document's uri — and only that case
    // needs the generated module registration.
    if (auto it = g_qmlTypeUri.find(typeName); it != g_qmlTypeUri.end())
        return "attachedObj(this, \"" + it->second + "\", \"" + typeName + "\")";
    g_needsModuleRegistration = true;
    return "attachedObj(this, \"" + g_qmlUri + "\", \"" + typeName + "\")";
}
static std::string attachedExprOn(const std::string &target, const std::string &typeName) {
    if (auto it = g_qmlTypeUri.find(typeName); it != g_qmlTypeUri.end())
        return "attachedObj(" + target + ", \"" + it->second + "\", \"" + typeName + "\")";
    g_needsModuleRegistration = true;
    return "attachedObj(" + target + ", \"" + g_qmlUri + "\", \"" + typeName + "\")";
}

// `x: undefined` in QML RESETS the property — it calls the RESET method, it does not assign a
// value. Emits that call for `prop` on `obj`, or returns false when the property has no resetter
// (in which case assigning undefined is not something we can reproduce).
static bool isUndefined(ExpressionNode *e) {
    auto *id = cast<IdentifierExpression *>(e);
    return id && qs(id->name.toString()) == "undefined";
}
static bool resetCall(const std::string &obj, const std::string &prop, std::string &out) {
    auto r = g_baseReset.find(prop);
    if (r == g_baseReset.end()) return false;
    out = "        resetProp(" + obj + ", \"" + prop + "\");\n";
    return true;
}

// While a USE-SITE binding is being compiled, these declared properties of the merged class do NOT
// shadow the enclosing document — the binding was written where they are not in scope.
static std::set<std::string> g_useSiteShadowed;
static bool shadowedByLocalType(const std::string &n) { return g_useSiteShadowed.count(n) > 0; }

static bool readName(const std::string &n, std::string &out) {
    if (g_metaTextProps.count(n)) { out = "propStr(this, \"" + n + "\")"; return true; }
    if (shadowedByLocalType(n)) return false;   // resolve it in the enclosing scope instead
    if (auto a = g_aliasRead.find(n); a != g_aliasRead.end()) { out = a->second; return true; }
    auto bp = g_baseProps.find(n);
    if (bp != g_baseProps.end()) {
        if (g_baseIsD) { out = n; return true; }
        const char *rd = bp->second == "string" ? "propStr(this, \"" : bp->second == "double" ? "propDouble(this, \""
                       : bp->second == "bool" ? "propBool(this, \"" : "propInt(this, \"";
        out = rd + n + "\")"; return true;
    }
    if (g_valueLists.count(n)) { out = n; return true; }
    // A base property that this document only READS is not in g_baseProps — that map records what
    // the document ASSIGNS. But the property table knows the type, so the read is perfectly
    // routable through the meta-object, exactly like an assigned one. Without this,
    // `implicitWidth: Math.max(implicitContentWidth + leftPadding, ...)` — the single most common
    // shape in Qt's own Controls — failed on its operands, not on Math.
    if (!g_scope.count(n)) {
        if (auto qp = g_qmlProps.find(g_selfQmlType); qp != g_qmlProps.end()) {
            auto pt = qp->second.find(n);
            if (pt != qp->second.end()) {
                const std::string &ty = pt->second;
                if (ty == "string" || ty == "double" || ty == "bool" || ty == "int") {
                    if (g_baseIsD) { out = n; return true; }
                    const char *rd = ty == "string" ? "propStr(this, \"" : ty == "double" ? "propDouble(this, \""
                                   : ty == "bool" ? "propBool(this, \"" : "propInt(this, \"";
                    out = rd + n + "\")"; return true;
                }
            }
        }
        // ...and a bare name that belongs to an ENCLOSING object. Qt's ScrollBar writes
        // `color: pressed ? control.palette.dark : control.palette.mid` inside its contentItem: the
        // contentItem is a Rectangle and `pressed` is the ScrollBar's. QML resolves it up the scope
        // chain; without this the name did not compile, which failed the whole expression and left
        // the colour at the type default.
        {
            std::string pre;
            for (size_t k = 0; k < g_outerChain.size(); ++k) {
                pre += "__outer.";
                const std::string &oq = g_outerChain[k].qmlType;
                auto qp2 = g_qmlProps.find(oq);
                if (qp2 == g_qmlProps.end()) continue;
                auto pt2 = qp2->second.find(n);
                if (pt2 == qp2->second.end()) continue;
                const std::string &ty2 = pt2->second;
                if (ty2 != "string" && ty2 != "double" && ty2 != "bool" && ty2 != "int") continue;
                g_outerUsed = true;
                if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
                const char *rd2 = ty2 == "string" ? "propStr(" : ty2 == "double" ? "propDouble("
                               : ty2 == "bool" ? "propBool(" : "propInt(";
                out = rd2 + pre.substr(0, pre.size() - 1) + ", \"" + n + "\")";
                return true;
            }
        }
        return false;
    }
    out = n; return true;
}

static bool objPropQml(const std::string &owner, const std::string &prop, std::string &outQml) {
    std::string own = owner;
    // A DECLARED object property of a type this document itself defines: `indicator.control.
    // checkState` in Qt's Fusion, where `control` is CheckIndicator's own `property Item control`.
    // No registry knows about it — the document does, and the compiler records it under the same
    // QML type name the walk is already carrying.
    if (auto d2 = g_declObjProps.find(owner); d2 != g_declObjProps.end())
        if (auto p2 = d2->second.find(prop); p2 != d2->second.end()) { outQml = p2->second; return true; }
    if (!g_qmlCxxType.count(own))
        if (auto bm = g_qmlMap.find(own); bm != g_qmlMap.end()) own = bm->second.first;
    auto it = g_qmlCxxType.find(own);
    if (it == g_qmlCxxType.end()) return false;
    auto pit = it->second.find(prop);
    if (pit == it->second.end()) return false;
    std::string cxx = pit->second;
    while (!cxx.empty() && cxx.back() == ' ') cxx.pop_back();
    if (cxx.empty() || cxx.back() != '*') return false;   // must be an OBJECT
    cxx.pop_back();
    while (!cxx.empty() && cxx.back() == ' ') cxx.pop_back();
    std::string qn = qmlNameOfCxx(cxx);
    // qmlmap only names the types we SUBCLASS; the registry files an unbound helper's rows under
    // its QML name all the same (QQuickPalette's are under `Palette`), so ask the full table too.
    if (qn.empty() || !g_qmlCxxType.count(qn))
        if (auto it2 = g_cxxQmlName.find(cxx); it2 != g_cxxQmlName.end()) qn = it2->second;
    outQml = (!qn.empty() && g_qmlCxxType.count(qn)) ? qn : cxx;
    return true;
}
// The same walk, driven by the dotted TEXT of a dependency instead of by the AST: the wiring
// records deps as strings, and a path read has to be re-resolved there to know WHICH object
// carries the notify. `searchIndicator` itself never changes — `implicitIndicatorHeight` on it
// does — so connecting to the head is connecting to nothing.
static bool objPathFromString(const std::string &dotted, std::string &objExpr, std::string &leafSig);
static bool objPathExpr(ExpressionNode *x, std::string &oe, std::string &oq) {
    // `(contentItem as ListView).width` — parentheses and a type assertion wrap the object without
    // changing it, so the walk continues through both. Not unwrapping them stopped the path at the
    // first hop, which is why compiling `as` alone was not enough.
    if (auto *ne = cast<NestedExpression *>(x)) return objPathExpr(ne->expression, oe, oq);
    if (auto *ba = cast<BinaryExpression *>(x); ba && ba->op == QSOperator::As) {
        if (!objPathExpr(ba->left, oe, oq)) return false;
        // ...and the ASSERTED type retypes the walk, which is what `as` is for: `contentItem` is
        // declared QQuickItem* and Item has no `contentWidth`, so without this the walk stops one
        // hop short. The right side parses as an IDENTIFIER, not a TypeExpression — reading it as
        // the latter is why the first attempt at this changed nothing.
        if (auto *tid = cast<IdentifierExpression *>(ba->right)) {
            std::string tn = qs(tid->name.toString());
            if (g_qmlProps.count(tn) || g_qmlCxxType.count(tn)) oq = tn;
        }
        return true;
    }
    if (auto *id = cast<IdentifierExpression *>(x)) {
        std::string n2 = qs(id->name.toString());
        // A GROUP name is allowed here: the group IS an object property of this object, and the
        // registry types it like any other. (A VALUE group is not an object and has its own path.)
        // ...unless we are compiling a USE-SITE binding, where the merged class's own declarations are
    // not in scope (see shadowedByLocalType): `control: control` must reach the enclosing object.
        // A DECLARED object property of THIS object is in scope and is STILL a path head: Qt's
        // Fusion writes the bare form (`control.palette.base`, where `control` is this object's own
        // `property Item control`). The guard below stops a SCALAR name from being walked through;
        // an object one is what a path needs. (objPathHead has the same rule — this walker keeps its
        // own copy of the resolution, which is why fixing only the other one changed nothing.)
        if (auto pt0 = g_propType.find(n2); pt0 != g_propType.end() && pt0->second.size() > 1
                && pt0->second[0] == '@' && !shadowedByLocalType(n2)) {
            oe = dIdent(n2); oq = pt0->second.substr(1); return true;
        }
    if ((g_scope.count(n2) && !shadowedByLocalType(n2)) || g_vgroups.count(n2)) return false;
        if (isSelfId(n2)) { oe = "this"; oq = g_selfQmlType; return true; }
        if (auto ci2 = g_childIds.find(n2); ci2 != g_childIds.end()) {
            if (ci2->second.qmlType.empty()) return false;
            oe = ci2->second.field; oq = ci2->second.qmlType; return true;
        }
        std::string pre2; const OuterFrame *fr2 = nullptr;
        if (outerHop(n2, pre2, &fr2)) { oe = pre2.substr(0, pre2.size() - 1); oq = fr2->qmlType; return true; }
        if (objPropQml(g_selfQmlType, n2, oq)) { oe = "propObj(this, \"" + n2 + "\")"; return true; }
        // ...or an unqualified name that resolves up the SCOPE chain: inside Qt's SearchField the
        // indicator reads `background`, which is the enclosing control's property, not its own.
        std::string pre3;
        for (size_t k = 0; k < g_outerChain.size(); ++k) {
            pre3 += "__outer.";
            if (objPropQml(g_outerChain[k].qmlType, n2, oq)) {
                if (auto d1 = g_outerChain[k].childTypes.find(n2);
                        d1 != g_outerChain[k].childTypes.end() && g_qmlCxxType.count(d1->second))
                    oq = d1->second;   // what the FILE declares, not what the property's type says
                g_outerUsed = true;
                if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
                oe = "propObj(" + pre3.substr(0, pre3.size() - 1) + ", \"" + n2 + "\")";
                return true;
            }
        }
        // ...and LAST, a SIBLING's id — a child of an enclosing object. QML resolves an id
        // anywhere in its component; here it is a plain field of that object, reached by the same
        // hop. Last so that nothing which already resolved changes: a name is only looked up here
        // once every property lookup has failed.
        {
            std::string preS;
            for (size_t k = 0; k < g_outerChain.size(); ++k) {
                preS += "__outer.";
                auto sc = g_outerChain[k].childIds.find(n2);
                if (sc == g_outerChain[k].childIds.end() || sc->second.second.empty()) continue;
                g_outerUsed = true;
                if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
                oe = preS + sc->second.first; oq = sc->second.second;
                return true;
            }
        }
        return false;
    }
    if (auto *f2 = cast<FieldMemberExpression *>(x)) {
        // `parent.parent` — `parent` is the enclosing object here (Qt sets the visual parent AFTER
        // construction, so it resolves to the back-reference, not to propObj(this,"parent")), and
        // its parent is one level further out. Reading it through the meta-object would read null
        // at wire time, which is exactly what the `parent` special case exists to avoid.
        if (auto *bp = cast<IdentifierExpression *>(f2->base);
                bp && qs(bp->name.toString()) == "parent"
                && qs(f2->name.toString()) == "parent"
                && !g_scope.count("parent") && !g_childIds.count("parent")
                && g_outerChain.size() >= 2) {
            g_outerUsed = true;
            if (g_outerHopsNeeded < 1) g_outerHopsNeeded = 1;
            oe = "__outer.__outer"; oq = g_outerChain[1].qmlType;
            return true;
        }
        std::string be, bq;
        if (!objPathExpr(f2->base, be, bq)) return false;
        std::string mem2 = qs(f2->name.toString());
        if (!objPropQml(bq, mem2, oq)) return false;
        oe = "propObj(" + be + ", \"" + mem2 + "\")";
        return true;
    }
    return false;
}

// A dep spelled `__outer.…` whose remainder still has a dot is a PATH, not a member of the
// enclosing object: `__outer.searchIndicator.indicator`. The __outer branch would split it as the
// compound member "searchIndicator.indicator", find no notify under that name and report — 20
// phantom diagnostics — while the path branch resolves it. Let the path branch have it.
// A script binding is a BLOCK, not an expression: Qt's controls write
// `color: { if (c) return a; else return b }` — 18 of them in the Basic corpus, 12 on border.color.
// Rewritten here into the equivalent conditional EXPRESSION, so every path that already compiles an
// expression handles it with no change. Nodes come from the parser's own pool (kept alive because
// the AST is deliberately leaked); constructing them any other way is not possible.
static ExpressionNode *blockToExpr(Statement *st) {
    auto *blk = cast<Block *>(st);
    if (!blk || !blk->statements || !g_astEngine) return nullptr;
    // Also the guard-clause form Qt uses: `if (c) return A;` followed by `return B;` — an if with
    // NO else and a trailing return, possibly several of them. Folded right-to-left into the same
    // nested ternary, so the two shapes share one path.
    if (blk->statements->next) {
        std::vector<std::pair<ExpressionNode *, ExpressionNode *>> guards;
        ExpressionNode *tail = nullptr;
        for (auto *it = blk->statements; it; it = it->next) {
            if (auto *r = cast<ReturnStatement *>(it->statement)) {
                if (it->next || !r->expression) return nullptr;   // a return must be LAST
                tail = r->expression;
                break;
            }
            auto *iff = cast<IfStatement *>(it->statement);
            if (!iff || iff->ko || !iff->expression) return nullptr;
            auto *r2 = cast<ReturnStatement *>(iff->ok);
            if (!r2 || !r2->expression) return nullptr;
            guards.push_back({iff->expression, r2->expression});
        }
        if (!tail || guards.empty()) return nullptr;
        for (auto g = guards.rbegin(); g != guards.rend(); ++g)
            tail = new (g_astEngine->pool()) ConditionalExpression(g->first, g->second, tail);
        return tail;
    }
    // `StatementList::statement` is a Node*, not a Statement* — the casts below narrow it.
    std::function<ExpressionNode *(Node *)> conv = [&](Node *x) -> ExpressionNode * {
        if (auto *r = cast<ReturnStatement *>(x)) return r->expression;
        if (auto *b2 = cast<Block *>(x))
            return (b2->statements && !b2->statements->next) ? conv(b2->statements->statement) : nullptr;
        auto *iff = cast<IfStatement *>(x);
        if (!iff || !iff->ko) return nullptr;      // no else: the value would be undefined
        ExpressionNode *a = conv(iff->ok), *b = conv(iff->ko);
        if (!a || !b || !iff->expression) return nullptr;
        return new (g_astEngine->pool()) ConditionalExpression(iff->expression, a, b);
    };
    return conv(blk->statements->statement);
}

// `Qt.styleHints.<group>.<leaf>` — the types under the QML global are not exported to QML, so no
// table can name their notify. connectNotify resolves it through the META-OBJECT at runtime, which
// is exactly what this needs and needs nothing else.
static bool styleHintsDep(const std::string &d, std::string &objExpr, std::string &leaf) {
    if (d.rfind("Qt.styleHints.", 0) != 0) return false;
    std::string rest = d.substr(std::strlen("Qt.styleHints."));
    auto dot = rest.rfind('.');
    if (dot == std::string::npos) { objExpr = "styleHintsObj()"; leaf = rest; return true; }
    objExpr = "styleHintsObj()";
    size_t i = 0;
    while (i < dot) {
        auto j = rest.find('.', i);
        objExpr = "propObj(" + objExpr + ", \"" + rest.substr(i, j - i) + "\")";
        i = j + 1;
    }
    leaf = rest.substr(dot + 1);
    return true;
}

// `__outer[.__outer].<AttachedType>.<member>` — Qt's ComboBox sizes its popup from
// `control.Window.height`, and the ATTACHED object belongs to the enclosing control. The read side
// already resolves this (attachedExprOn); the dependency side did not, so the binding was reported
// as unwireable. connectNotify finds the member's notify through the meta-object, so no table of
// attached notifies is needed here either.
static bool attachedOuterDep(const std::string &d, std::string &objExpr, std::string &leaf) {
    std::vector<std::string> parts;
    for (size_t i = 0, j; i <= d.size(); i = j + 1) {
        j = d.find('.', i);
        if (j == std::string::npos) j = d.size();
        parts.push_back(d.substr(i, j - i));
        if (j == d.size()) break;
    }
    size_t k = 0;
    while (k < parts.size() && parts[k] == "__outer") ++k;
    if (k == 0 || k + 2 != parts.size()) return false;
    const std::string &tn = parts[k];
    if (!g_qmlTypeUri.count(tn) || !g_qmlAttachedCxx.count(tn)) return false;
    if (g_outerChain.size() < k) return false;
    g_outerUsed = true;
    if ((int) (k - 1) > g_outerHopsNeeded) g_outerHopsNeeded = (int) (k - 1);
    std::string tgt;
    for (size_t i = 0; i < k; ++i) tgt += (i ? "." : "") + std::string("__outer");
    objExpr = attachedExprOn(tgt, tn);
    leaf = parts.back();
    return true;
}

static bool outerBareDep(const std::string &d, std::string &objExpr, std::string &leaf) {
    if (d.find('.') != std::string::npos) return false;
    std::string pre;
    for (size_t k = 0; k < g_outerChain.size(); ++k) {
        pre += (k ? "." : "") + std::string("__outer");
        auto qp = g_qmlProps.find(g_outerChain[k].qmlType);
        if (qp == g_qmlProps.end() || !qp->second.count(d)) continue;
        g_outerUsed = true;
        if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
        objExpr = pre; leaf = d;
        return true;
    }
    return false;
}

static bool outerDepIsPath(const std::string &d) {
    size_t i = 0;
    while (d.compare(i, 8, "__outer.") == 0) i += 8;
    return d.find('.', i) != std::string::npos;
}

// Set when the last path resolved through a SIBLING's id. A sibling is a field of the enclosing
// object and is assigned as that object builds its children IN ORDER, so at our own wire time it
// may still be null — connecting there connects to nothing and the binding never runs again. The
// connect and the first evaluation belong to the late phase, which the root triggers once the
// whole tree exists.
static bool g_depIsSibling = false;
// True when the registry HAS rows for `qmlType` and none of them is `mem`. That is a different
// statement from "we do not know": the type is described and simply does not declare that member,
// which is what QML's dynamic typing makes routine — Qt's Fusion CheckIndicator is used by MenuItem,
// whose `control` has no `checkState`. The ENGINE has nothing to connect to there either, so a
// missing notify is not our defect; it is the shape of the document.
// Walk a DOTTED path (the spelling the wiring keeps deps in) to the object it names and the QML
// type that object has. objPathFromString answers the same walk but returns the leaf's SIGNAL,
// which is precisely what is missing in the case this exists for.
static bool objPathWalkDotted(const std::string &dotted, std::string &oe, std::string &oq);

static bool typeKnownWithoutMember(const std::string &qmlType, const std::string &mem) {
    if (qmlType.empty()) return false;
    auto c = g_qmlCxxType.find(qmlType);
    auto p = g_qmlProps.find(qmlType);
    bool known = (c != g_qmlCxxType.end() && !c->second.empty())
              || (p != g_qmlProps.end() && !p->second.empty());
    if (!known) return false;
    if (c != g_qmlCxxType.end() && c->second.count(mem)) return false;
    if (p != g_qmlProps.end() && p->second.count(mem)) return false;
    return true;
}

// A declared property whose value is an object LITERAL (`property ColorImage arrow: ColorImage {}`)
// is still a property, and still a path head. The child is built and the field IS the property, so
// everything about it worked EXCEPT being able to read through it: the literal path recorded no
// type, so `Math.max(arrow.implicitWidth, 20)` -- Qt's Fusion TreeViewDelegate -- had no head to
// resolve and was refused, along with every other read through such a property.
static void declObjHead(const std::string &name, const std::string &qmlTy) {
    if (qmlTy.empty()) return;
    g_propType[name] = "@" + qmlTy;
    if (!g_selfQmlType.empty()) g_declObjProps[g_selfQmlType][name] = qmlTy;
}

static bool objPathHead(const std::string &n2, std::string &oe, std::string &oq) {
    // `__outer` is a head like any other: the wiring holds deps spelled with it, and a path through
    // an enclosing object cannot be re-resolved there without this.
    if (n2 == "__outer" && !g_outerChain.empty()) {
        g_outerUsed = true;
        if (g_outerHopsNeeded < 0) g_outerHopsNeeded = 0;
        oe = "__outer"; oq = g_outerChain[0].qmlType; return true;
    }
    // A DECLARED object property is in scope AND is still a path head — the same rule objPathExpr
    // keeps, and this is the copy the WIRING re-resolves dependencies through. Without it every
    // `control.<member>` dep was stripped back to `control` and reported as having no notify.
    if (auto pt0 = g_propType.find(n2); pt0 != g_propType.end() && pt0->second.size() > 1
            && pt0->second[0] == '@' && !shadowedByLocalType(n2)) {
        oe = dIdent(n2); oq = pt0->second.substr(1); return true;
    }
    // ...unless we are compiling a USE-SITE binding, where the merged class's own declarations are
    // not in scope (see shadowedByLocalType): `control: control` must reach the enclosing object.
    if ((g_scope.count(n2) && !shadowedByLocalType(n2)) || g_vgroups.count(n2)) return false;
    if (isSelfId(n2)) { oe = "this"; oq = g_selfQmlType; return true; }
    if (auto ci2 = g_childIds.find(n2); ci2 != g_childIds.end()) {
        if (ci2->second.qmlType.empty()) return false;
        // ...and it is built AFTER this object's own properties are assigned, which is the order
        // the engine uses. So a dependency on it is in exactly the position the sibling case is in:
        // the field is still null while our own wire runs, and connecting there threw. Same sink,
        // same reason — the late phase connects and re-evaluates once. (Qt's TextField reads
        // `placeholder.implicitWidth` for its own implicitWidth; that is this case.)
        g_depIsSibling = true;
        oe = ci2->second.field; oq = ci2->second.qmlType; return true;
    }
    // A DECLARED object property of THIS object (`property Item control`): the field is the wrapper
    // and its QML type is what the document declared, which is how a path through it gets typed.
    if (auto pt2 = g_propType.find(n2); pt2 != g_propType.end() && pt2->second.size() > 1
            && pt2->second[0] == '@') {
        oe = dIdent(n2); oq = pt2->second.substr(1); return true;
    }
    std::string pre2; const OuterFrame *fr2 = nullptr;
    if (outerHop(n2, pre2, &fr2)) { oe = pre2.substr(0, pre2.size() - 1); oq = fr2->qmlType; return true; }
    if (objPropQml(g_selfQmlType, n2, oq)) { oe = "propObj(this, \"" + n2 + "\")"; return true; }
    std::string pre3;
    for (size_t k = 0; k < g_outerChain.size(); ++k) {
        pre3 += "__outer.";
        if (objPropQml(g_outerChain[k].qmlType, n2, oq)) {
            if (auto d1 = g_outerChain[k].childTypes.find(n2);
                    d1 != g_outerChain[k].childTypes.end() && g_qmlCxxType.count(d1->second))
                oq = d1->second;   // what the FILE declares, not what the property's type says
            g_outerUsed = true;
            if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
            oe = "propObj(" + pre3.substr(0, pre3.size() - 1) + ", \"" + n2 + "\")";
            return true;
        }
        // ...and a SIBLING's id, which is a field of that object. Same rule as the walker keeps —
        // this function has its own copy of the resolution, and a dependency re-resolved here has
        // to reach what the READ reached.
        if (auto sc = g_outerChain[k].childIds.find(n2);
                sc != g_outerChain[k].childIds.end() && !sc->second.second.empty()) {
            g_depIsSibling = true;
            g_outerUsed = true;
            if ((int) k > g_outerHopsNeeded) g_outerHopsNeeded = (int) k;
            oe = pre3 + sc->second.first; oq = sc->second.second;
            return true;
        }
    }
    return false;
}
static bool objPathWalkDotted(const std::string &dotted, std::string &oe, std::string &oq) {
    std::vector<std::string> parts;
    for (size_t i = 0, j; i <= dotted.size(); i = j + 1) {
        j = dotted.find('.', i);
        if (j == std::string::npos) j = dotted.size();
        parts.push_back(dotted.substr(i, j - i));
        if (j == dotted.size()) break;
    }
    if (parts.empty()) return false;
    size_t k0 = 0;
    while (k0 + 1 < parts.size() && parts[k0] == "__outer") ++k0;
    if (k0 > 0) {
        if (g_outerChain.size() < k0) return false;
        g_outerUsed = true;
        if ((int) (k0 - 1) > g_outerHopsNeeded) g_outerHopsNeeded = (int) (k0 - 1);
        oe.clear();
        for (size_t i = 0; i < k0; ++i) oe += (i ? "." : "") + std::string("__outer");
        oq = g_outerChain[k0 - 1].qmlType;
    } else if (!objPathHead(parts[0], oe, oq)) return false;
    for (size_t k = (k0 ? k0 : 1); k < parts.size(); ++k) {
        std::string nq;
        // A DECLARED object property of the enclosing object is a hop too — `__outer.control` on
        // every Fusion indicator. The registry does not know it (the DOCUMENT declares it), so the
        // frame's own table is where its QML type lives.
        if (k0 > 0 && k == k0) {
            auto &pt = g_outerChain[k0 - 1].propType;
            if (auto it = pt.find(parts[k]);
                    it != pt.end() && it->second.size() > 1 && it->second[0] == '@') {
                oe = "propObj(" + oe + ", \"" + parts[k] + "\")";
                oq = it->second.substr(1);
                continue;
            }
        }
        if (!objPropQml(oq, parts[k], nq)) return false;
        oe = "propObj(" + oe + ", \"" + parts[k] + "\")";
        oq = nq;
    }
    return true;
}

static bool objPathFromString(const std::string &dotted, std::string &objExpr, std::string &leafSig) {
    std::vector<std::string> parts;
    for (size_t i = 0, j; i <= dotted.size(); i = j + 1) {
        j = dotted.find('.', i);
        if (j == std::string::npos) j = dotted.size();
        parts.push_back(dotted.substr(i, j - i));
        if (j == dotted.size()) break;
    }
    if (parts.size() < 2) return false;
    std::string oe, oq;
    // A path may reach through SEVERAL enclosing objects (`__outer.__outer.first.position` in Qt's
    // RangeSlider). Consume every `__outer` at the head, not just one: stopping at the first left
    // the next segment being looked up as a property named `__outer`, which no type has.
    size_t k0 = 0;
    while (k0 + 1 < parts.size() && parts[k0] == "__outer") ++k0;
    if (k0 > 0) {
        if (g_outerChain.size() < k0) return false;
        g_outerUsed = true;
        if ((int) (k0 - 1) > g_outerHopsNeeded) g_outerHopsNeeded = (int) (k0 - 1);
        oe.clear();
        for (size_t i = 0; i < k0; ++i) oe += (i ? "." : "") + std::string("__outer");
        oq = g_outerChain[k0 - 1].qmlType;
    } else if (!objPathHead(parts[0], oe, oq)) return false;
    for (size_t k = (k0 ? k0 : 1); k + 1 < parts.size(); ++k) {
        std::string nq;
        if (!objPropQml(oq, parts[k], nq)) return false;
        oe = "propObj(" + oe + ", \"" + parts[k] + "\")";
        oq = nq;
    }
    std::string own = oq;
    if (!g_qmlNotify.count(own))
        if (auto bm = g_qmlMap.find(own); bm != g_qmlMap.end()) own = bm->second.first;
    auto qn = g_qmlNotify.find(own);
    if (qn == g_qmlNotify.end()) return false;
    auto nt = qn->second.find(parts.back());
    if (nt == qn->second.end() || nt->second.empty()) return false;
    objExpr = oe; leafSig = nt->second;
    return true;
}

// A role of the per-item model object, by NAME: the same read whether the name is a literal
// (`model.day`) or computed (`model[control.textRole]`). Empty when the property's declared type is
// not one this channel can carry, so the caller falls through to the ordinary refusal.
// Whether `model` means the per-item model here, and can therefore be asked of the context.
//
// Three cases, and the engine decides all three. A delegate that declares NO required property gets
// the context, and `model` is one of the names on it. A delegate that declares `model` as required
// -- which is how Qt's ComboBox and SearchField spell it -- is handed the same object by the view,
// so the two agree even though they arrive by different routes (we never mark our own properties
// required, so our side keeps the context). A delegate that declares required properties but NOT
// `model` has neither: the injection is off and nothing was injected under that name, so the engine
// answers EMPTY -- measured -- and a context read there would invent a value.
static bool modelIsReadable() {
    if (g_requiredDecls.count("model")) return true;
    if (g_hasRequiredDecl) return false;
    return !g_scope.count("model") && !g_propType.count("model");
}

static std::string modelRoleRead(const QString &dtype, const std::string &keyExpr) {
    // Through the CONTEXT, not through the context OBJECT. Measured: a Repeater over an int model
    // publishes `index` on the context itself and carries no context object at all, so a property
    // read off `contextObject()` answered empty on every path. `contextProperty` asks the context
    // and its object, in that order, and walks up -- one call that covers both, and the same one
    // the literal-name reads already use. The only difference here is that the name arrives at run
    // time.
    if (dtype == "int") return "contextInt(this, " + keyExpr + ")";
    if (dtype == "double" || dtype == "float" || dtype == "real")
        return "contextDouble(this, " + keyExpr + ")";
    if (dtype == "string") return "contextStr(this, " + keyExpr + ")";
    if (dtype == "bool") return "(contextInt(this, " + keyExpr + ") != 0)";
    return "";
}

static bool compileExpr(ExpressionNode *e, const QString &dtype, std::string &out) {
    if (!e) return false;
    if (auto *nested = cast<NestedExpression *>(e)) {
        std::string inner;
        if (!compileExpr(nested->expression, dtype, inner)) return false;
        out = "(" + inner + ")"; return true;
    }
    if (auto *id = cast<IdentifierExpression *>(e)) {
        // `background ? a : b` — the bare form of the same null test. Qt's Controls write it both
        // ways (`control.background` and plain `background`), and refusing one of them makes the
        // support look arbitrary.
        if (dtype == "bool") {
            std::string n = qs(id->name.toString());
            if (!g_scope.count(n) && !g_childIds.count(n))
                if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                    auto it = qc->second.find(n);
                    if (it != qc->second.end() && !it->second.empty() && it->second.back() == '*') {
                        out = "(propObj(this, \"" + n + "\") !is null)";
                        return true;
                    }
                }
        }
        {   // A CONTEXT name inside a delegate (`index`, `modelData`, a role): the view publishes
            // them on the per-item QQmlContext, so they are properties of no object and cannot be
            // resolved the way every other name here is. Anywhere in the delegate SUBTREE: a
            // child's context nests inside the delegate root's, so the per-item names reach it
            // too — which is where Qt's own Controls write them (`text: model[textRole]` sits on
            // a Control's contentItem, not on the delegate root).
            std::string n = qs(id->name.toString());
            // ...and NOT when the delegate declares required properties. Measured, with a
            // control in the same file: our context keeps a name the type does NOT declare and
            // loses one it does, while the engine has the opposite -- it withheld the context and
            // injected the declared ones. So in such a delegate a bare context name is a value the
            // engine does not have (undeclared: it has nothing) or one we cannot see (declared: it
            // left our context), and reading it invents an answer either way.
            if (!g_delegateCls.empty() && !g_hasRequiredDecl
                    && !g_scope.count(n) && !g_childIds.count(n) && !g_propType.count(n)
                    && !g_baseProps.count(n)) {
                // ...and the object's body waits for the context, but only when one is actually
                // read: a type this branch does not handle falls through to the ordinary name
                // resolution and must not gate the whole body on something it never asks for.
                if (dtype == "int") { g_ctxUsed = true; out = "contextInt(this, \"" + n + "\")"; return true; }
                if (dtype == "double" || dtype == "float" || dtype == "real") {
                    g_ctxUsed = true; out = "contextDouble(this, \"" + n + "\")"; return true;
                }
                if (dtype == "string") { g_ctxUsed = true; out = "contextStr(this, \"" + n + "\")"; return true; }
            }
        }
        return readName(qs(id->name.toString()), out);
    }
    // An ENUM CONSTANT where a NUMBER is wanted: `loops: Animation.Infinite`. A real enum-typed
    // property takes the KEY as text and QMetaEnum converts it, but `loops` is a plain `int` -- the
    // key names a constant of some other enum -- so the only thing that can travel is the value.
    // The registry already says which C++ class the QML type is; its meta-object has the key. No
    // table of enum values anywhere: the channel that knows them is the one Qt already ships.
    if (dtype == "int" || dtype == "double" || dtype == "real" || dtype == "float")
        if (auto *fmE = cast<FieldMemberExpression *>(e))
            if (auto *bE = cast<IdentifierExpression *>(fmE->base)) {
                std::string tn = qs(bE->name.toString()), mem = qs(fmE->name.toString());
                auto mm = g_qmlMap.find(tn);
                if (!mem.empty() && std::isupper((unsigned char) mem[0]) && tn != "Qt"
                        && !g_scope.count(tn) && !g_childIds.count(tn) && !g_singletons.count(tn)
                        && mm != g_qmlMap.end() && !mm->second.first.empty()) {
                    out = "enumValueOn(this, \"" + mm->second.first + "\", \"" + mem + "\")";
                    return true;
                }
            }
    // `[3, 1, 4]` -> a D array literal. Element type comes from the property's declared type, so
    // the elements compile with the same rules as a scalar binding of that type.
    if (auto *arr = cast<ArrayPattern *>(e)) {
        std::string items;
        for (auto *it = arr->elements; it; it = it->next) {
            if (!it->element || !it->element->initializer) return false;
            std::string one;
            if (!compileExpr(it->element->initializer, dtype, one)) return false;
            items += (items.empty() ? "" : ", ") + one;
        }
        out = "[" + items + "]"; return true;
    }
    // `nums[i]` on a value list -> D indexing (same syntax, and D bounds-checks it).
    if (auto *am = cast<ArrayMemberExpression *>(e)) {
        auto *b = cast<IdentifierExpression *>(am->base);
        if (b && g_valueLists.count(qs(b->name.toString()))) {
            std::string idx;
            if (!compileExpr(am->expression, QStringLiteral("int"), idx)) return false;
            out = qs(b->name.toString()) + "[" + idx + "]"; return true;
        }
        // A MODEL ROLE, read by a key computed at run time: `text: model[control.textRole]`, which
        // is how every Qt Control that shows a model writes its label. The key is a string and the
        // roles are PROPERTIES of the object the per-item context carries -- so this is the
        // meta-object channel again, a property read by name, not a new mechanism. `index` is one
        // of those properties too, which is why `model["index"]` works for exactly the same reason.
        if (b && !g_delegateCls.empty()) {
            std::string base = qs(b->name.toString());
            if (base == "model" && !g_childIds.count(base) && !g_baseProps.count(base)
                    && modelIsReadable()) {
                std::string key;
                if (!compileExpr(am->expression, QStringLiteral("string"), key)) return false;
                if (auto o = modelRoleRead(dtype, key); !o.empty()) { g_ctxUsed = true; out = o; return true; }
            }
        }
        return false;
    }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        // `Qt.platform.pluginName` — the third QML global with no object behind it, after the
        // colour helpers and Qt.styleHints. Qt's own context menus choose their popup type with it.
        if (auto *fmP = cast<FieldMemberExpression *>(fm->base))
            if (auto *bP = cast<IdentifierExpression *>(fmP->base);
                    bP && qs(bP->name.toString()) == "Qt" && !g_scope.count("Qt")
                    && !g_childIds.count("Qt") && qs(fmP->name.toString()) == "platform"
                    && qs(fm->name.toString()) == "pluginName") {
                out = "platformName()"; return true;
            }
        // The same model role written with a LITERAL name: `model.day` on Qt's MonthGrid. One
        // mechanism, two spellings -- the key is just known at compile time here.
        if (auto *bM = cast<IdentifierExpression *>(fm->base);
                bM && !g_delegateCls.empty() && qs(bM->name.toString()) == "model"
                && !g_childIds.count("model") && !g_baseProps.count("model")
                && modelIsReadable()) {
            std::string role = qs(fm->name.toString());
            if (auto o = modelRoleRead(dtype, "\"" + role + "\""); !o.empty()) {
                g_ctxUsed = true; out = o; return true;
            }
        }
        // An ATTACHED object as a TRUTH VALUE: `indicator.Window ? … : …` — Qt's Fusion Switch
        // asks whether it is in a window before dimming its gradient. First, because the ordinary
        // member paths below decline a capitalised member and never reach the object-path test at
        // the end. `qmlAttachedPropertiesObject` returns null when the object is not under one of
        // those types, which is exactly the question QML is asking.
        if (dtype == "bool")
            if (auto *bA = cast<IdentifierExpression *>(fm->base)) {
                std::string anB = qs(fm->name.toString()), tgtB, tqB;
                if (!anB.empty() && std::isupper((unsigned char) anB[0]) && g_qmlTypeUri.count(anB)
                        && g_qmlAttachedCxx.count(anB) && !g_scope.count(anB) && !g_childIds.count(anB)
                        && objPathHead(qs(bA->name.toString()), tgtB, tqB)) {
                    out = "(" + attachedExprOn(tgtB, anB) + " !is null)";
                    return true;
                }
            }
        // `nums.length` -> D's .length, but QML's is an int and D's is a size_t: cast so the
        // property's declared int type and any arithmetic on it stay int.
        if (auto *b = cast<IdentifierExpression *>(fm->base);
                b && qs(fm->name.toString()) == "length" && g_valueLists.count(qs(b->name.toString()))) {
            out = "cast(int) " + qs(b->name.toString()) + ".length"; return true;
        }
        auto *base = cast<IdentifierExpression *>(fm->base);
        // `Fusion.topShadow` — a PROPERTY of a singleton, not a method. Qt's Fusion reads sixteen
        // colours that way, next to the calls that already compiled. Same instance, same channel:
        // the value crosses as text and QMetaType converts it on write. Lowercase member only, so an
        // ENUM (`Type.Value`) keeps its own path.
        if (base) {
            std::string sn9 = qs(base->name.toString()), mn9 = qs(fm->name.toString());
            auto sg9 = g_qmlSingletonUri.find(sn9);
            if (sg9 != g_qmlSingletonUri.end() && !g_scope.count(sn9) && !g_childIds.count(sn9)
                    && (g_selfId.empty() || sn9 != g_selfId)
                    && !mn9.empty() && !std::isupper((unsigned char) mn9[0])) {
                std::string inst = "qmlSingleton(\"" + sg9->second.first + "\", \"" + sn9 + "\", "
                                 + std::to_string(sg9->second.second.first) + ", "
                                 + std::to_string(sg9->second.second.second) + ")";
                const std::string dt9 = dtype.toStdString();
                const char *rd9 = dt9 == "double" ? "propDouble(" : dt9 == "int" ? "propInt("
                                : dt9 == "bool" ? "propBool(" : "propStr(";
                out = rd9 + inst + ", \"" + mn9 + "\")";
                return true;
            }
        }
        // An object path of ANY depth used as a truth value: Qt's SearchField writes
        // `control.searchIndicator.indicator && !control.mirrored ? 6 : 0`. The two-level form has
        // its own handling below (which also records the dependency); this covers the deeper ones,
        // which were refused outright and left the padding at its default.
        if (dtype == "bool")
            if (auto *fb2 = cast<FieldMemberExpression *>(fm->base)) {
                std::string oe2, oq2;
                if (objPathExpr(fb2, oe2, oq2))
                    if (std::string leafQ; objPropQml(oq2, qs(fm->name.toString()), leafQ)) {
                        out = "(propObj(" + oe2 + ", \"" + qs(fm->name.toString()) + "\") !is null)";
                        return true;
                    }
            }
        // `control.indicator && ...` — an OBJECT-valued property used as a truth value. In QML
        // that is a null test, and the object is fetched through the meta-object, so it needs no
        // type knowledge at all. Only for a bool target: as a value it would be the object.
        if (dtype == "bool") {
            std::string obj, ownerType, pre;
            const OuterFrame *fr = nullptr;
            std::string bn = base ? qs(base->name.toString()) : "";
            if (!bn.empty()) {
                if (outerHop(bn, pre, &fr)) { obj = pre.substr(0, pre.size() - 1); ownerType = fr->qmlType; }
                else if (isSelfId(bn)) { obj = "this"; ownerType = g_selfQmlType; }
                // An ATTACHED read as a truth value: `Window.window ? … : false` (Qt's Menu.qml). The
                // base is a TYPE NAME; the module comes from qmluris.tsv and the proof that the member
                // is an object from qmlattached.tsv — neither guessed.
                else if (!g_scope.count(bn) && !g_childIds.count(bn)
                         && std::isupper((unsigned char) bn[0]) && g_qmlTypeUri.count(bn)) {
                    auto am = g_qmlAttachedCxx.find(bn);
                    std::string mem2 = qs(fm->name.toString());
                    if (am != g_qmlAttachedCxx.end()) {
                        auto it2 = am->second.find(mem2);
                        if (it2 != am->second.end() && !it2->second.empty() && it2->second.back() == '*') {
                            out = "(propObj(" + attachedExpr(bn) + ", \"" + mem2 + "\") !is null)";
                            return true;
                        }
                    }
                }
            }
            if (!obj.empty()) {
                std::string mem = qs(fm->name.toString());
                if (auto qc = g_qmlCxxType.find(ownerType); qc != g_qmlCxxType.end()) {
                    auto it = qc->second.find(mem);
                    if (it != qc->second.end() && !it->second.empty() && it->second.back() == '*') {
                        out = "(propObj(" + obj + ", \"" + mem + "\") !is null)";
                        return true;
                    }
                }
            }
        }
        // self reference `<id>.<prop>` -> the property; other object member access is a later phase.
        if (base && isSelfId(qs(base->name.toString())))
            return readName(qs(fm->name.toString()), out);   // `self.x` reads x however x is stored
        // `<childId>.<prop>` -> the child object's D field. A child is a real @QObject field, so
        // this is a direct read, not a meta lookup.
        if (base) {
            auto ci = g_childIds.find(qs(base->name.toString()));
            if (ci != g_childIds.end()) {
                std::string mem = qs(fm->name.toString());
                auto pt = ci->second.propType.find(mem);
                if (pt != ci->second.propType.end()) { out = ci->second.field + "." + mem; return true; }
                auto bp = ci->second.baseProps.find(mem);
                if (bp == ci->second.baseProps.end()) return false;
                const char *rd = bp->second == "string" ? "propStr(" : bp->second == "double" ? "propDouble("
                               : bp->second == "bool" ? "propBool(" : "propInt(";
                out = rd + ci->second.field + ", \"" + mem + "\")";
                return true;
            }
        }
        // `control.<prop>` from inside a child — the ENCLOSING object, reached through the
        // back-reference. A declared property is a typed D field on it; a property of its bound
        // base goes through the meta-object, exactly as it would on `this`.
        if (std::string pre; base) {
            const OuterFrame *fr = nullptr;
            if (outerHop(qs(base->name.toString()), pre, &fr)) {
                std::string mem = qs(fm->name.toString());
                std::string obj = pre.substr(0, pre.size() - 1);   // drop the trailing '.'
                if (!fr->baseProps.count(mem) && fr->propType.count(mem)) { out = pre + mem; return true; }
                if (auto qp = g_qmlProps.find(fr->qmlType); qp != g_qmlProps.end()) {
                    auto t = qp->second.find(mem);
                    if (t != qp->second.end()) {
                        const std::string &ty = t->second;
                        if (ty == "string" || ty == "double" || ty == "bool" || ty == "int") {
                            const char *rd = ty == "string" ? "propStr(" : ty == "double" ? "propDouble("
                                           : ty == "bool" ? "propBool(" : "propInt(";
                            out = rd + obj + ", \"" + mem + "\")"; return true;
                        }
                    }
                }
                // ...but a COLOUR is not unknown: it has no D scalar type, and the registry says
                // outright that it is a QColor, which crosses as text through the meta-object like
                // every other colour here. Qt's Fusion passes exactly this as an argument —
                // `Fusion.gradientStart(backgroundRect.color)` — and refusing it cost the call.
                if (dtype == "string")
                    if (auto qcE = g_qmlCxxType.find(fr->qmlType); qcE != g_qmlCxxType.end())
                        if (auto cE = qcE->second.find(mem);
                                cE != qcE->second.end() && cE->second.rfind("QColor", 0) == 0) {
                            out = "propStr(" + obj + ", \"" + mem + "\")";
                            return true;
                        }
                // ...and a member that type DOES NOT DECLARE. QML answers `undefined`, and the
                // meta channel answers the same in the target's own terms — false for the neutral
                // hint the logical operators compile their operands with. Qt's Fusion ButtonPanel
                // asks `control.down || control.checked` and is used by a ComboBox, which has no
                // `checked`; the engine reads the whole expression as `down`, and refusing it cost
                // that panel its colour AND its gradient (2949 of 3240 pixels, the largest render
                // difference in either corpus). "Refused, not guessed" was right while the registry
                // could not tell the two apart; typeKnownWithoutMember can.
                if (typeKnownWithoutMember(fr->qmlType, mem)) {
                    std::string dtE = dtype.isEmpty() ? std::string("bool") : dtype.toStdString();
                    const char *rdE = dtE == "string" ? "propStr(" : dtE == "double" ? "propDouble("
                                    : dtE == "bool" ? "propBool(" : dtE == "int" ? "propInt(" : nullptr;
                    if (rdE) { out = rdE + obj + ", \"" + mem + "\")"; return true; }
                }
                return false;   // unknown member of that enclosing object: refused, not guessed
            }
        }
        // `control.indicator.width` — a scalar reached THROUGH an object-valued property. The
        // object is fetched with propObj at runtime and its TYPE comes from the owner's C++ type
        // column, mapped back to a QML name so that type's table can say what `width` is. The
        // read is recorded so the binding can connect to the INNER object's notify in the late
        // phase: connecting here would be wrong (the dependency would be indicatorChanged, which
        // fires when the indicator is REPLACED) and impossible (the indicator does not exist yet).
        if (auto *fmb = cast<FieldMemberExpression *>(fm->base)) {
            if (auto *b1 = cast<IdentifierExpression *>(fmb->base)) {
                std::string bn = qs(b1->name.toString()), inner = qs(fmb->name.toString());
                std::string mem = qs(fm->name.toString()), obj, ownerType, pre;
                const OuterFrame *fr = nullptr;
                if (outerHop(bn, pre, &fr)) { obj = pre.substr(0, pre.size() - 1); ownerType = fr->qmlType; }
                else if (isSelfId(bn)) { obj = "this"; ownerType = g_selfQmlType; }
                if (!obj.empty() && !ownerType.empty() && !g_vgroups.count(inner)) {
                    std::string innerCxx;
                    if (auto qc = g_qmlCxxType.find(ownerType); qc != g_qmlCxxType.end()) {
                        auto it = qc->second.find(inner);
                        if (it != qc->second.end()) innerCxx = it->second;
                    }
                    // A helper type Qt does not export as a QML element (QQuickRangeSliderNode, the
                    // type of `RangeSlider.first`) has no QML name, so the property table is keyed by
                    // its C++ CLASS name instead. Fall back to that rather than refusing the read.
                    std::string innerQml = innerCxx.empty() ? "" : qmlNameOfCxx(innerCxx);
                    if (innerQml.empty() && !innerCxx.empty()) {
                        innerQml = innerCxx;
                        while (!innerQml.empty() && (innerQml.back() == '*' || innerQml.back() == ' '))
                            innerQml.pop_back();
                    }
                    if (!innerQml.empty())
                        if (auto qp = g_qmlProps.find(innerQml); qp != g_qmlProps.end()) {
                            auto t = qp->second.find(mem);
                            if (t != qp->second.end()) {
                                const std::string &ty = t->second;
                                if (ty == "string" || ty == "double" || ty == "bool" || ty == "int") {
                                    const char *rd = ty == "string" ? "propStr(" : ty == "double" ? "propDouble("
                                                   : ty == "bool" ? "propBool(" : "propInt(";
                                    out = rd + std::string("propObj(") + obj + ", \"" + inner + "\"), \""
                                        + mem + "\")";
                                    g_deepReads.push_back({obj, inner, mem, innerQml});
                                    return true;
                                }
                            }
                        }
                }
            }
        }
        // `background.implicitWidth` — the BARE form of a read through an object-valued property
        // of THIS object. Same rule and same late connect as `control.indicator.width`; Qt's
        // Controls use both spellings.
        if (base) {
            std::string inner = qs(base->name.toString()), mem = qs(fm->name.toString());
            if (!g_scope.count(inner) && !g_childIds.count(inner) && !g_vgroups.count(inner)
                    && (g_selfId.empty() || inner != g_selfId))
                if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                    auto it = qc->second.find(inner);
                    if (it != qc->second.end() && !it->second.empty() && it->second.back() == '*') {
                        std::string innerQml = qmlNameOfCxx(it->second);
                        if (!innerQml.empty())
                            if (auto qp = g_qmlProps.find(innerQml); qp != g_qmlProps.end()) {
                                auto t = qp->second.find(mem);
                                if (t != qp->second.end()) {
                                    const std::string &ty = t->second;
                                    if (ty == "string" || ty == "double" || ty == "bool" || ty == "int") {
                                        const char *rd = ty == "string" ? "propStr(" : ty == "double" ? "propDouble("
                                                       : ty == "bool" ? "propBool(" : "propInt(";
                                        out = rd + std::string("propObj(this, \"") + inner + "\"), \"" + mem + "\")";
                                        g_deepReads.push_back({"this", inner, mem, innerQml});
                                        return true;
                                    }
                                }
                            }
                    }
                }
        }
        // `parent.<prop>` — QQuickItem exposes `parent` as a Q_PROPERTY, so the OBJECT is fetched
        // through the meta-object at runtime and nothing static is assumed about it. Only the
        // member's TYPE is taken from the enclosing frame, which is sound because a child's visual
        // parent IS the enclosing object (Qt reparents contentItem/background to the control too),
        // and a mismatch would still convert through the QVariant rather than misread memory.
        if (base && qs(base->name.toString()) == "parent" && !g_scope.count("parent")
                && !g_childIds.count("parent")) {
            // Fetching the object with propObj(this, "parent") reads null: Qt sets the parent
            // AFTER construction and the wire runs inside the constructor. A child's visual parent
            // IS its enclosing object here — Qt reparents contentItem/background to the control
            // too — so `parent` resolves to the same back-reference as an enclosing id, which is
            // already correct about ordering, hops and notifies. (A child reparented at runtime,
            // or one built by a Repeater, is not compiled at all, so this cannot silently drift.)
            if (g_outerChain.empty()) return false;
            std::string mem = qs(fm->name.toString()), ty;
            const OuterFrame &fr = g_outerChain[0];
            g_outerUsed = true;
            if (g_outerHopsNeeded < 0) g_outerHopsNeeded = 0;
            if (!fr.baseProps.count(mem) && fr.propType.count(mem)) { out = "__outer." + mem; return true; }
            if (auto qp = g_qmlProps.find(fr.qmlType); qp != g_qmlProps.end()) {
                auto t = qp->second.find(mem);
                if (t != qp->second.end()) ty = t->second;
            }
            if (ty == "string" || ty == "double" || ty == "bool" || ty == "int") {
                const char *rd = ty == "string" ? "propStr(" : ty == "double" ? "propDouble("
                               : ty == "bool" ? "propBool(" : "propInt(";
                out = rd + std::string("__outer, \"") + mem + "\")";
                return true;
            }
            return false;
        }
        // `TypeName.Green` -> the D enum member `Color.Green` (int-valued).
        if (base && qs(base->name.toString()) == g_className) {
            auto it = g_enumMember.find(qs(fm->name.toString()));
            if (it != g_enumMember.end()) { out = it->second + "." + qs(fm->name.toString()); return true; }
        }
        // `Singleton.member` — a read off the singleton's one instance.
        if (base && g_singletons.count(qs(base->name.toString()))) {
            out = "__singleton_" + qs(base->name.toString()) + "()." + qs(fm->name.toString());
            return true;
        }
        // `Type.member` — a member of the object ATTACHED to us by `Type`. The attached object is
        // fetched by type name at runtime; its members are ordinary properties on it.
        {
            std::string an = attachedNameOf(fm->base);
            if (!an.empty()) {
                auto m = g_attached[an]->propType.find(qs(fm->name.toString()));
                if (m == g_attached[an]->propType.end()) return false;
                const char *rd = m->second == "string" ? "propStr(" : m->second == "double" ? "propDouble("
                               : m->second == "bool" ? "propBool(" : "propInt(";
                out = rd + attachedExpr(an) + ", \"" + qs(fm->name.toString()) + "\")";
                return true;
            }
        }
        // `group.member` -> a member of a GROUPED property: the group is a real child object
        // reached through the meta-object, its members are ordinary properties on it.
        if (base) {
            auto g = g_groups.find(qs(base->name.toString()));
            if (g != g_groups.end()) {
                auto m = g->second->propType.find(qs(fm->name.toString()));
                // A member the DOCUMENT did not write is not a failure — the group is a real object
                // and the registry knows all of its properties. Returning false here ended the whole
                // expression, so `searchIndicator.implicitIndicatorHeight` (Qt's SearchField, sizing
                // itself from its indicators) was refused and the control came out 12px short.
                // Falling through lets the generic object-path read below answer it.
                if (m == g->second->propType.end()) goto notADeclaredGroupMember;
                const char *rd = m->second == "string" ? "propStr(" : m->second == "double" ? "propDouble("
                               : m->second == "bool" ? "propBool(" : "propInt(";
                out = rd + std::string("propObj(this, \"") + qs(base->name.toString()) + "\"), \""
                    + qs(fm->name.toString()) + "\")";
                return true;
            }
        }
        notADeclaredGroupMember:;
        // `<AttachedType>.<group>.<member>` — Qt's Drawer reads `SafeArea.margins.top`. The attached
        // object comes from the same machinery as `Window.window`, and its `margins` is a VALUE group
        // (QMarginsF), so the member is extracted with the vgroup readers. Typed by the target, since
        // the attached table records the group's C++ type but not each member's.
        if (auto *fmb2 = cast<FieldMemberExpression *>(fm->base)) {
            if (auto *b2 = cast<IdentifierExpression *>(fmb2->base)) {
                std::string tn3 = qs(b2->name.toString()), grp = qs(fmb2->name.toString());
                if (!g_scope.count(tn3) && !g_childIds.count(tn3)
                        && std::isupper((unsigned char) tn3[0]) && g_qmlTypeUri.count(tn3)) {
                    auto am2 = g_qmlAttachedCxx.find(tn3);
                    if (am2 != g_qmlAttachedCxx.end() && am2->second.count(grp)) {
                        std::string dt = dtype.toStdString();
                        const char *rd2 = dt == "string" ? "vgroupStr(" : dt == "bool" ? "vgroupBool("
                                        : dt == "int" ? "vgroupInt(" : "vgroupDouble(";
                        out = rd2 + attachedExpr(tn3) + ", \"" + grp + "\", \""
                            + qs(fm->name.toString()) + "\")";
                        return true;
                    }
                }
            }
        }
        // `<objectPath>.<valueGroup>.<member>` — `control.locale.name` (Qt's SpinBox hands its
        // validator the control's locale) and `control.font.family`. The GROUP is a value, not an
        // object: the registry types it with a C++ name that does NOT end in `*`, which is exactly
        // what separates it from `control.palette.text` one line below. Reading it as an object
        // path walked into a null propObj, so the whole binding was refused — the copy form
        // (`locale: control.locale.name` as a whole binding) worked and the same read inside an
        // expression did not, which is the asymmetry that keeps turning up here.
        if (auto *fmv = cast<FieldMemberExpression *>(fm->base)) {
            std::string oev, oqv, grpv = qs(fmv->name.toString());
            if (objPathExpr(fmv->base, oev, oqv) && !oqv.empty())
                if (auto qcv = g_qmlCxxType.find(oqv); qcv != g_qmlCxxType.end()) {
                    auto gt = qcv->second.find(grpv);
                    // `^` marks a value type reached through an EXTENSION — it says the members
                    // are not WRITABLE through the plain channel, not that they cannot be read.
                    // QLocale is one (`control.locale.name`, which Qt's SpinBox hands its
                    // validator) and it is a Q_GADGET all the same, so the reader resolves the
                    // member by name like any other.
                    std::string gtn = gt == qcv->second.end() ? std::string() : gt->second;
                    if (!gtn.empty() && gtn.back() == '^') gtn.pop_back();
                    // ...and NOT a scalar: `field.selectedText.length` is a STRING's length, which
                    // the rule below answers, and treating `selectedText` as a value GROUP asked a
                    // gadget for a member it does not have — 0 where the engine reads 5.
                    if (!gtn.empty() && gtn.back() != '*' && !g_qmlProps.count(gtn)
                            && gtn != "string" && gtn != "int" && gtn != "double" && gtn != "bool"
                            && gtn != "QString" && gtn != "float" && gtn != "uint") {
                        std::string dtv = dtype.toStdString();
                        const char *rdv = dtv == "string" ? "vgroupStr(" : dtv == "bool" ? "vgroupBool("
                                        : dtv == "int" ? "vgroupInt(" : "vgroupDouble(";
                        out = rdv + oev + ", \"" + grpv + "\", \"" + qs(fm->name.toString()) + "\")";
                        return true;
                    }
                }
        }
        // `vgroup.member` -> a member of a VALUE-type group: no object to read through, so the
        // value is fetched and the member extracted from it.
        if (base) {
            auto g = g_vgroups.find(qs(base->name.toString()));
            if (g != g_vgroups.end()) {
                auto m = g->second->propType.find(qs(fm->name.toString()));
                if (m == g->second->propType.end()) return false;
                const char *rd = m->second == "string" ? "vgroupStr(" : m->second == "double" ? "vgroupDouble("
                               : m->second == "bool" ? "vgroupBool(" : "vgroupInt(";
                out = rd + std::string("this, \"") + qs(base->name.toString()) + "\", \""
                    + qs(fm->name.toString()) + "\")";
                return true;
            }
        }
        // An OBJECT PATH of any depth: `background.border.width`, `searchIndicator.indicator.visible`
        // (Qt's SearchField). Each hop is an object-valued property, which the registry types by its
        // C++ name ending in `*`, so the path can be walked with propObj hop by hop and the leaf read
        // with the ordinary typed reader. The two-level forms above were each handled by their own
        // special case; a third level was simply refused, which left a control's geometry at the type
        // default. Nothing here is per-type: the depth, the hops and the leaf all come from the
        // registry.
        {
            // `<id>.<AttachedType>.<member>` — Qt's ComboBox reads `control.Window.height`. The
                // attached object belongs to the object the id names, not to us.
            if (auto *fmb5 = cast<FieldMemberExpression *>(fm->base))
                if (auto *b5 = cast<IdentifierExpression *>(fmb5->base)) {
                    std::string tgt, tq, an5 = qs(fmb5->name.toString());
                    if (!an5.empty() && std::isupper((unsigned char) an5[0]) && g_qmlTypeUri.count(an5)
                            && objPathHead(qs(b5->name.toString()), tgt, tq)) {
                        auto am5 = g_qmlAttachedCxx.find(an5);
                        if (am5 != g_qmlAttachedCxx.end() && am5->second.count(qs(fm->name.toString()))) {
                            std::string dt5 = dtype.toStdString();
                            const char *rd5 = dt5 == "string" ? "propStr(" : dt5 == "bool" ? "propBool("
                                            : dt5 == "int" ? "propInt(" : "propDouble(";
                            out = rd5 + attachedExprOn(tgt, an5) + ", \"" + qs(fm->name.toString()) + "\")";
                            return true;
                        }
                    }
                }
            // ...and the whole path as a TRUTH VALUE: `!searchIndicator.indicator` (Qt's
            // SearchField, deciding its own padding). The leaf is an OBJECT, so the typed read
            // below cannot answer it, and refusing left the control's padding at 0 where the
            // engine computes 28 — which then moved every child.
            if (dtype == "bool") {
                std::string oe0, oq0;
                if (objPathExpr(fm, oe0, oq0)) { out = "(" + oe0 + " !is null)"; return true; }
            }
            // Any depth. This runs LAST, after every path that also records a dependency, so it
            // only ever answers what those refused — including the two-segment forms they decline
            // (a group member the document did not itself write, which the registry knows).
            {
                std::string oe, oq;
                if (objPathExpr(fm->base, oe, oq)) {
                    std::string own = oq;
                    if (!g_qmlProps.count(own))
                        if (auto bm = g_qmlMap.find(own); bm != g_qmlMap.end()) own = bm->second.first;
                    // A COLOUR has no D scalar type, but it crosses as text through the
                    // meta-object (QMetaType renders it #rrggbb) — which is how every colour here
                    // already travels, and what the oracle prints from the same QVariant. Without
                    // this, `Color.blend(control.palette.mid, ...)` could not compile its own
                    // arguments even though each one is a plain read.
                    if (dtype == "string")
                        if (auto qc2 = g_qmlCxxType.find(own); qc2 != g_qmlCxxType.end())
                            if (auto c2 = qc2->second.find(qs(fm->name.toString()));
                                    c2 != qc2->second.end() && c2->second.rfind("QColor", 0) == 0) {
                                out = "propStr(" + oe + ", \"" + qs(fm->name.toString()) + "\")";
                                return true;
                            }
                    if (auto qp = g_qmlProps.find(own); qp != g_qmlProps.end()) {
                        auto t2 = qp->second.find(qs(fm->name.toString()));
                        if (t2 != qp->second.end()) {
                            const std::string &ty2 = t2->second;
                            if (ty2 == "string" || ty2 == "double" || ty2 == "bool" || ty2 == "int") {
                                const char *rd2 = ty2 == "string" ? "propStr(" : ty2 == "double" ? "propDouble("
                                                : ty2 == "bool" ? "propBool(" : "propInt(";
                                out = rd2 + oe + ", \"" + qs(fm->name.toString()) + "\")";
                                return true;
                            }
                        }
                    }
                    // ...and a member the type DOES NOT DECLARE. QML answers `undefined` there and
                    // the meta channel answers the same in the target's own terms: false, 0, empty.
                    // Qt's Fusion ButtonPanel asks `control.down || control.checked` about a
                    // ComboBox, which has no `checked`; the engine reads the whole expression as
                    // `down`, and refusing the read cost that panel its colour AND its gradient —
                    // 2949 of 3240 pixels, the largest render difference in either corpus. Not a
                    // guess: the registry describes the type and the member is not in it. Two
                    // other parts have to land with this one — see collectIds and the three
                    // dependency consumers — and shipping any two of the three was measured worse
                    // than shipping none.
                    if (typeKnownWithoutMember(own, qs(fm->name.toString()))) {
                        // An EMPTY target type is the neutral hint the logical operators compile
                        // their operands with — `control.down || control.checked` is exactly that —
                        // and the truthiness of a member the type does not declare is false. So the
                        // bool reader is the answer there, which is also what `__qmltcOr` wants.
                        std::string dt2 = dtype.isEmpty() ? std::string("bool") : dtype.toStdString();
                        const char *rd3 = dt2 == "string" ? "propStr(" : dt2 == "double" ? "propDouble("
                                        : dt2 == "bool" ? "propBool(" : dt2 == "int" ? "propInt(" : nullptr;
                        if (rd3) {
                            out = rd3 + oe + ", \"" + qs(fm->name.toString()) + "\")";
                            return true;
                        }
                    }
                }
            }
        }
        // `<string>.length` -> D length (cast to int to match QML's int result).
        if (qs(fm->name.toString()) == "length") {
            std::string b;
            if (compileExpr(fm->base, "string", b)) { out = "cast(int)(" + b + ".length)"; return true; }
        }
        return false;
    }
    if (auto *call = cast<CallExpression *>(e)) {
        // Math.max/min(a,b), Math.abs(x) -> inline D (no import needed); other calls are later.
        auto *fm = cast<FieldMemberExpression *>(call->base);
        auto *recv = fm ? cast<IdentifierExpression *>(fm->base) : nullptr;
        if (recv && qs(recv->name.toString()) == "Math") {
            std::string fn = qs(fm->name.toString());
            std::vector<std::string> args;
            for (auto *a = call->arguments; a; a = a->next) {
                std::string s;
                if (!compileExpr(a->expression, dtype, s)) return false;
                args.push_back(s);
            }
            // std.algorithm's max/min are VARIADIC, which fixes two things at once: Math.max
            // with three arguments (Qt's Controls use it) was refused, and the two-argument form
            // was emitted as `a > b ? a : b`, evaluating each operand TWICE — every one of which
            // is a meta-object read here. Imported under a private alias so a QML property named
            // `max` cannot collide.
            if ((fn == "max" || fn == "min") && args.size() >= 2) {
                out = (fn == "max" ? "__qmltcMax(" : "__qmltcMin(");
                for (size_t i = 0; i < args.size(); ++i) out += (i ? ", " : "") + args[i];
                out += ")";
                return true;
            }
            if (fn == "abs" && args.size() == 1) { out = "(" + args[0] + " < 0 ? -(" + args[0] + ") : (" + args[0] + "))"; return true; }
            // `Math.round` is JS's, which is floor(x + 0.5) — NOT D's round(), which sends a
            // half away from zero in both directions. Qt's Fusion Slider places its handle with
            // `Math.round(visualPosition * (availableWidth - width))`, and refusing the call left
            // the handle at the left edge forever: identical at rest, and wrong the moment the
            // slider is clicked. ceil and floor come with it — Qt's Tumbler and ScrollView use
            // them and they were refused for the same reason.
            if (args.size() == 1 && (fn == "round" || fn == "ceil" || fn == "floor")) {
                const char *dfn = fn == "round" ? "__qmltcFloor((" : (fn == "ceil" ? "__qmltcCeil((" : "__qmltcFloor((");
                out = dfn + args[0] + (fn == "round" ? ") + 0.5)" : "))");
                return true;
            }
            return false;
        }
        // `<objPath>.hasOwnProperty("name")` — JS asking whether an object HAS a member. The meta
        // channel answers exactly that question, and it is the one `typeKnownWithoutMember` asks in
        // the other direction at compile time. Qt's Cut, Copy and Paste actions guard on it,
        // because the editor they are handed may be a TextInput or a TextEdit or neither.
        if (recv == nullptr || true)
            if (auto *hf = cast<FieldMemberExpression *>(call->base);
                    hf && qs(hf->name.toString()) == "hasOwnProperty"
                    && call->arguments && !call->arguments->next)
                if (auto *sl = cast<StringLiteral *>(call->arguments->expression)) {
                    std::string oe, oq;
                    if (objPathExpr(hf->base, oe, oq)) {
                        out = "hasProp(" + oe + ", \"" + qs(sl->value.toString()) + "\")";
                        return true;
                    }
                }
        // `Qt.darker(c, f)` / `Qt.lighter(c, f)` — the colour globals. Unlike `Qt.styleHints` there
        // is no object behind them, so nothing in the meta channel reaches them and the runtime
        // implements the two calls the engine implements (QColor::darker/lighter). They gate a
        // whole cluster rather than themselves: Fusion computes most of its palette this way, and
        // the results are what `Color.transparent(...)` and the declared colour properties are
        // handed — every one of which was refused for want of its argument.
        if (recv && qs(recv->name.toString()) == "Qt" && !g_scope.count("Qt") && !g_childIds.count("Qt")) {
            std::string fn = qs(fm->name.toString());
            if (fn != "darker" && fn != "lighter" && fn != "alpha") return false;
            std::vector<std::string> args;
            for (auto *a = call->arguments; a; a = a->next) {
                std::string s;
                // The colour is TEXT and the factor a real: compiled under the wrong target type
                // the first argument came out as a number and the second as a string.
                if (!compileExpr(a->expression, args.empty() ? "string" : "double", s)) return false;
                args.push_back(s);
            }
            if (args.empty() || args.size() > 2) return false;
            if (fn == "alpha") {   // ...which has no default: QML requires both arguments
                if (args.size() != 2) return false;
                out = "colorAlpha(" + args[0] + ", " + args[1] + ")";
                return true;
            }
            out = (fn == "darker" ? "colorDarker(" : "colorLighter(") + args[0]
                + (args.size() > 1 ? ", " + args[1] : "") + ")";
            return true;
        }
        // `<Singleton>.<method>(args)` — Qt's own controls compute colours with
        // `Color.blend(a, b, f)`. The registry says which names are singletons, the module and
        // version their one instance is fetched with, and how many parameters each method takes;
        // the arguments cross as TEXT and QMetaType converts each to the parameter's own type, the
        // same channel every property here uses. So this is one mechanism for every method of
        // every singleton, not a rule about blend.
        std::string recvAlias;   // the singleton's name when it arrived through an import alias
        if (!recv)
            if (auto *fmA = cast<FieldMemberExpression *>(fm ? fm->base : nullptr))
                if (auto *idA = cast<IdentifierExpression *>(fmA->base);
                        idA && g_importAliases.count(qs(idA->name.toString())))
                    recvAlias = qs(fmA->name.toString());
        if (recv || !recvAlias.empty()) {
            std::string sn = recvAlias.empty() ? qs(recv->name.toString()) : recvAlias;
            auto sg = g_qmlSingletonUri.find(sn);
            if (sg != g_qmlSingletonUri.end() && !g_scope.count(sn) && !g_childIds.count(sn)
                    && (g_selfId.empty() || sn != g_selfId)) {
                std::string mn2 = qs(fm->name.toString());
                auto mi = g_qmlMethods.find(sn);
                if (mi != g_qmlMethods.end())
                    if (auto me = mi->second.find(mn2); me != mi->second.end()) {
                        // Pick the overload with the argument count this call has.
                        size_t argc = 0;
                        for (auto *a0 = call->arguments; a0; a0 = a0->next) ++argc;
                        const std::pair<std::string, std::vector<std::string>> *ovl = nullptr;
                        for (auto &cand : me->second)
                            if (cand.second.size() == argc) { ovl = &cand; break; }
                        if (!ovl) return false;
                        // Each argument is compiled AS ITS PARAMETER'S TYPE, which the registry
                        // publishes. Trying `string` first and falling back was wrong in a way that
                        // compiled: a numeric ternary compiles fine with a string target and stays
                        // numeric, so the call went out with a double inside an array of strings.
                        std::vector<std::string> as;
                        bool ok2 = true;
                        size_t pi = 0;
                        const auto &ptypes = ovl->second;
                        for (auto *a = call->arguments; a && ok2; a = a->next, ++pi) {
                            if (pi >= ptypes.size()) { ok2 = false; break; }
                            const std::string &pt = ptypes[pi];
                            bool num = pt == "double" || pt == "qreal" || pt == "float"
                                    || pt == "int" || pt == "uint" || pt == "bool";
                            std::string one;
                            if (num) {
                                // numText, not to!string: a real crossing as TEXT has to
                                // ROUND-TRIP, and `to!string` gives six significant digits.
                                // `Color.transparent(c, 210 / 255)` arrived as 0.823529, which is
                                // 209.99989 alpha steps — one short of the engine's 210 on every
                                // checkmark Fusion draws.
                                if (compileExpr(a->expression, pt == "bool" ? "bool" : "double", one))
                                    as.push_back(pt == "bool" ? "to!string(" + one + ")"
                                                              : "numText(" + one + ")");
                                else ok2 = false;
                            }
                            // An OBJECT parameter cannot travel as text: Qt's Fusion computes every
                            // colour from `Fusion.buttonColor(control.palette, …)`, and a palette is
                            // a pointer. Passed as one; the helper marshals text and objects side by
                            // side.
                            else if (!pt.empty() && pt.back() == '*') {
                                std::string oe8, oq8;
                                if (objPathExpr(a->expression, oe8, oq8)) as.push_back(oe8);
                                else ok2 = false;
                            }
                            else if (compileExpr(a->expression, "string", one)) as.push_back(one);
                            else ok2 = false;
                        }
                        if (ok2 && as.size() == ptypes.size()) {
                            std::string joined;
                            for (auto &x : as) joined += (joined.empty() ? "" : ", ") + x;
                            std::string c2 = "invokeMixed(qmlSingleton(\"" + sg->second.first + "\", \""
                                + sn + "\", " + std::to_string(sg->second.second.first) + ", "
                                + std::to_string(sg->second.second.second) + "), \"" + mn2 + "\", "
                                + joined + ")";
                            if (dtype == "string") { out = c2; return true; }
                            if (dtype == "double" || dtype == "int" || dtype == "bool") {
                                out = "(" + c2 + ").to!" + dtype.toStdString(); return true;
                            }
                        }
                    }
            }
        }
        // `<childId>.method()` / `<childId>.signal(args)` — a call on ANOTHER object reached
        // through its id. The child is a D field, so this is a direct call; a name the child does
        // not declare fails rather than compiling to something that silently does nothing.
        if (recv) {
            auto ci = g_childIds.find(qs(recv->name.toString()));
            if (ci != g_childIds.end()) {
                std::string mn = qs(fm->name.toString());
                bool isSig = ci->second.signalParams.count(mn) > 0;
                if (!isSig && !ci->second.methods0.count(mn)) return false;
                if (!isSig && call->arguments) return false;   // only no-arg methods are pre-scanned
                std::vector<std::string> args;
                for (auto *a = call->arguments; a; a = a->next) {
                    std::string one;
                    if (!compileExpr(a->expression, dtype, one)) return false;
                    args.push_back(one);
                }
                std::string joined;
                for (auto &x : args) joined += (joined.empty() ? "" : ", ") + x;
                // A signal is emitted through its Signal! field; a function is a plain method.
                out = ci->second.field + "." + mn + (isSig ? ".emit(" : "(") + joined + ")";
                return true;
            }
        }
        // `qsTr("…")` — QML's translation call. Its context is the .qml file's base name, which is
        // what the engine uses, so the compiled form resolves against the same context.
        // (With no translator covering the string Qt returns the source, exactly as QML does.)
        if (auto *fnId = cast<IdentifierExpression *>(call->base);
                fnId && qs(fnId->name.toString()) == "qsTr" && call->arguments) {
            std::string src;
            if (!compileExpr(call->arguments->expression, "string", src)) return false;
            std::string disambig;
            if (call->arguments->next
                    && !compileExpr(call->arguments->next->expression, "string", disambig)) return false;
            out = "translate(\"" + g_trContext + "\", " + src
                + (disambig.empty() ? "" : ", " + disambig) + ")";
            return true;
        }
        // plain call `name(args)` -> a method of this class (a QML `function`) or a signal emit.
        if (auto *fnId = cast<IdentifierExpression *>(call->base)) {
            std::string nm = qs(fnId->name.toString());
            // A signal emit: type each argument to the signal's declared parameter type.
            if (g_signals.count(nm)) {
                std::string joined; int i = 0;
                auto &params = g_signalParams[nm];
                for (auto *a = call->arguments; a; a = a->next, ++i) {
                    std::string s, at = (i < (int)params.size()) ? params[i].second : std::string();
                    if (!compileExpr(a->expression, QString::fromStdString(at), s)) return false;
                    joined += (joined.empty() ? "" : ", ") + s;
                }
                out = nm + ".emit(" + joined + ")";
                return true;
            }
            std::string joined;
            for (auto *a = call->arguments; a; a = a->next) {
                std::string s;
                if (!compileExpr(a->expression, dtype, s)) return false;
                joined += (joined.empty() ? "" : ", ") + s;
            }
            out = nm + "(" + joined + ")";
            // Coerce a double-returning function into an int target (QML coerces on assignment;
            // D has no implicit double->int). g_funcRet holds this object's function return types.
            auto it = g_funcRet.find(nm);
            if (it != g_funcRet.end() && it->second == "double" && dtype == "int") out = "cast(int)(" + out + ")";
            return true;
        }
        return false;
    }
    if (auto *str = cast<StringLiteral *>(e)) {
        // A colour literal stays a STRING here. It is written through the meta-object, and
        // QMetaType converts it to the property's declared QColor — calling QColor.fromString
        // would be doing by hand what the type system already does, and it drags the binding's
        // QColor module into every document that mentions a colour.
        out = dstr(str->value.toString());
        return true;
    }
    if (auto *num = cast<NumericLiteral *>(e)) { out = dnum(num->value, dtype == "int", false); return true; }
    if (cast<TrueLiteral *>(e))  { out = "true";  return true; }
    if (cast<FalseLiteral *>(e)) { out = "false"; return true; }
    if (auto *u = cast<UnaryMinusExpression *>(e)) {
        std::string inner;
        if (!compileExpr(u->expression, dtype, inner)) return false;
        out = "(-" + inner + ")"; return true;
    }
    if (auto *n = cast<NotExpression *>(e)) {
        std::string inner;
        if (!compileExpr(n->expression, "bool", inner)) return false;
        out = "(!" + inner + ")"; return true;
    }
    if (auto *cond = cast<ConditionalExpression *>(e)) {
        // ternary `c ? a : b`. The branches carry the target type; the condition is boolean.
        std::string c, a, b;
        if (!compileExpr(cond->expression, "bool", c)) return false;
        if (!compileExpr(cond->ok, dtype, a) || !compileExpr(cond->ko, dtype, b)) return false;
        out = "(" + c + " ? " + a + " : " + b + ")"; return true;
    }
    if (auto *bin = cast<BinaryExpression *>(e)) {
        // `contentItem as ListView` — a TYPE ASSERTION, not a conversion: it tells the engine's type
        // checker what to expect and leaves the value alone. Every read here goes through the
        // meta-object BY NAME, which does not consult the declared type, so the assertion has
        // nothing to change and the left side is the whole expression. (Qt's DialogButtonBox writes
        // `(contentItem as ListView)?.contentWidth`.)
        if (bin->op == QSOperator::As) return compileExpr(bin->left, dtype, out);
        // `Qt.styleHints` is the one object in these documents that no name in scope can reach: it
        // is QGuiApplication::styleHints(), a plain QObject. Everything BELOW it is ordinary —
        // `accessibility` is a QObject property, `contrastPreference` an enum one — so once the
        // root is expressible the existing channel walks the rest with propObj, for any depth and
        // any member, with no table of style-hint names anywhere.
        std::function<std::string(ExpressionNode *)> qtGlobalObj = [&](ExpressionNode *x) -> std::string {
            auto *f = cast<FieldMemberExpression *>(x);
            if (!f) return "";
            std::string mem = qs(f->name.toString());
            if (auto *b = cast<IdentifierExpression *>(f->base)) {
                std::string bn = qs(b->name.toString());
                if (bn != "Qt" || g_childIds.count(bn) || g_singletons.count(bn)
                        || isSelfId(bn)
                        || (!g_outerId.empty() && bn == g_outerId)) return "";
                return mem == "styleHints" ? "styleHintsObj()" : "";
            }
            std::string inner = qtGlobalObj(f->base);
            return inner.empty() ? "" : "propObj(" + inner + ", \"" + mem + "\")";
        };
        // `control.checkState === Qt.Checked` — comparing an ENUM property to an enum member. The
        // numeric value is not knowable here, but an enum property READ AS A STRING gives its KEY
        // (QVariant::toString goes through QMetaEnum), and the member's key is its own name. So
        // the comparison is done on keys, which needs no table of enum values at all.
        if (bin->op == QSOperator::StrictEqual || bin->op == QSOperator::Equal
                || bin->op == QSOperator::StrictNotEqual || bin->op == QSOperator::NotEqual) {
            auto enumKey = [&](ExpressionNode *x, std::string &key) {
                auto *fm2 = cast<FieldMemberExpression *>(x);
                if (!fm2) return false;
                // `T.ScrollBar.AlwaysOff` — the type is reached through an IMPORT ALIAS, so the base
                // is itself a member expression. Qt's controls import QtQuick.Templates as T and
                // spell every enum this way; the unqualified form already compiled, which is how the
                // alias was pinned as the only difference.
                if (auto *fmq = cast<FieldMemberExpression *>(fm2->base))
                    if (auto *ba2 = cast<IdentifierExpression *>(fmq->base);
                            ba2 && g_importAliases.count(qs(ba2->name.toString()))) {
                        std::string tq = qs(fmq->name.toString()), mq = qs(fm2->name.toString());
                        if (mq.empty() || !std::isupper((unsigned char) mq[0])) return false;
                        if (!knownTypeName(tq)) return false;
                        key = mq; return true;
                    }
                auto *b2 = cast<IdentifierExpression *>(fm2->base);
                if (!b2) return false;
                std::string tn = qs(b2->name.toString()), mem = qs(fm2->name.toString());
                if (mem.empty() || !std::isupper((unsigned char)mem[0])) return false;
                // A type name or the `Qt` global — never an object in scope, which would be a
                // plain property read and must keep compiling as one.
                if (g_childIds.count(tn) || g_singletons.count(tn)) return false;
                if (!g_outerId.empty() && tn == g_outerId) return false;
                if (!g_selfId.empty() && tn == g_selfId) return false;
                if (tn != "Qt" && !knownTypeName(tn)) return false;
                key = mem; return true;
            };
            // ...and the other side must be a property whose type we do NOT map to a D scalar,
            // which is exactly what an enum property looks like in the tables.
            auto enumRead = [&](ExpressionNode *x, std::string &outRead) {
                std::string tmp;
                // The BARE form of the same read: Qt's ScrollBar writes
                // `orientation === Qt.Horizontal`, not `control.orientation === ...`. Only the
                // qualified form was accepted, so the whole binding (`minimumSize`) was refused for
                // the spelling rather than for the shape.
                if (auto *idb = cast<IdentifierExpression *>(x)) {
                    std::string n0 = qs(idb->name.toString());
                    if (g_scope.count(n0) || g_childIds.count(n0) || g_vgroups.count(n0)) return false;
                    if (auto qp = g_qmlProps.find(g_selfQmlType);
                            qp != g_qmlProps.end() && qp->second.count(n0)) return false;   // a scalar
                    auto qc = g_qmlCxxType.find(g_selfQmlType);
                    if (qc == g_qmlCxxType.end() || !qc->second.count(n0)) return false;
                    outRead = "propStr(this, \"" + n0 + "\")";
                    return true;
                }
                auto *fm2 = cast<FieldMemberExpression *>(x);
                if (!fm2) return false;
                // `control.TabBar.position !== T.TabBar.Header` (Qt's Fusion TabButton, deciding
                // its own y). The read is an ATTACHED property on ANOTHER object, and it is an
                // ENUM — so the typed reader the ordinary attached path uses cannot answer it, but
                // the key channel can, exactly as for a plain enum property.
                if (auto *fmA2 = cast<FieldMemberExpression *>(fm2->base))
                    if (auto *bA2 = cast<IdentifierExpression *>(fmA2->base)) {
                        std::string tgtA, tqA, anA = qs(fmA2->name.toString());
                        std::string memA = qs(fm2->name.toString());
                        if (!anA.empty() && std::isupper((unsigned char) anA[0]) && g_qmlTypeUri.count(anA)
                                && objPathHead(qs(bA2->name.toString()), tgtA, tqA)) {
                            auto amA = g_qmlAttachedCxx.find(anA);
                            if (amA != g_qmlAttachedCxx.end() && amA->second.count(memA)) {
                                outRead = "propStr(" + attachedExprOn(tgtA, anA) + ", \"" + memA + "\")";
                                return true;
                            }
                        }
                    }
                // ...or a member of a Qt global object, whose base is a CHAIN, not an identifier.
                if (std::string go = qtGlobalObj(fm2->base); !go.empty()) {
                    outRead = "propStr(" + go + ", \"" + qs(fm2->name.toString()) + "\")";
                    return true;
                }
                // ...or a path of ANY DEPTH. `indicator.control.checkState === Qt.Checked` is how
                // Qt's Fusion writes it, and the base is then a path in its own right, not an
                // identifier. objPathExpr resolves the object AND reports the QML type it has,
                // which is exactly what the registry lookup below needs — so the same enum rule
                // applies at one hop or five, with no new vocabulary.
                if (!cast<IdentifierExpression *>(fm2->base)) {
                    std::string oe3, oq3, mem3 = qs(fm2->name.toString());
                    if (objPathExpr(fm2->base, oe3, oq3) && !oq3.empty()) {
                        if (auto qp = g_qmlProps.find(oq3);
                                qp != g_qmlProps.end() && qp->second.count(mem3)) return false;
                        if (auto qc = g_qmlCxxType.find(oq3);
                                qc == g_qmlCxxType.end() || !qc->second.count(mem3)) return false;
                        outRead = "propStr(" + oe3 + ", \"" + mem3 + "\")";
                        return true;
                    }
                    return false;
                }
                auto *b2 = cast<IdentifierExpression *>(fm2->base);
                if (!b2) return false;
                std::string bn = qs(b2->name.toString()), mem = qs(fm2->name.toString()), pre;
                const OuterFrame *fr = nullptr;
                std::string obj;
                if (outerHop(bn, pre, &fr)) obj = pre.substr(0, pre.size() - 1);
                else if (auto ci = g_childIds.find(bn); ci != g_childIds.end()) obj = ci->second.field;
                else if (isSelfId(bn)) obj = "this";
                else return false;
                const std::string &qt = fr ? fr->qmlType : g_selfQmlType;
                bool scalar = false;
                if (auto qp = g_qmlProps.find(qt); qp != g_qmlProps.end()) scalar = qp->second.count(mem) > 0;
                if (scalar) return false;
                if (auto qc = g_qmlCxxType.find(qt); qc == g_qmlCxxType.end() || !qc->second.count(mem))
                    return false;
                outRead = "propStr(" + obj + ", \"" + mem + "\")";
                return true;
            };
            // `parent?.parent === Overlay.overlay` (Qt's Dialog) compares OBJECT IDENTITY, not
            // values: both sides are objects, and D's `is` is the same test QML performs. Without
            // this the comparison fell through to the value paths and the whole binding was refused.
            {
                auto objSide = [&](ExpressionNode *x, std::string &oe) {
                    std::string oq;
                    if (objPathExpr(x, oe, oq)) return true;
                    if (auto *fmo = cast<FieldMemberExpression *>(x))
                        if (auto *bo = cast<IdentifierExpression *>(fmo->base)) {
                            std::string tn = qs(bo->name.toString()), mem = qs(fmo->name.toString());
                            if (g_scope.count(tn) || g_childIds.count(tn)) return false;
                            auto am = g_qmlAttachedCxx.find(tn);
                            if (am != g_qmlAttachedCxx.end() && am->second.count(mem)) {
                                oe = "propObj(" + attachedExpr(tn) + ", \"" + mem + "\")";
                                return true;
                            }
                        }
                    return false;
                };
                std::string l1, r1;
                if ((bin->op == QSOperator::StrictEqual || bin->op == QSOperator::StrictNotEqual)
                        && objSide(bin->left, l1) && objSide(bin->right, r1)) {
                    out = "(" + l1 + (bin->op == QSOperator::StrictEqual ? " is " : " !is ") + r1 + ")";
                    return true;
                }
            }
            // ...and the SAME read when the registry says the object's type does not declare that
            // member at all. QML is dynamically typed: Qt's Fusion CheckIndicator is used by
            // MenuItem, whose `control` has no `checkState`, and the engine evaluates the read as
            // `undefined` — which `=== Qt.PartiallyChecked` answers false. The meta channel gives
            // exactly that: a property the object does not declare reads as the empty string, and
            // no key equals it. Correct too if the object turns out to BE a CheckBox at runtime,
            // which the declared type cannot promise either way. Only offered against an enum KEY,
            // which is what makes a bare path unambiguous here.
            auto enumReadAny = [&](ExpressionNode *x, std::string &outRead) {
                if (enumRead(x, outRead)) return true;
                auto *fmL = cast<FieldMemberExpression *>(x);
                if (!fmL) return false;
                std::string oeL, oqL, memL = qs(fmL->name.toString());
                if (memL.empty() || std::isupper((unsigned char) memL[0])) return false;
                if (!objPathExpr(fmL->base, oeL, oqL)) return false;
                outRead = "propStr(" + oeL + ", \"" + memL + "\")";
                return true;
            };
            // `indicator.control.checkState === undefined` (Qt's Fusion CheckIndicator) asks
            // whether the object HAS the property at all — the declared type is AbstractButton,
            // which has no checkState, and the object put there may or may not be a CheckBox. The
            // meta channel answers exactly that question: a property the object does not declare
            // reads as the empty string, and one it does reads as its key.
            {
                auto isUndef = [&](ExpressionNode *x) {
                    auto *id = cast<IdentifierExpression *>(x);
                    if (!id) return false;
                    std::string n = qs(id->name.toString());
                    return n == "undefined" && !g_scope.count(n) && !g_childIds.count(n);
                };
                std::string rd;
                if ((isUndef(bin->right) && enumReadAny(bin->left, rd))
                        || (isUndef(bin->left) && enumReadAny(bin->right, rd))) {
                    bool neg = bin->op == QSOperator::StrictNotEqual || bin->op == QSOperator::NotEqual;
                    out = "(" + rd + (neg ? " != \"\")" : " == \"\")");
                    return true;
                }
            }
            std::string key, read;
            if ((enumKey(bin->right, key) && enumReadAny(bin->left, read))
                    || (enumKey(bin->left, key) && enumReadAny(bin->right, read))) {
                bool neg = bin->op == QSOperator::StrictNotEqual || bin->op == QSOperator::NotEqual;
                out = "(" + read + (neg ? " != \"" : " == \"") + key + "\")";
                return true;
            }
        }
        // Comparisons yield bool and their operands are NOT the target type; compile them with a
        // neutral hint so numeric-literal formatting isn't skewed by a string/bool target.
        bool cmp = false, logical = false;
        std::string op;
        switch (bin->op) {
        case QSOperator::And: op = "&&"; logical = true; break;   // QML `&&` (BitAnd is `&`)
        case QSOperator::Or:  op = "||"; logical = true; break;
        case QSOperator::Add: op = (dtype == "string") ? "~" : "+"; break;
        case QSOperator::Sub: if (dtype == "string") return false; op = "-"; break;
        case QSOperator::Mul: if (dtype == "string") return false; op = "*"; break;
        case QSOperator::Div: if (dtype == "string") return false; op = "/"; break;
        case QSOperator::Mod: if (dtype == "string") return false; op = "%"; break;
        case QSOperator::Lt: op = "<";  cmp = true; break;
        case QSOperator::Gt: op = ">";  cmp = true; break;
        case QSOperator::Le: op = "<="; cmp = true; break;
        case QSOperator::Ge: op = ">="; cmp = true; break;
        case QSOperator::Equal:
        case QSOperator::StrictEqual:    op = "==";  cmp = true; break;
        case QSOperator::NotEqual:
        case QSOperator::StrictNotEqual: op = "!=";  cmp = true; break;
        default: return false;   // logical/bitwise/in/instanceof -> later
        }
        // A logical operator in a NUMERIC target is not a bool operation: JS yields one of the
        // operands. Compiling `a || b` as `(bool || bool)` would assign 1 or 0 to a width — and in
        // practice it did not even compile, so the binding was refused and the property kept its
        // default of 0 while the engine computed 200.
        if (logical && (dtype == "double" || dtype == "int")) {
            std::string l2, r2;
            if (compileExpr(bin->left, dtype, l2) && compileExpr(bin->right, dtype, r2)) {
                out = std::string(bin->op == QSOperator::Or ? "__qmltcOr(" : "__qmltcAnd(")
                    + l2 + ", " + r2 + ")";
                return true;
            }
        }
        QString sub = logical ? QString("bool") : (cmp ? QString("") : dtype);
        std::string l, r;
        if (op == "~") {
            // JS `+` CONCATENATES when either side is a string, converting the other one
            // (`"n=" + 5` -> "n=5"). Two consequences, and getting either wrong is silent:
            //  - each side must be compiled with ITS OWN type, not with the string target.
            //    `"width=" + (a + b)` adds a and b NUMERICALLY and concatenates the result;
            //    propagating the string hint inward would make that inner `+` a concatenation
            //    too ("10" ~ "10" -> "1010" instead of 20).
            //  - D's `~` has no coercion, so a non-string side is converted explicitly.
            // A side whose type can't be inferred is left as-is: already a string, or a visible
            // compile error — never a silently wrong value.
            auto side = [](ExpressionNode *x, std::string &outS) {
                std::string ty = inferType(x, g_propType);
                if (!compileExpr(x, QString::fromStdString(ty.empty() ? "string" : ty), outS)) return false;
                if (!ty.empty() && ty != "string") outS = "to!string(" + outS + ")";
                return true;
            };
            if (!side(bin->left, l) || !side(bin->right, r)) return false;
        } else if (!compileExpr(bin->left, sub, l) || !compileExpr(bin->right, sub, r)) return false;
        out = "(" + l + " " + op + " " + r + ")"; return true;
    }
    return false;
}

// Collect every identifier referenced in an expression (mirrors compileExpr's node coverage).
// Intersected with the declared property names, this is a binding's dependency set — the
// properties whose change must trigger a re-evaluation (live binding).
static void collectIds(ExpressionNode *e, std::vector<std::string> &ids) {
    if (!e) return;
    if (auto *nested = cast<NestedExpression *>(e)) { collectIds(nested->expression, ids); return; }
    if (auto *id = cast<IdentifierExpression *>(e)) {
        auto n = qs(id->name.toString());
        // `undefined` is a LITERAL that the parser spells as an identifier, not a name that could
        // change: `x === undefined` reported a dead dependency on something that does not exist.
        if (n == "undefined" && !g_scope.count(n) && !g_childIds.count(n)) return;
        auto a = g_aliasDep.find(n);
        ids.push_back(a != g_aliasDep.end() ? a->second : n);   // through an alias -> its target
        return;
    }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        auto *base = cast<IdentifierExpression *>(fm->base);
        // `Text.AlignHCenter` — an enum member is a CONSTANT, not a dependency. Recording the type
        // name made the binding look like it depended on an object called `Text` and reported a
        // dead dependency for something that can never change.
        if (base) {
            std::string bn = qs(base->name.toString()), mem = qs(fm->name.toString());
            bool isObj = g_childIds.count(bn) || g_scope.count(bn) || g_singletons.count(bn)
                      || isSelfId(bn);
            if (!isObj)
                for (auto &f : g_outerChain) if (f.ids.count(bn)) isObj = true;
            // A SIBLING's id is an object too, and the dependency is on its MEMBER — recording the
            // bare id said "depends on 'handle', which has no known notify" for a read that is
            // perfectly connectable (Qt's Fusion SwitchIndicator sizes its groove from the handle
            // next to it). The dotted form is re-resolved by the wiring through the same rule.
            if (!isObj)
                for (auto &f : g_outerChain)
                    if (f.childIds.count(bn)) {
                        ids.push_back(bn + "." + mem);
                        return;
                    }
            if (!isObj && !mem.empty() && std::isupper((unsigned char)mem[0])
                    && (bn == "Qt" || g_qmlCxxType.count(bn)))
                return;
            // `<declaredObjProp>.<member>` — the dependency is on the MEMBER, not on the property
            // that holds the object: `control` on Qt's Fusion ButtonPanel never changes after the
            // use site assigns it, and what does change is `control.down`. Spelled with the hops so
            // the wiring re-resolves the same path the READ took.
            if (!mem.empty() && !std::isupper((unsigned char) mem[0])) {
                auto isDeclObj = [](const std::map<std::string, std::string> &m, const std::string &n) {
                    auto it = m.find(n);
                    return it != m.end() && it->second.size() > 1 && it->second[0] == '@';
                };
                if (isDeclObj(g_propType, bn)) { ids.push_back(bn + "." + mem); return; }
                std::string pre;
                for (auto &f : g_outerChain) {
                    pre += "__outer.";
                    if (isDeclObj(f.propType, bn)) { ids.push_back(pre + bn + "." + mem); return; }
                }
            }
            // `Qt.platform.pluginName` is a CONSTANT for the life of the process, like an enum
            // member: the platform does not change under a running application. Recording `Qt` as
            // a dependency reported a dead one for something that can never fire.
            if (bn == "Qt" && mem == "platform" && !g_scope.count(bn) && !g_childIds.count(bn))
                return;
            // `<obj>.<AttachedType>` used as a whole — the truth test above. WHETHER an object has
            // an attached object of some type does not change over its life, so this is a constant,
            // not a dependency; recording it reported "depends on 'Window', which has no known
            // notify" for a test that can never go stale.
            if (isObj && !mem.empty() && std::isupper((unsigned char) mem[0])
                    && g_qmlAttachedCxx.count(mem) && !g_scope.count(mem) && !g_childIds.count(mem))
                return;
            // An ATTACHED read (`Window.window`) is a real dependency on the ATTACHED object, not on
            // something named `Window` in scope. Tagged so the wiring connects to that object's own
            // notify — which qmlattached.tsv carries (windowChanged()).
            if (!isObj) {
                auto am = g_qmlAttachedCxx.find(bn);
                if (am != g_qmlAttachedCxx.end() && am->second.count(mem)) {
                    ids.push_back("@" + bn + "." + mem);
                    return;
                }
            }
        }
        // `T.ScrollBar.AlwaysOff` — an enum reached through an IMPORT ALIAS. Neither the alias nor
        // the type is a value, so neither is a dependency; recursing down to `T` recorded the alias
        // and reported that it has no notify. Same shape as the type name on the right of `as`.
        if (auto *fmq = cast<FieldMemberExpression *>(fm->base))
            if (auto *bq = cast<IdentifierExpression *>(fmq->base);
                    bq && g_importAliases.count(qs(bq->name.toString())))
                return;
        // `<outerId>.<objectProp>.<member>` (Qt's RangeSlider: `control.first.pressed`) is already a
        // DEEP READ: compileExpr records it in g_deepReads and the late phase wires it with
        // connectNotify/bindLeaf, which is what follows an object property that does not exist yet.
        // Recording a flat dep on `first` as well produced "depends on 'first', which has no known
        // notify" — correctly, since the grouped node never changes — and marked the file partial for
        // a dependency that IS handled. Say nothing here and let the deep-read path do it.
        // ...but ONLY when the middle really is an object property. `control.palette.text` has the
        // same shape and `palette` is a VALUE group: no deep read handles it, so staying silent here
        // dropped its dependency entirely — the colour was copied once and never again, with no
        // diagnostic saying so. Found by mutating `enabled` and comparing: the engine repaints the
        // text with the disabled palette, we kept the enabled one.
        if (auto *fmb4 = cast<FieldMemberExpression *>(fm->base))
            if (auto *b4 = cast<IdentifierExpression *>(fmb4->base)) {
                std::string pre4; const OuterFrame *fr4 = nullptr;
                if (outerHop(qs(b4->name.toString()), pre4, &fr4)) {
                    // Silent only when the middle has NO notify — `first` on a RangeSlider never
                    // changes, so depending on it is what produced a false "would not update", and
                    // the deep-read path handles that shape. `palette` DOES have one, and staying
                    // silent for it dropped the dependency outright: the colour was copied once and
                    // never again, with nothing reporting it. Found by mutating `enabled`.
                    std::string mid4 = qs(fmb4->name.toString());
                    if (auto qn4 = g_qmlNotify.find(fr4->qmlType); qn4 != g_qmlNotify.end())
                        if (auto nt4 = qn4->second.find(mid4);
                                nt4 != qn4->second.end() && !nt4->second.empty()) {
                            ids.push_back(pre4 + mid4);
                            return;
                        }
                    // The middle has no notify of its own (`searchIndicator` is a CONSTANT group),
                    // so depending on IT is the false "would not update" the RangeSlider case
                    // produced. Depend on the MEMBER, which does change — Qt's SearchField pads
                    // itself from `control.searchIndicator.indicator`, and recording nothing left
                    // that read connected to nothing, with no message.
                    ids.push_back(pre4 + mid4 + "." + qs(fm->name.toString()));
                    return;
                }
            }
        // `<AttachedType>.<group>.<member>` (SafeArea.margins.top): the dependency is the attached
        // GROUP, whose notify the attached table carries. Without this the read compiled and connected
        // to nothing — a binding that never updates AND no diagnostic saying so, which is worse than
        // refusing it.
        if (auto *fmb3 = cast<FieldMemberExpression *>(fm->base))
            if (auto *b3 = cast<IdentifierExpression *>(fmb3->base)) {
                std::string tn4 = qs(b3->name.toString()), grp4 = qs(fmb3->name.toString());
                auto am4 = g_qmlAttachedCxx.find(tn4);
                if (!g_scope.count(tn4) && !g_childIds.count(tn4) && am4 != g_qmlAttachedCxx.end()
                        && am4->second.count(grp4)) {
                    ids.push_back("@" + tn4 + "." + grp4);
                    return;
                }
            }
        // A read off the enclosing object is a real dependency: record it tagged, so the wiring
        // connects to the OUTER's notify instead of treating the binding as a constant.
        if (base && qs(base->name.toString()) == "parent" && !g_scope.count("parent")
                && !g_childIds.count("parent")) {
            if (!g_outerChain.empty()) {
                g_outerUsed = true;
                if (g_outerHopsNeeded < 0) g_outerHopsNeeded = 0;
                ids.push_back("__outer." + qs(fm->name.toString()));
            }
            return;
        }
        if (std::string pre; base) {
            const OuterFrame *fr = nullptr;
            if (outerHop(qs(base->name.toString()), pre, &fr)) {
                ids.push_back(pre + qs(fm->name.toString()));   // "__outer.__outer.gap"
                return;
            }
        }
        if (base && isSelfId(qs(base->name.toString()))) ids.push_back(qs(fm->name.toString()));
        // `group.member` depends on that member OF THE GROUP OBJECT — kept dotted so the wire
        // connects the group's own notify rather than looking for a property of this class.
        else if (base && g_groups.count(qs(base->name.toString())))
            ids.push_back(qs(base->name.toString()) + "." + qs(fm->name.toString()));
        // `<childId>.<prop>` — the notify belongs to the CHILD, which is compiled later, so record
        // that it must emit one for this property.
        else if (base && g_childIds.count(qs(base->name.toString()))) {
            std::string cid = qs(base->name.toString()), mem = qs(fm->name.toString());
            g_forceNotify[cid].insert(mem);
            ids.push_back(cid + "." + mem);
        }
        // likewise for a member of an ATTACHED object (`TestType.attachedCount`, possibly written
        // through the object's own id).
        else if (auto an = attachedNameOf(fm->base); !an.empty())
            ids.push_back(an + "." + qs(fm->name.toString()));
        else if (base && qs(base->name.toString()) == g_className && g_enumMember.count(qs(fm->name.toString()))) { /* enum member: constant, no dep */ }
        // An OBJECT PATH the registry can resolve: the dependency is the LEAF, on the object the
        // path reaches. Recording only the head (`searchIndicator`) named something that never
        // changes, so the binding was reported as unreactive for a member that has a notify.
        else if (std::string oe5, sig5; objPathFromString(
                     qs(base ? base->name.toString() : QString()) + "." + qs(fm->name.toString()),
                     oe5, sig5))
            ids.push_back(qs(base->name.toString()) + "." + qs(fm->name.toString()));
        // `Qt.styleHints.accessibility.contrastPreference` — the head is the QML global, which is
        // not a property of anything. Recording it (which is what recursing down to `Qt` did) named
        // something that cannot change and reported "would not update" for a binding that DOES.
        // The whole path is recorded instead; the wiring connects through the meta-object by name.
        else if (std::string qp2; [&]{
                     std::function<bool(ExpressionNode *, std::string &)> path =
                         [&](ExpressionNode *x, std::string &outp) -> bool {
                         if (auto *idq = cast<IdentifierExpression *>(x)) {
                             outp = qs(idq->name.toString());
                             return outp == "Qt" && !g_scope.count("Qt") && !g_childIds.count("Qt");
                         }
                         if (auto *fq = cast<FieldMemberExpression *>(x)) {
                             std::string h;
                             if (!path(fq->base, h)) return false;
                             outp = h + "." + qs(fq->name.toString());
                             return true;
                         }
                         return false;
                     };
                     return path(fm, qp2) && qp2.rfind("Qt.styleHints.", 0) == 0;
                 }())
            ids.push_back(qp2);
        // A DEEP object path whose head is not an id: `background.border.width`, where `background`
        // is a property of the enclosing object. The branch above only handles a two-hop path off an
        // identifier, so this fell through to the recursion and recorded the HEAD — and `background`
        // has no D-typed row (object properties carry no scalar type), so the wiring reported "no
        // known notify" for a path whose leaf has one. Record the whole path: the wire re-resolves
        // it with the same walk and connects on the leaf.
        else if (std::string dp7, oe7, sig7; [&]{
                     std::function<bool(ExpressionNode *, std::string &)> path7 =
                         [&](ExpressionNode *x, std::string &outp) -> bool {
                         if (auto *idq = cast<IdentifierExpression *>(x)) {
                             outp = qs(idq->name.toString());
                             return true;
                         }
                         if (auto *fq = cast<FieldMemberExpression *>(x)) {
                             std::string h;
                             if (!path7(fq->base, h)) return false;
                             outp = h + "." + qs(fq->name.toString());
                             return true;
                         }
                         return false;
                     };
                     return path7(fm, dp7) && objPathFromString(dp7, oe7, sig7);
                 }())
            ids.push_back(dp7);
        else collectIds(fm->base, ids);   // e.g. `title.length` depends on title
        return;
    }
    if (auto *call = cast<CallExpression *>(e)) {
        for (auto *a = call->arguments; a; a = a->next) collectIds(a->expression, ids);
        // A no-arg function call depends on whatever that function reads (transitive).
        if (!call->arguments)
            if (auto *fnId = cast<IdentifierExpression *>(call->base)) {
                auto it = g_funcReads.find(qs(fnId->name.toString()));
                if (it != g_funcReads.end()) for (auto &r : it->second) ids.push_back(r);
            }
        return;
    }
    if (auto *u = cast<UnaryMinusExpression *>(e)) { collectIds(u->expression, ids); return; }
    if (auto *n = cast<NotExpression *>(e)) { collectIds(n->expression, ids); return; }
    if (auto *c = cast<ConditionalExpression *>(e)) {
        collectIds(c->expression, ids); collectIds(c->ok, ids); collectIds(c->ko, ids); return;
    }
    if (auto *b = cast<BinaryExpression *>(e)) {
        // The right side of `x as T` is a TYPE, not a value: descending into it recorded the type
        // name as a dependency and reported "ListView has no known notify".
        if (b->op == QSOperator::As) { collectIds(b->left, ids); return; }
        collectIds(b->left, ids); collectIds(b->right, ids); return; }
}

struct Prop { std::string name, dtype, expr; bool bound; std::vector<std::string> deps;
              std::vector<DeepRead> deep; };   // reads through an object property -> late connects

// Compile a signal-handler body (a JS statement) to D. Supports a single assignment
// `prop = <expr>` or a brace block of them; the LHS must be a known property (its type drives the
// RHS). Returns false on anything else (calls, control flow, ...) -> the handler is reported and
// skipped, never mis-emitted. `body` accumulates D statements (already indented).
// Bottom-up type of an expression: "int" | "double" | "string" | "bool" | "" (unknown). Mirrors
// compileExpr's node coverage. Numbers follow JS/QML: division is always double, an integral
// literal is int and a fractional literal double, `+` with any string operand is string. Used to
// give a QML `function`'s no-arg return a D type and to coerce it at a call site.
static std::string inferType(ExpressionNode *e, const std::map<std::string, std::string> &ptype) {
    if (!e) return "";
    if (auto *call = cast<CallExpression *>(e))
        if (auto *fnId = cast<IdentifierExpression *>(call->base);
                fnId && qs(fnId->name.toString()) == "qsTr") return "string";
    if (auto *n = cast<NestedExpression *>(e)) return inferType(n->expression, ptype);
    if (auto *id = cast<IdentifierExpression *>(e)) {
        std::string n = qs(id->name.toString());
        auto it = ptype.find(n); if (it != ptype.end()) return it->second;
        auto bp = g_baseProps.find(n); if (bp != g_baseProps.end()) return bp->second;
        return "";
    }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && isSelfId(qs(base->name.toString()))) { auto it = ptype.find(qs(fm->name.toString())); return it != ptype.end() ? it->second : ""; }
        if (base && qs(base->name.toString()) == g_className && g_enumMember.count(qs(fm->name.toString()))) return "int";   // enum member
        if (qs(fm->name.toString()) == "length") return "int";
        return "";
    }
    if (cast<StringLiteral *>(e)) return "string";
    if (auto *num = cast<NumericLiteral *>(e)) return (num->value == (long long)num->value) ? "int" : "double";
    if (cast<TrueLiteral *>(e) || cast<FalseLiteral *>(e)) return "bool";
    if (auto *u = cast<UnaryMinusExpression *>(e)) return inferType(u->expression, ptype);
    if (cast<NotExpression *>(e)) return "bool";
    if (auto *c = cast<ConditionalExpression *>(e)) { auto t = inferType(c->ok, ptype); return t.empty() ? inferType(c->ko, ptype) : t; }
    if (auto *b = cast<BinaryExpression *>(e)) {
        switch (b->op) {
        case QSOperator::Lt: case QSOperator::Gt: case QSOperator::Le: case QSOperator::Ge:
        case QSOperator::Equal: case QSOperator::NotEqual: case QSOperator::StrictEqual:
        case QSOperator::StrictNotEqual: case QSOperator::And: case QSOperator::Or: return "bool";
        case QSOperator::Div: return "double";
        case QSOperator::Add: {
            auto l = inferType(b->left, ptype), r = inferType(b->right, ptype);
            if (l == "string" || r == "string") return "string";
            return (l == "double" || r == "double") ? "double" : "int";
        }
        default: {   // Sub, Mul, Mod
            auto l = inferType(b->left, ptype), r = inferType(b->right, ptype);
            return (l == "double" || r == "double") ? "double" : "int";
        }
        }
    }
    if (auto *call = cast<CallExpression *>(e)) {
        auto *fm = cast<FieldMemberExpression *>(call->base);
        auto *recv = fm ? cast<IdentifierExpression *>(fm->base) : nullptr;
        if (recv && qs(recv->name.toString()) == "Math") {
            std::string fn = qs(fm->name.toString());
            if ((fn == "max" || fn == "min" || fn == "abs") && call->arguments) return inferType(call->arguments->expression, ptype);
            return "double";
        }
        // Qt.darker/Qt.lighter yield a COLOUR, which travels as text here.
        if (recv && qs(recv->name.toString()) == "Qt") {
            std::string fn = qs(fm->name.toString());
            if (fn == "darker" || fn == "lighter" || fn == "alpha") return "string";
        }
        if (auto *fnId = cast<IdentifierExpression *>(call->base)) { auto it = g_funcRet.find(qs(fnId->name.toString())); return it != g_funcRet.end() ? it->second : ""; }
    }
    return "";
}

// Does `e` use param `p` as a string (an operand of `+` whose sibling is a string)? QML params are
// untyped; numeric params become D `double` (JS number semantics), string params `string`.
static bool paramIsString(const std::string &p, ExpressionNode *e, const std::map<std::string, std::string> &ptype) {
    if (!e) return false;
    if (auto *n = cast<NestedExpression *>(e)) return paramIsString(p, n->expression, ptype);
    if (auto *u = cast<UnaryMinusExpression *>(e)) return paramIsString(p, u->expression, ptype);
    if (auto *nt = cast<NotExpression *>(e)) return paramIsString(p, nt->expression, ptype);
    if (auto *c = cast<ConditionalExpression *>(e)) return paramIsString(p, c->expression, ptype) || paramIsString(p, c->ok, ptype) || paramIsString(p, c->ko, ptype);
    if (auto *b = cast<BinaryExpression *>(e)) {
        if (b->op == QSOperator::Add) {
            auto isP = [&](ExpressionNode *x){ auto *id = cast<IdentifierExpression *>(x); return id && qs(id->name.toString()) == p; };
            if ((isP(b->left) && inferType(b->right, ptype) == "string") || (isP(b->right) && inferType(b->left, ptype) == "string")) return true;
        }
        return paramIsString(p, b->left, ptype) || paramIsString(p, b->right, ptype);
    }
    if (auto *call = cast<CallExpression *>(e)) for (auto *a = call->arguments; a; a = a->next) if (paramIsString(p, a->expression, ptype)) return true;
    return false;
}

// Evidence in a function BODY for what a formal's type must be. A QML formal is untyped, and
// assuming `double` everywhere emits D that does not compile: `function f(x) { stringProp = x }`
// needs a string, and passing a formal to a declared signal needs that signal's parameter type.
// Returns "" when the body says nothing.
static std::string paramTypeFromBody(const std::string &p, Node *n,
                                     const std::map<std::string, std::string> &pt0) {
    if (!n) return "";
    if (auto *blk = cast<Block *>(n)) {
        for (auto *st = blk->statements; st; st = st->next)
            if (auto t = paramTypeFromBody(p, st->statement, pt0); !t.empty()) return t;
        return "";
    }
    if (auto *iff = cast<IfStatement *>(n)) {
        if (auto t = paramTypeFromBody(p, iff->ok, pt0); !t.empty()) return t;
        return paramTypeFromBody(p, iff->ko, pt0);
    }
    auto *es = cast<ExpressionStatement *>(n);
    if (!es) return "";
    // `someProperty = p` -> p has that property's declared type.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *rhs = cast<IdentifierExpression *>(bin->right); rhs && qs(rhs->name.toString()) == p)
            if (auto *lhs = cast<IdentifierExpression *>(bin->left)) {
                auto it = pt0.find(qs(lhs->name.toString()));
                if (it != pt0.end()) return it->second;
            }
    // `declaredSignal(..., p, ...)` -> p has the signal parameter's declared type.
    if (auto *call = cast<CallExpression *>(es->expression))
        if (auto *fnId = cast<IdentifierExpression *>(call->base)) {
            auto sp = g_signalParams.find(qs(fnId->name.toString()));
            if (sp != g_signalParams.end()) {
                int i = 0;
                for (auto *a = call->arguments; a; a = a->next, ++i)
                    if (auto *id = cast<IdentifierExpression *>(a->expression);
                            id && qs(id->name.toString()) == p && i < (int)sp->second.size())
                        return sp->second[i].second;
            }
        }
    return "";
}

// (name, D type) for each formal parameter of a function.
// A CALL SITE reduces the type graph just as a typed body does: `times2(base)` where `base` is
// `property int base` pins the parameter, and no guess is involved. Collected per class before
// the functions are emitted; a parameter with conflicting call sites keeps an empty set and is
// refused, since picking one of two observed types would be the same guess in a new place.
static std::map<std::string, std::vector<std::set<std::string>>> g_callArgs;

struct CallArgScan : Visitor {
    const std::map<std::string, std::string> *pt = nullptr;
    void throwRecursionDepthError() override {}
    bool visit(CallExpression *c) override {
        if (auto *fnId = cast<IdentifierExpression *>(c->base)) {
            std::string n = qs(fnId->name.toString());
            size_t i = 0;
            for (auto *a = c->arguments; a; a = a->next, ++i) {
                std::string t = inferType(a->expression, *pt);
                auto &v = g_callArgs[n];
                if (v.size() <= i) v.resize(i + 1);
                if (t == "int" || t == "double" || t == "string" || t == "bool") v[i].insert(t);
                else v[i].insert("");   // an un-inferable argument poisons the slot
            }
        }
        return true;
    }
};

static std::vector<std::pair<std::string, std::string>> funcParams(FunctionExpression *fn, const std::map<std::string, std::string> &pt0) {
    ExpressionNode *ret = nullptr;
    if (fn->body && !fn->body->next) if (auto *r = cast<ReturnStatement *>(fn->body->statement)) ret = r->expression;
    std::vector<std::pair<std::string, std::string>> ps;
    for (auto *f = fn->formals; f; f = f->next)
        if (f->element) {
            std::string pn = qs(f->element->bindingIdentifier.toString());
            std::string ty;
            for (auto *st = fn->body; st && ty.empty(); st = st->next)
                ty = paramTypeFromBody(pn, st->statement, pt0);   // body evidence wins
            // Inference is only sound when the type graph REDUCES to a definite type: the body
            // uses the parameter with something typed, or the return expression does. With no
            // such evidence, `double` was a GUESS — and a wrong one for `f("a","b")`, where QML
            // concatenates and the generated D would add. Qt refuses these outright
            // ("Functions without type annotations won't be compiled"); an empty type here means
            // the same, and the caller reports it.
            if (ty.empty() && ret && paramIsString(pn, ret, pt0)) ty = "string";
            if (ty.empty()) {   // no body evidence: the call sites may still pin it
                auto ca = g_callArgs.find(qs(fn->name.toString()));
                if (ca != g_callArgs.end() && ps.size() < ca->second.size()) {
                    auto &slot = ca->second[ps.size()];
                    if (slot.size() == 1 && !slot.begin()->empty()) ty = *slot.begin();
                }
            }
            ps.push_back({pn, ty});
        }
    return ps;
}

static bool compileStmtList(StatementList *list, const std::map<std::string, std::string> &ptype, std::string &body);

// `st` is a Node* (a StatementList element is a Node*, since FunctionDeclaration doesn't inherit
// Statement) — the specific statement kinds are recovered by cast<> below.
static bool compileStmt(Node *st, const std::map<std::string, std::string> &ptype, std::string &body) {
    // A brace block `{ a = ...; b = ...; }` -> each statement in order.
    if (auto *blk = cast<Block *>(st)) return compileStmtList(blk->statements, ptype, body);
    // `var c = <expr>` -> a D local (`auto c = ...`). Type inferred for correct numeric formatting.
    if (auto *vs = cast<VariableStatement *>(st)) {
        for (auto *d = vs->declarations; d; d = d->next) {
            auto *pe = d->declaration;
            if (!pe || pe->bindingIdentifier.isEmpty() || !pe->initializer) return false;
            std::string ty = inferType(pe->initializer, ptype), init;
            if (!compileExpr(pe->initializer, QString::fromStdString(ty), init)) return false;
            body += "        auto " + qs(pe->bindingIdentifier.toString()) + " = " + init + ";\n";
            g_scope.insert(qs(pe->bindingIdentifier.toString()));   // in scope for the rest of the body
        }
        return true;
    }
    // `return <expr>` -> D return, formatted for the enclosing function's return type.
    if (auto *ret = cast<ReturnStatement *>(st)) {
        if (!ret->expression) { body += "        return;\n"; return true; }
        std::string r;
        if (!compileExpr(ret->expression, QString::fromStdString(g_returnType), r)) return false;
        body += "        return " + r + ";\n";
        return true;
    }
    // `if (cond) <then> [else <else>]` -> D if/else (braces around each branch).
    if (auto *iff = cast<IfStatement *>(st)) {
        std::string cond, thenB;
        if (!compileExpr(iff->expression, "bool", cond) || !compileStmt(iff->ok, ptype, thenB)) return false;
        body += "        if (" + cond + ") {\n" + thenB + "        }";
        if (iff->ko) {
            std::string elseB;
            if (!compileStmt(iff->ko, ptype, elseB)) return false;
            body += " else {\n" + elseB + "        }";
        }
        body += "\n";
        return true;
    }
    auto *es = cast<ExpressionStatement *>(st);
    if (!es) return false;
    // `p = <value>` on a property that carries a binding REMOVES that binding in QML. The
    // selector records it so the declarative recompute stops driving the property.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *lhs = cast<IdentifierExpression *>(bin->left);
                lhs && !cast<CallExpression *>(bin->right)
                && (g_hasSelector.count(qs(lhs->name.toString()))
                    || (g_aliasDep.count(qs(lhs->name.toString()))
                        && g_hasSelector.count(g_aliasDep[qs(lhs->name.toString())])))) {
            std::string nm = qs(lhs->name.toString()), val;
            if (auto a = g_aliasDep.find(nm); a != g_aliasDep.end()) nm = a->second;
            auto ty = g_propType.count(nm) ? g_propType[nm] : std::string();
            if (ty.empty() || !compileExpr(bin->right, QString::fromStdString(ty), val)) return false;
            body += "        __bind_" + nm + " = -1;\n        " + nm + " = " + val + ";\n";
            return true;
        }
    // `p = Qt.binding(function(){ return <expr> })` — install a NEW binding on p at runtime.
    // Compiled as an extra recompute slot guarded by p's selector; the assignment just switches
    // the selector and evaluates once. The new binding's dependencies are connected up front.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *lhs = cast<IdentifierExpression *>(bin->left))
            if (auto *call = cast<CallExpression *>(bin->right))
                if (auto *fm = cast<FieldMemberExpression *>(call->base))
                    if (auto *b = cast<IdentifierExpression *>(fm->base);
                            b && qs(b->name.toString()) == "Qt"
                            && qs(fm->name.toString()) == "binding" && call->arguments) {
                        std::string nm = qs(lhs->name.toString());
                        if (auto a = g_aliasDep.find(nm); a != g_aliasDep.end()) nm = a->second;
                        auto *fe = call->arguments->expression->asFunctionDefinition();
                        auto *ret = fe && fe->body ? findReturnExpr(fe->body) : nullptr;
                        auto ty = g_propType.count(nm) ? g_propType[nm] : std::string();
                        std::string expr;
                        if (!ret || ty.empty() || !compileExpr(ret, QString::fromStdString(ty), expr))
                            return false;
                        std::vector<std::string> deps;
                        collectIds(ret, deps);
                        int idx = (int) g_rebinds[nm].size() + 1;
                        g_rebinds[nm].push_back({idx, expr, deps});
                        body += "        __bind_" + nm + " = " + std::to_string(idx) + ";\n"
                              + "        __rc_" + nm + "_" + std::to_string(idx) + "();\n";
                        return true;
                    }
    // `<selfId>.prop = <expr>` — the object's own property, written through its id.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *fm = cast<FieldMemberExpression *>(bin->left))
            if (auto *b = cast<IdentifierExpression *>(fm->base);
                    b && isSelfId(qs(b->name.toString()))
                    && attachedNameOf(fm->base).empty() && groupNameOf(fm->base).empty()) {
                std::string nm = qs(fm->name.toString()), val;
                auto ty = ptype.find(nm) != ptype.end() ? ptype.at(nm)
                        : (g_propType.count(nm) ? g_propType[nm] : "");
                if (ty.empty() || !compileExpr(bin->right, QString::fromStdString(ty), val)) return false;
                std::string lv;
                if (!readName(nm, lv)) return false;
                // QML converts the value to the property's declared type; D will not narrow
                // implicitly (`lastWidth = width` is int <- qreal on an Item).
                body += "        " + lv + " = " + coerceTo(ty, val) + ";\n";
                return true;
            }
    // `Type.member = <expr>` / `Type.member++` / `Type.<signal>()` on an ATTACHED object.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *fm = cast<FieldMemberExpression *>(bin->left)) {
            std::string an = attachedNameOf(fm->base);
            if (!an.empty()) {
                std::string mem = qs(fm->name.toString()), val;
                auto mt = g_attached[an]->propType.find(mem);
                if (mt == g_attached[an]->propType.end()
                        || !compileExpr(bin->right, QString::fromStdString(mt->second), val)) return false;
                body += "        setProp(" + attachedExpr(an) + ", \"" + mem + "\", " + val + ");\n";
                return true;
            }
        }
    if (auto *call = cast<CallExpression *>(es->expression); call && !call->arguments)
        if (auto *fm = cast<FieldMemberExpression *>(call->base)) {
            std::string an = attachedNameOf(fm->base);
            if (!an.empty() && g_attached[an]->signalSig.count(qs(fm->name.toString()))) {
                body += "        invoke0(" + attachedExpr(an) + ", \"" + qs(fm->name.toString()) + "\");\n";
                return true;
            }
        }
    // `<objPath>.<method>(a, b)` — a method WITH arguments. Qt's DeleteAction writes
    // `editor.remove(editor.selectionStart, editor.selectionEnd)`. Same channel a singleton call
    // uses: each argument crosses as TEXT and QMetaType converts it to the parameter's own type,
    // so the only thing needed beyond the no-argument case is the argument list. The result is
    // discarded, which is what a statement does with it.
    if (auto *call = cast<CallExpression *>(es->expression); call && call->arguments)
        if (auto *fm = cast<FieldMemberExpression *>(call->base)) {
            std::string oe, oq, mem = qs(fm->name.toString());
            if (objPathExpr(fm->base, oe, oq) && !oq.empty()) {
                // The PARAMETER TYPES decide how each argument crosses, exactly as they do for a
                // singleton call: a number has to be spelled as text with numText (to!string gives
                // six digits), and anything else compiles as text directly. Guessing per-argument
                // instead put a `double` where invokeMixed wants a string and the generated D did
                // not compile.
                size_t nargs = 0;
                for (auto *a = call->arguments; a; a = a->next) ++nargs;
                const std::vector<std::string> *ptypes = nullptr;
                if (auto mi = g_qmlMethods.find(oq); mi != g_qmlMethods.end())
                    if (auto it = mi->second.find(mem); it != mi->second.end())
                        for (auto &ov : it->second) if (ov.second.size() == nargs) ptypes = &ov.second;
                bool known = ptypes != nullptr;
                std::vector<std::string> as;
                bool ok = true;
                size_t pi = 0;
                for (auto *a = call->arguments; a && ok; a = a->next, ++pi) {
                    std::string one;
                    std::string pt = ptypes ? (*ptypes)[pi] : inferType(a->expression, ptype);
                    bool num = pt == "double" || pt == "qreal" || pt == "float" || pt == "int"
                            || pt == "uint" || pt == "bool";
                    if (num && compileExpr(a->expression, pt == "bool" ? "bool" : "double", one))
                        as.push_back(pt == "bool" ? "to!string(" + one + ")" : "numText(" + one + ")");
                    else if (!num && compileExpr(a->expression, "string", one)) as.push_back(one);
                    else ok = false;
                }
                if (ok && (known || typeKnownWithoutMember(oq, mem))) {
                    std::string args;
                    for (auto &a : as) args += ", " + a;
                    body += "        invokeMixed(" + oe + ", \"" + mem + "\"" + args + ");\n";
                    return true;
                }
            }
        }
    // `<objPath>.<method>()` — a no-argument METHOD on an object the document can name. Qt's seven
    // editing Actions are all `onTriggered: editor.undo()`, where `editor` is a declared object
    // property. The registry publishes methods per type now, so this is a row lookup rather than a
    // guess: only a method the type declares, and only one that takes no parameters (an argument
    // would have to be marshalled, which is the invokable path and a different shape).
    if (auto *call = cast<CallExpression *>(es->expression); call && !call->arguments)
        if (auto *fm = cast<FieldMemberExpression *>(call->base)) {
            std::string oe, oq, mem = qs(fm->name.toString());
            if (objPathExpr(fm->base, oe, oq) && !oq.empty()) {
                if (auto mi = g_qmlMethods.find(oq); mi != g_qmlMethods.end())
                    if (auto it = mi->second.find(mem); it != mi->second.end())
                        for (auto &ov : it->second)
                            if (ov.second.empty()) {
                                body += "        invoke0(" + oe + ", \"" + mem + "\");\n";
                                return true;
                            }
                // ...and a method the DECLARED type does not have. QML is dynamically typed and Qt
                // relies on it here too: the editing Actions declare `property Item editor` and
                // call `editor.undo()`, which no Item has — the object put there is a TextInput.
                // The invoke resolves by name at runtime and returns false when there is nothing to
                // call, which is the engine's own outcome for the same line.
                if (typeKnownWithoutMember(oq, mem)) {
                    body += "        invoke0(" + oe + ", \"" + mem + "\");\n";
                    return true;
                }
            }
        }
    // `group.<signal>()` — emit a signal that belongs to the GROUP object, not to this one.
    if (auto *call = cast<CallExpression *>(es->expression); call && !call->arguments)
        if (auto *fm = cast<FieldMemberExpression *>(call->base))
            if (auto *b = cast<IdentifierExpression *>(fm->base)) {
                auto g = g_groups.find(qs(b->name.toString()));
                if (g != g_groups.end() && g->second->signalSig.count(qs(fm->name.toString()))) {
                    body += "        invoke0(propObj(this, \"" + qs(b->name.toString()) + "\"), \""
                          + qs(fm->name.toString()) + "\");\n";
                    return true;
                }
            }
    // `aliasName = <expr>` inside a body — same reference semantics as the declarative form.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *lhs = cast<IdentifierExpression *>(bin->left)) {
            auto aw = g_aliasWrite.find(qs(lhs->name.toString()));
            if (aw != g_aliasWrite.end()) {
                if (isUndefined(bin->right)) {   // reset through the alias
                    std::string call;
                    if (!resetCall(aw->second.first, aw->second.second, call)) return false;
                    body += call; return true;
                }
                std::string ty = g_propType.count(qs(lhs->name.toString())) ? g_propType[qs(lhs->name.toString())] : "";
                std::string val;
                if (ty.empty() || !compileExpr(bin->right, QString::fromStdString(ty), val)) return false;
                body += "        setProp(" + aw->second.first + ", \"" + aw->second.second + "\", " + val + ");\n";
                return true;
            }
        }
    // `group.member = <expr>` — assign through the group object (a meta-object hop), the write
    // counterpart of reading `group.member` in an expression.
    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
        if (auto *fm = cast<FieldMemberExpression *>(bin->left))
            if (auto *b = cast<IdentifierExpression *>(fm->base)) {
                auto g = g_groups.find(qs(b->name.toString()));
                if (g != g_groups.end()) {
                    std::string mem = qs(fm->name.toString());
                    auto mt = g->second->propType.find(mem);
                    std::string val;
                    if (mt == g->second->propType.end()
                            || !compileExpr(bin->right, QString::fromStdString(mt->second), val))
                        return false;
                    body += "        setProp(propObj(this, \"" + qs(b->name.toString()) + "\"), \""
                          + mem + "\", " + val + ");\n";
                    return true;
                }
                // A VALUE group member: read-modify-write-back, not a write into an object.
                auto vg = g_vgroups.find(qs(b->name.toString()));
                if (vg != g_vgroups.end()) {
                    std::string mem = qs(fm->name.toString());
                    auto mt = vg->second->propType.find(mem);
                    std::string val;
                    if (mt == vg->second->propType.end()
                            || !compileExpr(bin->right, QString::fromStdString(mt->second), val))
                        return false;
                    body += "        setVgroup(this, \"" + qs(b->name.toString()) + "\", \""
                          + mem + "\", " + val + ");\n";
                    return true;
                }
            }
    // `x++` / `++x` / `x--` / `--x` on a property -> the same in D.
    {
        ExpressionNode *inner = nullptr;
        const char *op = nullptr;
        if (auto *p = cast<PreIncrementExpression *>(es->expression)) { inner = p->expression; op = "++"; }
        else if (auto *p = cast<PostIncrementExpression *>(es->expression)) { inner = p->base; op = "++"; }
        else if (auto *p = cast<PreDecrementExpression *>(es->expression)) { inner = p->expression; op = "--"; }
        else if (auto *p = cast<PostDecrementExpression *>(es->expression)) { inner = p->base; op = "--"; }
        if (inner) {
            // `Type.member++` on an attached object: same read-modify-write shape.
            if (auto *fm = cast<FieldMemberExpression *>(inner)) {
                std::string an = attachedNameOf(fm->base);
                if (!an.empty()) {
                    std::string mem = qs(fm->name.toString()), rd;
                    auto mt = g_attached[an]->propType.find(mem);
                    if (mt == g_attached[an]->propType.end() || !compileExpr(inner, "", rd)) return false;
                    body += "        setProp(" + attachedExpr(an) + ", \"" + mem + "\", cast(" + mt->second
                          + ")(" + rd + (op[0] == '+' ? " + 1" : " - 1") + "));\n";
                    return true;
                }
            }
            // `group.member++` has no D lvalue — it is a read-modify-write through the group.
            if (auto *fm = cast<FieldMemberExpression *>(inner))
                if (auto *b = cast<IdentifierExpression *>(fm->base)) {
                    auto g = g_groups.find(qs(b->name.toString()));
                    if (g != g_groups.end()) {
                        std::string mem = qs(fm->name.toString()), rd;
                        auto mt = g->second->propType.find(mem);
                        if (mt == g->second->propType.end() || !compileExpr(inner, "", rd)) return false;
                        std::string gobj = "propObj(this, \"" + qs(b->name.toString()) + "\")";
                        body += "        setProp(" + gobj + ", \"" + mem + "\", cast(" + mt->second
                              + ")(" + rd + (op[0] == '+' ? " + 1" : " - 1") + "));\n";
                        return true;
                    }
                }
            std::string lv;   // the lvalue: an identifier or a self member (`foo.count` -> count)
            if (!compileExpr(inner, "", lv)) return false;
            body += "        " + lv + op + ";\n";
            return true;
        }
    }
    // `console.log(...)` / console.warn/etc. -> no-op (no observable effect on property state).
    if (auto *call = cast<CallExpression *>(es->expression))
        if (auto *fm = cast<FieldMemberExpression *>(call->base))
            if (auto *recv = cast<IdentifierExpression *>(fm->base))
                if (qs(recv->name.toString()) == "console") return true;
    // Assignment `prop = <expr>` and compound assignment `prop += <expr>` (etc.).
    if (auto *bin = cast<BinaryExpression *>(es->expression)) {
        const char *aop = nullptr;
        switch (bin->op) {
        case QSOperator::Assign:      aop = "="; break;
        case QSOperator::InplaceAdd:  aop = "+="; break;   // QML string += is concat; D uses ~=
        case QSOperator::InplaceSub:  aop = "-="; break;
        case QSOperator::InplaceMul:  aop = "*="; break;
        case QSOperator::InplaceDiv:  aop = "/="; break;
        default: break;
        }
        if (aop) {
            auto *lhs = cast<IdentifierExpression *>(bin->left);
            if (!lhs) return false;
            std::string name = qs(lhs->name.toString());
            auto it = ptype.find(name);
            if (it == ptype.end()) return false;
            std::string op = aop;
            if (op == "+=" && it->second == "string") op = "~=";   // string concat-assign
            std::string rhs;
            if (!compileExpr(bin->right, QString::fromStdString(it->second), rhs)) return false;
            // QML converts the value to the target's declared type; D refuses to narrow
            // implicitly, and a qreal base property read (`lastWidth = width`) is exactly that.
            body += "        " + name + " " + op + " "
                  + (std::string(op) == "=" ? coerceTo(it->second, rhs) : rhs) + ";\n";
            return true;
        }
    }
    // Bare call statement `foo()` (calling a QML function of this class).
    if (cast<CallExpression *>(es->expression)) {
        std::string c;
        if (compileExpr(es->expression, "", c)) { body += "        " + c + ";\n"; return true; }
    }
    return false;
}

// Compile a StatementList (a function body or block). `statement` is a Node* (FunctionDeclaration
// doesn't inherit Statement); the list is linear in the finished AST. Only statements compileStmt
// understands (assignment / bare call) are allowed — anything else fails and the caller reports it.
static bool compileStmtList(StatementList *list, const std::map<std::string, std::string> &ptype, std::string &body) {
    for (auto *s = list; s; s = s->next)
        if (!compileStmt(s->statement, ptype, body)) return false;   // s->statement is a Node*
    return true;
}

// The first top-level `return <expr>` in a function body (for return-type inference), or null.
static ExpressionNode *findReturnExpr(StatementList *body) {
    for (auto *s = body; s; s = s->next)
        if (auto *r = cast<ReturnStatement *>(s->statement)) return r->expression;
    return nullptr;
}

// The emitted shape of an object: its scalar properties (name+type) and its child objects
// (field name + subtree). Used to generate the differential dump with dotted paths (`kid.y`).
// Local-type files currently on the resolution stack — a cycle guard so a file that references a
// type resolving back to a file already being resolved (e.g. Connections.qml contains a
// `Connections {}` that name-matches the file itself) stops instead of recursing forever.
static std::set<std::string> g_resolving;

// Resolve a QML type name to a sibling `<dir>/<TypeName>.qml` (a local, .qml-defined type) and parse
// it, returning its root object definition — the engine auto-imports same-directory .qml types and
// we mirror that. Returns null (and leaves *outPath empty) if missing or already on the resolution
// stack. Engine/Parser are leaked (process-lifetime) so the returned AST stays valid.
// The name a member BINDS, for deciding what a use site overrides.
static std::string memberBoundName(UiObjectMember *m) {
    if (auto *pub = cast<UiPublicMember *>(m)) return qs(pub->name.toString());
    if (auto *sb = cast<UiScriptBinding *>(m)) return qname(sb->qualifiedId);
    if (auto *ob = cast<UiObjectBinding *>(m)) return qname(ob->qualifiedId);
    if (auto *ab = cast<UiArrayBinding *>(m)) return qname(ab->qualifiedId);
    return "";
}

// `Label { color: "red" }` on a local type whose OWN definition also binds `color`: in QML the use
// site WINS, it does not add a second binding. Appending both emitted two recompute slots with the
// same name and the generated D did not compile (HorizontalHeaderViewDelegate). Both child paths
// splice through this, so the two cannot drift apart again.
// Members spliced in from a use site (see spliceUseSite).
static std::set<UiObjectMember *> g_useSiteMembers;

static UiObjectInitializer *spliceUseSite(UiObjectInitializer *defn, UiObjectInitializer *use) {
    if (!use || !use->members) return defn;
    if (!defn || !defn->members) return use;
    std::set<std::string> overridden;
    for (auto *m = use->members; m; m = m->next) {
        std::string n = memberBoundName(m->member);
        // `id` is NOT a property and does not override: each half of a merged object keeps the id
        // its own document gave it, and both are names the object answers to. Dropping the
        // definition's left the spliced object answering only to the use site's — so Qt's
        // `Menu.qml`, whose `id` is `control`, had its `model: control.contentModel` resolved two
        // frames out to the enclosing TextField (which also writes `id: control`), and the menu's
        // ListView never got a model. Which half a binding was WRITTEN in is what decides the
        // scope, and that is g_useSiteMembers' job, not this dedup's.
        if (!n.empty() && n != "id") overridden.insert(n);
    }
    // A binding written at the USE SITE is evaluated in the scope of the document that WROTE it —
    // `background: ButtonPanel { control: control }` means Button.qml's `control`, not the
    // ButtonPanel property being assigned. Merging both bodies into one class merges the scopes
    // too, so the members that came from the use site are remembered and compiled with the local
    // type's own declarations out of scope.
    for (auto *m = use->members; m; m = m->next)
        if (m->member) g_useSiteMembers.insert(m->member);
    UiObjectMemberList *first = nullptr, *last = nullptr;
    for (auto *m = defn->members; m;) {
        auto *nx = m->next;
        std::string n = memberBoundName(m->member);
        bool keep = n.empty() || !overridden.count(n);
        // A DECLARATION is not a binding: `property bool highlighted: <expr>` both declares the
        // property and gives it a first value, and the use site only replaces the VALUE. Dropping it
        // whole removed the property itself — the use-site assignment then wrote a name the object
        // does not have and threw at construction, with no diagnostic anywhere (Qt's Fusion
        // ButtonPanel, through ComboBox/CheckBox/DelayButton). Keep the declaration, strip its
        // binding: two bindings for one name is what this dedup exists to prevent.
        if (!keep)
            if (auto *pubD = cast<UiPublicMember *>(m->member);
                    pubD && pubD->type == UiPublicMember::Property) {
                pubD->statement = nullptr;
                pubD->binding = nullptr;
                keep = true;
            }
        if (keep) {
            if (!first) first = m; else last->next = m;
            last = m; last->next = nullptr;
        }
        m = nx;
    }
    if (!first) { defn->members = use->members; return defn; }
    last->next = use->members;
    defn->members = first;
    return defn;
}

// A child whose type we cannot bind must be REFUSED, not built as a bare @QObject: every property
// the document sets on it is then written to an object that HAS no such property, which throws at
// construction (Dial's `transform: [ Translate { y: ... } ]`) while the file looks compiled.
// QtObject really is a bare QObject, and a local .qml type is resolved by the caller, so neither
// counts as unbound here.
static bool unboundChildType(const std::string &t, const std::string &bound, const char *inPath);

// `component Handle : Rectangle { ... }` — a type DECLARED INSIDE the document, usable anywhere in
// it (Qt's SelectionRectangle declares its handle that way and binds it to two properties). It is a
// local type like any other; the only difference is that it does not live in a file of its own, so
// it is registered here and resolved through the same lookup.
static std::map<std::string, UiObjectDefinition *> g_inlineTypes;

static void adoptLocalTypeRows(const std::string &localName, const std::string &baseQmlType) {
    if (localName.empty() || baseQmlType.empty() || localName == baseQmlType) return;
    if (g_qmlProps.count(localName)) return;   // a real QML type, or already adopted
    if (auto p = g_qmlProps.find(baseQmlType); p != g_qmlProps.end()) g_qmlProps[localName] = p->second;
    if (auto n = g_qmlNotify.find(baseQmlType); n != g_qmlNotify.end()) g_qmlNotify[localName] = n->second;
    if (auto c = g_qmlCxxType.find(baseQmlType); c != g_qmlCxxType.end()) g_qmlCxxType[localName] = c->second;
    // ...and the SIGNALS and METHODS, for the same reason the properties are here. A local type
    // inherits everything its base declares, and a handler written on it (`onTriggered:` on Qt's
    // UndoAction, whose base is Action) was refused for want of the signature — the file compiled
    // clean on its own, where the type IS Action, and refused as a child, where it is UndoAction.
    if (auto g = g_qmlSignals.find(baseQmlType); g != g_qmlSignals.end()) g_qmlSignals[localName] = g->second;
    if (auto m = g_qmlMethods.find(baseQmlType); m != g_qmlMethods.end()) g_qmlMethods[localName] = m->second;
    // ...and the DEFAULT PROPERTY, which is where a bare child goes. A Menu holds its items in
    // `contentData`, not in `data`; without this row a bare child of a local type derived from one
    // fell back to hand-parenting and wrote `parent`, which threw at construction on four of Qt's
    // documents. The registry has the answer for the base and the local type IS its base here.
    if (auto d = g_qmlDefaultProp.find(baseQmlType); d != g_qmlDefaultProp.end())
        g_qmlDefaultProp.emplace(localName, d->second);
    if (g_qmlListProp.count(baseQmlType)) g_qmlListProp.emplace(localName, g_qmlListProp[baseQmlType]);
}

static UiObjectDefinition *loadLocalType(const std::string &typeName, const char *inPath,
                                         std::string *outPath = nullptr, bool *isSingleton = nullptr) {
    if (auto ic = g_inlineTypes.find(typeName); ic != g_inlineTypes.end()) {
        if (isSingleton) *isSingleton = false;   // an inline component is never a singleton
        return ic->second;                       // same document: text and url stay as they are
    }
    QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
    QString path = dir + "/" + QString::fromStdString(typeName) + ".qml";
    // ...or a type the document IMPORTS that is itself written in QML. Qt's Fusion style puts
    // ButtonPanel, CheckIndicator, SliderGroove and friends in QtQuick.Controls.Fusion.impl, a
    // directory of .qml files next to the style — 26 refusals in that corpus, all "not a bound Qt
    // type", because only the document's OWN directory was searched. The module maps to a directory
    // the way the engine maps it: dots become slashes under the import root, an ancestor of this
    // document.
    if (!QFileInfo::exists(path)) {
        for (auto &imp : g_bareImports) {
            QString rel = QString::fromStdString(imp);
            rel.replace('.', '/');
            QString up = dir;
            for (int i = 0; i < 8 && !up.isEmpty(); ++i) {
                QString cand = up + "/" + rel + "/" + QString::fromStdString(typeName) + ".qml";
                if (QFileInfo::exists(cand)) { path = cand; break; }
                int slash = up.lastIndexOf('/');
                if (slash <= 0) break;
                up.truncate(slash);
            }
            if (QFileInfo::exists(path)) break;
        }
    }
    if (!QFileInfo::exists(path) && getenv("QTD_IMPORT_TYPES")) {   // PROBE
        for (auto &imp : g_bareImports) {
            QString rel = QString::fromStdString(imp); rel.replace('.', '/');
            QString up = dir;
            for (int i = 0; i < 8 && !up.isEmpty(); ++i) {
                QString cand = up + "/" + rel + "/" + QString::fromStdString(typeName) + ".qml";
                if (QFileInfo::exists(cand)) { path = cand; break; }
                int slash = up.lastIndexOf('/'); if (slash <= 0) break; up.truncate(slash);
            }
            if (QFileInfo::exists(path)) break;
        }
    }
    std::string p = qs(path);
    if (g_resolving.count(p)) return nullptr;   // cycle: this file is already being resolved
    if (!QFileInfo::exists(path)) return nullptr;
    if (outPath) *outPath = p;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return nullptr;
    QString code = QString::fromUtf8(f.readAll());
    g_srcText = code;   // this document's text, for the snippet a diagnostic quotes
    g_docUrl = "file://" + QFileInfo(path).absoluteFilePath().toStdString();
    auto *engine = new Engine();
    g_astEngine = engine;
    auto *lexer = new Lexer(engine);
    lexer->setCode(code, 1, /*qmlMode*/ true);
    auto *parser = new Parser(engine);
    if (!parser->parse()) return nullptr;
    auto *program = cast<UiProgram *>(parser->ast());
    collectImportAliases(program);   // `import ... as T` -> `T.Button` is `Button`
    if (!program || !program->members || !program->members->member) return nullptr;
    if (isSingleton) {
        *isSingleton = false;
        for (auto *h = program->headers; h; h = h->next)
            if (auto *pr = cast<UiPragma *>(h->headerItem))
                if (pr->name.toString() == QLatin1String("Singleton")) { *isSingleton = true; break; }
    }
    return cast<UiObjectDefinition *>(program->members->member);
}

static bool unboundChildType(const std::string &t, const std::string &bound, const char *inPath) {
    return bound.empty() && !t.empty() && t != "QtObject" && !loadLocalType(t, inPath, nullptr);
}

// A local `.qml` type can derive from ANOTHER local `.qml` type, and following exactly one hop
// stops at a root that is itself local — leaving the object with NO bound C++ base. It is then
// built as a plain QObject: none of the type's properties exist, its bare children cannot be
// appended through a default property, and the hand-parenting fallback writes `parent`, which
// throws. Qt's own `TextEditingContextMenu` is the case that named this: it is a `Menu`, and
// inside a style directory that `Menu` is the STYLE's own `Menu.qml`, whose root is `T.Menu` —
// the bound one, two hops down.
//
// Every level's members are spliced in DEFINITION order (base first, use site last), which is
// what QML's own last-wins override needs. The registry rows are adopted DEEPEST FIRST, because
// each level inherits from the one below it and adopting shallow-first would copy rows that do
// not exist yet. Each file visited is recorded so the cycle guard covers the whole chain, not
// just its first link.
//
// The hop limit is a backstop, not a policy: a genuine chain is two or three links, and a cycle
// is already caught by g_resolving.
static std::pair<std::string, std::string>
resolveLocalChain(const std::string &qmlType, const char *inPath,
                  UiObjectInitializer *&init, std::vector<std::string> &paths,
                  std::string *finalRoot = nullptr, bool *found = nullptr)
{
    std::pair<std::string, std::string> bound;
    std::vector<std::pair<std::string, std::string>> adopt;   // (level, its root), shallow -> deep
    std::string cur = qmlType;
    for (int hop = 0; hop < 8; ++hop) {
        std::string p;
        UiObjectDefinition *lt = loadLocalType(cur, inPath, &p);
        if (!lt) break;
        if (found) *found = true;
        if (!p.empty()) paths.push_back(p);
        std::string ltRoot = lt->qualifiedTypeNameId ? typeName(lt->qualifiedTypeNameId) : "";
        bound = boundTypeFor(ltRoot);
        adopt.push_back({cur, ltRoot});
        init = spliceUseSite(lt->initializer, init);
        if (finalRoot) *finalRoot = ltRoot;
        if (!bound.first.empty() || ltRoot.empty() || ltRoot == cur) break;
        cur = ltRoot;
    }
    for (auto it = adopt.rbegin(); it != adopt.rend(); ++it)
        adoptLocalTypeRows(it->first, it->second);   // the registry knows the BASE, not the file
    return bound;
}

struct ObjNode {
    std::string id;                                             // this object's QML `id:` (if any)
    // Value lists (`property list<int>`): name -> D element type. Dumped as one label whose value
    // is the elements joined by "," — the oracle formats a QVariantList the same way. Without a
    // label the engine's own property would be uncompared, and --verify-props rejects that.
    std::vector<std::pair<std::string, std::string>> valueLists;
    std::vector<std::pair<std::string, std::string>> scalars;   // custom @Property (name, dtype)
    std::vector<std::pair<std::string, std::string>> baseProps; // base C++ Q_PROPERTYs set (name, dtype)
    std::vector<std::pair<std::string, std::string>> groupProps;// grouped members set ("group.member", dtype)
    std::vector<std::pair<std::string, std::string>> attachedProps;// attached members set ("Type.member", dtype)
    std::vector<std::string> notified;                          // props that carry a NOTIFY signal
    bool usesOuter = false;   // reads its enclosing object -> needs the __outer back-reference
    int outerHops = -1;       // deepest enclosing level it reached (0 = immediate parent)
    bool hasLate = false;     // it (or a descendant) has late-phase work
    // ...and whether it (or a descendant) is a BOUND type, i.e. can implement QQmlFinalizerHook —
    // the third construction phase, which runs after every componentComplete in the tree.
    bool hasFinal = false;
    // The C++ base this object actually IS. The dump's `__class` needs it for a NESTED child: the
    // engine names a class after the DOCUMENT wherever the document defines a type — the root, and
    // a local type — and reports the Qt base everywhere else, while we name every generated class
    // after the document. The two agreed only when those namings happened to line up.
    std::string boundBase;
    bool engineInst = false;  // a registered QML type with no exported symbol: the class WRAPS the
                              // instance the engine built (see g_engineChildCls) rather than being it
    std::vector<std::pair<std::string, ObjNode>> kids;          // property-typed children (field, child)
    std::set<std::string> listKids;   // ...of those, the ones whose property is a LIST: the engine
                                      // holds them at <prop>[0], so that is the path to compare.
    // Value sources (`NumberAnimation on v`). They need completion like any object, but they are
    // NOT children in QML's object model — the engine has no `_vs0.duration` path, so dumping them
    // as children made the oracle fail on a path that cannot exist.
    std::vector<std::pair<std::string, ObjNode>> vsKids;
    // Children attached to a member of a GROUPED property. Unlike `kids`, the D FIELD and the QML
    // PATH differ (field `_g_group_object`, path `group.object`), so both are carried. (A struct
    // holding an ObjNode by value can't be declared here — ObjNode is still incomplete — so the
    // path rides alongside, one entry per groupKids entry.)
    // A QML alias is a REFERENCE. It is compiled as a compile-time ALIAS, not a property: nothing
    // is stored, reads go straight to the target and writes land on it. That removes the whole
    // question of keeping a copy in sync — a binding that uses the alias depends on the TARGET,
    // whose reactivity already exists — and it is what an alias actually means.
    // (name, read expression, D type, write target object, write target property)
    struct AliasLine { std::string name, read, dtype, setObj, setProp; };
    std::vector<AliasLine> aliasLines;
    std::vector<std::pair<std::string, ObjNode>> groupKids;     // (D field, child)
    std::vector<std::string> groupKidPaths;                     // QML path, parallel to groupKids
    // When a single-object `default property` holds the lone bare child, the engine reaches it
    // through THAT PROPERTY, not through children()[0] — so the dump label is the property name.
    std::string defaultKidLabel;
    bool defaultKidIsList = false;                              // ...and reached at an INDEX
    // No-arg QML `function`s on the ROOT. The differential can then exercise them: a mutation
    // argument `name()` invokes one on both sides, which is the only way to observe anything a
    // method does — imperative binding installs, resets, counters.
    std::vector<std::string> methods0;
    // Members contributed by this object's BOUND type (not declared in the .qml). Dumped through
    // the meta-object — they are the only thing that proves the object really IS that type, since
    // members the document assigns would read back the same from a plain QObject holding dynamic
    // properties.
    std::vector<std::pair<std::string, std::string>> boundProps;
    // Value-group members this object set (`vt.count`), dumped like grouped ones.
    std::vector<std::pair<std::string, std::string>> valueGroupProps;
    std::vector<std::pair<std::string, ObjNode>> defaultKids;   // default-property children (field, child)
};

// Compile one QML object (its initializer) into a D @QObject class `cls`, appending the class text
// (and any nested child classes) to `classes`. Recursive: a child object `field: Type { ... }`
// (a UiObjectBinding) becomes a nested @QObject `cls_field` held in a plain field and constructed
// in __qmltcWire, so the whole tree materialises without the QML engine. Returns the ObjNode.
// One `State`: its name and the overrides its PropertyChanges blocks declare, as raw expressions
// (compiled later, once the property types of the enclosing object are known).
struct StateOverride { std::string prop; ExpressionNode *value; };
// `when:` is a CONDITION, not a name — QML enters the state while it holds. Kept as the
// expression: the emission turns it into an ordinary binding on `state`, which is exactly what the
// engine does, so the save/apply/restore machinery below needs no new case at all.
struct StateEntry { std::string name; std::vector<StateOverride> overrides;
                    ExpressionNode *when = nullptr; };

// Reads `states: State { ... }` (or a list of them) into a table. Returns false for any shape not
// handled — a target other than the enclosing object, or a member that is neither `name` nor a
// PropertyChanges — so it is reported instead of silently producing a state that does nothing.
static bool collectStates(UiObjectMember *binding, std::vector<StateEntry> &out) {
    std::vector<UiObjectInitializer *> stateInits;
    if (auto *ob = cast<UiObjectBinding *>(binding)) {
        if (!ob->qualifiedTypeNameId || typeName(ob->qualifiedTypeNameId) != "State") return false;
        stateInits.push_back(ob->initializer);
    } else if (auto *arr = cast<UiArrayBinding *>(binding)) {
        for (auto *m = arr->members; m; m = m->next)
            if (auto *od = cast<UiObjectDefinition *>(m->member)) {
                if (!od->qualifiedTypeNameId || typeName(od->qualifiedTypeNameId) != "State") return false;
                stateInits.push_back(od->initializer);
            }
    } else return false;

    for (auto *si : stateInits) {
        StateEntry e;
        for (auto *m = si ? si->members : nullptr; m; m = m->next) {
            if (auto *sb = cast<UiScriptBinding *>(m->member)) {
                std::string sn = qname(sb->qualifiedId);
                auto *es = cast<ExpressionStatement *>(sb->statement);
                if (sn == "when") {
                    if (!es) return false;
                    e.when = es->expression;
                    continue;
                }
                if (sn != "name") return false;
                auto *sl = es ? cast<StringLiteral *>(es->expression) : nullptr;
                if (!sl) return false;
                e.name = qs(sl->value.toString());
                continue;
            }
            auto *od = cast<UiObjectDefinition *>(m->member);
            if (!od || !od->qualifiedTypeNameId || typeName(od->qualifiedTypeNameId) != "PropertyChanges")
                return false;
            for (auto *pm = od->initializer ? od->initializer->members : nullptr; pm; pm = pm->next) {
                auto *psb = cast<UiScriptBinding *>(pm->member);
                if (!psb) return false;
                std::string pn = qname(psb->qualifiedId);
                auto *pes = cast<ExpressionStatement *>(psb->statement);
                if (!pes) return false;
                if (pn == "target") {
                    // Only the enclosing object: anything else needs a reference this object does
                    // not hold, and wiring it to the wrong target would be worse than refusing.
                    auto *idx = cast<IdentifierExpression *>(pes->expression);
                    if (!idx || g_selfId.empty() || qs(idx->name.toString()) != g_selfId) return false;
                    continue;
                }
                // `PropertyChanges { control.contentItem.opacity: 0.75 }` — Qt 6 spells the target
                // in the NAME instead of in a `target:` line. Kept whole; the emission resolves the
                // path and accepts it only when it lands on THIS object, which is the same rule the
                // `target:` form enforces (Qt's ScrollBar writes it that way about its own
                // contentItem, from inside that contentItem).
                e.overrides.push_back({pn, pes->expression});
            }
        }
        if (e.name.empty()) return false;
        out.push_back(e);
    }
    return !out.empty();
}

static ObjNode compileObject(UiObjectInitializer *init, const std::string &cls,
                             std::string &classes, int &partial, const char *inPath,
                             const std::string &boundBase = "", const DType *dBase = nullptr,
                             const std::string &qmlType = "") {
    // The object's OWN QML type name drives every property-table lookup (types and notify
    // signatures). It used to be set once, at the root, so inside a child every lookup consulted
    // the ROOT's table: a Rectangle inside an Item resolved its properties against Item, which is
    // why child properties came back typeless — and would have silently used the root's type for
    // any name the two happened to share.
    // Taken at ENTRY and cleared, so a nested compile does not inherit the caller's answer.
    const bool thisParentCompletes = g_parentCompletes;
    g_parentCompletes = false;
    // Offset in `wire` where this object's CHILDREN begin. Everything before it is what the object
    // does to ITSELF; everything after is the tree below it, which the engine builds only once the
    // object is in place. npos while no wire has been emitted.
    size_t kidsAt = std::string::npos;
    std::string savedSelfQmlType = g_selfQmlType;
    std::string savedId = g_selfId;
    auto savedIds = g_selfIds;
    auto savedIdsDefn = g_selfIdsDefn;   // ...and which half each came from
    // Everything still in the globals belongs to the ENCLOSING object: capture it as the outer
    // scope before it is overwritten. Only an enclosing object with an `id` is addressable.
    std::string savedOuterId = g_outerId, savedOuterClass = g_outerClass,
                savedOuterQmlType = g_outerQmlType, savedSelfClass = g_selfClass;
    auto savedOuterPropType = g_outerPropType;
    auto savedOuterBaseProps = g_outerBaseProps;
    bool savedOuterUsed = g_outerUsed, savedCtxUsed = g_ctxUsed;
    auto savedRequired = g_requiredDecls; bool savedHasRequired = g_hasRequiredDecl;
    // Push the enclosing object onto the chain — WITH or WITHOUT an id, because an anonymous
    // level still costs a hop. Its base properties are kept apart from the declared ones:
    // g_propType also carries base names the document assigns (`width: 100`), and those are
    // Q_PROPERTYs on the C++ base, not D fields — reading them as `__outer.width` won't compile.
    auto savedOuterChain = g_outerChain;
    {
        std::map<std::string, std::pair<std::string, std::string>> sibs;
        for (auto &ci : g_childIds) sibs[ci.first] = {ci.second.field, ci.second.qmlType};
        if (!g_selfClass.empty())
            g_outerChain.insert(g_outerChain.begin(),
                                OuterFrame{savedId, g_selfClass, savedSelfQmlType, savedIds,
                                           g_propType, g_baseProps, g_childDeclType, sibs});
    }
    if (!g_outerChain.empty()) {
        g_outerId = g_outerChain[0].id;
        g_outerClass = g_outerChain[0].cls;
        g_outerQmlType = g_outerChain[0].qmlType;
        g_outerPropType = g_outerChain[0].propType;
        g_outerBaseProps = g_outerChain[0].baseProps;
    }
    g_outerUsed = false;
    g_ctxUsed = false;
    g_requiredDecls.clear();
    g_hasRequiredDecl = false;
    int savedHops = g_outerHopsNeeded;
    g_outerHopsNeeded = -1;
    g_selfClass = cls;
    // Declared here rather than beside propNames: children are compiled BEFORE the property
    // emission and drain their `__outer.<prop>` notify requirements into it.
    std::vector<std::string> needsNotify;
    if (!qmlType.empty()) g_selfQmlType = qmlType;
    g_selfId = "";
    g_selfIds.clear();
    g_selfIdsDefn.clear();
    for (auto *m = init ? init->members : nullptr; m; m = m->next)   // pre-scan this object's id(s)
        if (auto *sb = cast<UiScriptBinding *>(m->member))
            if (qname(sb->qualifiedId) == "id")
                if (auto *es = cast<ExpressionStatement *>(sb->statement))
                    if (auto *idn = cast<IdentifierExpression *>(es->expression)) {
                        g_selfId = qs(idn->name.toString());
                        g_selfIds.insert(g_selfId);
                        // ...and WHICH half it came from, which is the whole point of keeping two.
                        if (!g_useSiteMembers.count(m->member)) g_selfIdsDefn.insert(g_selfId);
                    }

    // Pre-scan declared property types and no-arg function return types, so a binding compiled in
    // the main loop below can resolve/coerce a call `f()` to its return type. (Declared types are
    // enough here — the binding VALUES aren't needed to type a return expression.)
    auto savedFuncRet = g_funcRet;
    auto savedFuncReads = g_funcReads;
    auto savedEnumMember = g_enumMember;
    auto savedClassName = g_className;
    auto savedSignals = g_signals;
    auto savedSignalParams = g_signalParams;
    auto savedBaseProps = g_baseProps;
    auto savedScope = g_scope;
    auto savedPropType = g_propType;
    auto savedChildIds = g_childIds;
    // An inline component is usable ANYWHERE in the document, including above its declaration
    // (Qt's SelectionRectangle binds `Handle` two lines before declaring it), so register them all
    // before compiling any member.
    for (auto *m0 = init ? init->members : nullptr; m0; m0 = m0->next)
        if (auto *ic = cast<UiInlineComponent *>(m0->member))
            if (ic->component) g_inlineTypes[qs(ic->name.toString())] = ic->component;
    g_childIds.clear();
    auto savedChildDecl = g_childDeclType;
    g_childDeclType.clear();
    prescanChildIds(init);
    auto savedAliasRead = g_aliasRead;
    auto savedAliasDep = g_aliasDep;
    auto savedAliasWrite = g_aliasWrite;
    auto savedRebound = g_rebound;
    auto savedHasSelector = g_hasSelector;
    auto savedRebinds = g_rebinds;
    g_rebound.clear();
    g_hasSelector.clear();
    g_rebinds.clear();
    g_scope.clear();
    g_propType.clear();
    g_aliasRead.clear();
    g_aliasDep.clear();
    g_aliasWrite.clear();
    g_funcRet.clear();
    g_funcReads.clear();
    g_enumMember.clear();
    g_signals.clear();
    g_signalParams.clear();
    g_baseProps.clear();
    auto savedBaseIsD = g_baseIsD;
    g_baseIsD = dBase != nullptr && !dBase->bound;   // a bound C++ base still goes through meta
    // An app-defined D base contributes its properties WITH THEIR DECLARED TYPES, straight from
    // the registry — better than the literal-inference fallback used for a bound C++ base, and it
    // also puts properties the .qml only READS (never assigns) in scope.
    if (dBase) for (auto &p : dBase->propType) g_baseProps[p.first] = p.second;
    auto savedBaseReset = g_baseReset;
    g_baseReset.clear();
    if (dBase) g_baseReset = dBase->propReset;
    auto savedGroups = g_groups;
    g_groups.clear();
    // A grouped property's MEMBERS are typed from the group class's own registry entry.
    if (dBase) for (auto &g : dBase->groupClass)
        for (auto &kv : g_dTypes)
            if (kv.second.dClass == g.second) { g_groups[g.first] = &kv.second; break; }
    auto savedVGroups = g_vgroups;
    g_vgroups.clear();
    // Same, for VALUE groups. Kept in a separate table from g_groups on purpose: which one a name
    // is in decides whether a member access compiles to an object write or a read-modify-write,
    // and treating a value group as an object group crashes (propObj yields null).
    if (dBase) for (auto &g : dBase->valueGroupClass)
        for (auto &kv : g_dTypes)
            if (kv.second.dClass == g.second) { g_vgroups[g.first] = &kv.second; break; }
    auto savedAttached = g_attached;
    g_attached.clear();
    // Any registered type that declares QML_ATTACHED can be addressed as `Type.member` from any
    // object, so the whole registry is in scope — not just this object's base.
    for (auto &kv : g_dTypes) {
        if (kv.second.attachedClass.empty()) continue;
        for (auto &a : g_dTypes)
            if (a.second.dClass == kv.second.attachedClass) { g_attached[kv.first] = &a.second; break; }
    }
    g_className = cls;
    for (auto *m = init ? init->members : nullptr; m; m = m->next) {
        if (auto *en = cast<UiEnumDeclaration *>(m->member))
            for (auto *em = en->members; em; em = em->next)
                g_enumMember[qs(em->member.toString())] = qs(en->name.toString());
        if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Signal) {
            std::vector<std::pair<std::string, std::string>> ps;
            bool ok = true;
            for (auto *p = pub->parameters; p; p = p->next) {
                const char *dt = p->type ? dtypeOf(paramTypeName(p)) : "";
                if (!dt[0]) { ok = false; break; }
                ps.push_back({qs(p->name.toString()), dt});
            }
            if (ok) { std::string sn = qs(pub->name.toString()); g_signals.insert(sn); g_signalParams[sn] = ps; }
        }
    }
    {
        std::map<std::string, std::string> pt0;
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Property)
                if (pub->memberType) {   // typeName(): a QUALIFIED declared type, see above
                    const char *dt = dtypeOf(QString::fromStdString(typeName(pub->memberType)));
                    if (dt[0]) pt0[qs(pub->name.toString())] = dt;
                }
        // Base C++ properties: the TYPE comes from the property table, which records what the
        // type actually declares. Inferring it from the assigned literal was wrong and quietly so:
        // `width: 120` on an Item made width an `int`, so it was read with propInt() and mutated
        // with v.to!int — but Item::width is a qreal. It survived only because every literal in
        // the corpus is integral; `width: 10.5` truncates and `width=10.5` throws. The literal is
        // still the fallback for a type absent from the table.
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *sb = cast<UiScriptBinding *>(m->member)) {
                std::string hid = qname(sb->qualifiedId);
                if (hid == "id" || hid == "Component.onCompleted" || hid.find('.') != std::string::npos || pt0.count(hid)) continue;
                if (hid.size() > 2 && hid[0] == 'o' && hid[1] == 'n' && std::isupper((unsigned char)hid[2])) continue;
                if (auto *es = cast<ExpressionStatement *>(sb->statement)) {
                    if (g_baseProps.count(hid)) continue;             // a declared type already won
                    // The table first — it knows Item::width is a double.
                    if (auto qp = g_qmlProps.find(g_selfQmlType); qp != g_qmlProps.end()) {
                        auto pt = qp->second.find(hid);
                        if (pt != qp->second.end() && !pt->second.empty()) {
                            g_baseProps[hid] = pt->second;
                            continue;
                        }
                    }
                    std::string ty = inferType(es->expression, pt0);
                    if (ty == "int" || ty == "string" || ty == "double" || ty == "bool")
                        g_baseProps[hid] = ty;
                }
            }
        // Call sites first: funcParams consults them when the body gives no evidence.
        g_callArgs.clear();
        { CallArgScan scan; scan.pt = &pt0;
          for (auto *m = init ? init->members : nullptr; m; m = m->next) m->member->accept(&scan); }
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *se = cast<UiSourceElement *>(m->member))
                if (auto *fn = se->sourceElement->asFunctionDefinition())
                    if (auto *rexpr = fn->body ? findReturnExpr(fn->body) : nullptr) {
                        auto pt = pt0;
                        for (auto &pp : funcParams(fn, pt0)) pt[pp.first] = pp.second;   // params in scope
                        g_funcRet[qs(fn->name.toString())] = inferType(rexpr, pt);
                        if (!fn->formals) {   // no-arg: record which properties it reads (for reactive bindings)
                            std::vector<std::string> reads;
                            collectIds(rexpr, reads);
                            for (auto &r : reads) if (pt0.count(r)) g_funcReads[qs(fn->name.toString())].push_back(r);
                        }
                    }
        // The object's bare-name scope (see g_scope): every declared property (even one whose
        // type we can't map — the name still exists in QML), every base Q_PROPERTY we set, every
        // `function`, and every declared signal.
        for (auto *m = init ? init->members : nullptr; m; m = m->next) {
            if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Property) {
                g_scope.insert(qs(pub->name.toString()));
                if (isRequiredMem(pub)) {
                    g_requiredDecls.insert(qs(pub->name.toString()));
                    g_hasRequiredDecl = true;
                }
            }
            if (auto *se = cast<UiSourceElement *>(m->member))
                if (auto *fn = se->sourceElement->asFunctionDefinition())
                    g_scope.insert(qs(fn->name.toString()));
        }
        for (auto &bp : g_baseProps) g_scope.insert(bp.first);
        for (auto &sg : g_signals) g_scope.insert(sg);
        g_propType = pt0;
        for (auto &bp : g_baseProps) g_propType[bp.first] = bp.second;
        // Pre-resolve aliases whose target needs no child object, so a binding can USE the alias.
        for (auto *m = init ? init->members : nullptr; m; m = m->next) {
            auto *pub = cast<UiPublicMember *>(m->member);
            if (!pub || pub->type != UiPublicMember::Property) continue;
            if (!pub->memberType || pub->memberType->name.toString() != "alias") continue;
            auto *aes = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr;
            auto *fm = aes ? cast<FieldMemberExpression *>(aes->expression) : nullptr;
            if (!fm) continue;
            std::string mem = qs(fm->name.toString());
            // The base may be a bare identifier (`root.x`, `group.x`) or the object's own id in
            // front of a group (`root.group.x`) — both name the same thing.
            std::string bn = groupNameOf(fm->base);
            if (bn.empty()) {
                auto *base = cast<IdentifierExpression *>(fm->base);
                if (!base) continue;
                bn = qs(base->name.toString());
            }
            std::string nm = qs(pub->name.toString()), rd, ty;
            if (isSelfId(bn) && pt0.count(mem)) { ty = pt0[mem]; rd = mem; }
            else if (isSelfId(bn) && g_baseProps.count(mem)) {
                ty = g_baseProps[mem];
                if (!readName(mem, rd)) continue;
            } else if (g_groups.count(bn)) {
                auto mt = g_groups[bn]->propType.find(mem);
                if (mt == g_groups[bn]->propType.end()) continue;
                ty = mt->second;
                const char *r = ty == "string" ? "propStr(" : ty == "double" ? "propDouble("
                              : ty == "bool" ? "propBool(" : "propInt(";
                rd = r + std::string("propObj(this, \"") + bn + "\"), \"" + mem + "\")";
            } else continue;
            g_aliasRead[nm] = rd;
            g_aliasDep[nm] = (g_groups.count(bn) ? bn + "." + mem : mem);
            g_aliasWrite[nm] = g_groups.count(bn)
                ? std::pair<std::string, std::string>{"propObj(this, \"" + bn + "\")", mem}
                : std::pair<std::string, std::string>{"this", mem};
            g_scope.insert(nm);
            g_propType[nm] = ty;
        }
        // Function return types were inferred before the aliases existed, so a function whose
        // return expression IS an alias came out untyped. Redo that pass now that g_propType
        // knows the aliases (and the base's properties) too.
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *se = cast<UiSourceElement *>(m->member))
                if (auto *fn = se->sourceElement->asFunctionDefinition())
                    if (auto *rexpr = fn->body ? findReturnExpr(fn->body) : nullptr) {
                        auto pt = g_propType;
                        for (auto &pp : funcParams(fn, pt0)) pt[pp.first] = pp.second;
                        auto ty2 = inferType(rexpr, pt);
                        if (!ty2.empty()) g_funcRet[qs(fn->name.toString())] = ty2;
                    }
        // Which properties does a function reassign? Their recompute needs a selector, and that
        // has to be known before the property is emitted — hence a scan rather than discovery
        // during compilation. Assigning through an ALIAS reassigns the alias's TARGET, so the
        // scan resolves aliases (which is why it runs after they are known).
        {
            std::function<void(Node *)> scan = [&](Node *n) {
                if (!n) return;
                if (auto *blk = cast<Block *>(n)) { for (auto *st = blk->statements; st; st = st->next) scan(st->statement); return; }
                if (auto *iff = cast<IfStatement *>(n)) { scan(iff->ok); scan(iff->ko); return; }
                if (auto *es = cast<ExpressionStatement *>(n))
                    if (auto *bin = cast<BinaryExpression *>(es->expression); bin && bin->op == QSOperator::Assign)
                        if (auto *lhs = cast<IdentifierExpression *>(bin->left)) {
                            auto nm = qs(lhs->name.toString());
                            auto a = g_aliasDep.find(nm);
                            if (a != g_aliasDep.end()) nm = a->second;
                            if (pt0.count(nm)) g_rebound.insert(nm);
                        }
            };
            for (auto *m = init ? init->members : nullptr; m; m = m->next)
                if (auto *se = cast<UiSourceElement *>(m->member))
                    if (auto *fn = se->sourceElement->asFunctionDefinition())
                        for (auto *st = fn->body; st; st = st->next) scan(st->statement);
        }
        // A selector only exists for a reassigned property that carries a BINDING (a
        // literal-initialised one is just a field). Decide it here: the methods that consult it
        // are compiled before the properties are emitted.
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *pub = cast<UiPublicMember *>(m->member);
                    pub && pub->type == UiPublicMember::Property && g_rebound.count(qs(pub->name.toString())))
                if (auto *es = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr) {
                    auto *e = es->expression;
                    if (auto *u = cast<UnaryMinusExpression *>(e)) e = u->expression;
                    bool literal = cast<NumericLiteral *>(e) || cast<StringLiteral *>(e)
                                || cast<TrueLiteral *>(e) || cast<FalseLiteral *>(e);
                    if (!literal) g_hasSelector.insert(qs(pub->name.toString()));
                }
    }

    std::vector<Prop> props;
    std::vector<RawHandler> rawHandlers;
    // (field, initializer, QML type). The TYPE used to be dropped here, so a child bound to a
    // property (`property FontMetrics fm: FontMetrics { ... }`) was compiled as a bare @QObject
    // instead of its bound type — and `setProp(this, "font", …)` then created a Qt DYNAMIC property
    // rather than setting the real one. That looks right in a dump whenever both sides happen to
    // hold the same value, which is how it went unnoticed once already.
    struct ChildBinding { std::string field; UiObjectInitializer *init; std::string type; };
    std::vector<ChildBinding> childBindings;     // (field, init)
    // Declared properties whose value must go through the meta-object rather than into the D
    // field: a value type takes its literal as a string and QMetaType converts it.
    std::vector<std::pair<std::string, std::string>> metaAssigns;
    // A declared OBJECT property with an initial binding: written through setPropObj, the channel a
    // use-site assignment already uses. Collected here because baseWire does not exist yet.
    std::vector<std::pair<std::string, std::string>> objInitAssigns;
    // ...and the EXPRESSION behind each, so its dependencies can be wired once wireGroupDeps
    // exists. A declared value-type property was written ONCE and never again: Qt's Fusion
    // RadioIndicator computes `pressedColor` from `control.palette`, and disabling the control
    // switches which palette GROUP that resolves to — the engine repaints, we kept the enabled
    // colour. Found by the reactivity sweep on Fusion, which nothing had run before.
    std::vector<std::pair<std::string, ExpressionNode *>> metaAssignDeps;
    std::vector<StateEntry> stateTable;          // `states:` compiled as data, not as objects
    std::string initialState;                    // the document's `state: "..."`, if any
    // ("group.member", init, child QML type). The type used to be dropped, so every grouped child
    // was created as a bare newQObject — right for a D-registered group holding plain QObjects,
    // wrong for `first.handle: Rectangle {}`, whose class must subclass QQuickRectangle (setProp
    // then failed at runtime: "no writable property implicitWidth").
    struct GroupKid { std::string path; UiObjectInitializer *init; std::string type; };
    std::vector<GroupKid> groupKidBindings;
    // ("Type.member", init, child QML type) — the type is needed for the same reason grouped
    // children need it: without it the child is a bare QObject and a write to any property of its
    // real type throws at construction.
    struct AttachedKid { std::string path; UiObjectInitializer *init; std::string type, label; };
    std::vector<AttachedKid> attachedKidBindings;
    struct ArrayElem { std::string prop; int idx; UiObjectDefinition *def; };
    std::vector<ArrayElem> arrayBindings;                                        // `listProp: [ … ]`
    std::vector<UiObjectDefinition *> defaultKids;                               // bare `Type { }` children
    std::vector<std::pair<std::string, ExpressionNode *>> aliases;                // (name, target)
    std::vector<FunctionExpression *> functions;                                  // QML `function`s
    struct BaseAssign { std::string first; ExpressionNode *second; bool useSite = false; };
    std::vector<BaseAssign> rawBaseAssigns;         // base prop `name: expr`
    std::vector<std::pair<std::string, ExpressionNode *>> rawGroupAssigns;        // `group.member: expr`
    std::vector<std::pair<std::string, ExpressionNode *>> rawValueGroupAssigns;   // `vgroup.member: expr`
    // `<baseProp>.<member>: expr` where baseProp holds an OBJECT (border.width on a Rectangle).
    std::vector<std::pair<std::string, ExpressionNode *>> rawObjGroupAssigns;
    // `<Type> on <prop> { ... }` — a value source: built like a child, then handed its property.
    struct ValueSource { std::string prop; UiObjectInitializer *init; std::string type; };
    std::vector<ValueSource> valueSources;
    // `<baseProp>.<member>: expr` where baseProp is a plain Q_GADGET value (icon.width).
    std::vector<std::pair<std::string, ExpressionNode *>> rawBaseVGroupAssigns;
    // ...and the ones whose value type is reached through an EXTENSION (font.*), written by name.
    std::vector<std::pair<std::string, ExpressionNode *>> rawExtVGroupAssigns;
    std::vector<std::pair<std::string, Statement *>> rawGroupHandlers;            // `group.on<Sig>: body`
    std::vector<std::pair<std::string, ExpressionNode *>> rawAttachedAssigns;     // `Type.member: expr`
    std::vector<std::pair<std::string, Statement *>> rawAttachedHandlers;         // `Type.on<Sig>: body`
    std::string enumDecls, signalDecls, valueListDecls;                                           // emitted D enums / signals
    Statement *onCompleted = nullptr;                                            // Component.onCompleted body
    bool hasCustomDefaultProp = false;                                           // a `default property` declared
    std::string defaultPropName;                                                 // ...its name
    std::string defaultKidLabel;                                                 // dump label for the lone default child
    bool defaultKidIsList = false;                                               // ...held at an index
    bool defaultPropIsList = false;                                              // ...and whether it's a list<>
    for (auto *m = init ? init->members : nullptr; m; m = m->next) {
        if (auto *sb = cast<UiScriptBinding *>(m->member)) {
            std::string hid = qname(sb->qualifiedId);
            if (hid == "id") continue;
            if (hid == "Component.onCompleted") { onCompleted = sb->statement; continue; }   // runs at construction
            if (hid.size() > 2 && hid[0] == 'o' && hid[1] == 'n' && std::isupper((unsigned char)hid[2])) {
                std::string sig = hid.substr(2);
                sig[0] = (char)std::tolower((unsigned char)sig[0]);
                rawHandlers.push_back({sig, sb->statement, nullptr, ""});
                continue;
            }
            // A plain `<name>: <expr>` that isn't an id/handler assigns a base C++ Q_PROPERTY;
            // a DOTTED one (`group.count: 42`) assigns a member of a GROUPED property.
            {
                auto dot = hid.find('.');
                std::string head = dot == std::string::npos ? "" : hid.substr(0, dot);
                std::string tail = dot == std::string::npos ? "" : hid.substr(dot + 1);
                // `Type.member: <expr>` / `Type.on<Sig>: body` — the ATTACHED object of `Type`.
                if (g_attached.count(head)) {
                    if (tail.size() > 2 && tail[0] == 'o' && tail[1] == 'n'
                            && std::isupper((unsigned char)tail[2])) {
                        std::string sig = tail.substr(2);
                        sig[0] = (char)std::tolower((unsigned char)sig[0]);
                        rawAttachedHandlers.push_back({head + "." + sig, sb->statement});
                    } else if (auto *es = cast<ExpressionStatement *>(sb->statement)) {
                        rawAttachedAssigns.push_back({hid, es->expression});
                    } else { ++partial; }
                    continue;
                }
                // `group.on<Signal>: <body>` — a handler on the GROUP object, not on this one.
                if (g_groups.count(head) && tail.size() > 2 && tail[0] == 'o' && tail[1] == 'n'
                        && std::isupper((unsigned char)tail[2])) {
                    std::string sig = tail.substr(2);
                    sig[0] = (char)std::tolower((unsigned char)sig[0]);
                    rawGroupHandlers.push_back({head + "." + sig, sb->statement});
                    continue;
                }
                // A script binding (`color: { if (c) return a; else return b }`) is rewritten into
                // the equivalent conditional expression, so everything below treats it as one.
                ExpressionNode *sbExpr = nullptr;
                if (auto *es0 = cast<ExpressionStatement *>(sb->statement)) sbExpr = es0->expression;
                else sbExpr = blockToExpr(sb->statement);
                if (sbExpr) {
                    auto *es = sb->statement ? cast<ExpressionStatement *>(sb->statement) : nullptr;
                    (void) es;
                    if (dot == std::string::npos) {
                        // `state: "big"` selects which State's overrides apply. It is recorded
                        // rather than assigned: assigning the base property would set the name
                        // without applying anything, which reads as a state that silently did
                        // nothing.
                        if (hid == "state")
                            if (auto *sl = cast<StringLiteral *>(sbExpr)) {
                                initialState = qs(sl->value.toString());
                                rawBaseAssigns.push_back({hid, sbExpr, g_useSiteMembers.count(m->member) > 0});
                                continue;
                            }
                        rawBaseAssigns.push_back({hid, sbExpr,
                                                  g_useSiteMembers.count(m->member) > 0}); continue;
                    }
                    if (g_groups.count(head)) { rawGroupAssigns.push_back({hid, sbExpr}); continue; }
                    // `vgroup.member: <expr>` — same shape, but it must compile to a
                    // read-modify-write on the VALUE (see rawValueGroupAssigns below).
                    if (g_vgroups.count(head)) { rawValueGroupAssigns.push_back({hid, sbExpr}); continue; }
                    // `font.pixelSize: 22` on a BOUND type. g_vgroups is populated only for
                    // D-registered types, so this was refused outright — but no compile-time
                    // table is needed: setVgroup resolves the member BY NAME through the gadget's
                    // meta-object at runtime and QMetaType converts the value. The compiler only
                    // has to know that `font` is a property whose type is not a scalar.
                    // `border.width: 2` — a grouped assignment where the group is an OBJECT
                    // (`isPointer` in the registry, recorded as a trailing `*`). That is a plain
                    // property write on the object the group holds, which the meta-object reaches
                    // with propObj. The member's type comes from the VALUE, since the group's own
                    // type has no table here — QMetaType converts on write, and setProp throws if
                    // the member does not exist, so a wrong name is loud.
                    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                        auto it = qc->second.find(head);
                        if (it != qc->second.end() && !it->second.empty() && it->second.back() == '*') {
                            rawObjGroupAssigns.push_back({hid, sbExpr});
                            continue;
                        }
                    }
                    // `icon.width: 24` — a VALUE group that is a plain Q_GADGET: setVgroup does a
                    // read-modify-write through its own meta-object, which QQuickIcon has. A value
                    // type marked `^` is reached through an EXTENSION (QFont -> QQuickFontValueType)
                    // and has no meta-object of its own, so it stays refused — that distinction is
                    // what made this safe to enable at all.
                    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                        auto it = qc->second.find(head);
                        if (it != qc->second.end() && !it->second.empty()
                                && it->second.back() != '*' && it->second.back() != '^') {
                            rawBaseVGroupAssigns.push_back({hid, sbExpr});
                            continue;
                        }
                    }
                    // ...and one reached through an EXTENSION (`^`: QFont via QQuickFontValueType)
                    // goes through QQmlProperty, which resolves value-type members by name using
                    // QML's own registry — the channel the engine uses for the same line. The
                    // gadget read-modify-write cannot: there is no meta-object to read.
                    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                        auto it = qc->second.find(head);
                        if (it != qc->second.end() && !it->second.empty() && it->second.back() == '^') {
                            rawExtVGroupAssigns.push_back({hid, sbExpr});
                            continue;
                        }
                    }
                    // `font.pixelSize: 22` on a BOUND type stays unsupported, deliberately.
                    // Routing it through setVgroup looks right — the member would resolve by name
                    // at runtime — but QFont is NOT a Q_GADGET: QMetaType::metaObjectForType finds
                    // nothing for it, because QML reaches font members through a FOREIGN value-type
                    // wrapper (QQuickFontValueType), not through the plain meta-object channel.
                    // Emitting the call turned a compile-time partial into a construction-time
                    // throw, which is strictly worse. Reaching it needs the value-type registry.
                }
            }
        }
        // A QML `enum Name { A, B = 5, C }` -> a D enum (int members).
        if (auto *en = cast<UiEnumDeclaration *>(m->member)) {
            std::string e = "    enum " + qs(en->name.toString()) + " {";
            const char *sep = " ";
            for (auto *em = en->members; em; em = em->next) {
                e += std::string(sep) + qs(em->member.toString()) + " = " + std::to_string((long long)em->value);
                sep = ", ";
            }
            enumDecls += e + " }\n";
            continue;
        }
        // A QML `function name(...) { ... }` is a UiSourceElement wrapping a function definition.
        if (auto *se = cast<UiSourceElement *>(m->member)) {
            if (auto *fn = se->sourceElement->asFunctionDefinition()) { functions.push_back(fn); continue; }
        }
        // `field: Type { ... }` re-binding an existing property to a child object.
        if (auto *ob = cast<UiObjectBinding *>(m->member)) {
            // `Type on <prop> { ... }` (hasOnToken) is a PROPERTY-VALUE SOURCE (NumberAnimation on
            // width, Behavior on x, ...), NOT a child object bound to <prop>. We don't model these,
            // so flag PARTIAL — treating it as a `<prop>: Type{}` child would emit a wrong dump.
            if (ob->hasOnToken) {
                // `NumberAnimation on width`, `Behavior on x`: a PROPERTY VALUE SOURCE. The object
                // is built like any child and then handed the property it drives — one generic Qt
                // interface (QQmlPropertyValueSource) covers every animation type and Behavior, so
                // nothing here needs to know what a NumberAnimation is. Refusing it meant a
                // compiled document was visually right and frozen: the animation never existed.
                std::string vsType = typeName(ob->qualifiedTypeNameId);
                std::string vsProp = qname(ob->qualifiedId);
                auto vst = boundTypeFor(vsType);
                if (vst.first.empty()) {
                    std::fprintf(stderr, "qmltc-d: %s: '%s on %s' value source in %s is not a bound "
                                 "type — skipped (later phase)\n", inPath, vsType.c_str(),
                                 vsProp.c_str(), cls.c_str());
                    ++partial; continue;
                }
                valueSources.push_back({vsProp, ob->initializer, vsType});
                continue;
            }
            // A DOTTED target (`group.object: QtObject { … }`) binds a child to a member of a
            // GROUPED property: build the child, then attach it THROUGH the group object. The D
            // field cannot be named after the dotted path (`class X_group.object` is not valid D),
            // so field and QML path are tracked separately from here on.
            {
                std::string qid = qname(ob->qualifiedId);
                // `T.Overlay.modal: Rectangle {}` — the path is QUALIFIED by an import alias, so
                // splitting at the first dot yields `T`, which names no type at all. The alias
                // names the import, exactly as it does for a type name, so it is dropped here too.
                std::string qidAsWritten = qid;   // the label must use the name the DOCUMENT uses:
                // the engine resolves `T.Overlay.modal`, not `Overlay.modal`, and the oracle reads
                // the label through QQmlProperty against the document's own context.
                if (auto d0 = qid.find('.'); d0 != std::string::npos
                        && g_importAliases.count(qid.substr(0, d0)))
                    qid = qid.substr(d0 + 1);
                auto dot = qid.find('.');
                if (dot != std::string::npos) {
                    // NOT extended to attached types of BOUND modules, for two separate reasons.
                    // `Overlay.modal: Rectangle {}` targets a QQmlComponent property: it defines a
                    // TEMPLATE the overlay instantiates on demand, so compiling it as a child would
                    // assign an instance where Qt expects a factory — the same mistake the
                    // Component case already refuses rather than instantiating eagerly. The rest
                    // (ScrollBar.vertical) are real object properties and the compiler side works
                    // (the table carries each type's module URI now), but the ORACLE cannot read an
                    // attached path back, and shipping what the differential cannot compare is how
                    // false green happens.
                    // ...and an attached type of a BOUND module whose member is a real OBJECT.
                    // Held back until the ORACLE could read an attached path back, which it now
                    // can (QQmlProperty resolves one by name, public API). A QQmlComponent* member
                    // stays refused: that is a TEMPLATE the attachee instantiates, and compiling it
                    // as a child would assign an instance where Qt expects a factory.
                    bool boundAttachedObj = false;
                    if (auto am6 = g_qmlAttachedCxx.find(qid.substr(0, dot));
                            am6 != g_qmlAttachedCxx.end()) {
                        auto mi6 = am6->second.find(qid.substr(dot + 1));
                        if (mi6 != am6->second.end()) {
                            std::string ct = mi6->second;
                            while (!ct.empty() && ct.back() == ' ') ct.pop_back();
                            boundAttachedObj = !ct.empty() && ct.back() == '*'
                                            && ct.rfind("QQmlComponent", 0) != 0;
                        }
                    }
                    // GATE STAYS SHUT, deliberately: with `|| boundAttachedObj` the corpus gets
                    // WORSE — 99 divergences become 149, files identical in every property 34 -> 33,
                    // and the oracle dies on two more. The compiled attached child differs from the
                    // engine's by more than its absence does, so shipping it would trade a reported
                    // gap for a silent wrong object. Re-open only when a compiled ScrollBar.vertical
                    // matches the engine property-for-property.
                    // GATE STILL SHUT — FOURTH measurement, after the local type learned to adopt
                    // its base's SIGNALS and METHODS (which took Qt's spliced ContextMenu from 15
                    // refusals to 3, all of them attached children). NINE attached children are
                    // emitted in Basic now, up from three, and the diagnostics IMPROVE: 64 -> 59.
                    // What disqualifies it is four documents THROWING at construction — ComboBox,
                    // SearchField, TextArea, TextField — all on the same line:
                    //   setProp failed: no writable property "parent" taking a QObject* on
                    //   IComboBox_contentItem_ContextMenu_menu_dc2
                    // which is the FALLBACK the child-append takes when `listAppend(this, "data",
                    // child)` fails. A Menu's default property is `contentData`, not `data`, and
                    // the registry publishes it (qmlmap's fifth column). Appending through the
                    // type's own default property is the next step, and it is not about the gate.
                    // SIXTH, and this one NAMES the blocker. With the gate open, a print at the
                    // default-child label shows the attached Menu compiled with
                    //   selfQml=TextEditingContextMenu boundBase=[] dpSelf=contentData
                    // — no BOUND BASE. Qt's TextEditingContextMenu is a `Menu`, and in a style
                    // document that `Menu` is the STYLE's own Menu.qml, not the Templates type: one
                    // loadLocalType stops at a root that is ITSELF a local type. The label branch
                    // requires a bound base, so it never runs, and the append falls through to
                    // hand-parenting — which is the `parent` write that throws. Following the chain
                    // was tried and did not resolve it either: `boundTypeFor` depends on the
                    // import state of the document being parsed, and loadLocalType swaps that out.
                    // The fix is a local-type resolution that CHAINS and manages the import state
                    // the way the root path does; that is a refactor, not a branch.
                    // (fifth) adopting the base's DEFAULT PROPERTY onto the local type as well
                    // (a Menu holds its items in `contentData`) changed nothing — same nine
                    // children, same four throws. The generated Menu emits NO listAppend at all for
                    // its bare MenuSeparator children, only the hand-parenting fallback, so the
                    // label is not reaching that object from the registry in the first place. That
                    // is where to put the next print.
                    // (third measurement) — once all three prerequisites the
                    // ContextMenu needed had landed and all seven of Qt's editing Actions compiled
                    // whole. The number MOVED for the first time: with "compile it only if it
                    // compiles WHOLE", THREE attached children are emitted in Basic where the two
                    // earlier measurements emitted zero. It is still net negative — documents
                    // identical in every property 48 -> 47, paths the engine has and we do not
                    // 0 -> 21, diagnostics 64 -> 107 (the children compile and report their own
                    // gaps before being discarded) — but render and click stay at 49 and 34 with
                    // zero differing. The blocker has moved up a layer: it is the MENU those
                    // Actions live in, whose contentItem refuses `model`, `interactive` and
                    // `currentIndex` when spliced.
                    // (second measurement) — at the end of 2026-08-02, with
                    // Fusion down to 60 diagnostics: opening it plus the "compile it only if it
                    // compiles WHOLE" rule gives 158 diagnostics and emits ZERO attached children,
                    // exactly as it did at 83. Every one is still partial. The number to watch is
                    // not the gate, it is whether `ContextMenu.menu`'s Actions compile.
                    // (first measurement) — re-measured 2026-08-02, after the object write, the
                    // sibling ids, the colour precision and the ordering fixes, i.e. with every
                    // prerequisite the earlier note asked for. Opening it: Fusion 83 -> 171
                    // diagnostics, 41 -> 39 documents identical, 20 -> 26 value differences, 0 ->
                    // 21 paths the engine has and we do not, and four documents throwing at
                    // construction. Adding "compile it only if it compiles WHOLE" removes every
                    // one of those regressions — and then NOTHING is emitted: all 11 attached
                    // children in that corpus are partial, so the corpus is identical to the gate
                    // being shut, at the cost of 98 diagnostics for work that is thrown away. The
                    // blocker is not the attachment, it is the children: `ContextMenu.menu` is a
                    // Menu of Actions with script bindings we do not compile. Re-open when those
                    // compile, not before.
                    // (earlier note) The number is now MEANINGFUL. Both prerequisites are
                    // done — the oracle descends past an attached object (2a744e5) and the colour
                    // that probe found is fixed (732f674) — so opening it no longer mixes our error
                    // with the oracle's blindness. Measured with both in place: divergences 96 ->
                    // 104 and files identical in every property 34 -> 33. Better than the 149 it
                    // cost before, still net negative. Re-open when a compiled attached child
                    // matches the engine property-for-property.
                    (void) boundAttachedObj;
                    if (g_attached.count(qid.substr(0, dot))) {
                        attachedKidBindings.push_back({qid, ob->initializer,
                                                       ob->qualifiedTypeNameId ? typeName(ob->qualifiedTypeNameId) : "",
                                                       qidAsWritten});
                        continue;
                    }
                    // A group of the BOUND type (`up.indicator: Rectangle {}` on a SpinBox) is
                    // just as assignable: the emission below resolves the group with propObj at
                    // RUNTIME and never consults g_groups, which only ever held D-registered
                    // types. The `*` marker is what says the property holds an object.
                    bool boundObjGroup = false;
                    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
                        auto it = qc->second.find(qid.substr(0, dot));
                        boundObjGroup = it != qc->second.end() && !it->second.empty()
                                     && it->second.back() == '*';
                    }
                    if (!g_groups.count(qid.substr(0, dot)) && !boundObjGroup) {
                        std::fprintf(stderr, "qmltc-d: %s: child object bound to '%s' in %s is not a grouped "
                                     "property — skipped (later phase)\n", inPath, qid.c_str(), cls.c_str());
                        ++partial; continue;
                    }
                    groupKidBindings.push_back({qid, ob->initializer,
                                                ob->qualifiedTypeNameId ? typeName(ob->qualifiedTypeNameId) : ""});
                    continue;
                }
            }
            // `states: State { name: "x"; PropertyChanges { target: <self>; p: v } }` is not an
            // object tree to build — it is a table of OVERRIDES the engine applies to a target when
            // that state is entered. Compiled as objects it produced labels the engine has no
            // property for (a PropertyChanges holds no `width` of its own).
            if (qname(ob->qualifiedId) == "states") {
                if (!collectStates(m->member, stateTable)) {
                    std::fprintf(stderr, "qmltc-d: %s: `states` in %s uses a shape not compiled yet "
                                 "(only State { name; PropertyChanges { target: <this object>; ... } })"
                                 " — skipped (later phase)\n", inPath, cls.c_str());
                    ++partial;
                }
                continue;
            }
            childBindings.push_back({qname(ob->qualifiedId), ob->initializer,
                                         ob->qualifiedTypeNameId ? typeName(ob->qualifiedTypeNameId) : ""});
            continue;
        }
        // `listProp: [ Type { … }, Type { … } ]` — an array binding fills a `list<>` property.
        // Each element is a child object, reached by the engine at its INDEX in that property.
        if (auto *ab = cast<UiArrayBinding *>(m->member)) {
            std::string nm = qname(ab->qualifiedId);
            // `states: [State {...}, State {...}]` — same data-not-objects treatment as the
            // single-State form. Without this the list went through the generic array path and
            // produced labels for the State objects themselves (states[0].data[0].tag), which the
            // engine has no property for, while the state was never applied.
            if (nm == "states") {
                if (!collectStates(m->member, stateTable)) {
                    std::fprintf(stderr, "qmltc-d: %s: `states` in %s uses a shape not compiled yet "
                                 "(only State { name; PropertyChanges { target: <this object>; ... } })"
                                 " — skipped (later phase)\n", inPath, cls.c_str());
                    ++partial;
                }
                continue;
            }
            int idx = 0;
            for (auto *am = ab->members; am; am = am->next, ++idx) {
                auto *od = cast<UiObjectDefinition *>(am->member);
                if (!od) {
                    std::fprintf(stderr, "qmltc-d: %s: element %d of array binding '%s' in %s is not "
                                 "an object — skipped (later phase)\n", inPath, idx, nm.c_str(), cls.c_str());
                    ++partial; continue;
                }
                arrayBindings.push_back({nm, idx, od});
            }
            continue;
        }
        // A bare `Type { ... }` is a default-property child (e.g. an Item inside an Item).
        if (auto *od = cast<UiObjectDefinition *>(m->member)) { defaultKids.push_back(od); continue; }
        // A declared `signal name(type arg, ...)` -> a runtime `Signal!(dtypes) name;`.
        if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Signal) {
            std::string sn = qs(pub->name.toString());
            if (!g_signals.count(sn)) {   // pre-scan rejected a param type
                std::fprintf(stderr, "qmltc-d: %s: signal '%s' has an unsupported parameter type — skipped (later phase)\n", inPath, sn.c_str());
                ++partial; continue;
            }
            std::string types;
            for (auto &pp : g_signalParams[sn]) types += (types.empty() ? "" : ", ") + pp.second;
            signalDecls += "    Signal!(" + types + ") " + sn + ";\n";
            continue;
        }
        if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Property) {
            QString qmlType = pub->memberType
                    ? QString::fromStdString(typeName(pub->memberType)) : QString("var");
            std::string name = qs(pub->name.toString());
            // A declared property becomes a D FIELD, and the meta-object exports it under that
            // field's name — so a name that is a D keyword cannot simply be renamed: Qt would stop
            // knowing the property by its QML name. A CHILD field can be renamed safely (it is not
            // a property), which is what `delegate` needs; a declared one is refused instead. This
            // has to be checked before any other handling: a literal-valued property takes an
            // earlier path and skipped the check entirely when it sat further down.
            if (dKeywords().count(name)) {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' in %s is a D keyword, and renaming "
                             "the field would change the name Qt sees — skipped (later phase)\n",
                             inPath, name.c_str(), cls.c_str());
                ++partial; continue;
            }
            // A custom `default property` (typically `list<QtObject>`) redirects bare children into
            // that list rather than the object's QObject children; whether that breaks our `@N` =
            // children()[N] dump model depends on there being bare children, which we only know after
            // the scan — record it and decide below.
            if (isDefaultMem(pub)) {
                hasCustomDefaultProp = true;
                defaultPropName = name;
                // `list<QtObject>` keeps `list` in typeModifier and `QtObject` as the member
                // type — the modifier is where "is this a list" actually lives.
                defaultPropIsList = pub->typeModifier == QLatin1String("list");
                // `default property alias child: self.someObject` — an alias is a REFERENCE, so
                // the bare child lands on the TARGET. Name the target, since that is what the
                // engine (and the dump) reaches it through.
                if (qmlType == QLatin1String("alias"))
                    if (auto *aes = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr)
                        if (auto *fm = cast<FieldMemberExpression *>(aes->expression))
                            if (auto *b = cast<IdentifierExpression *>(fm->base);
                                    b && isSelfId(qs(b->name.toString())))
                                defaultPropName = qs(fm->name.toString());
            }
            // `property alias <name>: <target>` — collect; resolved to a bound property (with the
            // target's type) once all property types are known.
            if (qmlType == "alias") {
                if (auto *aes = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr)
                    aliases.push_back({name, aes->expression});
                else { std::fprintf(stderr, "qmltc-d: %s: alias '%s' has no target — skipped\n", inPath, name.c_str()); ++partial; }
                continue;
            }
            const char *dt = dtypeOf(qmlType);
            // A declared OBJECT property (`property Item control`): no D scalar type, but the type
            // IS bound, so the field is the wrapper class and the meta-object records `X*`. The
            // property has to exist whether or not this document assigns it — whoever instantiates
            // the type writes to it, and dropping it made that write throw at construction (Qt's
            // Fusion ButtonPanel declares `property Item control`, and every control that uses it
            // sets it). Only the UNBOUND form: an initial binding to an object is still refused.
            std::string objDt;
            auto *es0 = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr;
            // An INITIAL BINDING to an object is allowed now: the property is declared exactly the
            // same way and the value is written through setPropObj, the channel a use-site
            // assignment already uses. Qt's SelectionRectangle writes
            // `property Item control: SelectionRectangle.control` — an attached read — and the
            // whole property was refused for having a value at all.
            std::string objInit;
            if (!dt[0] && es0 && !pub->binding) {
                std::string oeI, oqI;
                if (objPathExpr(es0->expression, oeI, oqI)) objInit = oeI;
                else if (auto *fmI = cast<FieldMemberExpression *>(es0->expression))
                    if (auto *bI = cast<IdentifierExpression *>(fmI->base)) {
                        std::string tnI = qs(bI->name.toString()), memI = qs(fmI->name.toString());
                        auto amI = g_qmlAttachedCxx.find(tnI);
                        if (!g_scope.count(tnI) && !g_childIds.count(tnI)
                                && amI != g_qmlAttachedCxx.end() && amI->second.count(memI))
                            objInit = "propObj(" + attachedExpr(tnI) + ", \"" + memI + "\")";
                    }
            }
            if (!dt[0] && (!es0 || !objInit.empty()) && !pub->binding) {
                auto obt = boundTypeFor(qs(qmlType));
                if (!obt.first.empty() && !obt.second.empty()) {
                    objDt = obt.first;
                    // The type the DOCUMENT ASSIGNS, when it assigns one, in preference to the
                    // DECLARED one. QML is dynamically typed here and Qt exploits it: Fusion's
                    // CheckIndicator declares `property T.AbstractButton control` and then reads
                    // `control.checkState` — a property AbstractButton does not have and CheckBox
                    // does, which is what the use site actually puts there. The declaration is a
                    // lower bound on the object; the assignment names it. (An assignment that
                    // resolves to nothing leaves the declared type alone.)
                    std::string ty = qs(qmlType);
                    for (auto *m2 = init ? init->members : nullptr; m2; m2 = m2->next) {
                        auto *sb2 = cast<UiScriptBinding *>(m2->member);
                        if (!sb2 || !sb2->qualifiedId || sb2->qualifiedId->next) continue;
                        if (qs(sb2->qualifiedId->name.toString()) != name) continue;
                        auto *es2 = cast<ExpressionStatement *>(sb2->statement);
                        std::string oe2, oq2;
                        if (es2 && objPathExpr(es2->expression, oe2, oq2) && !oq2.empty()
                                && !boundTypeFor(oq2).first.empty())
                            ty = oq2;
                        break;
                    }
                    if (!g_selfQmlType.empty())
                        g_declObjProps[g_selfQmlType][name] = ty;
                    g_propType[name] = "@" + ty;   // ...and as a path head in this scope
                    if (!objInit.empty()) objInitAssigns.push_back({name, objInit});
                    std::string imp = "import " + obt.second + ";\n";
                    if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
                    dt = objDt.c_str();
                } else if (isQmlObjectType(qs(qmlType))
                           && pub->typeModifier != QLatin1String("list")) {
                    // ...and an object type with no BOUND mapping is still a property. QML's own
                    // `QtObject` is the case that shows it: `default property QtObject child` with
                    // no value is `child <null>` in the engine's meta-object and was nothing at all
                    // in ours — the property simply did not exist, so a use site assigning it wrote
                    // a name the object does not have. `Object` is the D type here because the only
                    // thing the channel needs is a QObject slot: cppSig spells a class as `X*` and
                    // the meta-object builder falls back to QObject* when that name has no
                    // metatype, which is exactly this.
                    objDt = "Object";
                    g_propType[name] = "@" + qs(qmlType);
                    if (!objInit.empty()) objInitAssigns.push_back({name, objInit});
                    dt = objDt.c_str();
                }
            }
            std::string expr;
            auto *es = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr;
            // ...or a BLOCK, which blockToExpr folds into the equivalent conditional. Qt's
            // RangeSlider declares `readonly property color handleBorderColor: { if (activeFocus)
            // return ... }` and every path here takes an expression, so the whole property was
            // refused for the SHAPE of its value. The base-property path has done this since it
            // was written; the declared-property one never learned.
            ExpressionStatement *esBlk = nullptr;
            if (!es && pub->statement)
                if (ExpressionNode *be = blockToExpr(pub->statement)) {
                    esBlk = new (g_astEngine->pool()) ExpressionStatement(be);
                    es = esBlk;
                }
            // `property var x: <expr>` — QML gives `var` no static type; it holds a QVariant. The
            // type of the INITIALISER is nonetheless known, so a var whose value is a scalar
            // compiles as that scalar and behaves identically for every read the document makes.
            // What is NOT supported is a var that changes type later (QML allows it, a typed D
            // field does not) or one holding an object/array — those still fail loudly rather
            // than being guessed into the wrong type.
            std::string varInferred;
            if (qmlType == "var" && es) {
                std::map<std::string, std::string> pt0;
                for (auto &pp : props) pt0[pp.name] = pp.dtype;
                varInferred = inferType(es->expression, pt0);
                if (!varInferred.empty()) dt = varInferred.c_str();
            }
            // `property list<int> nums: [...]` — a list of a VALUE type. Held as a plain D array
            // field so bindings can read it (see g_valueLists for why it is not an @Property).
            if (dt[0] && pub->typeModifier == QLatin1String("list") && !isDefaultMem(pub)) {
                std::string init = "[]";
                if (es && !compileExpr(es->expression, qmlType, init)) {
                    std::fprintf(stderr, "qmltc-d: %s: list property '%s' has an unsupported initialiser"
                                 " — skipped (later phase)\n", inPath, name.c_str());
                    ++partial; continue;
                }
                g_valueLists[name] = dt;
                valueListDecls += "    " + std::string(dt) + "[] " + name + " = " + init + ";\n";
                continue;
            }
            // ...and a list of OBJECTS is a meta-object list property. The elements are ordinary
            // children and the generated code ALREADY appends each through it
            // (`listAppend(this, "kids", _al_kids_0)`); the call did nothing because the property
            // did not exist, so the engine reached `kids[0]` and we reached nothing. The D side
            // stores none of it: the runtime owns the elements behind the QQmlListProperty this
            // property hands out, which is what that append writes into.
            if (!dt[0] && pub->typeModifier == QLatin1String("list")
                    && isQmlObjectType(qs(qmlType))) {
                props.push_back({name, "QmlObjectList", "", false, {}});
                continue;
            }
            // `property Type kid: Type { ... }` — the child object hangs off pub->binding.
            if (pub->binding) {
                if (auto *ob = cast<UiObjectBinding *>(pub->binding);
                        ob && ob->qualifiedTypeNameId && isComponentType(typeName(ob->qualifiedTypeNameId))) {
                    std::fprintf(stderr, "qmltc-d: %s: `Component` (property '%s') is a template, not an "
                                 "object — compiling it would instantiate its contents eagerly; skipped "
                                 "(later phase)\n", inPath, name.c_str());
                    ++partial; continue;
                }
                if (auto *ob = cast<UiObjectBinding *>(pub->binding)) {
                    // `property QtObject c: Connections { ... }` — the only spelling available on a
                    // QtObject root, which has no default property to hold a bare child.
                    if (ob->qualifiedTypeNameId && typeName(ob->qualifiedTypeNameId) == "Connections") {
                        if (!connectionsHandlers(ob->initializer, rawHandlers)) {
                            std::fprintf(stderr, "qmltc-d: %s: Connections '%s' in %s needs `target: <this"
                                         " object's id>` and `function on<Signal>(...)` members — skipped"
                                         " (later phase)\n", inPath, name.c_str(), cls.c_str());
                            ++partial;
                        }
                        continue;
                    }
                    std::string obTy = ob->qualifiedTypeNameId ? typeName(ob->qualifiedTypeNameId) : "";
                    declObjHead(name, obTy);
                    childBindings.push_back({name, ob->initializer, obTy}); continue;
                }
                if (auto *od = cast<UiObjectDefinition *>(pub->binding)) {
                    std::string odTy = od->qualifiedTypeNameId ? typeName(od->qualifiedTypeNameId) : "";
                    declObjHead(name, odTy);
                    childBindings.push_back({name, od->initializer, odTy}); continue;
                }
            }
            if (!dt[0] && !pub->statement) continue;   // bare `property Type kid` declaration -> skip
            // `property string s` with NO value, and `required property string shortName` (whose
            // value comes from the view's model), are ordinary declared properties: in QML they
            // exist and hold the type's default. Refusing them left the name in scope with no
            // field behind it, so any expression reading it emitted an undefined identifier and
            // the generated D did not compile (DayOfWeekRow, WeekNumberColumn).
            if (dt[0] && !pub->statement && !pub->binding) {
                props.push_back({name, dt, "", false, {}});
                continue;
            }
            // The VALUE must compile as the inferred type too, or `property var n: 42` emits a
            // double literal into an int field.
            QString effType = varInferred.empty() ? qmlType : QString::fromStdString(varInferred);
            if (dt[0] && pub->statement && literalOf(pub->statement, effType, expr)) {
                // A scalar literal becomes a FIELD INITIALISER, evaluated at compile time.
                // A VALUE TYPE cannot go that way, and must not be assigned to the D field
                // directly either: the literal is a string and the field is a QColor, and it is
                // the META-OBJECT that converts between them (QMetaType). So the field is
                // declared without an initialiser and the value is written through setProp —
                // which is the whole point of the property being in the meta-object.
                bool scalar = !std::strcmp(dt, "int") || !std::strcmp(dt, "bool")
                           || !std::strcmp(dt, "double") || !std::strcmp(dt, "string");
                if (!scalar) {
                    props.push_back({name, dt, "", false, {}});
                    metaAssigns.push_back({name, expr});
                } else props.push_back({name, dt, expr, false, {}});
            } else if (dt[0] && (g_deepReads.clear(), es && compileExpr(es->expression, effType, expr))) {
                std::vector<std::string> ids; collectIds(es->expression, ids);
                props.push_back({name, dt, expr, true, ids, g_deepReads});
                g_deepReads.clear();
            // A declared VALUE-TYPE property (`readonly property color checkMarkColor: <expr>`):
            // Qt's Fusion declares twenty of them and reads them from its children. The property
            // has to EXIST — the field carries the value type so the meta-object records it as
            // such, and both the initial value and every read cross as TEXT through the meta-object,
            // which is how every colour here already travels. Reading the D FIELD instead is what
            // broke the first attempt (a QColor where the expression wants a string).
            } else if (!std::strcmp(dt, "QColor") && es
                       && compileExpr(es->expression, "string", expr)) {
                props.push_back({name, "QColor", "", false, {}});
                metaAssigns.push_back({name, expr});
                metaAssignDeps.push_back({name, es->expression});
                g_metaTextProps.insert(name);
            } else if (!std::strcmp(dt, "int") || !std::strcmp(dt, "bool")
                       || !std::strcmp(dt, "double") || !std::strcmp(dt, "string") || !objDt.empty()) {
                // The property EXISTS whether or not its INITIAL BINDING compiles.
                // SCALARS and objects only: a value type (`property color x`) declared as a D
                // struct field changes how every READ of it compiles — the refusal path takes the
                // name out of scope, so reads fall back to the meta-object, and a QColor field used
                // where the expression wants a string stops the generated D from compiling
                // (measured: 8 link failures in Fusion, 1 in Basic). Qt's Fusion
                // ButtonPanel declares `property bool highlighted: control.highlighted`, and every
                // control that instantiates it writes that property; dropping the declaration made
                // those writes throw at construction ("no writable property highlighted"). Declared
                // with its default, and the binding reported as the refusal it is.
                // ...unless the value was an OBJECT and it was accepted. The chain above only
                // knows how to compile a SCALAR initial value, so an object property whose init
                // resolved (`property Item probe: kid` -> setPropObj) fell out of it and reported
                // a refusal for something that had in fact been emitted -- assignment, reads and
                // notify connections included. A census that steers the work cannot afford a
                // diagnostic that is not true.
                if (!objInit.empty()) { /* emitted above; nothing was refused */ }
                else
                std::fprintf(stderr, "qmltc-d: %s: the initial binding of property '%s' (%s) in %s is not "
                             "supported — the property is DECLARED, its initial value is not\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType), cls.c_str());
                ++partial;
                props.push_back({name, dt, "", false, {}});
            } else {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' (%s) is an unsupported binding/type — skipped (later phase)\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType));
                ++partial;
                // Nor may it stay in scope: a bare read would emit an identifier no field backs,
                // and the generated D would not compile at all.
                g_scope.erase(name);
                // A refused property has no field and no notify, so it must stop being VISIBLE:
                // a child reading `control.handleBorderColor` otherwise emitted a connect to
                // handleBorderColorChanged() and threw at construction (RangeSlider). Erasing it
                // here makes every dependent binding take the ordinary "no known notify" refusal.
                g_propType.erase(name);
            }
            continue;
        }
        // `component X : Base { ... }` declares a TYPE, it does not build anything here — it was
        // registered before the members were compiled (see the prescan) and is resolved wherever a
        // local type is.
        if (cast<UiInlineComponent *>(m->member)) continue;
        // Say WHAT was refused. This was the largest remaining cluster and carried no detail at
        // all, so it could not be acted on — the same reason the expression diagnostics were made
        // to quote their source.
        std::fprintf(stderr, "qmltc-d: %s: a member of %s is not yet handled: %s [%s] — skipped (later phase)\n",
                     inPath, cls.c_str(),
                     cast<UiScriptBinding *>(m->member)     ? "script binding"
                     : cast<UiObjectBinding *>(m->member)   ? "object binding"
                     : cast<UiObjectDefinition *>(m->member)? "object definition"
                     : cast<UiPublicMember *>(m->member)    ? "property/signal declaration"
                     : cast<UiArrayBinding *>(m->member)    ? "array binding"
                     : cast<UiSourceElement *>(m->member)   ? "source element"
                     : "other",
                     srcOf(m->member).c_str());
        ++partial;
    }

    // Child objects FIRST, so aliases can target a child property and __qmltcWire builds each child
    // before anything reads it. Each child is a recursively-compiled nested @QObject in a plain field.
    ObjNode node;
    node.id = g_selfId;   // still this object's id here (the loop doesn't touch g_selfId)
    std::string childFields, childWire, crossConnects;
    // Forwarding properties for this object's aliases — see where they are filled.
    std::string aliasProps;
    std::string dcWire;   // default children, emitted before the property-bound ones (see below)
    // ...and Component-valued properties before BOTH: they are templates the type builds children
    // from, so they have to be in place before any child is appended.
    std::string componentWire;
    // ...and the children that are written on ANOTHER object — a group's member (`first.handle:`)
    // or an attached one (`ScrollIndicator.vertical:`). Those are not deferred properties of this
    // object: the engine builds them with the rest of its body, BEFORE the object is assigned
    // anywhere. Qt's Menu is where the difference shows — its ListView contentItem carries a
    // `ScrollIndicator.vertical`, and created after the ListView had already become the Menu's
    // contentItem, the Menu counted the indicator as a menu ITEM (count 10 against the engine's 9,
    // and its 1000-pixel height is most of a content height of 1293 against 306).
    std::string ownBodyWire;
    // A use-site binding OVERRIDES a same-named binding from a merged local definition (QML
    // property-override semantics): keep only the LAST binding per property name (use-site members
    // were spliced on AFTER the local definition's), else we'd emit two `cls_<name>` classes.
    {
        std::vector<ChildBinding> dedup;
        for (auto it = childBindings.rbegin(); it != childBindings.rend(); ++it) {
            bool seen = false;
            for (auto &d : dedup) if (d.field == it->field) { seen = true; break; }
            if (!seen) dedup.push_back(*it);
        }
        std::reverse(dedup.begin(), dedup.end());
        childBindings.swap(dedup);
    }

    // What a declared OBJECT property is actually ASSIGNED, before any child is compiled. Qt's
    // Fusion declares `property Item control` and assigns a CheckBox to it; every child that reads
    // `indicator.control.checkState` needs the type of the OBJECT, not of the declaration, and the
    // document says which it is right here. Recorded against the same key the walk consults, so the
    // declared type stays the fallback for a property nobody assigns.
    if (!g_selfQmlType.empty())
        for (auto &ba0 : rawBaseAssigns) {
            bool declaredObj = false;
            for (auto &p0 : props)
                if (p0.name == ba0.first)
                    declaredObj = !p0.dtype.empty() && p0.dtype != "int" && p0.dtype != "bool"
                               && p0.dtype != "double" && p0.dtype != "string";
            if (!declaredObj) continue;
            // ...resolved in the scope the assignment was WRITTEN in, or `control: control` reads
            // the property being assigned and records the declared type over itself.
            if (ba0.useSite) {
                for (auto &p1 : props) g_useSiteShadowed.insert(p1.name);
                for (auto &i1 : g_selfIdsDefn) g_useSiteShadowed.insert(i1);
            }
            std::string oeA, oqA;
            bool okA = objPathExpr(ba0.second, oeA, oqA);
            g_useSiteShadowed.clear();
            if (okA && !oqA.empty()) g_declObjProps[g_selfQmlType][ba0.first] = oqA;
        }

    // A child target `<childId>.<prop>` for an alias -> (dtype, D access `<field>.<prop>`, notified?).
    std::map<std::string, std::string> childType, childAccess;
    std::map<std::string, bool> childNotified;
    for (auto &cb : childBindings) {
        std::string childCls = cls + "_" + cb.field;
        // Resolve the child's BOUND base, exactly as the default-child path already does, and
        // import its module (plus the package's qtvirt, which the trampoline mixin needs).
        // A property whose type is QQmlComponent takes a TEMPLATE, not an instance: `delegate:
        // Item {}` on a Repeater defines what to build per item, and the view instantiates it.
        // Building it eagerly as a child assigns one instance where Qt expects a factory — the
        // same mistake the compiler already refuses for an explicit `Component {}`. The registry
        // says which properties those are, so this is data rather than a list of names.
        if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end()) {
            auto it = qc->second.find(cb.field);
            if (it != qc->second.end() && it->second.find("QQmlComponent") != std::string::npos) {
                // A TEMPLATE, not an instance: `delegate: Text {}` says what to build per item and
                // the view builds it. So the body is compiled to a class like any other, and what
                // the property gets is a QQmlComponent that instantiates THAT class — registered as
                // a QML element, which is the only handle a view accepts.
                auto dbt = boundTypeFor(cb.type);
                if (unboundChildType(cb.type, dbt.first, inPath)) {
                    std::fprintf(stderr, "qmltc-d: %s: the Component bound to '%s' in %s is a '%s', "
                                 "which is not a bound Qt type — skipped (later phase)\n",
                                 inPath, cb.field.c_str(), cls.c_str(), cb.type.c_str());
                    ++partial; continue;
                }
                if (!dbt.first.empty() && !dbt.second.empty()) {
                    std::string imp = "import " + dbt.second + ";\n";
                    if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
                    std::string vimp = "import " + dbt.second.substr(0, dbt.second.rfind('.')) + ".qtvirt;\n";
                    if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
                }
                // A LOCAL type here is compiled from its own root, exactly as a property-bound
                // child already is — `component Handle : Rectangle {}` declared in the same
                // document included. Without it the class came out EMPTY (no base, no members) and
                // the view instantiated an object with nothing on it.
                UiObjectInitializer *dInit = cb.init;
                std::vector<std::string> dResolved;
                std::string dQmlType = cb.type;
                QString savedDSrc = g_srcText;
        g_srcStack.push_back(savedDSrc);
                auto savedDBare = g_bareImports, savedDQual = g_qualifiedTypes;
                if (dbt.first.empty() && cb.type != "QtObject" && !cb.type.empty()) {
                    std::string ltRoot; bool ltFound = false;
                    auto chained = resolveLocalChain(cb.type, inPath, dInit, dResolved, &ltRoot, &ltFound);
                    if (ltFound) {
                        dbt = chained;
                        // The registry knows the type it DERIVES from, not the local name: an
                        // inline component has no rows of its own, so `border.width` on a
                        // `component Handle : Rectangle` was looked up on "Handle" and refused.
                        if (!g_qmlCxxType.count(dQmlType) && !ltRoot.empty()) dQmlType = ltRoot;
                        if (!dbt.first.empty() && !dbt.second.empty()) {
                            std::string imp2 = "import " + dbt.second + ";\n";
                            if (g_extraImports.find(imp2) == std::string::npos) g_extraImports += imp2;
                            std::string vimp2 = "import " + dbt.second.substr(0, dbt.second.rfind('.'))
                                              + ".qtvirt;\n";
                            if (g_extraImports.find(vimp2) == std::string::npos) g_extraImports += vimp2;
                        }
                    }
                }
                bool savedDeleg = g_isDelegate;
                auto savedDelegCls = g_delegateCls;
                g_isDelegate = true;
                g_delegateCls = childCls;
                for (auto &rp : dResolved) g_resolving.insert(rp);
                ObjNode dkid = compileObject(dInit, childCls, classes, partial, inPath,
                                             dbt.first, nullptr, dQmlType);
                for (auto &rp : dResolved) g_resolving.erase(rp);
                g_srcStack.pop_back(); g_srcText = savedDSrc; g_bareImports = savedDBare; g_qualifiedTypes = savedDQual;
                g_isDelegate = savedDeleg;
                g_delegateCls = savedDelegCls;
                (void) dkid;
                // A delegate that reads a DECLARED property of an enclosing object needs that
                // object to EMIT its notify — the same two halves as any other child (record the
                // dependency, then make the far side emit). Forgetting the drain here made every
                // such connect throw at runtime ("no such signal tagChanged()"), which aborted the
                // delegate's whole wire: the values were computed and then thrown away.
                {
                    auto pendingD = g_outerNeedsNotify;
                    g_outerNeedsNotify.clear();
                    for (auto &__on : pendingD) {
                        if (__on.first == 0) {
                            if (std::find(needsNotify.begin(), needsNotify.end(), __on.second)
                                    == needsNotify.end())
                                needsNotify.push_back(__on.second);
                        } else {
                            g_outerNeedsNotify.push_back({__on.first - 1, __on.second});
                        }
                    }
                }
                // Into its OWN buffer, emitted BEFORE the default children. A Component is a
                // TEMPLATE the type builds children FROM, not a child in its own right: Qt's Menu
                // wraps an `Action` put in `contentData` into a `MenuItem` made from `delegate`,
                // and with the delegate still null it appended the Action raw. That is 144
                // properties per item the engine has and we do not, times seven Actions, on every
                // document with a context menu — the largest single gap behind the attached-child
                // gate, and it was an ordering one.
                componentWire += "        bindComponent!" + childCls + "(this, \"" + cb.field
                               + "\", \"" + g_docUrl + "\");\n";
                g_hasComponentBind = true;
                continue;
            }
        }
        auto cbt = boundTypeFor(cb.type);
        // An UNBOUND child type used to become a bare @QObject with no diagnostic, and then every
        // property the document sets on it failed at RUNTIME ("no writable property
        // implicitHeight") — while the file was reported CLEAN. `contentItem: ProgressBarImpl {}`
        // in Qt's own ProgressBar.qml is exactly that: ProgressBarImpl is not a bound type here.
        // QtObject legitimately IS a bare QObject, and a local .qml type is resolved further down,
        // so neither is refused.
        if (unboundChildType(cb.type, cbt.first, inPath)) {
            // ...unless the ENGINE knows the type. Qt's DialImpl, BusyIndicatorImpl and
            // ProgressBarImpl export no C++ symbol (they live in a style plugin), so no D subclass
            // of them can exist — but they are registered QML types, and the engine builds them by
            // name. The generated class then holds that instance and writes it through the
            // meta-object, which is what every other object here already does.
            std::string ecUri = uriForType(cb.type);
            if (!ecUri.empty() && g_qmlCxxType.count(cb.type)) {
                auto savedEC = g_engineChildCls, savedET = g_engineChildType, savedEU = g_engineChildUri;
                g_engineChildCls = childCls; g_engineChildType = cb.type; g_engineChildUri = ecUri;
                ObjNode ekid = compileObject(cb.init, childCls, classes, partial, inPath, "", nullptr, cb.type);
                g_engineChildCls = savedEC; g_engineChildType = savedET; g_engineChildUri = savedEU;
                {   // the same notify drain every child does
                    auto pendingE = g_outerNeedsNotify;
                    g_outerNeedsNotify.clear();
                    for (auto &__on : pendingE) {
                        if (__on.first == 0) {
                            if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                                needsNotify.push_back(__on.second);
                        } else g_outerNeedsNotify.push_back({__on.first - 1, __on.second});
                    }
                }
                if (ekid.outerHops >= 1) {
                    g_outerUsed = true;
                    if (ekid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = ekid.outerHops - 1;
                }
                // Same rule as the bound-child path below: a DECLARED object property belongs in
                // the meta-object, and a fresh @QObject is exactly the case the reverse lookup in
                // qtmoc was added for (it has no `wrap`).
                childFields += std::string(!isBoundObjectProp(cb.field) && !g_baseProps.count(cb.field)
                                           && !isListProp(g_selfQmlType, cb.field)
                                           ? "    @Property " : "    ")
                             + childCls + " " + dIdent(cb.field) + ";\n";
                childWire += std::string((ekid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                           + "        " + dIdent(cb.field) + " = newQObject!" + childCls + "();\n"
                           // the INSTANCE is what the property takes and what gets parented; the
                           // generated class is only its wiring.
                           + "        setQtParent(" + dIdent(cb.field) + ".__inst, this);\n"
                           + (isListProp(g_selfQmlType, cb.field)
                                ? "        listAppend(this, \"" + cb.field + "\", " + dIdent(cb.field) + ".__inst);\n"
                                : isBoundObjectProp(cb.field)
                                ? "        setPropObj(this, \"" + cb.field + "\", " + dIdent(cb.field) + ".__inst);\n"
                                : "");
                node.kids.push_back({cb.field, ekid});
                continue;
            }
            std::fprintf(stderr, "qmltc-d: %s: '%s' in %s is bound to '%s', which is not a bound Qt "
                         "type — building it as a bare object would drop every property set on it "
                         "— skipped (later phase)\n",
                         inPath, cb.field.c_str(), cls.c_str(), cb.type.c_str());
            ++partial; continue;
        }
        // A LOCAL `.qml` type here is compiled from its own root, exactly as a default child
        // already was. Only the default-child path had this, and the asymmetry was invisible while
        // a bare name still resolved through the registry: `footer: DialogButtonBox {}` in Qt's
        // Dialog.qml names the STYLED file next to it, and building it as a bare object left every
        // padding, size and offset at zero.
        UiObjectInitializer *cbInit = cb.init;
        std::vector<std::string> cbResolvedPath;
        QString savedCbSrc = g_srcText;
        g_srcStack.push_back(savedCbSrc);
        auto savedBare = g_bareImports, savedQual = g_qualifiedTypes;
        if (cbt.first.empty() && cb.type != "QtObject" && !cb.type.empty()) {
            bool cbFound = false;
            auto chained = resolveLocalChain(cb.type, inPath, cbInit, cbResolvedPath, nullptr, &cbFound);
            if (cbFound) cbt = chained;
        }
        if (!cbt.first.empty() && !cbt.second.empty()) {
            std::string imp = "import " + cbt.second + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + cbt.second.substr(0, cbt.second.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        for (auto &rp : cbResolvedPath) g_resolving.insert(rp);
        g_parentCompletes = true;   // ...after this wire assigns and parents it
        // The PROPERTY this child is bound to, for the length of its compile. A `PropertyChanges`
        // inside it can name itself the long way — `control.contentItem.opacity`, which Qt's
        // ScrollBar does — and the only way to know that path lands on THIS object is to know which
        // property of the enclosing one holds it.
        std::string savedBoundProp = g_selfBoundProp;
        g_selfBoundProp = cb.field;
        ObjNode kid = compileObject(cbInit, childCls, classes, partial, inPath, cbt.first, nullptr, cb.type);
        g_selfBoundProp = savedBoundProp;
        for (auto &rp : cbResolvedPath) g_resolving.erase(rp);
        // The imports (and what arrived qualified) belong to the DOCUMENT they were read from.
        g_srcStack.pop_back(); g_srcText = savedCbSrc; g_bareImports = savedBare; g_qualifiedTypes = savedQual;
        {   // a child connects to <prop>Changed on us, or on someone above us
            auto pending = g_outerNeedsNotify;
            g_outerNeedsNotify.clear();
            for (auto &__on : pending) {
                if (__on.first == 0) {
                    if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                        needsNotify.push_back(__on.second);
                } else {
                    g_outerNeedsNotify.push_back({__on.first - 1, __on.second});   // forward it up
                }
            }
        }
        // A child that reached PAST us needs us to hold our own back-reference, since its hops
        // are spelled `__outer.__outer...` and go through ours.
        if (kid.outerHops >= 1) {
            g_outerUsed = true;
            if (kid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = kid.outerHops - 1;
        }
        if (auto qp = g_qmlProps.find(cb.type); qp != g_qmlProps.end() && !cbt.first.empty())
            for (auto &pp : qp->second) kid.boundProps.push_back({pp.first, pp.second});
        // A DECLARED object property is a PROPERTY, not just a field. `property CheckBox cb:
        // CheckBox {}` puts `cb` in the object's meta-object for the engine; a plain D field put it
        // nowhere, so a read through the meta channel found nothing and the full property dump
        // showed the engine with `cb <object>` and us with no such key at all. A BASE object
        // property (`contentItem:`) is already in the C++ meta-object and must not get a second,
        // shadowing one.
        bool declaredObjProp = !isBoundObjectProp(cb.field) && !g_baseProps.count(cb.field)
                            && !isListProp(g_selfQmlType, cb.field);
        childFields += std::string(declaredObjProp ? "    @Property " : "    ")
                     + childCls + " " + dIdent(cb.field) + ";\n";
        childWire += std::string((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + dIdent(cb.field) + " = "
                   + (cbt.first.empty() ? "newQObject!" + childCls + "()" : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + dIdent(cb.field) + ", this);\n"
                   // ...and ACTUALLY ASSIGN it to the property. Creating and parenting the object
                   // is not the same as `contentItem: Label {}`: without this the Control's own
                   // contentItem/indicator stayed NULL, so anything Qt computes from them (an
                   // implicitContentWidth, a layout) was computed from nothing. The differential
                   // did not catch it because it reads OUR D field and the engine reads ITS
                   // object — both configured identically — rather than asking the control.
                   // Only a property of the BOUND type goes through the meta-object; a declared
                   // `property Item foo: Rectangle {}` is a plain D field.
                   // A LIST property takes an APPEND, not an assignment: QML allows a single
                   // object there (`transitions: Transition {}`) and the engine holds it at
                   // <prop>[0]. Assigning it as an object named a path the engine does not have.
                   + (isListProp(g_selfQmlType, cb.field)
                        ? "        listAppend(this, \"" + cb.field + "\", " + dIdent(cb.field) + ");\n"
                        : isBoundObjectProp(cb.field)
                        ? "        setPropObj(this, \"" + cb.field + "\", " + dIdent(cb.field) + ");\n" : "")
                   // ...and NOT classBegin: the child already did it at the top of its own wire.
                   // The child's OWN children come now, after the assignment above and before it
                   // is completed — the engine defers them that far and Qt relies on it: a Popup
                   // assigned to a ComboBox has its ListView contentItem reset by
                   // QQuickComboBox::setPopup, which cannot happen if the ListView does not exist
                   // yet (reproduced against the engine alone).
                   + "        " + dIdent(cb.field) + ".__qmltcKids();\n"
                   // componentComplete IS ours to call, and only now: the child is in the tree.
                   + "        componentComplete(" + dIdent(cb.field) + ");\n";
        if (!kid.id.empty()) {
            for (auto &s : kid.scalars) {
                childType[kid.id + "." + s.first] = s.second;
                childAccess[kid.id + "." + s.first] = cb.field + "." + s.first;
            }
            for (auto &n : kid.notified) childNotified[kid.id + "." + n] = true;
        }
        node.kids.push_back({cb.field, kid});
        if (isListProp(g_selfQmlType, cb.field)) node.listKids.insert(cb.field);
    }

    // A custom `default property` redirects bare children into that list, not the object's QObject
    // children — so `@N` = children()[N] no longer holds. Only a problem when there ARE bare
    // children; flag PARTIAL for each rather than emit a wrong dump.
    if (hasCustomDefaultProp && !defaultKids.empty()) {
        // The children stay on the default-child path either way — that is what resolves each
        // child's own TYPE. Only the DUMP LABEL changes, because the engine does not reach them
        // through children(): a single-object default property holds the one child directly, and
        // a `list<>` one holds them at an INDEX.
        if (!defaultPropName.empty() && (defaultPropIsList || defaultKids.size() == 1)) {
            defaultKidLabel = defaultPropName;
            defaultKidIsList = defaultPropIsList;
        } else {
            std::fprintf(stderr, "qmltc-d: %s: bare children under a custom default property in %s not yet supported — skipped (later phase)\n",
                         inPath, cls.c_str());
            partial += (int)defaultKids.size();
            defaultKids.clear();
        }
    }

    // A bound Qt base holds bare children in its own default property — `data` for anything
    // QQuickItem-derived — and that, not `children()[i]`, is the path the engine resolves. The
    // `@N` form is kept only for a plain @QObject root, which has no such property.
    // ...and WHICH property that is comes from the registry, not from an assumption: a Flickable
    // holds them in `flickableData` (reparented into its contentItem) and a Control in
    // `contentData`. Labelling them `data[i]` named a path the ENGINE does not have, which is how
    // the oracle refused ComboBox outright.
    if (defaultKidLabel.empty() && !boundBase.empty() && !defaultKids.empty()) {
        std::string dp = defaultPropOf(g_selfQmlType);
        if (dp.empty()) dp = defaultPropOf(qmlNameOfCxx(boundBase));
        if (dp.empty()) {
            // No default property in the registry means the type CANNOT hold bare children --
            // Action, FontLoader, Translate and 11 others declare none. Assuming `data` invented a
            // path neither side has; refusing says so.
            std::fprintf(stderr, "qmltc-d: %s: '%s' declares no default property, so the bare "
                         "child(ren) in %s have nowhere to go — skipped (later phase)\n",
                         inPath, g_selfQmlType.c_str(), cls.c_str());
            partial += (int)defaultKids.size();
            defaultKids.clear();
        } else {
            defaultKidLabel = dp;
            defaultKidIsList = true;
        }
    }

    // Default-property children: a bare `Type { }`. The child type is mapped to a bound Qt type
    // (Item -> QQuickItem) and compiled as a nested subclass in its own field, built in __qmltcWire.
    // For the differential we don't need to reparent (the D dump reads the field directly; the
    // oracle reads childItems()[i]) — only the declaration order must match.
    // The loop below has a local `childType` (the child's QML type NAME) that shadows the map of
    // the same name, so the map is reached through this reference.
    auto &childTypeMap = childType;
    for (size_t di = 0; di < defaultKids.size(); ++di) {
        auto *od = defaultKids[di];
        std::string childType = od->qualifiedTypeNameId ? typeName(od->qualifiedTypeNameId) : "";
        if (isComponentType(childType)) {
            std::fprintf(stderr, "qmltc-d: %s: `Component` in %s is a template, not an object — "
                         "compiling it would instantiate its contents eagerly; skipped (later "
                         "phase)\n", inPath, cls.c_str());
            ++partial; continue;
        }
        if (childType == "Connections") {
            if (!connectionsHandlers(od->initializer, rawHandlers)) {
                std::fprintf(stderr, "qmltc-d: %s: Connections in %s needs `target: <this object's id>` and"
                             " `function on<Signal>(...)` members — skipped (later phase)\n", inPath, cls.c_str());
                ++partial;
            }
            continue;
        }
        auto cbt = boundTypeFor(childType);
        UiObjectInitializer *childInit = od->initializer;   // members compiled for this child
        std::string childBase = cbt.first;                  // bound Qt base (empty = fresh @QObject)
        std::string childBaseImport = cbt.second;           // its import module (for g_extraImports)
        std::vector<std::string> childResolvedPath;           // local-type files (for the cycle guard)
        // Loading a local type parses ANOTHER file and repoints the text a diagnostic quotes from;
        // without putting it back, this document's own diagnostics quote the child's file.
        QString savedSrc = g_srcText;
        g_srcStack.push_back(savedSrc);
    std::string savedDocUrl = g_docUrl;
        // ...and its IMPORT STATE, which the other three local-type sites already put back and this
        // one did not. `g_qualifiedTypes` accumulates every bare name that arrived qualified, and
        // Qt's `MenuSeparator.qml` is rooted in `T.MenuSeparator` — so loading it for the FIRST
        // separator made `boundTypeFor("MenuSeparator")` answer the Templates type from then on,
        // and the SECOND separator in the same menu was compiled as a bare bound object with none
        // of the style's body. Two identical children, two different classes: the first 13 pixels
        // tall, the second 0.
        auto savedDcBare = g_bareImports, savedDcQual = g_qualifiedTypes;
        if (cbt.first.empty() && childType != "QtObject") {
            // A local `.qml`-defined type (HelloWorld { }): compile ITS OWN root as this child's
            // class, taking the local definition's base (QtObject -> fresh @QObject, Item -> bound).
            // Use-site members (`HelloWorld { property string text: ... }`) EXTEND the local type:
            // the chain splices each definition's member list in front of the use site's, so the
            // merged class carries both and the deepest base comes first.
            bool ltFound = false;
            auto chained = resolveLocalChain(childType, inPath, childInit, childResolvedPath,
                                             nullptr, &ltFound);
            if (!ltFound) {
                std::fprintf(stderr, "qmltc-d: %s: default child of type '%s' in %s not yet supported — skipped (later phase)\n",
                             inPath, childType.c_str(), cls.c_str());
                ++partial; continue;
            }
            childBase = chained.first;
            childBaseImport = chained.second;
        }
        // A bound child type (Rectangle/Text) needs ITS module imported too (the root's import
        // alone isn't enough); mirror the root's import + <pkg>.qtvirt, deduped.
        if (!childBase.empty() && !childBaseImport.empty()) {
            std::string imp = "import " + childBaseImport + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + childBaseImport.substr(0, childBaseImport.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        std::string field = "_dc" + std::to_string(di);
        std::string childCls = cls + "_dc" + std::to_string(di);
        for (auto &rp : childResolvedPath) g_resolving.insert(rp);
        g_parentCompletes = true;   // ...after this wire appends and parents it
        ObjNode kid = compileObject(childInit, childCls, classes, partial, inPath, childBase, nullptr, childType);
        g_srcStack.pop_back(); g_srcText = savedSrc;   // back to THIS document, so our own diagnostics quote it
        g_docUrl = savedDocUrl;   // ...and so a class emits ITS document's baseUrl, not ours
        g_bareImports = savedDcBare; g_qualifiedTypes = savedDcQual;
        {   // a child connects to <prop>Changed on us, or on someone above us
            auto pending = g_outerNeedsNotify;
            g_outerNeedsNotify.clear();
            for (auto &__on : pending) {
                if (__on.first == 0) {
                    if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                        needsNotify.push_back(__on.second);
                } else {
                    g_outerNeedsNotify.push_back({__on.first - 1, __on.second});   // forward it up
                }
            }
        }
        // A child that reached PAST us needs us to hold our own back-reference, since its hops
        // are spelled `__outer.__outer...` and go through ours.
        if (kid.outerHops >= 1) {
            g_outerUsed = true;
            if (kid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = kid.outerHops - 1;
        }
        for (auto &rp : childResolvedPath) g_resolving.erase(rp);
        childFields += "    " + childCls + " " + field + ";\n";
        // Into its OWN buffer, flushed BEFORE the property-bound children. The engine's `data`
        // holds the default children first: TextField declares its placeholder before its
        // background and TextArea after it, and the engine puts the placeholder at data[0] in
        // BOTH — so the order is not the document's, it is default-then-property. Ours was the
        // reverse, which made `data[N]` name a different object on each side.
        dcWire += std::string((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (childBase.empty() ? "newQObject!" + childCls + "()" : "new " + childCls + "()") + ";\n"
                   // Append through the type's DEFAULT PROPERTY, which is how the engine places a
                   // default child and lets each type apply its own rule (a Flickable reparents
                   // into its contentItem, a Control into its). Hand-parenting is the fallback for
                   // a type with no appendable list — a fresh @QObject, or a local .qml child.
                   // A LOCAL .qml child has no entry in the bound-type table, so its item-ness
                   // comes from the C++ base it resolved to. Missing that left `Greeter {}` — an
                   // Item-derived local type — unparented, which is exactly what the linkage
                   // check caught.
                   + (defaultKidIsList && !defaultKidLabel.empty() && defaultKidLabel[0] != '@'
                        ? "        if (!listAppend(this, \"" + defaultKidLabel + "\", " + field + ")) {\n    "
                        : "")
                   + "        setQtParent(" + field + ", this);\n"
                   // ...and a SINGLE-OBJECT default property is ASSIGNED, not appended. The label
                   // already named it (that is how the dump reaches the child), but nothing wrote
                   // it: `default property QtObject child` read `<null>` on our side against the
                   // engine's `<object>`, so the property existed and held nothing.
                   + (!defaultKidIsList && !defaultKidLabel.empty() && defaultKidLabel[0] != '@'
                        ? "        setPropObj(this, \"" + defaultKidLabel + "\", " + field + ");\n" : "")
                   + (((isItemType(childType) || isItemType(qmlNameOfCxx(childBase)))
                        && isItemType(g_selfQmlType))
                        ? std::string(defaultKidIsList && !defaultKidLabel.empty() && defaultKidLabel[0] != '@' ? "    " : "")
                          + "        setPropObj(" + field + ", \"parent\", this);\n" : "")
                   + (defaultKidIsList && !defaultKidLabel.empty() && defaultKidLabel[0] != '@'
                        ? "        }\n" : "")
                   // ...and NOT classBegin (the child did it); its own children come now, once it
                   // is appended and parented; componentComplete IS ours, and only after that.
                   + "        " + field + ".__qmltcKids();\n"
                   + "        componentComplete(" + field + ");\n";
        // A BARE child with an id is just as addressable as one bound to a property:
        // `property alias source: dps.source` where dps is a default child is the dominant shape
        // in real QML (241 of the alias skips measured against Qt's own .qml). Registering its
        // members here is what lets an alias — or any binding — reach them.
        if (!kid.id.empty()) {
            for (auto &sc : kid.scalars) {
                childTypeMap[kid.id + "." + sc.first] = sc.second;
                childAccess[kid.id + "." + sc.first] = field + "." + sc.first;
            }
            for (auto &n : kid.notified) childNotified[kid.id + "." + n] = true;
        }
        node.defaultKids.push_back({field, kid});
        node.defaultKidLabel = defaultKidLabel;
        node.defaultKidIsList = defaultKidIsList;
    }

    // Resolve `property alias <name>: <target>`. A SELF target (`<id>.<prop>` or bare `<prop>`)
    // becomes a reactive bound property. A CHILD target (`kid.y`) becomes an initial-value read of
    // the child field (kid built first in __qmltcWire); live re-evaluation of a child target needs
    // the child prop to carry a NOTIFY and is a later step.
    {
        std::map<std::string, std::string> t;
        for (auto &p : props) t[p.name] = p.dtype;
        for (auto &al : aliases) {
            // An alias is resolved to (how to READ the target, where to WRITE it). No property is
            // emitted, so there is no copy to keep in sync and no NOTIFY requirement on the target.
            // The owning object's access path isn't known here (an alias may live in a child), so
            // emit a marker that collectDump replaces with the real one.
            static const std::string SELF = "\x01";
            std::string read, atype, setObj, setProp;
            if (auto *fm = cast<FieldMemberExpression *>(al.second)) {
                auto *base = cast<IdentifierExpression *>(fm->base);
                std::string mem = qs(fm->name.toString());
                std::string bn = groupNameOf(fm->base);          // `root.group.x` -> `group`
                if (bn.empty()) bn = base ? qs(base->name.toString()) : "";
                if (base && isSelfId(bn) && t.count(mem)) {
                    atype = t[mem]; read = SELF + "." + mem; setObj = SELF; setProp = mem;   // own property
                } else if (base && isSelfId(bn) && g_baseProps.count(mem)) {
                    // a property of the base type: read as the base is read, write through meta.
                    atype = g_baseProps[mem];
                    std::string rd = atype == "string" ? "propStr(" + SELF + ", \"" : atype == "double" ? "propDouble(" + SELF + ", \""
                                   : atype == "bool" ? "propBool(" + SELF + ", \"" : "propInt(" + SELF + ", \"";
                    read = g_baseIsD ? (SELF + "." + mem) : (rd + mem + "\")");
                    setObj = SELF; setProp = mem;
                } else if (g_groups.count(bn)) {   // `base` is null for `root.group.x`; bn came from groupNameOf
                    // a member of a grouped property
                    auto mt = g_groups[bn]->propType.find(mem);
                    if (mt != g_groups[bn]->propType.end()) {
                        atype = mt->second;
                        const char *rd = atype == "string" ? "propStr(" : atype == "double" ? "propDouble("
                                       : atype == "bool" ? "propBool(" : "propInt(";
                        std::string gobj = "propObj(" + SELF + ", \"" + bn + "\")";
                        read = rd + gobj + ", \"" + mem + "\")";
                        setObj = gobj; setProp = mem;
                    }
                } else if (base && childType.count(bn + "." + mem)) {
                    atype = childType[bn + "." + mem];
                    std::string acc = childAccess[bn + "." + mem];   // "field.prop"
                    read = SELF + "." + acc;
                    setObj = SELF + "." + acc.substr(0, acc.find('.')); setProp = mem;
                }
            } else if (auto *id = cast<IdentifierExpression *>(al.second)) {
                std::string bn = qs(id->name.toString());
                if (t.count(bn)) { atype = t[bn]; read = SELF + "." + bn; setObj = SELF; setProp = bn; }
                else if (g_baseProps.count(bn)) {
                    atype = g_baseProps[bn];
                    std::string rd = atype == "string" ? "propStr(" + SELF + ", \"" : atype == "double" ? "propDouble(" + SELF + ", \""
                                   : atype == "bool" ? "propBool(" + SELF + ", \"" : "propInt(" + SELF + ", \"";
                    read = g_baseIsD ? (SELF + "." + bn) : (rd + bn + "\")");
                    setObj = SELF; setProp = bn;
                }
            }
            if (atype.empty()) {
                // An alias onto a declared property we hold no SCALAR type for is an alias to an
                // OBJECT property. It is a reference to the very object that property already
                // names, so it contributes no value of its own to compare — accept it and emit
                // no dump line, rather than refuse the file over a redundant name.
                bool objectAlias = false;
                if (auto *fm = cast<FieldMemberExpression *>(al.second))
                    if (auto *b = cast<IdentifierExpression *>(fm->base);
                            b && isSelfId(qs(b->name.toString()))
                            && g_scope.count(qs(fm->name.toString())))
                        objectAlias = true;
                if (objectAlias) {
                    // An alias whose target is an OBJECT property of this same object. It carries
                    // no scalar to dump, but it IS a property in the engine's meta-object — and a
                    // `default property alias` is how a bare child reaches its target at all
                    // (Qt's own shape in AliasHolder). Same forwarding pair as a scalar alias,
                    // typed by the target property's own D type.
                    if (auto *fm2 = cast<FieldMemberExpression *>(al.second)) {
                        std::string mem2 = qs(fm2->name.toString()), dty;
                        for (auto &p2 : props) if (p2.name == mem2) dty = p2.dtype;
                        if (!dty.empty() && dty != "int" && dty != "double" && dty != "bool"
                                && dty != "string") {
                            aliasProps += "    @PropertyAlias(\"" + al.first + "\") " + dty
                                        + " __pa_" + al.first + "() { return " + dIdent(mem2) + "; }\n"
                                        + "    void __pa_" + al.first + "_set(" + dty + " v) { "
                                        + dIdent(mem2) + " = v; }\n";
                        }
                    }
                    continue;
                }
                std::fprintf(stderr, "qmltc-d: %s: alias '%s' target is unsupported — skipped (later phase)\n", inPath, al.first.c_str());
                ++partial; continue;
            }
            node.aliasLines.push_back({al.first, read, atype, setObj, setProp});
            // ...and the alias is a PROPERTY of this object in the engine's meta-object, so it has
            // to be one here too. It forwards rather than stores — a field would hold a copy, which
            // is what an alias is not — so it is a getter with @PropertyAlias and a `<name>_set`
            // beside it, which is the pair qtmoc routes a forwarding property through.
            if (!atype.empty()) {
                bool scalarAlias = atype == "int" || atype == "double" || atype == "bool"
                                || atype == "string";
                // The self marker is `this` INSIDE the class — collectDump resolves it to the
                // object's access path for the dump, and these members are in the object itself.
                auto self = [](std::string x) {
                    for (size_t i; (i = x.find('\x01')) != std::string::npos;) x.replace(i, 1, "this");
                    return x;
                };
                // An OBJECT target is assigned through the D field rather than through setProp:
                // the target is a member of this same class, and the meta channel would only
                // re-enter the property we are defining. `default property alias child:
                // self.someObject` is that shape, and it is how a bare child of a user of the type
                // reaches its target at all.
                aliasProps += "    @PropertyAlias(\"" + al.first + "\") " + atype
                            + " __pa_" + al.first + "() { return " + self(read) + "; }\n"
                            + "    void __pa_" + al.first + "_set(" + atype + " v) { "
                            + (scalarAlias ? "setProp(" + self(setObj) + ", \"" + setProp + "\", v);"
                                           : self(setObj) + "." + dIdent(setProp) + " = v;")
                            + " }\n";
            }
        }
    }

    std::vector<std::string> propNames;   // needsNotify is declared earlier: children drain into it
    for (auto &p : props) propNames.push_back(p.name);
    // A PARENT binding that reads `<thisObject'sId>.<prop>` needs a change signal on that property,
    // and only the parent knew that — it recorded the requirement while its own bindings compiled.
    if (!g_selfId.empty())
        if (auto fn = g_forceNotify.find(g_selfId); fn != g_forceNotify.end())
            for (auto &m : fn->second)
                if (std::find(propNames.begin(), propNames.end(), m) != propNames.end()
                        && std::find(needsNotify.begin(), needsNotify.end(), m) == needsNotify.end())
                    needsNotify.push_back(m);
    auto isProp = [&](const std::string &n){ return std::find(propNames.begin(), propNames.end(), n) != propNames.end(); };

    std::map<std::string, std::string> ptype;
    for (auto &p : props) ptype[p.name] = p.dtype;
    // Two different things used to share one stream, and the difference is semantic: a BINDING
    // must be live before the initial assignments (its recompute is the value), while a user
    // HANDLER must not see them at all — QML does not fire on<Signal> for assignments made while
    // the object is being created. Merging them made `onWidthChanged` fire on `width: 100` and
    // report seen=1 where the engine reports 0.
    std::string handlerSlots, handlerWire, bindWire;
    for (auto &h : rawHandlers) {
        // `on<Prop>Changed` connects to a property's change signal (mark the prop notified);
        // `on<Signal>` connects to a declared signal directly.
        std::string notifyProp, hbody;
        // A handler on another object's signal takes its parameter types from THAT object, and is
        // never an `on<Prop>Changed` of this one.
        const ChildRef *hostChild = nullptr;
        if (!h.sender.empty())
            for (auto &kv : g_childIds)
                if (kv.second.field == h.sender) { hostChild = &kv.second; break; }
        const std::vector<std::pair<std::string, std::string>> *sigParams = nullptr;
        if (hostChild) {
            auto sp0 = hostChild->signalParams.find(h.sig);
            if (sp0 != hostChild->signalParams.end()) sigParams = &sp0->second;
        } else if (auto sp0 = g_signalParams.find(h.sig); sp0 != g_signalParams.end())
            sigParams = &sp0->second;
        bool isCustom = hostChild ? true : g_signals.count(h.sig) > 0;
        if (!isCustom && h.sig.size() > 7 && h.sig.compare(h.sig.size() - 7, 7, "Changed") == 0)
            notifyProp = h.sig.substr(0, h.sig.size() - 7);
        // A handler body may be a statement, a function expression `function(a, b) { ... }` whose
        // formals name the signal's arguments, or (from Connections) a named function declaration.
        StatementList *fnBody = nullptr;
        std::vector<std::string> fnParams;
        if (h.fn) {
            fnBody = h.fn->body;
            for (auto *f = h.fn->formals; f; f = f->next)
                if (f->element) fnParams.push_back(qs(f->element->bindingIdentifier.toString()));
        } else if (auto *es = cast<ExpressionStatement *>(h.stmt))
            if (auto *fe = es->expression->asFunctionDefinition()) {
                fnBody = fe->body;
                for (auto *f = fe->formals; f; f = f->next) if (f->element) fnParams.push_back(qs(f->element->bindingIdentifier.toString()));
            }
        bool bodyOk;
        {
            ScopeGuard sg;   // the signal's arguments are named in the body (formals override)
            if (sigParams) {
                int i = 0;
                for (auto &pp : *sigParams) {
                    auto pn = i < (int)fnParams.size() ? fnParams[i] : pp.first;
                    g_scope.insert(pn);
                    g_propType[pn] = pp.second;   // typed: `stringProp = x + y` can coerce y
                    ++i;
                }
            }
            bodyOk = fnBody ? compileStmtList(fnBody, ptype, hbody) : compileStmt(h.stmt, ptype, hbody);
        }
        // `onWidthChanged` on an Item: width belongs to the BOUND BASE, not to this document, so
        // isProp() says no. The notify table knows it (and knows its real signature), which is
        // what makes the handler connectable — refusing it was a gap, not a rule.
        bool baseNotifyOk = false;
        std::string baseNotifySig;
        if (!isCustom && !notifyProp.empty()) {
            auto qn = g_qmlNotify.find(g_selfQmlType);
            if (qn != g_qmlNotify.end()) {
                auto nt = qn->second.find(notifyProp);
                if (nt != qn->second.end() && !nt->second.empty()) {
                    baseNotifyOk = true;
                    baseNotifySig = nt->second;
                }
            }
        }
        // `onClicked` on a MouseArea: a signal the BOUND TYPE declares, which is neither a notify
        // nor declared by this document. It was refused for want of a signature — the same shape
        // as the notify case above, and the signal table now supplies it. This is the majority
        // shape in real QML (226 of 373 handlers in the QML Qt ships), and the reason a compiled
        // MouseArea rendered pixel-identically and did nothing when clicked.
        if (!isCustom && !baseNotifyOk)
            if (auto qs2 = g_qmlSignals.find(g_selfQmlType); qs2 != g_qmlSignals.end()) {
                auto it = qs2->second.find(h.sig);
                if (it != qs2->second.end() && !it->second.empty()) {
                    baseNotifyOk = true;
                    baseNotifySig = it->second;
                    notifyProp.clear();   // not a property change: nothing to mark as notified
                }
            }
        if ((!isCustom && !baseNotifyOk && (notifyProp.empty() || !isProp(notifyProp))) || !bodyOk) {
            std::fprintf(stderr, "qmltc-d: %s: signal handler in %s not yet supported — skipped (later phase)\n", inPath, cls.c_str());
            ++partial; continue;
        }
        // A base property's notify is Qt's, not one we synthesise, so it must NOT go on
        // needsNotify (that list makes qmltc-d emit a Signal! field of its own).
        if (!baseNotifyOk && !notifyProp.empty()
                && std::find(needsNotify.begin(), needsNotify.end(), notifyProp) == needsNotify.end())
            needsNotify.push_back(notifyProp);
        // A custom signal handler takes the signal's parameters (accessible by name in the body);
        // param NAMES come from the handler function's formals when present, TYPES from the signal.
        std::string dparams, cppsig;
        if (sigParams) {
            int i = 0;
            for (auto &pp : *sigParams) {
                std::string pn = (i < (int)fnParams.size()) ? fnParams[i] : pp.first;
                dparams += (dparams.empty() ? "" : ", ") + pp.second + " " + pn;
                cppsig += (cppsig.empty() ? "" : ",") + cppTypeOf(pp.second);
                ++i;
            }
        }
        // The slot name carries the SENDER: two Connections targeting different objects may both
        // handle a signal of the same name, and a bare __h_<sig> made those collide (a D
        // redeclaration error — caught, but only at link time and only by luck of compiling both).
        std::string sndr = h.sender.empty() ? "this" : h.sender;
        std::string slotName = "__h_" + (h.sender.empty() ? "" : h.sender + "_") + h.sig;
        handlerSlots += "    @Slot void " + slotName + "(" + dparams + ") {\n" + hbody + "    }\n";
        // Connect with the base notify's REAL signature when that is what this handler is on.
        std::string connSig = baseNotifyOk ? baseNotifySig : (h.sig + "(" + cppsig + ")");
        handlerWire += "        connectMeta(" + sndr + ", \"" + connSig + "\", this, \""
                     + slotName + "(" + cppsig + ")\");\n";
    }
    // Component.onCompleted runs once at construction — emit its body at the tail of __qmltcWire
    // (after children built, bindings initialised, handlers connected), matching QML's timing.
    std::string onCompletedBody;
    if (onCompleted && !compileStmt(onCompleted, ptype, onCompletedBody)) {
        std::fprintf(stderr, "qmltc-d: %s: Component.onCompleted in %s not yet supported — skipped (later phase)\n", inPath, cls.c_str());
        ++partial; onCompletedBody.clear();
    }

    // Base C++ property assignments (`objectName: "hi"`) -> set through the meta-object in
    // __qmltcWire, and record for the dump (read back through the meta-object). int/string only.
    std::string baseWire;
    // Assignments that must run BEFORE this object's own bindings are evaluated. In QML a binding
    // is lazy — it is evaluated when its value is first needed, by which time every direct
    // assignment on the same object has happened — so `control: <the enclosing Button>` is in
    // place when `color: control.palette.base` runs. Our initial pass is eager and in document
    // order, so the same binding read through a null `control` and produced an empty colour
    // (Qt's Fusion RadioButton, CheckBox, MenuItem: the write failed outright once the colour
    // expressions started compiling). Only the assignments whose value is the ENCLOSING object go
    // here: it exists from the first line of the wire, where a child field does not.
    std::string earlyWire;
    for (auto &oa : objInitAssigns)
        baseWire += "        setPropObj(this, \"" + oa.first + "\", " + oa.second + ");\n";
    // Statements that must run only once the WHOLE tree is complete: connects to objects a Control
    // creates during its own completion (indicator/contentItem/background). The root triggers the
    // pass; every level forwards it to its children.
    std::string lateWire;
    // Recompute slots that must run AGAIN once the whole tree exists: their expression reads
    // through an object the enclosing wire assigns later. Collected as a set so a binding with
    // several such reads is re-evaluated once.
    std::set<std::string> reEval;
    for (auto &ba : rawBaseAssigns) {
        // A use-site binding resolves names in the USE SITE's scope: the local type's own declared
        // properties must not shadow the enclosing document. Qt's Fusion writes
        // `background: ButtonPanel { control: control }`, where the right-hand `control` is the
        // Button's id and the left-hand one is ButtonPanel's property. Merging the two bodies into
        // one class merged the scopes; this takes the declarations out for the length of this one
        // binding. Restored right after, because the DEFINITION's own bindings do see them.
        struct UseSiteScope { bool on = false; ~UseSiteScope() { if (on) g_useSiteShadowed.clear(); } } uss;
        if (ba.useSite && (!props.empty() || !g_selfIdsDefn.empty())) {
            for (auto &p : props) g_useSiteShadowed.insert(p.name);
            for (auto &i : g_selfIdsDefn) g_useSiteShadowed.insert(i);
            uss.on = true;
        }
        // Deep reads belong to the binding being compiled RIGHT NOW. The accumulator is global and
        // was only cleared after a consumer took it, so anything an earlier expression recorded and
        // nobody consumed — a CHILD's, whose object expression is spelled `__outer.__outer` —
        // stayed and was attributed to the next binding that did consume. That put a two-hop
        // connect in a ROOT class, which has no enclosing object at all, and it only became visible
        // when one more expression in Qt's Dial started compiling.
        g_deepReads.clear();
        // `aliasName: <expr>` assigns THROUGH the alias — QML aliases are references, so this
        // writes the target rather than declaring anything of our own.
        if (auto aw = g_aliasWrite.find(ba.first); aw != g_aliasWrite.end()) {
            if (isUndefined(ba.second)) {   // reset THROUGH the alias
                std::string call;
                if (!resetCall(aw->second.first, aw->second.second, call)) {
                    std::fprintf(stderr, "qmltc-d: %s: `%s: undefined` in %s targets a property with no RESET "
                                 "— skipped (later phase)\n", inPath, ba.first.c_str(), cls.c_str());
                    ++partial; continue;
                }
                baseWire += call; continue;
            }
            std::string ty = g_propType.count(ba.first) ? g_propType[ba.first] : "", val;
            if (ty.empty() || !compileExpr(ba.second, QString::fromStdString(ty), val)) {
                std::fprintf(stderr, "qmltc-d: %s: assignment to alias '%s' in %s not yet supported — skipped (later phase)\n",
                             inPath, ba.first.c_str(), cls.c_str());
                ++partial; continue;
            }
            baseWire += "        setProp(" + aw->second.first + ", \"" + aw->second.second + "\", " + val + ");\n";
            continue;
        }
        // The registry is authoritative: a property it declares with a type we don't compile
        // against must NOT fall through to literal inference, which would emit a plausible but
        // wrong value (a QJSValue property assigned `true` is not a bool).
        if (dBase && dBase->propUnsupported.count(ba.first)) {
            std::fprintf(stderr, "qmltc-d: %s: base property '%s' in %s has an unsupported declared type — skipped (later phase)\n",
                         inPath, ba.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        if (isUndefined(ba.second)) {
            std::string call;
            if (!resetCall("this", ba.first, call)) {
                std::fprintf(stderr, "qmltc-d: %s: `%s: undefined` in %s targets a property with no RESET "
                             "— skipped (later phase)\n", inPath, ba.first.c_str(), cls.c_str());
                ++partial; continue;
            }
            baseWire += call; continue;
        }
        // The DECLARED type wins over what the literal looks like — `width: 120` on an Item is a
        // qreal, and typing it from the literal made the dump read it with propInt and mutate it
        // with to!int, so a fractional value truncated or threw. g_baseProps already holds the
        // declared type (taken from the property table); inferType is the fallback.
        std::string ty = g_baseProps.count(ba.first) ? g_baseProps[ba.first]
                                                     : inferType(ba.second, ptype);
        // The table is authoritative and must be consulted before inferType's guess is accepted:
        // g_baseProps only holds what the ROOT prescan recorded, so a child object's base
        // property fell through to the literal — and to '?' whenever the value was not a literal.
        // 74 of Qt's own Controls assignments were rejected this way on plain double/bool.
        if (ty.empty() || !g_baseProps.count(ba.first))
            if (auto qp = g_qmlProps.find(g_selfQmlType); qp != g_qmlProps.end()) {
                auto pt = qp->second.find(ba.first);
                if (pt != qp->second.end() && !pt->second.empty()) ty = pt->second;
            }
        // ...and the C++ type for a property with NO D scalar — a colour, a font, an enum.
        // g_baseProps is keyed by property NAME alone and is global, so whichever type was
        // prescanned last decides: `color` on Qt's ButtonPanel was typed QColor in Button (the
        // last local type that document loaded) and untyped in ComboBox, where a later one
        // overwrote it. Same panel, same property, compiled in one file and refused in the other.
        // g_qmlCxxType is per-type and does not care about order.
        if (ty.empty())
            if (auto qc0 = g_qmlCxxType.find(g_selfQmlType); qc0 != g_qmlCxxType.end()) {
                auto ct0 = qc0->second.find(ba.first);
                // `^` marks a value type reached through an EXTENSION (see the generator); it says
                // nothing about the type itself, and the branches below match on the plain name.
                if (ct0 != qc0->second.end() && !ct0->second.empty()) {
                    ty = ct0->second;
                    if (ty.back() == '^') ty.pop_back();
                }
            }
        std::string val;
        std::string copyAssign;   // set when the value is a plain property read (a QVariant copy)
        // ...and set when the value is an OBJECT-or-null ternary, which takes the same binding path
        // as a scalar rather than being assigned once (see the note where it is filled in).
        std::string objAssign;
        bool scalar = (ty == "int" || ty == "string" || ty == "double" || ty == "bool");
        // A property we cannot type as a D scalar (QColor, QFont, an enum, a model) is still
        // perfectly reachable when the VALUE is just another property: the QVariant carries the
        // type and QMetaType converts on write. `font: control.font` and `color:
        // control.palette.text` are the two commonest lines in Qt's own Controls, and neither
        // needs the generator to know what a QFont is.
        // FLAGS: `closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside`. Qt parses
        // "A|B" for a flags property (QMetaEnum::keysToValue), so the keys are joined the way they
        // are written and no table of flag values is needed. It sits OUTSIDE the `!scalar` gate
        // below on purpose: with `|` the expression infers as int, so everything in there —
        // including the enum recognisers — is skipped, which is why putting it inside did nothing.
        // Its own key reader, because the one in there depends on locals defined with it.
        {
            // Recursive: `A | B | C` nests as ((A|B)|C), so an operand may itself be a chain. The
            // real line in Qt's ToolTip has three.
            std::function<std::string(ExpressionNode *)> flagKey = [&](ExpressionNode *x) -> std::string {
                if (auto *bx = cast<BinaryExpression *>(x); bx && bx->op == QSOperator::BitOr) {
                    std::string a = flagKey(bx->left), b = flagKey(bx->right);
                    return (a.empty() || b.empty()) ? std::string() : a + "|" + b;
                }
                auto *f = cast<FieldMemberExpression *>(x);
                if (!f) return "";
                std::string mem = qs(f->name.toString());
                if (mem.empty() || !std::isupper((unsigned char) mem[0])) return "";
                std::string tn;
                if (auto *fq = cast<FieldMemberExpression *>(f->base)) {          // Alias.Type.Key
                    auto *ai = cast<IdentifierExpression *>(fq->base);
                    if (!ai || !g_importAliases.count(qs(ai->name.toString()))) return "";
                    tn = qs(fq->name.toString());
                } else if (auto *ti = cast<IdentifierExpression *>(f->base)) {    // Type.Key
                    tn = qs(ti->name.toString());
                    if (g_scope.count(tn) || g_childIds.count(tn)) return "";
                } else return "";
                if (tn != "Qt" && !knownTypeName(tn)) return "";
                return mem;
            };
            if (auto *bor = cast<BinaryExpression *>(ba.second); bor && bor->op == QSOperator::BitOr) {
                std::string ka = flagKey(bor->left), kb = flagKey(bor->right);
                if (!ka.empty() && !kb.empty()) {
                    baseWire += "        setProp(this, \"" + ba.first + "\", \"" + ka + "|" + kb
                              + "\");\n";
                    node.baseProps.push_back({ba.first, "string"});
                    continue;
                }
            }
        }
        if (!scalar) {
            std::string srcObj, srcProp, srcGroup;
            // The source object is resolved through the SAME hop chain as a scalar read, so an
            // enclosing id two levels up works here too.
            auto resolveObj = [&](IdentifierExpression *b) -> std::string {
                std::string bn = qs(b->name.toString()), pre;
                const OuterFrame *fr = nullptr;
                if (outerHop(bn, pre, &fr)) return pre.substr(0, pre.size() - 1);
                if (auto ci = g_childIds.find(bn); ci != g_childIds.end()) return ci->second.field;
                if (isSelfId(bn)) return "this";
                return "";
            };
            // Resolves one property-read expression to (object, group, member); empty object
            // means it is not a plain read and cannot be copied.
            auto readSrc = [&](ExpressionNode *e, std::string &o, std::string &g, std::string &pr) {
                o.clear(); g.clear(); pr.clear();
                auto *fmv = cast<FieldMemberExpression *>(e);
                if (!fmv) return;
                if (auto *b0 = cast<IdentifierExpression *>(fmv->base)) {
                    o = resolveObj(b0);
                    if (!o.empty()) pr = qs(fmv->name.toString());
                } else if (auto *fmb = cast<FieldMemberExpression *>(fmv->base)) {
                    // `control.palette.text` — a member of a value-typed group on another object.
                    if (auto *b1 = cast<IdentifierExpression *>(fmb->base)) {
                        o = resolveObj(b1);
                        if (!o.empty()) { g = qs(fmb->name.toString()); pr = qs(fmv->name.toString()); }
                    }
                }
            };
            auto copyStmt = [&](const std::string &o, const std::string &g, const std::string &pr) {
                return g.empty()
                    ? "copyProp(" + o + ", \"" + pr + "\", this, \"" + ba.first + "\");"
                    : "copyGroupProp(" + o + ", \"" + g + "\", \"" + pr + "\", this, \""
                      + ba.first + "\");";
            };
            readSrc(ba.second, srcObj, srcGroup, srcProp);
            // `color: control.down ? control.palette.light : control.palette.base` — a ternary
            // BETWEEN two value-typed reads. Neither branch can be compiled to a D expression
            // (there is no D type for a QColor here), but each is a copy, so the condition picks
            // which copy runs. Both branches' dependencies are collected as usual, so it reacts.
            // ...and the branches may THEMSELVES be ternaries: Qt's Button picks defaultIconColor
            // through three nested ones. Handling only one level accepted the simple spelling and
            // refused the nested one — the same asymmetry, one nesting deeper.
            std::function<std::string(ExpressionNode *, const std::string &)> copyChain =
                [&](ExpressionNode *x, const std::string &ind) -> std::string {
                    // `(a ? b : c)` — a parenthesised branch is a NestedExpression, and Qt's Button
                    // writes one. Unwrap before asking what shape it is.
                    while (auto *ne = cast<NestedExpression *>(x)) x = ne->expression;
                    std::string ox, gx, px;
                    readSrc(x, ox, gx, px);
                    if (!ox.empty()) return ind + copyStmt(ox, gx, px) + "\n";
                    auto *c2 = cast<ConditionalExpression *>(x);
                    if (!c2) return "";
                    std::string ce2;
                    if (!compileExpr(c2->expression, "bool", ce2)) return "";
                    std::string a = copyChain(c2->ok, ind + "    "), b = copyChain(c2->ko, ind + "    ");
                    if (a.empty() || b.empty()) return "";
                    return ind + "if (" + ce2 + ") {\n" + a + ind + "} else {\n" + b + ind + "}\n";
                };
            if (srcObj.empty())
                if (cast<ConditionalExpression *>(ba.second)) {
                    std::string chain = copyChain(ba.second, "        ");
                    if (!chain.empty()) { copyAssign = chain; ty = "string"; }
                }
            // An ENUM member (`Text.AlignVCenter`, `Qt.AlignLeft`): the meta-object converts a KEY
            // STRING through QMetaEnum on write, so the numeric value is never needed here. `Qt` is
            // the namespace holder rather than a bound type, and the COMPARISON path accepts it, so
            // this must too. Returns the key, or empty when the expression is not an enum member.
            auto enumKeyOf = [&](ExpressionNode *x) -> std::string {
                auto *fme = cast<FieldMemberExpression *>(x);
                if (!fme) return "";
                // ...also when the type is reached through an IMPORT ALIAS (`T.Popup.CloseOnEscape`):
                // the base is then a member expression, not an identifier. Same shape the comparison
                // path needed; this is the ASSIGNMENT side of it.
                if (auto *fmq = cast<FieldMemberExpression *>(fme->base))
                    if (auto *ba2 = cast<IdentifierExpression *>(fmq->base);
                            ba2 && g_importAliases.count(qs(ba2->name.toString()))) {
                        std::string tq = qs(fmq->name.toString()), mq = qs(fme->name.toString());
                        if (mq.empty() || !std::isupper((unsigned char) mq[0])) return "";
                        if (!knownTypeName(tq)) return "";
                        return mq;
                    }
                auto *tb = cast<IdentifierExpression *>(fme->base);
                if (!tb) return "";
                std::string tn = qs(tb->name.toString()), mem = qs(fme->name.toString());
                if (!resolveObj(tb).empty() || g_singletons.count(tn) || mem.empty()
                        || !std::isupper((unsigned char)mem[0])
                        || (tn != "Qt" && !knownTypeName(tn))) return "";
                return mem;
            };
            if (srcObj.empty())
                if (std::string k = enumKeyOf(ba.second); !k.empty()) {
                    baseWire += "        setProp(this, \"" + ba.first + "\", \"" + k + "\");\n";
                    node.baseProps.push_back({ba.first, "string"});
                    continue;
                }
            // ...and a TERNARY between two enum members (`alignment: cond ? Qt.AlignCenter :
            // Qt.AlignLeft`). The direct form was accepted and this one was not, which is the same
            // asymmetry that kept turning up: one spelling compiles, the other does not.
            if (srcObj.empty())
                if (auto *cnd = cast<ConditionalExpression *>(ba.second)) {
                    std::string k1 = enumKeyOf(cnd->ok), k2 = enumKeyOf(cnd->ko), ce;
                    if (!k1.empty() && !k2.empty() && compileExpr(cnd->expression, "bool", ce)) {
                        copyAssign = "        setProp(this, \"" + ba.first + "\", " + ce
                                   + " ? \"" + k1 + "\" : \"" + k2 + "\");\n";
                        ty = "string";
                    }
                }
            // `color: defaultIconColor` — a value-typed property of THIS object, by bare name.
            if (srcObj.empty())
                if (auto *bi = cast<IdentifierExpression *>(ba.second)) {
                    std::string n = qs(bi->name.toString());
                    if (auto qc = g_qmlCxxType.find(g_selfQmlType); qc != g_qmlCxxType.end())
                        if (qc->second.count(n) && !g_scope.count(n)) { srcObj = "this"; srcProp = n; }
                }
            if (!srcObj.empty()) {
                copyAssign = srcGroup.empty()
                    ? "        copyProp(" + srcObj + ", \"" + srcProp + "\", this, \"" + ba.first + "\");\n"
                    : "        copyGroupProp(" + srcObj + ", \"" + srcGroup + "\", \"" + srcProp
                      + "\", this, \"" + ba.first + "\");\n";
                // Recorded as a STRING for the dump: QMetaType renders a QColor as #rrggbb and a
                // QFont as its descriptor, which is exactly what the oracle prints from the same
                // QVariant. An empty type made the dump fall back to an int read and print 0.
                ty = "string";
            }
        }
        // A property whose declared type we do not route (a colour) assigned from a SINGLETON
        // CALL: `color: Color.blend(a, b, f)` in Qt's own controls. The result crosses as text and
        // QMetaType turns it into a QColor on write — exactly how every other colour here travels,
        // so this needs no new type routing. Restricted to a singleton call: accepting any
        // string-compilable expression for an unrouted type would quietly write text into
        // properties that are not colours.
        // ...and a CONDITIONAL whose branches are themselves colours: `color: cond ? a : b`, which
        // is what a rewritten script binding becomes. Same channel as the singleton call above —
        // the value crosses as text and QMetaType turns it into a QColor on write — and setProp
        // throws if the property does not take it, so a wrong target is loud rather than silent.
        if (copyAssign.empty() && !scalar)
            if (cast<ConditionalExpression *>(ba.second) && compileExpr(ba.second, "string", val)) {
                scalar = true;
                ty = "string";
            }
        // ...and a NON-SCALAR target fed an enum member of a type exported for its enum alone:
        // `shortcut: StandardKey.Undo` on Qt's editing Actions, where `shortcut` is a QVariant and
        // `StandardKey` is QKeySequence. There is no object to read the member from and the key as
        // text is no use (Qt would parse "Undo" as three letters), so the NUMBER goes across —
        // which is exactly what QML assigns there. Resolved at runtime through QMetaEnum, so no
        // table of enum values is needed anywhere.
        if (copyAssign.empty() && !scalar)
            if (auto *ee = cast<FieldMemberExpression *>(ba.second))
                if (auto *et = cast<IdentifierExpression *>(ee->base)) {
                    std::string tn = qs(et->name.toString()), key = qs(ee->name.toString());
                    auto cx = g_qmlCxxName.find(tn);
                    if (cx != g_qmlCxxName.end() && !key.empty()
                            && std::isupper((unsigned char) key[0])
                            && !g_scope.count(tn) && !g_childIds.count(tn)) {
                        baseWire += "        setProp(this, \"" + ba.first + "\", enumValue(\""
                                  + cx->second + "\", \"" + key + "\"));\n";
                        node.baseProps.push_back({ba.first, "int"});
                        continue;
                    }
                }
        // ...and a target whose declared type IS a colour, fed from anything that compiles as text:
        // `color: pressedColor`, where `pressedColor` is a declared `property color` that now exists
        // and is read through the meta-object. The value crosses as text and QMetaType converts it,
        // the same channel the colour literals and singleton calls already use.
        if (copyAssign.empty() && !scalar && ty == "QColor"
                && compileExpr(ba.second, "string", val)) {
            scalar = true;
            ty = "string";
        }
        // ...and a bare singleton PROPERTY read into the same unrouted type: `color: Fusion.topShadow`
        // (Qt's Fusion, eleven times). Same channel as the call below — the value crosses as text
        // and QMetaType converts it on write.
        if (copyAssign.empty() && !scalar)
            if (auto *px = cast<FieldMemberExpression *>(ba.second))
                if (auto *pv = cast<IdentifierExpression *>(px->base);
                        pv && g_qmlSingletonUri.count(qs(pv->name.toString()))
                        && compileExpr(ba.second, "string", val)) {
                    scalar = true;
                    ty = "string";
                }
        if (copyAssign.empty() && !scalar)
            if (auto *cx = cast<CallExpression *>(ba.second))
                if (auto *cfm = cast<FieldMemberExpression *>(cx->base)) {
                    // The receiver is an identifier (`Fusion.buttonColor(…)`) or a singleton reached
                    // through an IMPORT ALIAS (`FusionControls.Fusion.gradientStart(…)`, which Qt's
                    // own Fusion writes wherever it imports its module aliased). The alias is not a
                    // value — what decides is the name AFTER it.
                    std::string sName;
                    if (auto *crv = cast<IdentifierExpression *>(cfm->base))
                        sName = qs(crv->name.toString());
                    else if (auto *cfa = cast<FieldMemberExpression *>(cfm->base))
                        if (auto *cia = cast<IdentifierExpression *>(cfa->base);
                                cia && g_importAliases.count(qs(cia->name.toString())))
                            sName = qs(cfa->name.toString());
                    if (!sName.empty() && g_qmlSingletonUri.count(sName)
                            && compileExpr(ba.second, "string", val)) {
                        scalar = true;
                        ty = "string";
                    }
                }
        // ...or the target is a DECLARED OBJECT property and the value is an object: `control:
        // control` on Qt's Fusion ButtonPanel, where the right-hand side is the enclosing Button
        // (the use-site scope rule above is what makes it resolve to that and not to the property
        // being assigned). An ordinary meta-object write of an object, the same channel a
        // property-bound child uses.
        if (copyAssign.empty() && !scalar) {
            auto isObjProp = [&](const std::string &n) {
                for (auto &p : props)
                    if (p.name == n)
                        return !p.dtype.empty() && p.dtype != "int" && p.dtype != "bool"
                            && p.dtype != "double" && p.dtype != "string";
                return false;
            };
            // ...and a BASE property that holds an object, which the registry types with a name
            // ending in `*` — or with QJSValue, which is how Qt's Rectangle declares `gradient`.
            // `gradient: control.down || control.checked ? null : buttonGradient` is how every
            // Fusion panel switches its gradient off: an OBJECT-or-null ternary, written through
            // the same channel a plain object assignment uses (the runtime turns an object into a
            // script value for a QJSValue target).
            auto isNullLit = [](ExpressionNode *x) { return cast<NullExpression *>(x) != nullptr; };
            if (copyAssign.empty() && !scalar
                    && (ty == "QJSValue" || (!ty.empty() && ty.back() == '*')))
                if (auto *cnd9 = cast<ConditionalExpression *>(ba.second)) {
                    std::string ce9, oeA, oqA;
                    ExpressionNode *objSide = isNullLit(cnd9->ok) ? cnd9->ko
                                            : isNullLit(cnd9->ko) ? cnd9->ok : nullptr;
                    if (objSide && compileExpr(cnd9->expression, "bool", ce9)
                            && objPathExpr(objSide, oeA, oqA)) {
                        std::string yes = isNullLit(cnd9->ok) ? "null" : oeA;
                        std::string no  = isNullLit(cnd9->ok) ? oeA : "null";
                        // Falls through to the BINDING path below instead of assigning once. The
                        // condition reads `control.down`, and a one-shot left every Fusion panel
                        // drawing its UNPRESSED gradient forever — the flat pressed colour is what
                        // shows when the gradient is null. Measured on the frame after a click on
                        // Fusion's ComboBox: 2714 of 3240 pixels, every row of the panel, with
                        // every readable property of both sides already equal.
                        objAssign = "        setPropObj(this, \"" + ba.first + "\", "
                                  + ce9 + " ? " + yes + " : " + no + ");\n";
                    }
                }
            std::string oe9, oq9;
            if (isObjProp(ba.first) && objPathExpr(ba.second, oe9, oq9)) {
                (oe9.rfind("__outer", 0) == 0 ? earlyWire : baseWire)
                    += "        setPropObj(this, \"" + ba.first + "\", " + oe9 + ");\n";
                node.baseProps.push_back({ba.first, ty});
                continue;
            }
        }
        if (objAssign.empty() && copyAssign.empty()
                && (!scalar || !compileExpr(ba.second, QString::fromStdString(ty), val))) {
            // Two very different gaps used to share one message, which made the cluster
            // unreadable: a declared TYPE we don't route (color, font, an enum) is not the same
            // problem as an EXPRESSION we can't compile into a type we do route.
            // ...and WHICH type the property was looked up on: "declared type '?'" alone never
            // said whose table came back empty, which is the difference between an unrouted type
            // and a type whose registry rows were never loaded.
            std::fprintf(stderr, "qmltc-d: %s:%s: base property '%s' in %s (%s) not yet supported: %s '%s' [%s] — skipped (later phase)\n",
                         inPath, posOf(ba.second).c_str(), ba.first.c_str(), cls.c_str(),
                         g_selfQmlType.empty() ? "?" : g_selfQmlType.c_str(),
                         scalar ? "expression for" : "declared type", ty.empty() ? "?" : ty.c_str(),
                         srcOf(ba.second).c_str());
            ++partial; continue;
        }
        // A D base's property is an inherited FIELD -> assign it; a bound C++ base's is a
        // Q_PROPERTY reachable only through the meta-object.
        // The copy is a BINDING like any other: it goes through the same recompute+connect path
        // below, which also fixes ordering — children are constructed before the parent assigns
        // its own properties, so the first copy reads a default and the notify corrects it.
        std::string assign = !objAssign.empty() ? objAssign
                           : !copyAssign.empty() ? copyAssign
                           : g_baseIsD ? ("        " + ba.first + " = " + val + ";\n")
                                       : ("        setProp(this, \"" + ba.first + "\", " + val + ");\n");
        baseWire += assign;
        // ...and if the expression READS anything, it is a BINDING, not an assignment: it has to
        // recompute when a dependency changes. This was emitted as a one-shot with no connect and
        // no diagnostic, so `width: pad * 10` kept its first value forever and looked correct
        // (QBaseReactive pins it: after pad=7 the engine says 70, the one-shot said 40). The
        // declared-property direction was already wired; this is the same wire, the other way.
        {
            std::vector<std::string> deps;
            collectIds(ba.second, deps);
            std::set<std::string> seen;
            std::string conns;
            // ...and the connects that must wait for the whole tree: a SIBLING id.
            std::string sibConns;
            for (auto &d : deps) {
                if (d == ba.first || !seen.insert(d).second) continue;   // self-reference is not a dep
                // `@Type.prop` — an ATTACHED read: connect to the attached object's own notify.
                if (d.rfind("@", 0) == 0) {
                    auto dot = d.find('.');
                    std::string tn2 = d.substr(1, dot - 1), mem2 = d.substr(dot + 1);
                    std::string sig2;
                    if (auto an = g_qmlAttachedNotify.find(tn2); an != g_qmlAttachedNotify.end()) {
                        auto nt2 = an->second.find(mem2);
                        if (nt2 != an->second.end()) sig2 = nt2->second;
                    }
                    if (sig2.empty()) {
                        std::fprintf(stderr, "qmltc-d: %s: base binding '%s' in %s depends on the "
                                     "attached '%s.%s', whose notify is unknown — it would not update "
                                     "(later phase)\n", inPath, ba.first.c_str(), cls.c_str(),
                                     tn2.c_str(), mem2.c_str());
                        ++partial; continue;
                    }
                    // tryConnectMeta, not connectMeta: the ATTACHED object does not exist until the
                    // item is in a window, so at construction the endpoint is legitimately null and a
                    // throwing connect kills the object. The initial value is still right (a null
                    // window is the `false` branch, which is what the engine reports); what is missing
                    // is re-evaluation when the window arrives — recorded, not hidden.
                    conns += "        tryConnectMeta(" + attachedExpr(tn2) + ", \"" + sig2
                           + "\", this, \"__rcb_" + ba.first + "()\");\n";
                    continue;
                }
                if (d.rfind("__outer.", 0) == 0 && !outerDepIsPath(d)) {   // reads an enclosing object
                    std::string obj, mem, sig; const OuterFrame *fr = nullptr;
                    if (!splitOuterDep(d, obj, mem, &fr)) {
                        // Reported, not dropped. `__outer.<group>.<member>` (Qt's SearchField pads
                        // itself from `control.searchIndicator.indicator`) does not split, and this
                        // used to `continue` in SILENCE — the read compiled, nothing connected, and
                        // no message said so. A binding that looks live and is not is the worst
                        // thing this compiler can emit, so it says so now.
                        std::fprintf(stderr, "qmltc-d: %s: binding in %s depends on '%s', a path through "
                                     "an enclosing object that is not wired — it would not update "
                                     "(later phase)\n", inPath, cls.c_str(), d.c_str());
                        ++partial; continue;
                    }
                    if (!fr->baseProps.count(mem) && fr->propType.count(mem)) {
                        sig = mem + "Changed()";
                        g_outerNeedsNotify.push_back({(int)std::count(obj.begin(), obj.end(), '.'), mem});
                    }
                    else if (auto qn = g_qmlNotify.find(fr->qmlType); qn != g_qmlNotify.end()) {
                        auto nt = qn->second.find(mem);
                        if (nt != qn->second.end()) sig = nt->second;
                    }
                    if (!sig.empty()) {
                        conns += "        connectMeta(" + obj + ", \"" + sig + "\", this, \"__rcb_"
                               + ba.first + "()\");\n";
                        continue;
                    }
                    // A CONSTANT dependency is complete without a connection — the value read at
                    // construction is the only value there will ever be. Reporting it as partial
                    // said a correct translation was incomplete.
                    if (isConstProp(fr->qmlType, mem)) continue;
                    std::fprintf(stderr, "qmltc-d: %s: base binding '%s' in %s depends on '%s' of the "
                                 "enclosing object, which has no known notify — it would not update "
                                 "(later phase)\n", inPath, ba.first.c_str(), cls.c_str(), mem.c_str());
                    ++partial; continue;
                }
                if (isProp(d)) {
                    // The dependency must actually CARRY a notify: needsNotify is what makes
                    // qmltc-d emit the `Signal!() <d>Changed` field. Connecting without this
                    // threw at wire time ("no such signal padChanged()"), because nothing else
                    // in the document happened to depend on that property.
                    if (std::find(needsNotify.begin(), needsNotify.end(), d) == needsNotify.end())
                        needsNotify.push_back(d);
                    conns += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rcb_"
                           + ba.first + "()\");\n";
                    continue;
                }
                // `<childId>.<prop>` — the binding reads ANOTHER object of this document through
                // its id (Qt's TextField sizes itself from `placeholder.implicitHeight`). The
                // notify belongs to THAT object, so the connection is made to it; connecting to
                // ourselves would compile and never fire.
                if (auto dot = d.find('.'); dot != std::string::npos) {
                    auto ci = g_childIds.find(d.substr(0, dot));
                    if (ci != g_childIds.end()) {
                        std::string mem = d.substr(dot + 1), csig;
                        if (auto bn2 = ci->second.baseNotify.find(mem); bn2 != ci->second.baseNotify.end())
                            csig = bn2->second;
                        else if (ci->second.propType.count(mem)) {
                            csig = mem + "Changed()";
                            g_forceNotify[d.substr(0, dot)].insert(mem);
                        }
                        if (!csig.empty()) {
                            // sibConns, not conns: a CHILD is built after this object's own
                            // properties are assigned (the order the engine uses), so its field is
                            // still null while the wire's connect section runs and connectMeta
                            // threw on it — Qt's TextField reads `placeholder.implicitWidth`. The
                            // late phase already exists for exactly this shape and re-evaluates
                            // once after connecting.
                            sibConns += "        connectMeta(" + ci->second.field + ", \"" + csig
                                      + "\", this, \"__rcb_" + ba.first + "()\");\n";
                            continue;
                        }
                    }
                }
                // ...or an object PATH the registry resolves: connect to the object the path
                // reaches, on the leaf's own notify. tryConnectMeta because that object may not
                // exist yet at wire time (a control builds its background in componentComplete),
                // and a throwing connect would kill the object for a reactivity detail.
                // A bare name that is a property of THIS object belongs to THIS object — QML
                // resolves a name in the nearest scope, and so must the dependency. Offering it to
                // the enclosing chain first made `maximumFlickVelocity: 4 * width` inside a
                // control's contentItem re-run when the CONTROL's width changed — before Qt had
                // resized the contentItem — and never again. Measured on Qt's SwipeView and TabBar
                // by mutating `width`: both matched at construction and were wrong after it.
                if (d.find('.') == std::string::npos)
                    if (auto qnS = g_qmlNotify.find(g_selfQmlType);
                            qnS != g_qmlNotify.end() && qnS->second.count(d)
                            && !qnS->second.at(d).empty()) {
                        conns += "        connectMeta(this, \"" + qnS->second.at(d) + "\", this, \"__rcb_"
                               + ba.first + "()\");\n";
                        continue;
                    }
                if (std::string so9, lf9; styleHintsDep(d, so9, lf9) || attachedOuterDep(d, so9, lf9)
                        || outerBareDep(d, so9, lf9)) {
                    conns += "        connectNotify(" + so9 + ", \"" + lf9 + "\", this, \"__rcb_"
                           + ba.first + "()\");\n";
                    // ...and the FIRST computation belongs to the late phase. Connecting alone let
                    // the binding recompute mid-construction, with geometry that is not final yet,
                    // and never again — measured: five ScrollBar radii and two implicitWidths came
                    // out wrong that way, which is worse than the one-shot it replaced.
                    lateWire += "        __rcb_" + ba.first + "();\n";
                    continue;
                }
                std::string dEff = d;
                if (dEff.find('.') != std::string::npos) {
                    std::string oe6, sig6;
                    g_depIsSibling = false;
                    if (objPathFromString(dEff, oe6, sig6)) {
                        // lateConns, not conns: a sibling built after us is still null while our
                        // own wire runs. The late phase already exists for exactly this, and it
                        // re-evaluates once after connecting.
                        std::string &sink = g_depIsSibling ? sibConns : conns;
                        sink += "        tryConnectMeta(" + oe6 + ", \"" + sig6 + "\", this, \"__rcb_" + ba.first + "()\");\n";
                        // ...and the object's OWN "something changed" signal. A value group can
                        // change what it RESOLVES to without any member signal firing: disabling a
                        // control switches its palette group, `windowTextChanged()` never fires,
                        // and the colour stayed at the enabled one. Measured on Qt's Label —
                        // `changed()` on the palette object is what the engine's binding follows.
                        // tryConnectMeta because a group without that signal simply has none.
                        sink += "        tryConnectMeta(" + oe6 + ", \"changed()\", this, \"__rcb_"
                              + ba.first + "()\");\n";
                        // A path that goes THROUGH a property-held object (`control.popup.palette`)
                        // reads an object the enclosing wire has not assigned yet — QML would have
                        // evaluated the binding later, when it is there. Re-evaluated in the late
                        // phase, which the root triggers once the whole tree exists; a recompute
                        // only emits on an actual change, so a redundant one costs nothing.
                        if (oe6.find("propObj(") != std::string::npos)
                            reEval.insert("__rcb_" + ba.first);
                        continue;
                    }
                    // ...or it resolves to an object whose TYPE simply does not declare the leaf.
                    // QML is dynamically typed and Qt relies on it: `indicator.control.checkState`
                    // where `control` is a MenuItem, which has no checkState. The ENGINE has
                    // nothing to connect to there either, so best effort on Qt's notify convention
                    // — null-safe AND signal-safe, so if the object turns out to have it the
                    // binding is live, and if not, nothing happens.
                    {
                        std::string headD = dEff.substr(0, dEff.rfind('.'));
                        std::string leafD = dEff.substr(dEff.rfind('.') + 1);
                        std::string oeW, oqW;
                        if (objPathWalkDotted(headD, oeW, oqW)
                                && typeKnownWithoutMember(oqW, leafD)) {
                            conns += "        tryConnectMeta(" + oeW + ", \"" + leafD
                                   + "Changed()\", this, \"__rcb_" + ba.first + "()\");\n";
                            conns += "        tryConnectMeta(" + oeW + ", \"changed()\", this, \"__rcb_"
                                   + ba.first + "()\");\n";
                            continue;
                        }
                    }
                    // ...and when it does not resolve, depend on the HEAD, which is what this did
                    // before the path was recorded at all. Reporting instead would turn a binding
                    // that used to connect into a refusal — a regression dressed as honesty.
                    dEff = dEff.substr(0, dEff.find('.'));
                }
                std::string sig;
                if (auto qn = g_qmlNotify.find(g_selfQmlType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(dEff);
                    if (nt != qn->second.end() && !nt->second.empty()) sig = nt->second;
                }
                if (!sig.empty()) {
                    conns += "        connectMeta(this, \"" + sig + "\", this, \"__rcb_"
                           + ba.first + "()\");\n";
                    continue;
                }
                if (g_valueLists.count(d) || g_singletons.count(d) || g_qmlSingletonUri.count(d)) continue;
            if (g_childIds.count(d)) continue;   // a child object's id: the field never changes   // nothing mutates these
                // ...and a bare CHILD ID is a field this class holds: the object it names never
                // changes, so there is nothing to connect to and nothing missing. Qt's Fusion
                // panels write `gradient: control.down ? null : buttonGradient`, and reporting
                // `buttonGradient` as having no notify called a correct translation incomplete.
                if (g_childIds.count(d)) continue;
                // A CONTEXT name inside a delegate (`index`): it belongs to no object the document
                // names, but the per-item context carries an object that publishes it as a property
                // WITH a notify — so the binding is as live as any other, same channel.
                if (!g_delegateCls.empty() && !g_hasRequiredDecl
                        && d.find('.') == std::string::npos && !g_propType.count(d)
                        && !g_baseProps.count(d) && !g_scope.count(d) && !g_childIds.count(d)) {
                    conns += "        connectNotify(contextObject(this), \"" + d + "\", this, \"__rcb_"
                           + ba.first + "()\");\n";
                    continue;
                }
                std::fprintf(stderr, "qmltc-d: %s: base binding '%s' in %s depends on '%s', which has "
                             "no known notify — it would not update (later phase)\n",
                             inPath, ba.first.c_str(), cls.c_str(), d.c_str());
                ++partial;
            }
            // A read through an object-valued property connects in the LATE phase, to the inner
            // object's own notify — by then the Control has created it. The recompute is called
            // once there too, since the value read at wire time came from a null object.
            std::string lateConns, lateLeaf;
            for (auto &dr : g_deepReads) {
                std::string sig;
                if (auto qn = g_qmlNotify.find(dr.innerQmlType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(dr.member);
                    if (nt != qn->second.end()) sig = nt->second;
                }
                if (sig.empty()) {
                    std::fprintf(stderr, "qmltc-d: %s: base binding '%s' in %s reads '%s.%s' whose "
                                 "notify is unknown — it would not update (later phase)\n",
                                 inPath, ba.first.c_str(), cls.c_str(), dr.inner.c_str(), dr.member.c_str());
                    ++partial; lateConns.clear(); lateLeaf.clear(); break;
                }
                // Follow the PROPERTY, not the object it happens to hold right now: connect its
                // notify so the binding re-runs when it is assigned, and re-subscribe to the leaf
                // signal from inside the slot (a root's `parent` is still null in the LATE phase).
                lateConns += "        connectNotify(" + dr.obj + ", \"" + dr.inner
                           + "\", this, \"__rcb_" + ba.first + "()\");\n";
                lateLeaf  += "        bindLeaf(" + dr.obj + ", \"" + dr.inner + "\", \"" + sig
                           + "\", this, \"__rcb_" + ba.first + "()\");\n";
            }
            g_deepReads.clear();
            if (!conns.empty() || !lateConns.empty() || !sibConns.empty()) {
                handlerSlots += "    @Slot void __rcb_" + ba.first + "() {\n" + lateLeaf
                              + "    " + assign + "    }\n";
                bindWire += conns;
                if (!lateConns.empty() || !sibConns.empty())
                    lateWire += lateConns + sibConns + "        __rcb_" + ba.first + "();\n";
            }
        }
        node.baseProps.push_back({ba.first, ty});
    }

    // Children attached to a grouped property's member: compile like any child, but the D field is
    // named after the sanitised path (a dotted name is not a valid D identifier) and the object is
    // attached THROUGH the group rather than held by a property of this class.
    for (auto &gk : groupKidBindings) {
        std::string path = gk.path;
        auto dot = path.find('.');
        std::string gname = path.substr(0, dot), mem = path.substr(dot + 1);
        std::string field = "_g_" + gname + "_" + mem;
        std::string childCls = cls + "_" + gname + "_" + mem;
        auto gkt = boundTypeFor(gk.type);          // a bound child type makes this a SUBCLASS
        UiObjectInitializer *gkInit = gk.init;
        // A LOCAL `.qml` type here too — `first.handle: SliderHandle { … }` is how Qt's Fusion
        // RangeSlider builds both of its handles. Without this the child came out a bare @QObject,
        // and writing a plain QObject into a `QQuickItem*` property is either refused (so the
        // handle never appears) or, if forced, dereferenced by Qt as an item and segfaults. Same
        // three steps the default-child path takes: take the base from the local definition's own
        // root, adopt the registry rows the base publishes, and splice the use site's members onto
        // the definition's.
        std::vector<std::string> gkResolved;
        if (gkt.first.empty() && gk.type != "QtObject") {
            QString savedSrc2 = g_srcText;
        g_srcStack.push_back(savedSrc2);
            std::string savedUrl2 = g_docUrl;
            bool gkFound = false;
            auto chained = resolveLocalChain(gk.type, inPath, gkInit, gkResolved, nullptr, &gkFound);
            if (gkFound) gkt = chained;
            g_srcStack.pop_back(); g_srcText = savedSrc2;
            g_docUrl = savedUrl2;
        }
        if (!gkt.first.empty() && !gkt.second.empty()) {
            std::string imp = "import " + gkt.second + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + gkt.second.substr(0, gkt.second.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        for (auto &rp : gkResolved) g_resolving.insert(rp);
        ObjNode kid = compileObject(gkInit, childCls, classes, partial, inPath, gkt.first, nullptr, gk.type);
        for (auto &rp : gkResolved) g_resolving.erase(rp);
        {   // a child connects to <prop>Changed on us, or on someone above us
            auto pending = g_outerNeedsNotify;
            g_outerNeedsNotify.clear();
            for (auto &__on : pending) {
                if (__on.first == 0) {
                    if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                        needsNotify.push_back(__on.second);
                } else {
                    g_outerNeedsNotify.push_back({__on.first - 1, __on.second});   // forward it up
                }
            }
        }
        // A child that reached PAST us needs us to hold our own back-reference, since its hops
        // are spelled `__outer.__outer...` and go through ours.
        if (kid.outerHops >= 1) {
            g_outerUsed = true;
            if (kid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = kid.outerHops - 1;
        }
        childFields += "    " + childCls + " " + field + ";\n";
        // A GROUP member, unlike an attached one, CAN be a deferred property: Qt's
        // QQuickIndicatorButton declares `Q_CLASSINFO("DeferredPropertyNames", "indicator")`, which
        // is what `searchIndicator.indicator:` assigns. So it stays with the deferred children —
        // moving it into the object's own body changed the frame after a click on Qt's own
        // SearchField (56 pixels, measured), while the attached case needs the opposite.
        childWire += std::string((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (gkt.first.empty() ? "newQObject!" + childCls + "()"
                                                                       : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + field + ", this);\n";
        childWire += "        setPropObj(propObj(this, \"" + gname + "\"), \"" + mem + "\", " + field + ");\n";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(path);
    }

    // Array-binding elements: each is an ordinary child object; the engine reaches it at its index
    // in the list property, so that is the dump label. Nothing is appended to the D-side list —
    // the dump reads the field, exactly as for default children.
    for (auto &ae : arrayBindings) {
        std::string field = "_al_" + ae.prop + "_" + std::to_string(ae.idx);
        std::string childCls = cls + "_" + ae.prop + "_" + std::to_string(ae.idx);
        std::string childType = ae.def->qualifiedTypeNameId ? typeName(ae.def->qualifiedTypeNameId) : "";
        auto cbt = boundTypeFor(childType);
        if (unboundChildType(childType, cbt.first, inPath)) {
            std::fprintf(stderr, "qmltc-d: %s: '%s[%d]' in %s is a '%s', which is not a bound Qt type "
                         "— building it as a bare object would drop every property set on it — "
                         "skipped (later phase)\n",
                         inPath, ae.prop.c_str(), ae.idx, cls.c_str(), childType.c_str());
            ++partial; continue;
        }
        if (!cbt.first.empty()) g_extraImports += "import " + cbt.second + ";\n";
        ObjNode kid = compileObject(ae.def->initializer, childCls, classes, partial, inPath, cbt.first, nullptr, childType);
        {   // a child connects to <prop>Changed on us, or on someone above us
            auto pending = g_outerNeedsNotify;
            g_outerNeedsNotify.clear();
            for (auto &__on : pending) {
                if (__on.first == 0) {
                    if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                        needsNotify.push_back(__on.second);
                } else {
                    g_outerNeedsNotify.push_back({__on.first - 1, __on.second});   // forward it up
                }
            }
        }
        // A child that reached PAST us needs us to hold our own back-reference, since its hops
        // are spelled `__outer.__outer...` and go through ours.
        if (kid.outerHops >= 1) {
            g_outerUsed = true;
            if (kid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = kid.outerHops - 1;
        }
        childFields += "    " + childCls + " " + field + ";\n";
        childWire += std::string((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (cbt.first.empty() ? "newQObject!" + childCls + "()"
                                                                     : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + field + ", this);\n"
                   // ...and APPENDED to the list the document names, in ORDER. Creating and
                   // parenting is not the same as `transform: [ Translate {}, Rotation {} ]`:
                   // without the append the objects exist and do nothing — Qt's Dial builds both of
                   // its handle transforms and the handle was neither translated nor rotated.
                   + "        listAppend(this, \"" + ae.prop + "\", " + field + ");\n";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(ae.prop + "[" + std::to_string(ae.idx) + "]");
    }

    // A child object bound to an ATTACHED member: built in D, then attached through the attached
    // object. Same field-vs-path split as a group child — the D field can't be the dotted path.
    for (auto &ak : attachedKidBindings) {
        auto dot = ak.path.find('.');
        std::string tn = ak.path.substr(0, dot), mem = ak.path.substr(dot + 1);
        std::string field = "_a_" + tn + "_" + mem;
        std::string childCls = cls + "_" + tn + "_" + mem;
        auto akt = boundTypeFor(ak.type);   // a bound child type makes this a SUBCLASS
        // ...and if it is not bound, it may be a LOCAL .qml type, exactly as for an ordinary child.
        // ScrollView.qml writes `ScrollBar.vertical: ScrollBar {}` where that ScrollBar is the
        // style's OWN ScrollBar.qml — QtQuick.Templates is imported under an alias, so the bare
        // name is not the Templates type. Without this the child came out a bare QObject with none
        // of the type's properties, and its first connect threw.
        UiObjectInitializer *akInit = ak.init;
        std::vector<std::string> akResolvedPath;
        QString savedAkSrc = g_srcText;
        g_srcStack.push_back(savedAkSrc);
        auto savedAkBare = g_bareImports, savedAkQual = g_qualifiedTypes;
        if (akt.first.empty() && ak.type != "QtObject" && !ak.type.empty()) {
            bool akFound = false;
            auto chained = resolveLocalChain(ak.type, inPath, akInit, akResolvedPath, nullptr, &akFound);
            if (akFound) akt = chained;
        }
        if (!akt.first.empty() && !akt.second.empty()) {
            std::string imp = "import " + akt.second + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + akt.second.substr(0, akt.second.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        for (auto &rp : akResolvedPath) g_resolving.insert(rp);
        ObjNode kid = compileObject(akInit, childCls, classes, partial, inPath, akt.first, nullptr, ak.type);
        for (auto &rp : akResolvedPath) g_resolving.erase(rp);
        g_srcStack.pop_back(); g_srcText = savedAkSrc; g_bareImports = savedAkBare; g_qualifiedTypes = savedAkQual;
        {   // a child connects to <prop>Changed on us, or on someone above us
            auto pending = g_outerNeedsNotify;
            g_outerNeedsNotify.clear();
            for (auto &__on : pending) {
                if (__on.first == 0) {
                    if (std::find(needsNotify.begin(), needsNotify.end(), __on.second) == needsNotify.end())
                        needsNotify.push_back(__on.second);
                } else {
                    g_outerNeedsNotify.push_back({__on.first - 1, __on.second});   // forward it up
                }
            }
        }
        // A child that reached PAST us needs us to hold our own back-reference, since its hops
        // are spelled `__outer.__outer...` and go through ours.
        if (kid.outerHops >= 1) {
            g_outerUsed = true;
            if (kid.outerHops - 1 > g_outerHopsNeeded) g_outerHopsNeeded = kid.outerHops - 1;
        }
        childFields += "    " + childCls + " " + field + ";\n";
        ownBodyWire += std::string((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (akt.first.empty() ? "newQObject!" + childCls + "()"
                                                                       : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + field + ", this);\n";
        ownBodyWire += "        setPropObj(" + attachedExpr(tn) + ", \"" + mem + "\", " + field + ");\n";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(ak.label.empty() ? ak.path : ak.label);
    }

    // Use-site override: merging a local type's members in front of this file's can leave two
    // assignments to the same attached member. QML semantics are last-wins, and a duplicate would
    // also emit the same dump label twice.
    {
        std::vector<std::pair<std::string, ExpressionNode *>> dedup;
        for (auto it = rawAttachedAssigns.rbegin(); it != rawAttachedAssigns.rend(); ++it) {
            bool seen = false;
            for (auto &d : dedup) if (d.first == it->first) { seen = true; break; }
            if (!seen) dedup.push_back(*it);
        }
        std::reverse(dedup.begin(), dedup.end());
        rawAttachedAssigns.swap(dedup);
    }

    // Attached-property assignments and handlers. The attached object is fetched by type name at
    // runtime; from there its members and signals are ordinary ones on that object.
    std::string attachedHandlerSlots;
    // An attached assignment inherited from a local `.qml` BASE is not reproduced faithfully: the
    // engine does not re-apply the base's attached bindings to the derived object's attachment
    // (attachedPropertyDerived.qml keeps the default where the base sets 41+1). Rather than emit a
    // plausible-but-different value, refuse the case.
    if (g_localMerged && !rawAttachedAssigns.empty()) {
        std::fprintf(stderr, "qmltc-d: %s: attached properties inherited from a local .qml base type in %s "
                     "are not yet supported — skipped (later phase)\n", inPath, cls.c_str());
        ++partial;
        rawAttachedAssigns.clear();
    }
    for (auto &aa : rawAttachedAssigns) {
        auto dot = aa.first.find('.');
        std::string tn = aa.first.substr(0, dot), mem = aa.first.substr(dot + 1);
        auto mt = g_attached[tn]->propType.find(mem);
        std::string val;
        if (mt == g_attached[tn]->propType.end()
                || !compileExpr(aa.second, QString::fromStdString(mt->second), val)) {
            std::fprintf(stderr, "qmltc-d: %s: attached property '%s' in %s not yet supported — skipped (later phase)\n",
                         inPath, aa.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        baseWire += "        setProp(" + attachedExpr(tn) + ", \"" + mem + "\", " + val + ");\n";
        node.attachedProps.push_back({aa.first, mt->second});
    }
    for (auto &ah : rawAttachedHandlers) {
        auto dot = ah.first.find('.');
        std::string tn = ah.first.substr(0, dot), sig = ah.first.substr(dot + 1);
        auto *at = g_attached[tn];
        Statement *bodyStmt = ah.second;
        StatementList *fnBody = nullptr;
        if (auto *es = cast<ExpressionStatement *>(bodyStmt))
            if (auto *fe = es->expression->asFunctionDefinition()) fnBody = fe->body;
        std::string hbody;
        if (!(fnBody ? compileStmtList(fnBody, ptype, hbody) : compileStmt(bodyStmt, ptype, hbody))) {
            std::fprintf(stderr, "qmltc-d: %s: handler '%s' on an attached property in %s not yet supported — skipped (later phase)\n",
                         inPath, ah.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        auto ss = at->signalSig.find(sig);
        std::string cppsig = ss != at->signalSig.end() ? ss->second : (sig + "()");
        std::string slot = "__ha_" + tn + "_" + sig;
        attachedHandlerSlots += "    @Slot void " + slot + "() {\n" + hbody + "    }\n";
        handlerWire += "        connectMeta(" + attachedExpr(tn) + ", \"" + cppsig
                     + "\", this, \"" + slot + "()\");\n";
    }

    // Handlers ON a grouped property (`group.onCountChanged: …`): the signal belongs to the GROUP
    // object, the slot to this one. The signal's real signature comes from the group class's
    // registry entry — a NOTIFY is not necessarily a parameterless `<prop>Changed`.
    std::string groupHandlerSlots;
    for (auto &gh : rawGroupHandlers) {
        auto dot = gh.first.find('.');
        std::string gname = gh.first.substr(0, dot), sig = gh.first.substr(dot + 1);
        auto *gt = g_groups[gname];
        // the handler body may be a bare statement or `function(...) { … }`
        Statement *bodyStmt = gh.second;
        StatementList *fnBody = nullptr;
        if (auto *es = cast<ExpressionStatement *>(bodyStmt))
            if (auto *fe = es->expression->asFunctionDefinition()) fnBody = fe->body;
        std::string hbody;
        bool ok = fnBody ? compileStmtList(fnBody, ptype, hbody) : compileStmt(bodyStmt, ptype, hbody);
        if (!ok) {
            std::fprintf(stderr, "qmltc-d: %s: handler '%s' on grouped property in %s not yet supported — skipped (later phase)\n",
                         inPath, gh.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        auto ss = gt->signalSig.find(sig);
        std::string cppsig = ss != gt->signalSig.end() ? ss->second : (sig + "()");
        std::string slot = "__hg_" + gname + "_" + sig;
        groupHandlerSlots += "    @Slot void " + slot + "() {\n" + hbody + "    }\n";
        handlerWire += "        connectMeta(propObj(this, \"" + gname + "\"), \"" + cppsig
                     + "\", this, \"" + slot + "()\");\n";
    }

    // Grouped-property assignments: set the member on the group OBJECT, which is reached through
    // the parent's meta-object. The dump reports them under the same dotted path the engine-side
    // oracle walks (`group.count`), so the two sides compare directly.
    for (auto &ga : rawGroupAssigns) {
        auto dot = ga.first.find('.');
        std::string gname = ga.first.substr(0, dot), mem = ga.first.substr(dot + 1);
        auto &members = g_groups[gname]->propType;
        auto mt = members.find(mem);
        std::string val;
        if (mt == members.end() || !compileExpr(ga.second, QString::fromStdString(mt->second), val)) {
            std::fprintf(stderr, "qmltc-d: %s: grouped property '%s' in %s not yet supported — skipped (later phase)\n",
                         inPath, ga.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        baseWire += "        setProp(propObj(this, \"" + gname + "\"), \"" + mem + "\", " + val + ");\n";
        node.groupProps.push_back({ga.first, mt->second});
    }

    // A VALUE group's member: setVgroup reads the value, changes the member and writes the whole
    // value back. Writing through propObj here would dereference null — there is no group object.
    for (auto &ga : rawValueGroupAssigns) {
        auto dot = ga.first.find('.');
        std::string gname = ga.first.substr(0, dot), mem = ga.first.substr(dot + 1);
        auto &members = g_vgroups[gname]->propType;
        auto mt = members.find(mem);
        std::string val;
        if (mt == members.end() || !compileExpr(ga.second, QString::fromStdString(mt->second), val)) {
            std::fprintf(stderr, "qmltc-d: %s: value-type group property '%s' in %s not yet supported"
                         " — skipped (later phase)\n", inPath, ga.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        baseWire += "        setVgroup(this, \"" + gname + "\", \"" + mem + "\", " + val + ");\n";
        node.valueGroupProps.push_back({ga.first, mt->second});
    }

    // Wire a GROUP assignment's dependencies, the way a base-property binding is wired: without
    // this a grouped write is a one-shot that goes stale silently (`border.width: bw + 1` kept its
    // first value when bw changed). Mirrors the logic the base-property loop has inline; the two
    // must agree, which is why this is a named helper rather than a fourth copy.
    // `emitSlot == false`: the caller already wrote the slot and only wants it CONNECTED. The
    // text-channel fallback for an object-group member does that — it hand-writes the slot with a
    // different name and, until this, wired no dependencies at all: `border.color:
    // control.activeFocus ? palette.highlight : palette.mid` on Qt's TextField was computed once in
    // the late phase and never again, so clicking into the field left the border grey where the
    // engine paints it with the accent colour. Found by the CLICK axis; the mutation sweep could
    // not see it, since `activeFocus` is read-only and never mutated.
    auto wireGroupDeps = [&](ExpressionNode *expr, const std::string &slot,
                             const std::string &assign, const std::string &what,
                             bool emitSlot = true) {
        std::vector<std::string> deps;
        collectIds(expr, deps);
        std::set<std::string> seen;
        std::string conns;
        // ...and the connects that must wait for the whole tree: a SIBLING id.
        std::string sibConns;
        for (auto &d : deps) {
            if (!seen.insert(d).second) continue;
            if (d.rfind("__outer.", 0) == 0 && !outerDepIsPath(d)) {
                std::string obj, mem, sig; const OuterFrame *fr = nullptr;
                if (!splitOuterDep(d, obj, mem, &fr)) continue;
                if (!fr->baseProps.count(mem) && fr->propType.count(mem)) {
                    sig = mem + "Changed()";
                    g_outerNeedsNotify.push_back({(int)std::count(obj.begin(), obj.end(), '.'), mem});
                } else if (auto qn = g_qmlNotify.find(fr->qmlType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(mem);
                    if (nt != qn->second.end()) sig = nt->second;
                }
                if (!sig.empty()) conns += "        connectMeta(" + obj + ", \"" + sig + "\", this, \""
                                         + slot + "()\");\n";
                continue;
            }
            if (isProp(d)) {
                if (std::find(needsNotify.begin(), needsNotify.end(), d) == needsNotify.end())
                    needsNotify.push_back(d);
                conns += "        connectMeta(this, \"" + d + "Changed()\", this, \"" + slot + "()\");\n";
                continue;
            }
            // `<childId>.<prop>` — the binding reads ANOTHER object of this document through its
            // id. The notify belongs to that object, so the connection is made to IT: connecting to
            // ourselves would compile and never fire. A property the child DECLARES has no notify
            // until someone asks for one, which is what g_forceNotify records.
            if (auto dot = d.find('.'); dot != std::string::npos) {
                auto ci = g_childIds.find(d.substr(0, dot));
                if (ci != g_childIds.end()) {
                    std::string mem = d.substr(dot + 1), csig;
                    if (auto bn = ci->second.baseNotify.find(mem); bn != ci->second.baseNotify.end())
                        csig = bn->second;
                    else if (ci->second.propType.count(mem)) {
                        csig = mem + "Changed()";
                        g_forceNotify[d.substr(0, dot)].insert(mem);
                    }
                    if (!csig.empty()) {
                        sibConns += "        connectMeta(" + ci->second.field + ", \"" + csig
                                  + "\", this, \"" + slot + "()\");\n";   // ...built after us
                        continue;
                    }
                }
            }
            // ...or an object PATH the registry resolves: connect to the object the path
            // reaches, on the leaf's own notify. tryConnectMeta because that object may not
            // exist yet at wire time (a control builds its background in componentComplete),
            // and a throwing connect would kill the object for a reactivity detail.
            // Nearest scope first — see the same guard in the base-binding wiring above.
            if (d.find('.') == std::string::npos)
                if (auto qnS = g_qmlNotify.find(g_selfQmlType);
                        qnS != g_qmlNotify.end() && qnS->second.count(d) && !qnS->second.at(d).empty()) {
                    conns += "        connectMeta(this, \"" + qnS->second.at(d) + "\", this, \""
                           + slot + "()\");\n";
                    continue;
                }
            if (std::string so9, lf9; styleHintsDep(d, so9, lf9) || attachedOuterDep(d, so9, lf9)
                        || outerBareDep(d, so9, lf9)) {
                conns += "        connectNotify(" + so9 + ", \"" + lf9 + "\", this, \"" + slot + "()\");\n";
                continue;
            }
            std::string dEff = d;
            if (dEff.find('.') != std::string::npos) {
                std::string oe6, sig6;
                g_depIsSibling = false;
                if (objPathFromString(dEff, oe6, sig6)) {
                    // A SIBLING is null while our own wire runs (the enclosing object builds its
                    // children in order), so both the connect and the first evaluation belong to
                    // the late phase the root triggers once the whole tree exists.
                    std::string &sink = g_depIsSibling ? sibConns : conns;
                    sink += "        tryConnectMeta(" + oe6 + ", \"" + sig6 + "\", this, \"" + slot + "()\");\n";
                    sink += "        tryConnectMeta(" + oe6 + ", \"changed()\", this, \"" + slot + "()\");\n";
                    if (oe6.find("propObj(") != std::string::npos) reEval.insert(slot);
                    continue;
                }
                // ...or the path resolves to an object whose TYPE simply does not declare the
                // leaf. Best effort on Qt's own notify convention, null-safe and signal-safe: if
                // it is there at runtime the binding is live, and if it is not, nothing happens —
                // which is exactly what the engine does with the same document.
                {
                    std::string headD = dEff.substr(0, dEff.rfind('.'));
                    std::string leafD = dEff.substr(dEff.rfind('.') + 1);
                    std::string oeW, oqW;
                    if (objPathWalkDotted(headD, oeW, oqW)
                            && typeKnownWithoutMember(oqW, leafD)) {
                        conns += "        tryConnectMeta(" + oeW + ", \"" + leafD
                               + "Changed()\", this, \"" + slot + "()\");\n";
                        conns += "        tryConnectMeta(" + oeW + ", \"changed()\", this, \""
                               + slot + "()\");\n";
                        continue;
                    }
                }
                dEff = dEff.substr(0, dEff.find('.'));   // as before: depend on the head
            }
            std::string sig;
            if (auto qn = g_qmlNotify.find(g_selfQmlType); qn != g_qmlNotify.end()) {
                auto nt = qn->second.find(dEff);
                if (nt != qn->second.end()) sig = nt->second;
            }
            if (!sig.empty()) { conns += "        connectMeta(this, \"" + sig + "\", this, \"" + slot + "()\");\n"; continue; }
            if (g_valueLists.count(d) || g_singletons.count(d) || g_qmlSingletonUri.count(d)) continue;
            // A CONTEXT name inside a delegate (`index`): it belongs to no object the document
            // names, but the per-item context DOES carry an object that publishes it as a property
            // with a notify — so the binding is as live as any other, through the same channel.
            if (!g_delegateCls.empty() && !g_hasRequiredDecl
                    && d.find('.') == std::string::npos && !g_propType.count(d)
                    && !g_baseProps.count(d) && !g_scope.count(d) && !g_childIds.count(d)) {
                conns += "        connectNotify(contextObject(this), \"" + d + "\", this, \""
                       + slot + "()\");\n";
                continue;
            }
            std::fprintf(stderr, "qmltc-d: %s: %s in %s depends on '%s', which has no known notify "
                         "— it would not update (later phase)\n", inPath, what.c_str(), cls.c_str(), d.c_str());
            ++partial;
        }
        if (!conns.empty() || !sibConns.empty()) {
            if (emitSlot) handlerSlots += "    @Slot void " + slot + "() {\n    " + assign + "    }\n";
            bindWire += conns;
            if (!sibConns.empty()) lateWire += sibConns + "        " + slot + "();\n";
        }
    };

    // Value sources: build the object, then hand it the property it drives.
    for (size_t vi = 0; vi < valueSources.size(); ++vi) {
        auto &vs = valueSources[vi];
        auto vst = boundTypeFor(vs.type);
        if (!vst.second.empty()) {
            std::string imp = "import " + vst.second + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + vst.second.substr(0, vst.second.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        std::string field = "_vs" + std::to_string(vi);
        std::string childCls = cls + "_vs" + std::to_string(vi);
        bool savedVS = g_isValueSource;
        g_isValueSource = true;
        ObjNode kid = compileObject(vs.init, childCls, classes, partial, inPath, vst.first, nullptr, vs.type);
        g_isValueSource = savedVS;
        childFields += "    " + childCls + " " + field + ";\n";
        // qobjOf(this), not cast(void*)this: the handoff carries the C++ QObject, and a void*
        // passes straight through qobjOf — publishing the D reference handed Qt a pointer that is
        // not a QObject at all, which segfaulted inside QQmlProperty.
        childWire += "        __qmltcVsTarget = qobjOf(this); __qmltcVsProp = \"" + vs.prop + "\";\n"
                   // ...and the back-reference handoff, which every other child site does and this
                   // one did not: a value source that reads its enclosing object cast whatever the
                   // PARENT had published, which between unrelated D classes is null. Qt's Fusion
                   // BusyIndicator and ProgressBar died at construction on the resulting null
                   // endpoint ("no such signal runningChanged() ... or a null endpoint").
                   + ((kid.usesOuter || g_isDelegate) ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = new " + childCls + "();\n"
                   + "        setQtParent(" + field + ", this);\n";
        node.vsKids.push_back({field, kid});
    }

    std::string whenMethods;   // folded into stateMethods where the rest of the state machinery is
    // `when:` is an ordinary binding on `state` — which is what the engine does with it,
    // so entering AND leaving both go through the machinery above with no new case. Qt's
    // ScrollBar hides its contentItem with `opacity: 0.0` and reveals it from a state whose
    // `when` follows `control.active`; without this the bar never appeared at all, which
    // the CLICK differential is what noticed.
    for (auto &st : stateTable) {
        if (!st.when) continue;
        std::string ce;
        if (!compileExpr(st.when, "bool", ce)) {
            std::fprintf(stderr, "qmltc-d: %s: `when` of state '%s' in %s not yet supported "
                         "— skipped (later phase)\n", inPath, st.name.c_str(), cls.c_str());
            ++partial; continue;
        }
        std::string slot = "__rcw_" + st.name;
        std::string stmt = "        setProp(this, \"state\", " + ce + " ? \"" + st.name
                         + "\" : \"\");\n";
        whenMethods += "    @Slot void " + slot + "() {\n" + stmt + "    }\n";
        wireGroupDeps(st.when, slot, stmt, "`when` of state '" + st.name + "'", false);
        lateWire += "        " + slot + "();\n";
    }

    // A declared VALUE-TYPE property is live like any other binding: same channel, same connects.
    for (auto &md : metaAssignDeps) {
        std::string st;
        for (auto &ma : metaAssigns)
            if (ma.first == md.first) { st = "        setProp(this, \"" + ma.first + "\", " + ma.second + ");\n"; break; }
        if (st.empty()) continue;
        wireGroupDeps(md.second, "__rcm_" + md.first, st,
                      "declared value property '" + md.first + "'");
    }

    // Grouped assignment on a plain Q_GADGET value: read-modify-write of the whole value.
    for (auto &ga : rawBaseVGroupAssigns) {
        auto dot = ga.first.find('.');
        std::string gname = ga.first.substr(0, dot), mem = ga.first.substr(dot + 1);
        std::string vty = inferType(ga.second, ptype), val;
        // A value with NO inferred type is not necessarily unusable: an enum member crosses this
        // channel as an INT (`Easing.InOutCubic` is a property of a real QML singleton, and QML's
        // own value for it is a number), and anything else that compiles as text crosses as text.
        // The KEY is the last resort, for a namespace the registry does not export at all.
        if (vty.empty() && compileExpr(ga.second, "int", val)) vty = "int";
        else if (vty.empty() && compileExpr(ga.second, "string", val)) vty = "string";
        else if (std::string ek = enumMemberKeyLoose(ga.second); !ek.empty()) {
            vty = "string"; val = "\"" + ek + "\"";
        } else
        if ((vty != "int" && vty != "double" && vty != "bool" && vty != "string")
                || !compileExpr(ga.second, QString::fromStdString(vty), val)) {
            std::fprintf(stderr, "qmltc-d: %s: value-group member '%s' in %s: value is not a scalar "
                         "the channel can convert [%s] — skipped (later phase)\n",
                         inPath, ga.first.c_str(), cls.c_str(), srcOf(ga.second).c_str());
            ++partial; continue;
        }
        std::string st = "        setVgroup(this, \"" + gname + "\", \"" + mem + "\", " + val + ");\n";
        baseWire += st;
        wireGroupDeps(ga.second, "__rcv_" + gname + "_" + mem, st, "value-group member '" + ga.first + "'");
        node.valueGroupProps.push_back({ga.first, vty});
    }

    // ...and on a value type reached through an extension: written BY NAME through QML's own
    // value-type registry, since there is no gadget meta-object to read-modify-write.
    for (auto &ga : rawExtVGroupAssigns) {
        std::string vty = inferType(ga.second, ptype), val;
        if (vty.empty() && compileExpr(ga.second, "int", val)) vty = "int";   // ...same as above
        else if (vty.empty() && compileExpr(ga.second, "string", val)) vty = "string";
        else if (std::string ek = enumMemberKeyLoose(ga.second); !ek.empty()) {
            vty = "string"; val = "\"" + ek + "\"";
        } else
        if ((vty != "int" && vty != "double" && vty != "bool" && vty != "string")
                || !compileExpr(ga.second, QString::fromStdString(vty), val)) {
            std::fprintf(stderr, "qmltc-d: %s: value-type member '%s' in %s: value is not a scalar "
                         "the channel can convert [%s] — skipped (later phase)\n",
                         inPath, ga.first.c_str(), cls.c_str(), srcOf(ga.second).c_str());
            ++partial; continue;
        }
        std::string st = "        setQmlProp(this, \"" + ga.first + "\", " + val + ");\n";
        baseWire += st;
        auto dotE = ga.first.find('.');
        wireGroupDeps(ga.second, "__rcx_" + ga.first.substr(0, dotE) + "_" + ga.first.substr(dotE + 1),
                      st, "value-type member '" + ga.first + "'");
        node.valueGroupProps.push_back({ga.first, vty});
    }

    // Grouped assignment where the group is an OBJECT: a property write on what it holds.
    for (auto &ga : rawObjGroupAssigns) {
        auto dot = ga.first.find('.');
        std::string gname = ga.first.substr(0, dot), mem = ga.first.substr(dot + 1);
        std::string vty = inferType(ga.second, ptype), val;
        if ((vty != "int" && vty != "double" && vty != "bool" && vty != "string")
                || !compileExpr(ga.second, QString::fromStdString(vty), val)) {
            // `border.color: control.palette.dark` — a VALUE-typed source. The group is an object,
            // so this is the same QVariant copy used for a base property, with the group object as
            // the destination: the type is carried by the variant, not known here.
            std::string so, sg, sp;
            resolveReadSrc(ga.second, so, sg, sp);
            // `border.color: control.visualFocus ? control.palette.highlight : control.palette.dark`
            // — a ternary BETWEEN two value reads, which a base property already supports. Doing
            // it here too keeps the two positions consistent: the condition picks which copy runs.
            std::string condExpr, so2, sg2, sp2;
            if (so.empty())
                if (auto *cnd = cast<ConditionalExpression *>(ga.second)) {
                    std::string o1, g1, p1;
                    resolveReadSrc(cnd->ok, o1, g1, p1);
                    resolveReadSrc(cnd->ko, so2, sg2, sp2);
                    if (!o1.empty() && !so2.empty() && compileExpr(cnd->expression, "bool", condExpr)) {
                        so = o1; sg = g1; sp = p1;
                    } else { condExpr.clear(); }
                }
            if (!so.empty()) {
                std::string dst = "propObj(this, \"" + gname + "\")";
                auto one = [&](const std::string &o, const std::string &g, const std::string &pr) {
                    return g.empty()
                        ? "copyProp(" + o + ", \"" + pr + "\", " + dst + ", \"" + mem + "\");"
                        : "copyGroupProp(" + o + ", \"" + g + "\", \"" + pr + "\", " + dst
                          + ", \"" + mem + "\");";
                };
                std::string stmt = condExpr.empty()
                    ? "        " + one(so, sg, sp) + "\n"
                    : "        if (" + condExpr + ") " + one(so, sg, sp) + "\n"
                      + "        else " + one(so2, sg2, sp2) + "\n";
                // A BINDING, not a one-shot — and its first run belongs in the late phase: the
                // child is constructed before its parent assigns anything, so a copy made during
                // the wire necessarily reads a default (measured: #b8b8b8 where the engine had
                // seagreen). The connect is to whatever the source hangs off, so a later change
                // still propagates.
                std::string slot = "__rcg_" + gname + "_" + mem;
                std::string dep = sg.empty() ? sp : sg, sig;
                const OuterFrame *fr0 = nullptr;
                for (auto &f : g_outerChain) if (so.rfind("__outer", 0) == 0) { fr0 = &f; break; }
                const std::string &srcType = fr0 ? fr0->qmlType : g_selfQmlType;
                if (fr0 && !fr0->baseProps.count(dep) && fr0->propType.count(dep)) sig = dep + "Changed()";
                else if (auto qn = g_qmlNotify.find(srcType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(dep);
                    if (nt != qn->second.end()) sig = nt->second;
                }
                handlerSlots += "    @Slot void " + slot + "() {\n    " + stmt + "    }\n";
                if (!sig.empty())
                    bindWire += "        connectMeta(" + so + ", \"" + sig + "\", this, \""
                                 + slot + "()\");\n";
                // ...and every dependency of the CONDITION, which this connected none of: Qt's
                // SearchField paints its border with the accent colour while
                // `control.activeFocus || control.contentItem.activeFocus` holds, and only the
                // colour SOURCE was followed — so clicking into the field left the border grey.
                // Same defect the text-channel branch below had, in the branch that takes the
                // ternary-between-two-reads shape instead.
                if (ga.second)
                    wireGroupDeps(ga.second, slot, stmt, "object-group member '" + ga.first + "'", false);
                lateWire += "        " + slot + "();\n";
                node.groupProps.push_back({ga.first, "string"});
                continue;
            }
            // ...and when the source is not a plain read or a ternary BETWEEN two of them — Qt's
            // SpinBox nests one: `c ? A : (enabled ? B : C)` — fall back to the text channel the
            // colours already use. QMetaType turns the string into a QColor on write, and setProp
            // throws if the member does not take one, so a wrong target stays loud.
            if (std::string sval; compileExpr(ga.second, "string", sval)) {
                std::string slot = "__rcg_" + gname + "_" + mem;
                std::string sst = "        setProp(propObj(this, \"" + gname + "\"), \"" + mem
                                + "\", " + sval + ");\n";
                handlerSlots += "    @Slot void " + slot + "() {\n" + sst + "    }\n";
                // ...and CONNECTED, which it was not: the slot existed and nothing ever called it
                // again after the late phase.
                wireGroupDeps(ga.second, slot, sst, "object-group member '" + ga.first + "'", false);
                lateWire += "        " + slot + "();\n";
                node.groupProps.push_back({ga.first, "string"});
                continue;
            }
            std::fprintf(stderr, "qmltc-d: %s: object-group member '%s' in %s: value is not a scalar "
                         "the channel can convert [%s] — skipped (later phase)\n",
                         inPath, ga.first.c_str(), cls.c_str(), srcOf(ga.second).c_str());
            ++partial; continue;
        }
        std::string st = "        setProp(propObj(this, \"" + gname + "\"), \"" + mem + "\", " + val + ");\n";
        baseWire += st;
        wireGroupDeps(ga.second, "__rco_" + gname + "_" + mem, st, "object-group member '" + ga.first + "'");
        node.groupProps.push_back({ga.first, vty});
    }

    // QML `function`s -> D methods (no-arg). A `return <expr>` body becomes a typed method whose
    // return type was inferred into g_funcRet; other bodies become void methods (assignments/calls).
    // Typed PARAMETERS are still a later step.
    std::string methods;
    {
        std::map<std::string, std::string> pt0;   // declared prop types, for param inference
        for (auto &p : props) pt0[p.name] = p.dtype;
        for (auto *fn : functions) {
            std::string name = qs(fn->name.toString());
            auto params = funcParams(fn, pt0);
            // A parameter whose type the graph does not reduce to something definite: refuse the
            // function rather than pick one. Guessing `double` compiled `f(x, y) { return x + y }`
            // into numeric addition, which is wrong the moment it is called with strings — QML
            // concatenates there. Qt declines the same shape ("Functions without type annotations
            // won't be compiled"), and being wrong is worse than being incomplete.
            {
                bool untyped = false;
                for (auto &pp : params) if (pp.second.empty()) untyped = true;
                if (untyped) {
                    std::fprintf(stderr, "qmltc-d: %s: function '%s' in %s has a parameter whose type "
                                 "cannot be determined from its use — skipped rather than guessed "
                                 "(later phase)\n", inPath, qs(fn->name.toString()).c_str(), cls.c_str());
                    ++partial; continue;
                }
            }
            std::string sig;   // "double n, string s"
            auto ptWithParams = ptype;
            ScopeGuard sg;   // params (and any `var` locals) are in scope for this body only
            for (auto &pp : params) {
                sig += (sig.empty() ? "" : ", ") + pp.second + " " + pp.first;
                ptWithParams[pp.first] = pp.second;
                g_scope.insert(pp.first);
                g_propType[pp.first] = pp.second;
            }
            // A body with a `return` -> a typed method (return type inferred into g_funcRet); the
            // WHOLE body is compiled with g_returnType set, so multi-statement bodies (locals,
            // increments, then `return ...`) work, not just a single return.
            if (auto *rexpr = fn->body ? findReturnExpr(fn->body) : nullptr) {
                // A function that RETURNS a value must emit a typed method; if its return type can't
                // be resolved (unmapped type) or the body doesn't compile, flag PARTIAL — never fall
                // through to the void path (which would emit `return <expr>` inside a `void` function).
                std::string rt = g_funcRet.count(name) ? g_funcRet[name] : inferType(rexpr, ptWithParams);
                bool done = false;
                if (!rt.empty()) {
                    auto savedRT = g_returnType;
                    g_returnType = rt;
                    std::string fbody;
                    bool ok = compileStmtList(fn->body, ptWithParams, fbody);
                    g_returnType = savedRT;
                    if (ok) {
                        methods += "    " + rt + " " + name + "(" + sig + ") {\n" + fbody + "    }\n";
                        if (sig.empty()) node.methods0.push_back(name);
                        done = true;
                    }
                }
                if (!done) {
                    std::fprintf(stderr, "qmltc-d: %s: function '%s' in %s has an unsupported return type — skipped (later phase)\n", inPath, name.c_str(), cls.c_str());
                    ++partial;
                }
                continue;
            }
            // Void body (assignments / calls). Parameters allowed but only over property/param refs.
            std::string fbody;
            if (!compileStmtList(fn->body, ptWithParams, fbody)) {
                std::fprintf(stderr, "qmltc-d: %s: function '%s' in %s body not yet supported — skipped (later phase)\n", inPath, name.c_str(), cls.c_str());
                ++partial; continue;
            }
            methods += "    void " + name + "(" + sig + ") {\n" + fbody + "    }\n";
            if (sig.empty()) node.methods0.push_back(name);
        }
    }

    for (auto &p : props) {
        if (p.bound && std::find(needsNotify.begin(), needsNotify.end(), p.name) == needsNotify.end())
            needsNotify.push_back(p.name);
        for (auto &d : p.deps)
            if (isProp(d) && std::find(needsNotify.begin(), needsNotify.end(), d) == needsNotify.end())
                needsNotify.push_back(d);
    }
    auto notified = [&](const std::string &n){ return std::find(needsNotify.begin(), needsNotify.end(), n) != needsNotify.end(); };
    node.notified = needsNotify;   // so a parent can tell whether an aliased child prop is live

    for (auto &vl : g_valueLists) node.valueLists.push_back({vl.first, vl.second});
    std::string body, recompute, stateFields, stateMethods = whenMethods;
    bool anyBound = false;
    // The store half of a recompute. A property whose D type is a VALUE TYPE (QColor and every
    // other type with no D scalar) can be driven by an expression that produced TEXT — a colour
    // read crosses the meta channel as text, and so does anything computed from one — and D will
    // not put a string in a QColor field. Writing it back through the meta channel instead lets
    // QMetaType convert it to the field's own type, and that write already fires the notify and
    // already suppresses a no-op (callProp's value path), so this branch must not emit either.
    // Which branch applies is decided by the compiler from the expression's own type, so a value
    // type driven by a real value (`property color a: base`) still assigns the field directly.
    auto storeInto = [&](const Prop &p) {
        std::string direct = "if (" + p.name + " != _v) { " + p.name + " = _v;"
                           + (notified(p.name) ? " " + p.name + "Changed.emit();" : "") + " }";
        if (p.dtype == "int" || p.dtype == "double" || p.dtype == "float"
                || p.dtype == "bool" || p.dtype == "string")
            return "        " + direct + "\n";
        // Braced: `static if (c) if (x) {...} else ...` binds the `else` to the INNER `if`.
        return "        static if (is(typeof(_v) : typeof(" + p.name + "))) { " + direct + " }\n"
             + "        else setProp(this, \"" + p.name + "\", _v);\n";
    };
    for (auto &p : props) {
        node.scalars.push_back({p.name, p.dtype});
        std::string notifyUda = notified(p.name) ? "@Property(\"" + p.name + "Changed\") " : "@Property ";
        if (p.bound) {
            // D initialises a floating-point field to NaN; QML's default for `real` is 0. The
            // difference is observable the moment one binding reads another before it has been
            // evaluated — Fusion's CheckIndicator computes `Qt.lighter(base, baseLightness)`
            // before `baseLightness` is assigned, and a NaN factor aborts Qt inside qRound.
            // (The value settles either way, through the notify; it is the transient that differs.)
            const char *zero = (p.dtype == "double" || p.dtype == "float") ? " = 0" : "";
            body += "    " + notifyUda + p.dtype + " " + p.name + zero + ";\n";
            if (notified(p.name)) body += "    Signal!() " + p.name + "Changed;\n";
            // Which binding currently drives this property. 0 = the declarative one; a
            // `Qt.binding(...)` install switches it, and a plain assignment (`p = 42`) clears it
            // to -1 — matching QML, where assigning a value REMOVES the binding. Every recompute
            // is connected up front and simply does nothing unless it is the active one, which
            // avoids having to disconnect anything at runtime.
            if (g_rebound.count(p.name)) {
                g_hasSelector.insert(p.name);
                body += "    private int __bind_" + p.name + " = 0;\n";
                recompute += "    @Slot void __rc_" + p.name + "() {\n"
                           + "        if (__bind_" + p.name + " != 0) return;\n"
                           + "        auto _v = " + coerceTo(p.dtype, p.expr) + ";\n"
                           + storeInto(p) + "    }\n";
                anyBound = true;
                continue;
            }
            recompute += "    @Slot void __rc_" + p.name + "() {\n"
                       + "        auto _v = " + coerceTo(p.dtype, p.expr) + ";\n"
                       + storeInto(p) + "    }\n";
            anyBound = true;
        } else {
            // An empty expr means the value is written through the meta-object (see metaAssigns):
            // the field is declared bare and QMetaType fills it — and a bare floating-point field
            // is NaN in D where QML's `real` defaults to 0. A declared property whose initial
            // binding was refused kept that NaN and reported it as the property's value (Fusion's
            // SliderGroove `offset`, where the engine reads 0).
            body += "    " + notifyUda + p.dtype + " " + p.name
                  + (p.expr.empty() ? ((p.dtype == "double" || p.dtype == "float") ? " = 0" : "")
                                    : " = " + p.expr) + ";\n";
            if (notified(p.name)) body += "    Signal!() " + p.name + "Changed;\n";
        }
    }

    // Imperatively-installed bindings: one guarded recompute each, connected up front so the
    // selector alone decides which is live.
    for (auto &rb : g_rebinds) {
        auto pt = g_propType.count(rb.first) ? g_propType[rb.first] : std::string();
        for (auto &b : rb.second) {
            recompute += "    @Slot void __rc_" + rb.first + "_" + std::to_string(b.idx) + "() {\n"
                       + "        if (__bind_" + rb.first + " != " + std::to_string(b.idx) + ") return;\n"
                       + "        auto _v = " + coerceTo(pt, b.expr) + ";\n"
                       + "        if (" + rb.first + " != _v) { " + rb.first + " = _v;"
                       + (notified(rb.first) ? " " + rb.first + "Changed.emit();" : "") + " }\n    }\n";
            for (auto &d : b.deps)
                if (isProp(d))
                    bindWire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_"
                                 + rb.first + "_" + std::to_string(b.idx) + "()\");\n";
        }
    }

    std::string wire;
    // ...and an object that takes the `__outer` handoff (or drives a value source) needs a ctor
    // body even when every one of its own members was refused: SpinBox's IntValidator child had
    // all three bindings skipped, so the wire was empty, and inserting the handoff into it hit
    // `npos + 18` == 17 and ABORTED the compiler on three of Qt's files.
    // ...and UNCONDITIONALLY otherwise: the engine attaches a context and calls
    // classBegin/componentComplete on every object it creates, members or not, and a bound type
    // can need that even when the document says nothing about it. `T.HorizontalHeaderView {}` —
    // two lines, no members — got no wire at all, so it never completed: Qt's TableView builds its
    // model in componentComplete, and the object reported model null and rows -1 where the engine
    // reports 0 and 1. The wire costs three calls for an object that has nothing else to do.
    {
        wire = "    void __qmltcWire() {\n";
        // Before ANY property is read: a Control's palette comes from the theme its style module
        // installs, and resolution is lazy, so this only has to precede the first read.
        if (!g_docModule.empty())
            wire += "        ensureModule(\"" + g_docModule + "\");\n";
        // classBegin() BEFORE any property is assigned, which is the order the engine uses: a
        // type implementing QQmlParserStatus may need to know it is being built from a document
        // (rather than constructed directly) before it sees its first assignment.
        // ...with THIS class's document, so a relative URL inside it resolves the way the engine
        // resolves it. Emitted as its own call BEFORE classBegin rather than as an argument to it:
        // a later pass finds the literal `classBegin(this);` to splice the outer back-reference in
        // after it, and changing that text silently dropped the splice — leaving __outer null and
        // every connection through it failing at construction. classBegin attaches the root
        // context only when the object has none, so this one wins.
        // The delegate ROOT attaches nothing: the view is about to install the per-item context on
        // it, and the document context attached here first won and kept it -- so `index`,
        // `modelData` and every model role inside a delegate had never resolved at all. Item 0 hid
        // it: its index IS zero, and so is a lookup that found nothing.
        // Its CHILDREN nest inside it, which is where Qt's own Controls write the model reads
        // (`text: model[textRole]` sits on a Control's contentItem, not on the delegate root).
        if (g_isDelegate && g_className == g_delegateCls)
            wire += "        holdContext(this);\n";
        else
            wire += std::string(g_isDelegate
                        ? "        attachContextIn(this, __qmltcOuter, \"" : "        attachContext(this, \"")
                  + (g_rootDocUrl.empty() ? g_docUrl : g_rootDocUrl)
                  + "\");\n";
        wire += "        classBegin(this);\n";
        // Before the CHILDREN, not just before our own bindings: a child's binding can read
        // through this object too (Fusion's ButtonPanel holds a Gradient whose stops compute
        // `panel.control.palette`), and a child is fully wired at construction. The `__outer`
        // back-reference is spliced in right after classBegin by a later pass, so it is already
        // set here — which is why only the assignments whose value is the enclosing object can
        // move this far up.
        wire += earlyWire;   // ...what every binding below READS THROUGH
        // Connect EVERYTHING before the initial binding pass. Two reasons:
        //  - a bound property's first evaluation IS a change (`property int p: dummy` goes
        //    0 -> 42) and QML's handler observes it; wiring handlers afterwards would miss it.
        //  - it makes the initial pass order-independent. Bindings are recomputed in declaration
        //    order, but aliases are appended after the declared properties, so `property int n:
        //    someAlias + 1` would otherwise be computed while the alias still held 0. With the
        //    connections already live, evaluating the alias propagates into the dependent binding.
        //    Recomputes are idempotent (each emits only on an actual change), so the extra passes
        //    settle instead of looping.
        // A property initialised from a LITERAL is assigned in its field initialiser and emits
        // nothing, so none of this makes handlers fire on init.
        wire += bindWire;    // bindings live BEFORE anything is assigned
        // ...and the SAME reasoning applies to base properties, which used to be assigned before
        // any of this. `padding: 12` on a Pane fires leftPaddingChanged, which is what recomputes
        // `implicitWidth: ... contentWidth + leftPadding + rightPadding ...` — but the connect was
        // made afterwards, so the notification arrived with nobody listening and the Pane kept an
        // implicit width of 0 forever. The engine draws it 24x24; we drew 1x1. Found by rendering
        // a real Qt Controls file, which is the only kind of test that could see it.
        // ...but an assignment whose VALUE is a child cannot precede the children. This is the
        // mirror of `earlyWire`, which moves up the assignments the children READ; here the flow
        // goes the other way (`probe: label` names a child by id, and the fixture caught it
        // assigning null). Split by whether the line mentions a child field — the fields are
        // generated names, so the test is exact rather than heuristic.
        std::set<std::string> kidFields;
        for (auto &k : node.kids)         kidFields.insert(dIdent(k.first));
        for (auto &dk : node.defaultKids) kidFields.insert(dk.first);
        for (auto &gk : node.groupKids)   kidFields.insert(gk.first);
        auto mentionsKid = [&](const std::string &line) {
            for (auto &f : kidFields) {
                for (size_t at = 0; (at = line.find(f, at)) != std::string::npos; ) {
                    size_t e = at + f.size();
                    bool lok = at == 0 || (!std::isalnum((unsigned char) line[at - 1]) && line[at - 1] != '_');
                    bool rok = e >= line.size() || (!std::isalnum((unsigned char) line[e]) && line[e] != '_');
                    if (lok && rok) return true;
                    at = e;
                }
            }
            return false;
        };
        std::string baseBeforeKids, baseAfterKids;
        for (size_t i = 0, j; i < baseWire.size(); i = j + 1) {
            j = baseWire.find('\n', i);
            if (j == std::string::npos) j = baseWire.size() - 1;
            std::string line = baseWire.substr(i, j - i + 1);
            (mentionsKid(line) ? baseAfterKids : baseBeforeKids) += line;
        }
        wire += baseBeforeKids;   // set base C++ properties, with every BINDING already live
        // Everything from HERE on is "my children and what reads them", and it becomes a separate
        // method the PARENT calls once this object is assigned to its property — see the split
        // below.
        wire += ownBodyWire;   // ...still the object's OWN body: see the buffer's note
        kidsAt = wire.size();
        // ...and the CHILDREN only after this object's own properties, which is the order the
        // engine uses: `background`, `contentItem` and `indicator` are DEFERRED properties
        // (Q_CLASSINFO("DeferredPropertyNames", ...) on QQuickControl and friends), created inside
        // componentComplete once everything written in the document body has been assigned.
        //
        // Building them first is observable, and the observable is not the child but the PARENT's
        // effect on it. Qt's CheckBox writes `spacing: 6` and a contentItem whose `leftPadding`
        // reads `indicator.width + control.spacing`. With the child built first, that binding
        // settles at 28 (spacing still 0), the Control sizes the text, and the LATER `spacing: 6`
        // re-runs it to 34 — a second text layout, this time with a valid height, which moves
        // `baselineOffset` from the engine's 14.84375 to 19.34375. Same value in the end, wrong
        // number of layouts. Measured by hand on the generated D before it was written here: with
        // the two assignments moved above the children, both the root's and the contentItem's
        // baselineOffset match the engine exactly.
        wire += componentWire;   // ...the TEMPLATES first: a type builds children FROM them
        wire += dcWire;      // ...default children first, as the engine's `data` has them...
        wire += childWire;   // ...then the property-bound ones
        wire += baseAfterKids;   // ...and the assignments that NAME one
        wire += handlerWire; // ...and user handlers only after, so they do not see the initial pass
        for (auto &p : props) if (p.bound) {
            std::string dleaf;   // re-subscription lines for this property's deep reads
            for (auto &dr : p.deep) {   // reads through an object property connect in the late phase
                std::string sig;
                if (auto qn = g_qmlNotify.find(dr.innerQmlType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(dr.member);
                    if (nt != qn->second.end()) sig = nt->second;
                }
                if (sig.empty()) {
                    std::fprintf(stderr, "qmltc-d: %s: binding '%s' in %s reads '%s.%s' whose notify "
                                 "is unknown — it would not update (later phase)\n",
                                 inPath, p.name.c_str(), cls.c_str(), dr.inner.c_str(), dr.member.c_str());
                    ++partial; continue;
                }
                // Follow the PROPERTY: its notify re-runs __rcd_, which re-subscribes to the leaf
                // signal on whatever object it now holds. A one-shot connect to the object read at
                // wire time connected to null for a root's `parent` (and for HeaderView.syncView).
                lateWire += "        connectNotify(" + dr.obj + ", \"" + dr.inner
                          + "\", this, \"__rcd_" + p.name + "()\");\n";
                dleaf += "        bindLeaf(" + dr.obj + ", \"" + dr.inner + "\", \"" + sig
                       + "\", this, \"__rc_" + p.name + "()\");\n";
            }
            if (!dleaf.empty()) {
                recompute += "    @Slot void __rcd_" + p.name + "() {\n" + dleaf
                           + "        __rc_" + p.name + "();\n    }\n";
                lateWire += "        __rcd_" + p.name + "();\n";
            }
            for (auto &d : p.deps) {
                if (isProp(d)) {   // a property of THIS object: qmltc-d named its notify <p>Changed
                    wire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_" + p.name + "()\");\n";
                    continue;
                }
                // `<childId>.<prop>` — the notify belongs to the CHILD object, held in a D field.
                if (auto dot = d.find('.'); dot != std::string::npos && g_childIds.count(d.substr(0, dot))) {
                    auto &cr = g_childIds[d.substr(0, dot)];
                    std::string mem = d.substr(dot + 1);
                    // A member of the child's BOUND type carries the notify Qt declared for it
                    // (often with a parameter); one the .qml declared follows <name>Changed.
                    auto bn = cr.baseNotify.find(mem);
                    std::string sig = bn != cr.baseNotify.end() && !bn->second.empty()
                                    ? bn->second : (mem + "Changed()");
                    wire += "        connectMeta(" + cr.field + ", \"" + sig
                          + "\", this, \"__rc_" + p.name + "()\");\n";
                    continue;
                }
                // `Type.member` — the notify belongs to the ATTACHED object.
                if (auto dot = d.find('.'); dot != std::string::npos && g_attached.count(d.substr(0, dot))) {
                    std::string tn = d.substr(0, dot), mem = d.substr(dot + 1);
                    auto *at = g_attached[tn];
                    auto nt = at->propNotify.find(mem);
                    if (nt == at->propNotify.end()) continue;
                    auto sg = at->signalSig.find(nt->second);
                    std::string sig = sg != at->signalSig.end() ? sg->second : (nt->second + "()");
                    wire += "        connectMeta(" + attachedExpr(tn) + ", \"" + sig
                          + "\", this, \"__rc_" + p.name + "()\");\n";
                    continue;
                }
                // `group.member` — the notify belongs to the GROUP object, and its signature comes
                // from the group class's registry entry (a NOTIFY need not be `<prop>Changed()`).
                if (auto dot = d.find('.'); dot != std::string::npos && g_groups.count(d.substr(0, dot))) {
                    std::string gname = d.substr(0, dot), mem = d.substr(dot + 1);
                    auto *gt = g_groups[gname];
                    auto nt = gt->propNotify.find(mem);
                    if (nt == gt->propNotify.end()) continue;   // no NOTIFY -> nothing can re-fire it
                    auto sg = gt->signalSig.find(nt->second);
                    std::string sig = sg != gt->signalSig.end() ? sg->second : (nt->second + "()");
                    wire += "        connectMeta(propObj(this, \"" + gname + "\"), \"" + sig
                          + "\", this, \"__rc_" + p.name + "()\");\n";
                    continue;
                }
                // `control.<prop>` — the dependency lives on the ENCLOSING object, so the connect
                // is made on __outer, not on this. Its notify comes from the outer's own table
                // (declared properties spell it <prop>Changed; base ones carry a full signature).
                if (d.rfind("__outer.", 0) == 0 && !outerDepIsPath(d)) {
                    std::string obj, mem, sig; const OuterFrame *fr = nullptr;
                    if (!splitOuterDep(d, obj, mem, &fr)) {
                        // Reported, not dropped. `__outer.<group>.<member>` (Qt's SearchField pads
                        // itself from `control.searchIndicator.indicator`) does not split, and this
                        // used to `continue` in SILENCE — the read compiled, nothing connected, and
                        // no message said so. A binding that looks live and is not is the worst
                        // thing this compiler can emit, so it says so now.
                        std::fprintf(stderr, "qmltc-d: %s: binding in %s depends on '%s', a path through "
                                     "an enclosing object that is not wired — it would not update "
                                     "(later phase)\n", inPath, cls.c_str(), d.c_str());
                        ++partial; continue;
                    }
                    if (!fr->baseProps.count(mem) && fr->propType.count(mem)) {
                        sig = mem + "Changed()";
                        g_outerNeedsNotify.push_back({(int)std::count(obj.begin(), obj.end(), '.'), mem});
                    }
                    else if (auto qn = g_qmlNotify.find(fr->qmlType); qn != g_qmlNotify.end()) {
                        auto nt = qn->second.find(mem);
                        if (nt != qn->second.end()) sig = nt->second;
                    }
                    if (!sig.empty()) {
                        wire += "        connectMeta(" + obj + ", \"" + sig + "\", this, \"__rc_"
                              + p.name + "()\");\n";
                        continue;
                    }
                    std::fprintf(stderr, "qmltc-d: %s: binding '%s' depends on '%s' of the enclosing "
                                 "object, which has no known notify — it would not update (later phase)\n",
                                 inPath, p.name.c_str(), mem.c_str());
                    ++partial; continue;
                }
                // A property of the BOUND base (width on an Item): its notify is in the property
                // table the compiler already loads, with the FULL signature. Without this the
                // binding was never connected — `property int inner: width - pad` recomputed on
                // pad and silently ignored width, exit 0, no diagnostic.
                if (!dBase) {
                    // An object PATH the registry resolves: connect to the object the path reaches,
                    // on the leaf's own notify — the head of the path is typically a group that
                    // never changes. When it does not resolve, depend on the head, as before.
                    if (std::string so9, lf9; styleHintsDep(d, so9, lf9) || attachedOuterDep(d, so9, lf9)
                        || outerBareDep(d, so9, lf9)) {
                        wire += "        connectNotify(" + so9 + ", \"" + lf9 + "\", this, \"__rc_"
                              + p.name + "()\");\n";
                        continue;
                    }
                    std::string dEff = d;
                    if (dEff.find('.') != std::string::npos) {
                        std::string oe7, sig7;
                        if (objPathFromString(dEff, oe7, sig7)) {
                            wire += "        tryConnectMeta(" + oe7 + ", \"" + sig7
                                  + "\", this, \"__rc_" + p.name + "()\");\n";
                            wire += "        tryConnectMeta(" + oe7 + ", \"changed()\", this, \"__rc_"
                                  + p.name + "()\");\n";
                            continue;
                        }
                        // ...or the path lands on an object whose TYPE simply does not declare
                        // the leaf. The ENGINE has nothing to connect to there either, so this is
                        // a best-effort connect on Qt's notify convention — null-safe AND
                        // signal-safe — rather than a report. Same rule as the other two consumers;
                        // this is the one a DECLARED property's binding reaches.
                        {
                            std::string headD = dEff.substr(0, dEff.rfind('.'));
                            std::string leafD = dEff.substr(dEff.rfind('.') + 1);
                            std::string oeW, oqW;
                            if (objPathWalkDotted(headD, oeW, oqW)
                                    && typeKnownWithoutMember(oqW, leafD)) {
                                wire += "        tryConnectMeta(" + oeW + ", \"" + leafD
                                      + "Changed()\", this, \"__rc_" + p.name + "()\");\n";
                                wire += "        tryConnectMeta(" + oeW + ", \"changed()\", this, \"__rc_"
                                      + p.name + "()\");\n";
                                continue;
                            }
                        }
                        dEff = dEff.substr(0, dEff.find('.'));
                    }
                    auto qn = g_qmlNotify.find(g_selfQmlType);
                    if (qn != g_qmlNotify.end()) {
                        auto nt = qn->second.find(dEff);
                        if (nt != qn->second.end() && !nt->second.empty()) {
                            wire += "        connectMeta(this, \"" + nt->second
                                  + "\", this, \"__rc_" + p.name + "()\");\n";
                            continue;
                        }
                    }
                    // A value list is a plain D field, not a meta-object property: it has no
                    // notify by construction and nothing mutates it, so a binding reading it is
                    // correct as a one-shot. Not a dead dependency.
                    if (g_valueLists.count(dEff)) continue;
                    // A SINGLETON name is an object, not a property — `number: Fixture.value`
                    // records the singleton as the dependency. Reacting to a singleton's property
                    // changing is a real gap, but it is a missing DEPENDENCY (the member is never
                    // recorded), not a missing notify, so it does not belong to this diagnostic.
                    if (g_singletons.count(dEff)) continue;
                    // Anything else that can never fire is reported, not silently dropped: the
                    // binding would look live and never update.
                    std::fprintf(stderr, "qmltc-d: %s: binding '%s' depends on '%s', which has no "
                                 "known notify — it would not update (later phase)\n",
                                 inPath, p.name.c_str(), d.c_str());
                    ++partial;
                    continue;
                }
                // A property of a D BASE: its notify signal is whatever the type declared, which
                // the registry records — don't assume the <prop>Changed spelling.
                auto n = dBase->propNotify.find(d);
                if (n == dBase->propNotify.end()) continue;
                // Use the signal's REAL signature — a NOTIFY may carry parameters
                // (TypeWithProperties::dSignal(QString,int)), and connecting it as `name()`
                // silently matches nothing, leaving the binding dead.
                auto sg = dBase->signalSig.find(n->second);
                std::string sig = sg != dBase->signalSig.end() ? sg->second : (n->second + "()");
                wire += "        connectMeta(this, \"" + sig + "\", this, \"__rc_" + p.name + "()\");\n";
            }
        }
        // Entering a state OVERRIDES properties; leaving it must put the previous values BACK,
        // which the engine does on exit. The base values are captured when a state is entered
        // (not at compile time — a binding may have changed them since), so switching states
        // restores what was there before rather than what the document literally wrote.
        if (!stateTable.empty()) {
            // A dotted override name is resolved HERE, where the scope is complete: everything up
            // to the last segment must land on THIS object, and then the leaf is an ordinary
            // property of ours. Anything else is left alone and the loops below refuse it by type,
            // which is what they already do for a name they cannot place.
            for (auto &st : stateTable)
                for (auto &ov : st.overrides) {
                    auto dot = ov.prop.rfind('.');
                    if (dot == std::string::npos) continue;
                    std::string headP = ov.prop.substr(0, dot), leafP = ov.prop.substr(dot + 1);
                    std::string oeS, oqS;
                    if (objPathWalkDotted(headP, oeS, oqS)
                            && (oeS == "this"
                                || (!g_selfBoundProp.empty()
                                    && oeS == "propObj(__outer, \"" + g_selfBoundProp + "\")")))
                        ov.prop = leafP;
                }
            std::set<std::string> touched;
            for (auto &st : stateTable) for (auto &ov : st.overrides) touched.insert(ov.prop);
            std::string saves, restores, applies;
            for (auto &pn : touched) {
                std::string ty = isProp(pn) ? ptype[pn] : (g_baseProps.count(pn) ? g_baseProps[pn] : "");
                if (ty.empty()) continue;
                stateFields += "    private " + ty + " __save_" + pn + ";\n";
                std::string rd = isProp(pn) ? pn
                               : (ty == "string" ? "propStr(this, \"" + pn + "\")"
                                 : ty == "double" ? "propDouble(this, \"" + pn + "\")"
                                 : ty == "bool" ? "propBool(this, \"" + pn + "\")"
                                 : "propInt(this, \"" + pn + "\")");
                saves += "            __save_" + pn + " = " + rd + ";\n";
                restores += (isProp(pn)
                    ? "            " + pn + " = __save_" + pn + ";\n"
                      + (std::find(needsNotify.begin(), needsNotify.end(), pn) != needsNotify.end()
                         ? "            " + pn + "Changed.emit();\n" : "")
                    : "            setProp(this, \"" + pn + "\", __save_" + pn + ");\n");
            }
            for (auto &st : stateTable) {
                std::string body2;
                for (auto &ov : st.overrides) {
                    std::string ty = isProp(ov.prop) ? ptype[ov.prop]
                                   : (g_baseProps.count(ov.prop) ? g_baseProps[ov.prop] : "");
                    std::string val;
                    if (ty.empty() || !compileExpr(ov.value, QString::fromStdString(ty), val)) {
                        std::fprintf(stderr, "qmltc-d: %s: state '%s' override of '%s' in %s not yet "
                                     "supported — skipped (later phase)\n", inPath, st.name.c_str(),
                                     ov.prop.c_str(), cls.c_str());
                        ++partial; continue;
                    }
                    if (isProp(ov.prop)) {
                        body2 += "            " + ov.prop + " = " + val + ";\n";
                        if (std::find(needsNotify.begin(), needsNotify.end(), ov.prop) != needsNotify.end())
                            body2 += "            " + ov.prop + "Changed.emit();\n";
                    } else body2 += "            setProp(this, \"" + ov.prop + "\", " + val + ");\n";
                }
                applies += "        if (want == \"" + st.name + "\") {\n" + body2 + "        }\n";
            }
            stateFields += "    private string __activeState;\n";
            stateMethods += std::string("    @Slot void __applyState() {\n")
                          + "        auto want = propStr(this, \"state\");\n"
                          + "        if (want == __activeState) return;\n"
                          + "        if (__activeState.length) {\n" + restores + "        }\n"
                          + "        __activeState = want;\n"
                          + "        if (want.length) {\n" + saves + "        }\n"
                          + applies;
            stateMethods += "    }\n";
            wire += "        connectMeta(this, \"stateChanged(QString)\", this, \"__applyState()\");\n";
        }
        // Values that must be converted by the meta-type system on their way in.
        for (auto &ma : metaAssigns)
            wire += "        setProp(this, \"" + ma.first + "\", " + ma.second + ");\n";
        wire += crossConnects;   // live child-alias connects (cross-object)
        for (auto &p : props) if (p.bound) wire += "        __rc_" + p.name + "();\n";
        // A state named by `state:` is applied AFTER the declarative bindings have run, which is
        // the order the engine uses: the state's overrides win over the base values.
        // Only the initial state is applied; changing `state` at runtime (and reverting the
        // previous state's overrides) is the next step and is not compiled yet.
        if (!stateTable.empty()) wire += "        __applyState();\n";
        // QQmlParserStatus, the way the engine drives it: componentComplete() once the whole tree
        // is built and every property assigned — CHILDREN FIRST, since a parent's completion may
        // read what its children settled. A type that does not implement the interface is a no-op.
        // Without this the objects are constructed but not COMPLETE: QQuickControl computes
        // hoverEnabled here, and Controls generally do their real initialisation in it.
        // ...ONCE, and by whoever can do it in the right ORDER. A child that its parent assigns
        // and parents is completed BY THE PARENT, right after that — the engine completes a tree
        // once it is built, and an object completed before it has a parent resolves anything that
        // depends on one against nothing (a QQuickPopup takes its `parent` from its QObject parent
        // in componentComplete). Everything else — the root, group, attached and value-source
        // children — completes itself here, because nobody else does.
        // Never BOTH: a Repeater re-completed after it has created its items releases them through
        // an already-completed QQmlDelegateModel, and Qt segfaults in QQuickRepeater::clear().
        if (!thisParentCompletes) wire += "        componentComplete(this);\n";
        wire += onCompletedBody;   // Component.onCompleted, last
        // THE SPLIT. `__qmltcWire` keeps what the object does to ITSELF; everything from the
        // children on becomes `__qmltcKids`, which the parent calls once this object is assigned
        // and parented. Nobody assigns the root (nor a group, attached or value-source child —
        // the same set that completes itself), so those call it at the end of their own wire.
        if (kidsAt != std::string::npos && kidsAt < wire.size()) {
            std::string kidsBody = wire.substr(kidsAt);
            wire.erase(kidsAt);
            if (!thisParentCompletes) wire += "        __qmltcKids();\n";
            wire += "    }\n    void __qmltcKids() {\n" + kidsBody;
        } else {
            // Emitted even when empty: the parent's call site cannot know whether a child class
            // has children of its own, and a method that is missing is a compile error.
            if (!thisParentCompletes) wire += "        __qmltcKids();\n";
            wire += "    }\n    void __qmltcKids() {\n";
        }
        wire += "    }\n";
    }

    // A non-QtObject root becomes a D subclass of the bound Qt type via the (generic) QtdWidget
    // mixin; the trampoline + attach come from the binding, base props are set in __qmltcWire.
    std::string mixinLine = boundBase.empty() ? "" : ("    mixin QtdWidget!" + boundBase + ";\n");
    // A bound C++ base is reached through the generated trampoline (the mixin); a D base is just
    // a D superclass — `@QObject class Foo : Backend`. qtmoc's __traits(allMembers) already flattens
    // inherited @Property/Signal/@Slot into the subclass meta-object.
    // Only a D base is a real D superclass. A BOUND C++ base is reached through the trampoline
    // mixin instead (the class must not also derive from the extern(C++) declaration).
    std::string ext = (dBase && !dBase->bound) ? (" : " + dBase->dClass) : "";
    // The back-reference, declared only when the object actually reads its enclosing scope.
    std::string outerField = g_outerUsed && !g_outerClass.empty()
                           ? "    " + g_outerClass + " __outer;\n" : "";
    // Insert right after classBegin(); a wire without one has no constructor body at all, and
    // find() returning npos would wrap the offset instead of failing.
    auto afterClassBegin = [&](const std::string &line) {
        auto at = wire.find("classBegin(this);\n");
        if (at != std::string::npos) wire.insert(at + 18, line);
    };
    if (g_outerUsed && !g_outerClass.empty() && !g_isDelegate)   // taken BEFORE this object constructs its own kids
        afterClassBegin("        __outer = cast(" + g_outerClass + ") __qmltcOuter;\n");
    // A DELEGATE is created by the view, not by its enclosing object, so there is no handoff to
    // take: it learns its enclosing object from the tree it is parented into — which happens AFTER
    // it is constructed. So everything that depends on the enclosing object waits for the parent,
    // and the wait is the meta-object channel like everything else (parentChanged), not a new
    // mechanism. Runs once; an item whose parent chain never reaches the class stays unwired,
    // which is visible rather than silently wrong.
    std::string delegFields;
    bool delegRewrite = false;
    if (g_isDelegate && (g_ctxUsed || (g_outerUsed && !g_outerClass.empty())) && !wire.empty()) {
        auto at = wire.find("classBegin(this);\n");
        if (at != std::string::npos) {
            std::string head = wire.substr(0, at + 18), tail = wire.substr(at + 18);
            // A compiled child reaches an enclosing object by HOPS (`__outer.__outer`), because
            // each level was handed its own back-reference at construction. A delegate has no such
            // chain: it is created by the view, so each level it reads has to be found on its own,
            // by class, in the tree it is parented into. The chains are rewritten into one field
            // per level at class assembly (where every buffer that can hold one exists), and this
            // marks where the resolution goes.
            wire = head
                 + "        __qtdReady();   // already parented? then nothing to wait for\n"
                 + "        tryConnectMeta(this, \"parentChanged(QQuickItem*)\", this, \"__qtdReady()\");\n"
                 + "    }\n"
                 + "    private bool __qtdWired;\n"
                 + "    @Slot void __qtdReady() {\n"
                 + "        if (__qtdWired) return;\n"
                 + "//__QTD_RESOLVE__\n"
                 + "        __qtdWired = true;\n"
                 + tail;
            delegRewrite = true;
        }
    }
    // A value source must know the property it drives BEFORE its own `running: true` is applied
    // and before it completes — otherwise it starts with nothing to animate. Taken at the top of
    // the wire, exactly like __outer.
    if (g_isValueSource)
        afterClassBegin("        attachValueSource(this, __qmltcVsTarget, __qmltcVsProp);\n");
    node.usesOuter = g_outerUsed && !g_outerClass.empty();
    // The late pass: this object's deferred connects, then every child's. Emitted only where
    // there is something to do, so the common object is unchanged.
    std::string lateKids;
    for (auto &k : node.kids)        if (k.second.hasLate) lateKids += "        " + dIdent(k.first) + ".__qmltcLate();\n";
    for (auto &dk : node.defaultKids) if (dk.second.hasLate) lateKids += "        " + dk.first + ".__qmltcLate();\n";
    for (auto &gk : node.groupKids)  if (gk.second.hasLate) lateKids += "        " + gk.first + ".__qmltcLate();\n";
    // ...and the bindings whose reads go through an object assigned later. Appended at the END of
    // the late body, after every connect it makes, so the value they settle on is the final one.
    for (auto &r : reEval) lateWire += "        " + r + "();\n";
    node.hasLate = !lateWire.empty() || !lateKids.empty();
    // Only the root fires it: at the end of ITS wire the whole tree exists and every
    // componentComplete has run, which is exactly when a Control has created its indicator.
    // The FINALIZE pass: QQmlFinalizerHook::componentFinalized(), which the engine runs from
    // QQmlComponent::completeCreate() once the WHOLE component is built — after every
    // componentComplete, and after the bindings are live. A QQuickTableView does all of its work
    // there: without it Qt's HorizontalHeaderView reports rows/columns/contentWidth/contentHeight
    // all -1 and an unset `model` where the engine reports 1/0/0/0 and int 0, and no number of
    // componentComplete calls (measured: two, plus an event-loop turn) stands in for it.
    //
    // Order is the engine's: the hooks are registered as objects are CREATED, so an object is
    // finalized before its children — the opposite of componentComplete, which runs in reverse.
    // Only a BOUND object can implement the interface (a fresh @QObject is a QtdMocObject and has
    // no C++ base to declare one), but a bound descendant of an unbound object still needs the
    // call, so the recursion is emitted wherever anything below it is bound.
    std::string finalKids;
    for (auto &k : node.kids)         if (k.second.hasFinal) finalKids += "        " + dIdent(k.first) + ".__qmltcFinal();\n";
    for (auto &dk : node.defaultKids) if (dk.second.hasFinal) finalKids += "        " + dk.first + ".__qmltcFinal();\n";
    for (auto &gk : node.groupKids)   if (gk.second.hasFinal) finalKids += "        " + gk.first + ".__qmltcFinal();\n";
    std::string finalSelf = boundBase.empty() ? std::string()
                                              : "        componentFinalized(this);\n";
    node.boundBase = boundBase;
    node.hasFinal = !finalSelf.empty() || !finalKids.empty();
    if (cls == g_rootClass && (node.hasLate || node.hasFinal)) {
        auto pos = wire.rfind("    }\n");   // inside __qmltcWire, not after its closing brace
        if (pos != std::string::npos)
            wire.insert(pos, std::string(node.hasLate ? "        __qmltcLate();\n" : "")
                           + (node.hasFinal ? "        __qmltcFinal();\n" : ""));
    }
    std::string lateMethod = node.hasLate
        ? "    void __qmltcLate() {\n" + lateWire + lateKids + "    }\n" : "";
    if (node.hasFinal)
        lateMethod += "    void __qmltcFinal() {\n" + finalSelf + finalKids + "    }\n";
    if (delegRewrite) {
        // `__outer.__outer` -> `__o1`, as a WHOLE chain (the next character must not continue it,
        // or the outermost level would be rewritten as the innermost). Longest first, and only the
        // levels the object actually reads get a field: a level that is not an ancestor cannot be
        // found by walking parents (a Repeater is a SIBLING of the items it creates), so resolving
        // an unused one would gate the whole wire on something that can never resolve.
        const int maxHop = g_outerHopsNeeded < 0 ? 0 : g_outerHopsNeeded;
        std::vector<bool> used(maxHop + 1, false);
        auto rewriteHops = [&](std::string &buf) {
            for (int k = maxHop; k >= 0; --k) {
                std::string chain = "__outer";
                for (int i = 0; i < k; ++i) chain += ".__outer";
                std::string var = "__o" + std::to_string(k);
                size_t at3 = 0;
                while ((at3 = buf.find(chain, at3)) != std::string::npos) {
                    size_t end = at3 + chain.size();
                    if (buf.compare(end, 8, ".__outer") == 0) { at3 = end; continue; }
                    used[k] = true;
                    buf.replace(at3, chain.size(), var);
                    at3 += var.size();
                }
            }
        };
        for (auto *buf : {&wire, &methods, &recompute, &handlerSlots, &groupHandlerSlots,
                          &attachedHandlerSlots, &lateMethod})
            rewriteHops(*buf);
        // The BAIL-OUT the early call needs. `__qtdReady()` is called once in the constructor in
        // case the object is already parented, and it is the resolution failing that sends it back
        // to wait -- with nothing to resolve there was no such condition, so the body ran in the
        // constructor exactly as before. For a context read the condition is the context itself.
        std::string resolve;
        if (g_ctxUsed)
            resolve += "        if (!hasContext(this)) return;   // the engine has not installed the per-item context yet\n";
        for (int k = 0; k <= maxHop; ++k) {
            if (!used[k]) continue;
            std::string ocls = k < (int) g_outerChain.size() ? g_outerChain[k].cls : g_outerClass;
            if (ocls.empty()) continue;
            delegFields += "    " + ocls + " __o" + std::to_string(k) + ";\n";
            resolve += "        __o" + std::to_string(k) + " = cast(" + ocls
                     + ") findOuter(this, \"" + ocls + "\");\n"
                     + "        if (__o" + std::to_string(k) + " is null) return;\n";
        }
        outerField = delegFields;
        if (auto rp = wire.find("//__QTD_RESOLVE__\n"); rp != std::string::npos)
            wire.replace(rp, 18, resolve);
    }
    // An ENGINE-CREATED child: everything this class does to "itself" is done to the instance the
    // engine built, because the type cannot be subclassed. `(this` is the first argument of every
    // self read/write/connect the emitter produces; a RECEIVER is always `, this, "slot"`, so it
    // keeps pointing at this object, which is where the slots live.
    if (!g_engineChildCls.empty() && cls == g_engineChildCls) {
        node.engineInst = true;
        auto toInst = [](std::string &buf) {
            size_t at = 0;
            while ((at = buf.find("(this", at)) != std::string::npos) {
                buf.replace(at, 5, "(__inst");
                at += 7;
            }
            // ...and `this` as a DESTINATION (`copyProp(src, "p", this, "q")`), which is not the
            // same position as a RECEIVER (`connectMeta(obj, "sig", this, "__rcb_x()")`). The two
            // are told apart by what follows: a receiver's next argument is a SIGNATURE, ending in
            // `()`. Getting this wrong is silent — the value lands on the wiring object instead of
            // on the instance, and the instance keeps its default.
            at = 0;
            while ((at = buf.find(", this, \"", at)) != std::string::npos) {
                size_t q = at + 9, e = buf.find('"', q);
                bool receiver = e != std::string::npos && e >= q + 2 && buf.compare(e - 2, 2, "()") == 0;
                if (!receiver) { buf.replace(at + 2, 4, "__inst"); at += 8; }
                else at = e;
            }
        };
        for (auto *buf : {&wire, &methods, &recompute, &handlerSlots, &groupHandlerSlots,
                          &attachedHandlerSlots, &lateMethod, &childFields})
            toInst(*buf);
        std::string mk = "    void* __inst;\n";
        // Created FIRST: every line of the wire writes through it.
        auto wp = wire.find("__qmltcWire() {\n");
        if (wp != std::string::npos)
            // VERSIONLESS: Qt 6 resolves the latest, and a style's impl module does not
            // necessarily register its types at 2.0 — Fusion's DialImpl is not a type at that
            // version, and asking for it failed the whole document at construction.
            wire.insert(wp + 16, "        __inst = createQmlObject(\"" + g_engineChildUri + "\", \""
                                 + g_engineChildType + "\");\n        if (__inst is null) return;\n");
        outerField += mk;
    }
    classes += "@QObject class " + cls + ext + " {\n" + mixinLine + outerField + lateMethod + enumDecls + signalDecls + valueListDecls + stateFields + body + stateMethods
             + childFields + aliasProps + methods + recompute + handlerSlots + groupHandlerSlots
             + attachedHandlerSlots + wire + "}\n";
    g_selfId = savedId;
    g_selfIds = savedIds;
    g_selfIdsDefn = savedIdsDefn;
    g_selfQmlType = savedSelfQmlType;
    g_outerId = savedOuterId; g_outerClass = savedOuterClass; g_outerQmlType = savedOuterQmlType;
    g_outerPropType = savedOuterPropType; g_outerBaseProps = savedOuterBaseProps;
    g_selfClass = savedSelfClass;
    node.outerHops = g_outerHopsNeeded;
    g_outerHopsNeeded = savedHops;
    g_outerChain = savedOuterChain;
    g_childDeclType = savedChildDecl;
    g_outerUsed = savedOuterUsed;
    g_ctxUsed = savedCtxUsed || g_ctxUsed;   // ...a subtree's need is the enclosing object's need
    g_requiredDecls = savedRequired; g_hasRequiredDecl = savedHasRequired;
    g_funcRet = savedFuncRet;
    g_funcReads = savedFuncReads;
    g_enumMember = savedEnumMember;
    g_className = savedClassName;
    g_signals = savedSignals;
    g_signalParams = savedSignalParams;
    g_baseProps = savedBaseProps;
    g_baseIsD = savedBaseIsD;
    g_baseReset = savedBaseReset;
    g_groups = savedGroups;
    g_attached = savedAttached;
    g_scope = savedScope;
    g_propType = savedPropType;
    g_aliasRead = savedAliasRead;
    g_aliasDep = savedAliasDep;
    g_aliasWrite = savedAliasWrite;
    g_rebound = savedRebound;
    g_hasSelector = savedHasSelector;
    g_rebinds = savedRebinds;
    g_childIds = savedChildIds;   // the PARENT's child ids: its wiring still needs them
    g_vgroups = savedVGroups;
    return node;
}

// Flatten the object tree into dump lines with dotted paths (`kid.y` <- access o.kid.y).
// `setObj`/`setProp` are the target of a MUTATION, which is not always derivable from the label:
// a child object path is a D field chain (`o.kid`), a grouped property is reached through the
// meta-object (`propObj(o, "group")`). Deriving it from the dotted label alone got that wrong.
// `vgroup` marks a VALUE-group member: mutating it needs setVgroup (read-modify-write), and
// setProp(o, "vt.count", v) would silently do nothing — setProperty fails on a dotted name.
struct DumpLine { std::string label, access, dtype, setObj, setProp; bool vgroup = false; };
// D access expression -> the class `__class` must report for that object (see collectDump).
static std::map<std::string, std::string> g_clsHint;
static void collectDump(const ObjNode &n, const std::string &acc, const std::string &lab,
                        std::vector<DumpLine> &out) {
    // An ENGINE-CREATED child is not the object the property holds — the instance it wraps is — so
    // its OWN reads go through `.__inst`. Its CHILDREN are still fields of the wiring object, and
    // walking into them through `__inst` (a void*) does not even compile: Qt's Fusion Dial has a
    // DialImpl handle with two transforms, and the generated main named `handle.__inst._al_transform_1`.
    std::string self = acc.substr(0, acc.size() - 1);
    if (n.engineInst) self += ".__inst";
    // What `__class` must report for this object. The ROOT keeps the walk — the engine names its
    // class after the document there, and so do we. A NESTED child does not: the engine reports the
    // Qt base and our generated class is named after the document too, so the two agreed only by
    // coincidence (`QNested_dc0` against `QQuickItem` is where it stopped being one).
    // ...but NOT for an engine-created instance: that object is one the ENGINE built (a style's
    // `*Impl`, which exports no symbol to subclass), so it really IS a QQuickBasicBusyIndicator and
    // the walk already says so. Hinting `QObject` there replaced a right answer with a wrong one on
    // four documents — which is what the corpora said the moment this was measured.
    // The ROOT names ITSELF, explicitly. It used to be left to the walk, which found our generated
    // class only because the walk's test for "is this a Qt class" was a leading Q -- true of every
    // fixture in the QtQuick set by naming convention, and of nothing else. Naming it here is also
    // what makes the engine's OWN rule fall out: the walk skips a class that declares no properties
    // of its own, and the engine builds a document type only when the document declares members, so
    // a root that declares nothing reports the Qt base on both sides without a special case.
    if (acc != "o." && !n.engineInst)
        g_clsHint[self] = n.boundBase.empty() ? "QObject" : n.boundBase;
    else if (acc == "o." && !n.engineInst && !g_className.empty())
        g_clsHint[self] = g_className;
    for (auto &s : n.scalars) {
        // A value type has no meaningful default text (a QColor prints its raw struct), so it is
        // dumped the way the engine formats it: QColor as #rrggbb, which is what QVariant gives
        // on the oracle side. Comparing the struct text against that would fail on formatting
        // while the colours were in fact identical.
        // A value-typed property is read back THROUGH the meta-object: QMetaType renders a
        // QColor as #rrggbb, which is exactly what the oracle's QVariant gives. Reading the D
        // field directly would print the raw struct and fail on formatting alone.
        // ...and the same for a declared OBJECT property, for the same reason: printing the D
        // wrapper gives its module-qualified type name, where the engine's dump gives whatever
        // QVariant makes of the pointer. One formatter on both sides or the comparison is about
        // spelling instead of about values.
        // ...except a LIST, which is not a value type and has no text on either side. Its D name
        // starts with Q like every Qt value type, so without naming it here it took the propStr
        // branch — which pushes the line with an EMPTY dtype — and the empty-print decision below
        // never saw it.
        if (s.second != "QmlObjectList"
                && (s.second == "QColor" || (!s.second.empty() && std::isupper((unsigned char) s.second[0])
                                             && s.second.rfind("Q", 0) == 0))) {
            out.push_back({lab + s.first, "propStr(" + self + ", \"" + s.first + "\")",
                           "", self, s.first});
            continue;
        }
        out.push_back({lab + s.first, acc + s.first, s.second, self, s.first});
    }
    // "" dtype keeps it out of the mutation block below (a list is not settable from a token).
    for (auto &s : n.valueLists)
        out.push_back({lab + s.first,
                       acc + s.first + ".map!(e => e.to!string).join(\",\")", "", self, s.first});
    // Base C++ properties have no D field — read them through the meta-object (prop<Int|Str>).
    for (auto &s : n.baseProps) {
        // An EMPTY type is "no D scalar maps this" — an enum, a colour, an object. Those were
        // read with propInt, which prints 0 for every one of them; the engine's own dump renders
        // them through QVariant, i.e. as text. propStr is the same channel, so the comparison is
        // about the value again instead of about 0 vs the engine's spelling.
        const char *fn = (s.second == "int") ? "propInt(" : (s.second == "double") ? "propDouble("
                       : (s.second == "bool") ? "propBool(" : "propStr(";
        out.push_back({lab + s.first, fn + self + ", \"" + s.first + "\")", s.second, self, s.first});
    }
    for (auto &a : n.aliasLines) {
        // Resolve the self marker to this object's access path. An alias reads and writes the
        // TARGET, so it needs no property of its own and no reactivity.
        auto sub = [&](std::string x) {
            for (size_t i; (i = x.find('\x01')) != std::string::npos;) x.replace(i, 1, self);
            return x;
        };
        out.push_back({lab + a.name, sub(a.read), a.dtype, sub(a.setObj), a.setProp});
    }
    for (auto &s : n.groupProps) {
        auto dot = s.first.find('.');
        std::string gname = s.first.substr(0, dot), mem = s.first.substr(dot + 1);
        const char *fn = (s.second == "string") ? "propStr(" : (s.second == "double") ? "propDouble("
                       : (s.second == "bool") ? "propBool(" : "propInt(";
        std::string gobj = "propObj(" + self + ", \"" + gname + "\")";
        out.push_back({lab + s.first, fn + gobj + ", \"" + mem + "\")", s.second, gobj, mem});
    }
    // A value group's member: read from the VALUE. The label keeps the QML path, which is what the
    // oracle walks — the engine resolves `vt.count` through the gadget's own meta-object.
    for (auto &s : n.valueGroupProps) {
        auto dot = s.first.find('.');
        std::string gname = s.first.substr(0, dot), mem = s.first.substr(dot + 1);
        const char *fn = (s.second == "string") ? "vgroupStr(" : (s.second == "double") ? "vgroupDouble("
                       : (s.second == "bool") ? "vgroupBool(" : "vgroupInt(";
        out.push_back({lab + s.first, fn + self + ", \"" + gname + "\", \"" + mem + "\")",
                       s.second, self + ", \"" + gname + "\"", mem, true});
    }
    for (auto &s : n.boundProps) {
        const char *fn = (s.second == "string") ? "propStr(" : (s.second == "double") ? "propDouble("
                       : (s.second == "bool") ? "propBool(" : "propInt(";
        out.push_back({lab + s.first, fn + self + ", \"" + s.first + "\")", s.second, self, s.first});
    }
    for (auto &k : n.kids) {
        // A child assigned to a LIST property is APPENDED: the engine resolves it at <prop>[0],
        // and labelling it <prop> asked the oracle for a path that does not exist (ScrollBar's
        // `transitions: Transition {}`).
        std::string klab = k.first + (n.listKids.count(k.first) ? "[0]" : "");
        // An ENGINE-CREATED child is not the object the property holds — the instance it wraps is.
        // Dumping (and asserting the linkage on) the wiring object compared the wrong thing.
        collectDump(k.second, acc + dIdent(k.first) + ".", lab + klab + ".", out);
    }
    // Group children: read through the D field, but label with the QML path the oracle walks.
    for (auto &a : n.attachedProps) {
        auto dot = a.first.find('.');
        std::string tn = a.first.substr(0, dot), mem = a.first.substr(dot + 1);
        const char *fn = (a.second == "string") ? "propStr(" : (a.second == "double") ? "propDouble("
                       : (a.second == "bool") ? "propBool(" : "propInt(";
        std::string aobj = "attachedObj(" + self + ", \"" + g_qmlUri + "\", \"" + tn + "\")";
        out.push_back({lab + a.first, fn + aobj + ", \"" + mem + "\")", a.second, aobj, mem});
    }
    for (size_t i = 0; i < n.groupKids.size(); ++i)
        collectDump(n.groupKids[i].second, acc + n.groupKids[i].first + ".",
                    lab + n.groupKidPaths[i] + ".", out);
    // Default (unnamed) children: the D field is accessed directly, but the label uses `@<i>` so the
    // oracle resolves it via childItems()[i] (declaration order == child list order).
    for (size_t i = 0; i < n.defaultKids.size(); ++i)
        collectDump(n.defaultKids[i].second, acc + n.defaultKids[i].first + ".",
                    lab + (n.defaultKidLabel.empty() ? "@" + std::to_string(i)
                           : n.defaultKidIsList ? n.defaultKidLabel + "[" + std::to_string(i) + "]"
                           : n.defaultKidLabel) + ".", out);
}

int main(int argc, char **argv) {
    // --dump: also emit a `main` that instantiates the type, applies `name=value` mutations, and
    // prints each scalar property (dotted path for children) as `name\tvalue` sorted — the
    // corpus-check-style differential vs the QQmlComponent oracle.
    bool dump = false, labels = false, objPaths = false;
    std::vector<char *> pos;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--dump") == 0) dump = true;
        else if (std::strcmp(argv[i], "--objpaths") == 0) objPaths = true;
        else if (std::strcmp(argv[i], "--labels") == 0) labels = true;   // print the dump labels (for the oracle --props)
        else if (std::strcmp(argv[i], "--qmlmap") == 0 && i + 1 < argc) {
            loadQmlMap(argv[i + 1]);                       // QML-name -> class table
            loadQmlUris(argv[i + 1]);                      // ...and every exported type's module URI
            loadQmlSingletons(argv[i + 1]);                // ...and the SINGLETONS and their methods
            loadQmlCxxNames(argv[i + 1]);                  // ...and every exported class's QML name
            loadQmlAttached(argv[i + 1]);                  // ...and the ATTACHED types' properties
            // qmlprops.tsv sits beside it and is written by the same pass, so it is never given
            // separately and the two cannot be mismatched.
            std::string pp(argv[++i]);
            auto slash = pp.find_last_of('/');
            pp = (slash == std::string::npos ? std::string() : pp.substr(0, slash + 1)) + "qmlprops.tsv";
            loadQmlProps(pp.c_str());
            // …and the signal table, written by the same pass and beside it for the same reason.
            std::string sp = pp.substr(0, pp.size() - std::strlen("qmlprops.tsv")) + "qmlsignals.tsv";
            loadQmlSignals(sp.c_str());
        }
        // --dtypes <registry.qmltypes> <d-module>: app-defined QML types written in D. The registry
        // is the CTFE .qmltypes of those types; the module is where the D classes live (the
        // .qmltypes format has no field for it, so it is a build input, like a header path).
        else if (std::strcmp(argv[i], "--dtypes") == 0 && i + 2 < argc) { loadDTypes(argv[i + 1], argv[i + 2], false); i += 2; }
        // --cpptypes <registry.qmltypes> <d-package>: app-defined QML types written in C++. Same
        // registry format (here produced by Qt's own moc --output-json | qmltyperegistrar), but the
        // base is reached through the generator's binding, so the generated class SUBCLASSES it.
        else if (std::strcmp(argv[i], "--cpptypes") == 0 && i + 2 < argc) { loadDTypes(argv[i + 1], argv[i + 2], true); i += 2; }
        else pos.push_back(argv[i]);
    }
    if (pos.empty()) { std::fprintf(stderr, "usage: %s [--dump] <file.qml> [ClassName]\n", argv[0]); return 2; }
    QFile f(pos[0]);
    if (!f.open(QIODevice::ReadOnly)) { std::fprintf(stderr, "qmltc-d: cannot open %s\n", pos[0]); return 2; }
    QString code = QString::fromUtf8(f.readAll());
    g_srcText = code;   // this document's text, for the snippet a diagnostic quotes
    g_rootSrcText = code;
    const char *inPath = pos[0];
    g_docUrl = "file://" + QFileInfo(inPath).absoluteFilePath().toStdString();
    g_rootDocUrl = g_docUrl;
    QString cls = pos.size() >= 2 ? QString::fromUtf8(pos[1]) : QFileInfo(inPath).completeBaseName();
    g_trContext = qs(QFileInfo(inPath).completeBaseName());   // qsTr's context is the file's name
    loadDocModule(inPath);   // the module this document belongs to (its style/theme comes with it)

    Engine engine;
    Lexer lexer(&engine);
    lexer.setCode(code, 1, /*qmlMode*/ true);
    Parser parser(&engine);
    if (!parser.parse()) {
        for (const auto &e : parser.diagnosticMessages())
            std::fprintf(stderr, "%s:%d:%d: %s\n", inPath, e.loc.startLine, e.loc.startColumn, qPrintable(e.message));
        return 1;
    }
    auto *program = cast<UiProgram *>(parser.ast());
    collectImportAliases(program);   // `import ... as T` -> `T.Button` is `Button`
    if (!program || !program->members || !program->members->member) {
        std::fprintf(stderr, "qmltc-d: %s has no root object\n", inPath); return 1;
    }
    auto *root = cast<UiObjectDefinition *>(program->members->member);
    if (!root) { std::fprintf(stderr, "qmltc-d: %s: root is not a plain object definition (unsupported)\n", inPath); return 3; }

    // Map the root's QML type: a bound Qt type (e.g. Item -> QQuickItem) makes qmltc-d emit a D
    // SUBCLASS of it (via the QtdWidget mixin); QtObject/unmapped stays a fresh @QObject.
    std::string rootType = root->qualifiedTypeNameId ? typeName(root->qualifiedTypeNameId) : "";
    auto bt = boundTypeFor(rootType);
    UiObjectInitializer *rootInit = root->initializer;
    std::string rootResolvedPath;
    if (bt.first.empty() && rootType != "QtObject") {
        // A local `.qml`-defined ROOT type (e.g. `LocallyImported { ... }`): take the local
        // definition's base and MERGE this file's use-site members onto the local definition's.
        if (UiObjectDefinition *lt = g_qualifiedTypes.count(rootType)
                                        ? nullptr : loadLocalType(rootType, inPath, &rootResolvedPath)) {
            g_localMerged = true;
            std::string ltRoot = lt->qualifiedTypeNameId ? typeName(lt->qualifiedTypeNameId) : "";
            bt = boundTypeFor(ltRoot);
            adoptLocalTypeRows(rootType, ltRoot);   // the registry knows the BASE, not the file
            rootInit = lt->initializer ? lt->initializer : root->initializer;
            if (lt->initializer && root->initializer && root->initializer->members) {
                if (!lt->initializer->members) lt->initializer->members = root->initializer->members;
                else {
                    auto *tail = lt->initializer->members;
                    while (tail->next) tail = tail->next;
                    tail->next = root->initializer->members;
                }
            }
        }
    }
    // An app-defined type written in D: `@QObject` + qmlRegisterType. The generated class simply
    // DERIVES from it — no trampoline, no mixin, inherited properties are real fields.
    const DType *rootD = nullptr;
    if (bt.first.empty() && rootResolvedPath.empty()) {
        rootD = dTypeFor(rootType);
        if (rootD && rootD->bound) {
            // Route into the bound-subclass backend (the same one QtQuick types use): the class
            // and its module come from the registry, the trampoline from the binding. The registry
            // additionally supplies the base property TYPES and notify names, which the bound path
            // otherwise has to infer from the assigned literal.
            bt = {rootD->dClass, rootD->dModule};
        } else if (rootD) {
            g_extraImports += "import " + rootD->dModule + ";\n";
        }
    }

    if (!bt.first.empty()) {
        g_extraImports += "import " + bt.second + ";\n";
        // the QtdWidget mixin needs the binding's `qtvirt` module (subclass factory / attach /
        // __<Base>_vnames), which lives at <package>.qtvirt.
        std::string pkg = bt.second.substr(0, bt.second.rfind('.'));
        g_extraImports += "import " + pkg + ".qtvirt;\n";
    }

    // Sibling `.qml` files declaring `pragma Singleton` whose element name appears in this
    // document: compile each as its own D class plus a lazy one-instance accessor, so
    // `Singleton.member` is an ordinary read. Scanning the source text is enough to decide WHICH
    // to compile — an unused one simply isn't emitted, and a used one must resolve anyway.
    std::string singletonDecls;
    int partialSing = 0;
    {
        // This scan loads EVERY .qml next to the document to find singletons, and each load
        // repoints the text a diagnostic quotes from. Without putting it back, every later
        // diagnostic about THIS document quotes whichever neighbour was read last.
        QString savedSrc = g_srcText;
        std::string savedDocUrl2 = g_docUrl;
    struct RestoreSrc { QString v; std::string u; ~RestoreSrc() { g_srcText = v; g_docUrl = u; } }
        __restore{savedSrc, savedDocUrl2};
        QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
        for (const auto &fi : QDir(dir).entryInfoList(QStringList() << "*.qml", QDir::Files)) {
            std::string nm = qs(fi.completeBaseName());
            if (nm == qs(cls) || code.indexOf(QString::fromStdString(nm)) < 0) continue;
            bool sing = false;
            std::string p2;
            UiObjectDefinition *lt = loadLocalType(nm, inPath, &p2, &sing);
            if (!lt || !sing) continue;
            // `pragma Singleton` alone does not make a type resolvable: QML requires a `qmldir`
            // declaring it. Without one the ENGINE cannot load a document that uses it, so
            // neither should we — resolving it anyway would compile a file the engine rejects.
            if (!singletonDeclaredInQmldir(dir, nm)) continue;
            g_singletons.insert(nm);
            // compile it like any local type, then a lazy accessor for its ONE instance
            std::string sres;
            g_resolving.insert(p2);
            ObjNode sn = compileObject(lt->initializer, "__Sing_" + nm, sres, partialSing, inPath);
            g_resolving.erase(p2);
            singletonDecls += sres;
            singletonDecls += "private __gshared __Sing_" + nm + " __sing_inst_" + nm + ";\n"
                + "private __Sing_" + nm + " __singleton_" + nm + "() {\n"
                + "    if (__sing_inst_" + nm + " is null) __sing_inst_" + nm
                + " = newQObject!__Sing_" + nm + "();\n    return __sing_inst_" + nm + ";\n}\n";
        }
    }

    int partial = partialSing;
    // An unmapped root that is neither QtObject, a resolved local `.qml` type, nor a registered
    // D type is an app-defined type we have no registry for. Treating it as a fresh @QObject would
    // silently emit values the engine doesn't have, so flag PARTIAL.
    bool rootUnbound = false;
    if (bt.first.empty() && rootType != "QtObject" && rootResolvedPath.empty() && !rootD) {
        std::fprintf(stderr, "qmltc-d: %s: root type '%s' is not a bound Qt type, QtObject, or local .qml type — skipped (later phase)\n",
                     inPath, rootType.c_str());
        ++partial; rootUnbound = true;
    }
    std::string classes;
    if (!rootResolvedPath.empty()) g_resolving.insert(rootResolvedPath);
    g_selfQmlType = rootType;   // so base-property notifies resolve in g_qmlNotify
    g_rootClass = qs(cls);
    ObjNode rootNode = compileObject(rootInit, qs(cls), classes, partial, inPath, bt.first, rootD);
    // A `property color` is a QColor FIELD, so the module declaring the type must be imported.
    // Only the CONVERSION is unnecessary: a colour literal is written through the meta-object and
    // QMetaType turns the string into a QColor, so nothing calls QColor.fromString. Emitted after
    // compiling, since that is when the document is known to mention one.
    // ...and the package is not always the ROOT's: a document whose root type is not bound (Qt's
    // Fusion SpinBox, whose QQuickSpinBox is not in the binding) still has children that declare
    // one, and taking the package only from `bt.second` left those with a QColor field and no
    // module — a compile error in the generated D, not a diagnostic. Any bound type the document
    // already imports names the same package.
    if (classes.find("QColor ") != std::string::npos) {
        std::string pkg = bt.second.empty() ? std::string() : bt.second.substr(0, bt.second.rfind('.'));
        if (pkg.empty()) {
            size_t p = g_extraImports.find("import qt.");
            if (p != std::string::npos) {
                size_t e = g_extraImports.find(';', p);
                std::string mod = g_extraImports.substr(p + 7, e - p - 7);
                if (auto d = mod.rfind('.'); d != std::string::npos) pkg = mod.substr(0, d);
            }
        }
        if (!pkg.empty()) {
            std::string imp = "import " + pkg + ".qcolor;\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
        }
    }
    if (!rootResolvedPath.empty()) g_resolving.erase(rootResolvedPath);

    // --objpaths: the OBJECT paths `--dumpall` enumerates, so the oracle walks the same set. Two
    // sides enumerating "everything" independently would silently disagree about which objects
    // exist, and the comparison would be of different trees.
    if (objPaths) {
        std::vector<DumpLine> lines;
        collectDump(rootNode, "o.", "", lines);
        std::set<std::string> objs, printed;
        std::printf("\n");                       // the root, as an empty path
        for (auto &l : lines) {
            if (l.setObj == "o" || l.setObj.empty()) continue;
            if (l.setObj.find("propObj(") != std::string::npos) continue;
            if (l.setObj.find(',') != std::string::npos) continue;
            auto lp = l.label.rfind('.');
            if (lp == std::string::npos) continue;
            std::string path = l.label.substr(0, lp);
            if (path.find('@') != std::string::npos) continue;
            if (!objs.insert(l.setObj).second) continue;
            std::printf("%s\n", path.c_str());
        }
        return partial ? 3 : 0;
    }
    // Labels whose index a VIEW decides — see g_hasComponentBind.
    auto dropGuessedIndices = [](std::vector<DumpLine> &ls) {
        if (!g_hasComponentBind) return;
        ls.erase(std::remove_if(ls.begin(), ls.end(), [](const DumpLine &l) {
                     return l.label.find('[') != std::string::npos; }), ls.end());
    };
    // --labels: print the sorted dump labels (property paths) for the oracle's --props mode.
    if (labels) {
        std::vector<DumpLine> lines;
        collectDump(rootNode, "o.", "", lines);
        dropGuessedIndices(lines);
        std::sort(lines.begin(), lines.end(), [](const DumpLine &a, const DumpLine &b){ return a.label < b.label; });
        for (auto &l : lines) std::printf("%s\n", l.label.c_str());
        return partial ? 3 : 0;
    }

    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    // Aliased so a QML property called `max` or `min` cannot collide with the import.
    std::printf("import qtmoc;\nimport std.conv : to;   // JS `+` string concatenation coerces\n"
                "import std.algorithm : __qmltcMax = max, __qmltcMin = min;   // Math.max/min (variadic)\n"
                "import std.math : __qmltcFloor = floor, __qmltcCeil = ceil;   // Math.round/ceil/floor\n%s\n%s%s",
                g_extraImports.c_str(), singletonDecls.c_str(), classes.c_str());
    if (g_needsModuleRegistration) {
        std::string sym = g_qmlUri;
        for (auto &c : sym) if (c == '.') c = '_';
        std::printf("// Attached properties resolve through Qt's QML type registry, whose module\n"
                    "// registration is lazy — with no engine to import the module, the compiled\n"
                    "// document registers it itself (qmltyperegistrar emits this function).\n"
                    "extern(C++) void qml_register_types_%s();\n", sym.c_str());
    }
    // A bound visual root needs a QGuiApplication before setting a property that lays out text.
    if (!bt.first.empty()) std::printf("extern(C) void qtd_qmltc_init_gui_app();\n");
    // --render draws the object into a PNG; the helper lives in the test harness, so the
    // declaration is only emitted where the mode can actually be used.
    if (isItemType(rootType)) {
        std::printf("extern(C) int qtd_render_item(void*, const(char)*);\n");
        std::printf("extern(C) int qtd_click_item(void*, int, int);\n");
        std::printf("extern(C) int qtd_key_item(void*, int, int);\n");
        std::printf("extern(C) int qtd_run_ms(void*, int);\n");
    }
    // ...but the property enumerator lives in the shared runtime and applies to ANY object, so it
    // is declared for every root, item or not.
    std::printf("extern(C) void qtd_dump_object(void*, const(char)*);\n"
                "extern(C) void qtd_dump_object_as(void*, const(char)*, const(char)*);\n");

    // ...but never a runnable entry point for a root we refused: `new IMonthGrid` would hand back a
    // bare QObject standing in for AbstractMonthGrid, construct real QQuickText children under it,
    // and look like a working program. The classes above are still emitted; main is not.
    if (dump && !rootUnbound) {
        std::vector<DumpLine> lines;
        collectDump(rootNode, "o.", "", lines);
        std::sort(lines.begin(), lines.end(), [](const DumpLine &a, const DumpLine &b){ return a.label < b.label; });
        std::printf("\nvoid main(string[] args) {\n");
        std::printf("    import std.stdio : writefln; import std.conv : to; import std.string : indexOf;\n    import std.algorithm : map; import std.array : join;\n");
        // A bound-type subclass is constructed with `new` (the mixin ctor builds the trampoline);
        // a fresh @QObject uses newQObject!T.
        if (!bt.first.empty()) std::printf("    qtd_qmltc_init_gui_app();\n");
        if (g_needsModuleRegistration) {
            std::string sym = g_qmlUri;
            for (auto &c : sym) if (c == '.') c = '_';
            std::printf("    qml_register_types_%s();\n", sym.c_str());
        }
        if (!bt.first.empty()) std::printf("    auto o = new %s();\n", qPrintable(cls));
        else                   std::printf("    auto o = newQObject!%s();\n", qPrintable(cls));
        // `--render <png>`: draw the object and write the frame instead of dumping property values.
        // Property values were never the bar — "renders and behaves like the interpreted version"
        // is — and nothing here drew a pixel until this mode existed. Emitted only for an ITEM
        // root: anything else has nothing to draw, and comparing two empty frames is worse than
        // having no test at all.
        // `--click <x> <y>` delivers a real click BEFORE the dump, so the value dump becomes a
        // behaviour comparison: same document, same event, same resulting state — or not.
        if (isItemType(rootType))
            std::printf("    foreach (i, a; args) if (a == \"--click\" && i + 2 < args.length)\n"
                        "        qtd_click_item(qobjOf(o), args[i + 1].to!int, args[i + 2].to!int);\n");
        // `--key <keycode>` delivers a real key press+release BEFORE the dump: focus and the bound
        // type's own C++ key handling are machinery neither the frame comparison nor the click test
        // touches, so a document can be pixel-identical, click-correct, and never see a key.
        if (isItemType(rootType))
            std::printf("    foreach (i, a; args) if (a == \"--key\" && i + 1 < args.length)\n"
                        "        qtd_key_item(qobjOf(o), args[i + 1].to!int, 0);\n");
        // `--run <ms>`: put the object in a live scene and let TIME pass before dumping, so an
        // animation has a chance to advance. Without it every dump reads the initial value.
        if (isItemType(rootType))
            std::printf("    foreach (i, a; args) if (a == \"--run\" && i + 1 < args.length)\n"
                        "        qtd_run_ms(qobjOf(o), args[i + 1].to!int);\n");
        if (isItemType(rootType))
            std::printf("    foreach (i, a; args) if (a == \"--render\" && i + 1 < args.length) {\n"
                        "        auto rc = qtd_render_item(qobjOf(o), (args[i + 1] ~ \"\\0\").ptr);\n"
                        "        if (rc != 0) writefln(\"render failed rc=%%s\", rc);\n"
                        "        return;\n"
                        "    }\n");
        std::printf("    foreach (a; args[1 .. $]) {\n");
        // `name()` INVOKES a no-arg method — the only way to observe what a method does
        // (imperative binding installs, resets, counters). Everything else is `name=value`.
        for (auto &m : rootNode.methods0)
            std::printf("        if (a == \"%s()\") { o.%s(); continue; }\n", m.c_str(), m.c_str());
        std::printf("        auto i = a.indexOf('='); if (i < 0) continue;\n");
        std::printf("        auto k = a[0 .. i]; auto v = a[i + 1 .. $];\n");
        for (auto &l : lines) {   // dynamic mutation of any int/double/bool/string prop (via meta, dotted path)
            if (l.dtype != "string" && l.dtype != "int" && l.dtype != "double" && l.dtype != "bool") continue;
            if (l.label.find('@') != std::string::npos) continue;   // default-child mutation not supported
            std::string val = (l.dtype == "int") ? "v.to!int" : (l.dtype == "double") ? "v.to!double"
                            : (l.dtype == "bool") ? "v.to!bool" : "v";
            std::printf("        if (k == \"%s\") %s(%s, \"%s\", %s);\n",
                        l.label.c_str(), l.vgroup ? "setVgroup" : "setProp",
                        l.setObj.c_str(), l.setProp.c_str(), val.c_str());
        }
        std::printf("    }\n");
        // LINKAGE CHECKS. Two bugs got past this differential because both sides compared objects
        // that were configured identically — ours simply was not ATTACHED to anything: a
        // property-bound child (`contentItem: Label {}`) was never assigned to its property, and a
        // visual child never got an ITEM parent (only a QObject one). Reading our own D field can
        // never see either. So the dump now asks QT whether each child is where the document says
        // it is, which fails loudly if the link is dropped again.
        {
            std::set<std::string> done;
            for (auto &l : lines) {
                if (l.setObj == "o" || l.setObj.empty()) continue;
                if (!done.insert(l.setObj).second) continue;
                auto dot = l.setObj.rfind('.');
                if (dot == std::string::npos) continue;
                std::string parentExpr = l.setObj.substr(0, dot);
                // the label segment naming this child (the one before the property)
                auto lp = l.label.rfind('.');
                if (lp == std::string::npos) continue;
                std::string path = l.label.substr(0, lp);
                auto sp = path.rfind('.');
                std::string seg = sp == std::string::npos ? path : path.substr(sp + 1);
                if (seg.compare(0, 5, "data[") == 0) {
                    // Guarded: only an ITEM has `parent`. A QtObject child sitting in `data` is
                    // not visual and must not be required to have an item parent.
                    std::printf("    assert(!hasProp(%s, \"parent\") || propObj(%s, \"parent\") is qobjOf(%s), "
                                "\"%s is not parented to %s as an ITEM\");\n",
                                l.setObj.c_str(), l.setObj.c_str(), parentExpr.c_str(),
                                l.label.c_str(), parentExpr.c_str());
                } else if (seg.find('[') == std::string::npos && parentExpr == "o"
                           && path.find('.') == std::string::npos
                           && isBoundObjectProp2(rootType, seg)) {
                    // Single-segment paths only. `Overlay.modal.x` names a property of the ATTACHED
                    // object, not of the root, so asking the root for `modal` fails for a reason
                    // that is not a linkage bug — the check must not claim what it cannot verify.
                    // Only a property of the ROOT's BOUND type: a declared `property QtObject kid:
                    // QtObject {}` is a plain D field and is not in the meta-object at all, so
                    // asking Qt for it would fail for a reason that is not a linkage bug.
                    std::printf("    assert(propObj(%s, \"%s\") is qobjOf(%s), "
                                "\"%s was built but never assigned to the '%s' property\");\n",
                                parentExpr.c_str(), seg.c_str(), l.setObj.c_str(), l.label.c_str(), seg.c_str());
                }
            }
        }
        // `--dumpall`: instead of the properties the COMPILER recorded, print every property each
        // object's meta-object declares, through the same shared enumerator the oracle uses. What
        // the compiler chose to record is exactly what it also chose to translate, so a document
        // could differ from the engine in any property no binding mentioned and the differential
        // would never look. Emitted as a MODE rather than replacing the dump: the recorded-label
        // comparison is what the gate is calibrated on, and widening it is a measurement, not a
        // silent change to the bar.
        {
            std::set<std::string> objs;
            // `--set <prop>=<value>` before a --dumpall: a MUTATION, so the dump becomes a test of
            // reactivity rather than of construction. Written through the meta-object as text and
            // converted by QMetaProperty, which is exactly what the oracle's `name=value` does — so
            // the two sides mutate the same way and any difference is the compiler's.
            //
            // Without this the differential only ever read initial values, and every connection the
            // compiler emits was untested: a binding wired to nothing looks identical to a correct
            // one until something changes.
            std::printf("    foreach (i, a; args) if (a.length > 6 && a[0 .. 6] == \"--set:\") {\n"
                        "        auto eq = a.indexOf('='); if (eq < 0) continue;\n"
                        "        setProp(o, a[6 .. eq], a[eq + 1 .. $]);\n"
                        "    }\n");
            std::printf("    foreach (a; args) if (a == \"--dumpall\") {\n");
            // ...named by the DOCUMENT, which is what the engine calls a type a document defines --
            // not by our generated class, whose name is whatever the caller asked for (the corpus
            // harness prefixes `Rt`, and the engine has never heard of it). When the two coincide
            // the walk stops there and reports it; when they do not, nothing in our chain matches
            // and the walk continues to the Qt base, which is also what the engine reports for a
            // document that defines no type of its own. And when the document declares no members,
            // the "skip a class that declares no properties" rule below skips past it on both
            // sides -- so one hint covers every case, including the two corpus roots (RangeSlider,
            // Tumbler) that naming our own class got wrong.
            {
                // the DOCUMENT's own file, not whatever file the resolution is standing in: with a
                // local type as the ROOT (`QLocalRoot.qml` is a `LocalBase`), g_docUrl is
                // LocalBase.qml and the hint named the wrong type.
                std::string stem = g_rootDocUrl.empty() ? g_docUrl : g_rootDocUrl;
                if (auto sl = stem.find_last_of('/'); sl != std::string::npos) stem = stem.substr(sl + 1);
                if (auto dot = stem.rfind(".qml"); dot != std::string::npos) stem = stem.substr(0, dot);
                std::printf("        qtd_dump_object_as(qobjOf(o), \"\", \"%s\");\n", stem.c_str());
            }
            for (auto &l : lines) {
                if (l.setObj == "o" || l.setObj.empty()) continue;
                if (l.setObj.find("propObj(") != std::string::npos) continue;   // a group, not a child
                // A VALUE group's setObj is the two-argument form (`o, "icon"`): a gadget, not an
                // object, so there is no QObject to enumerate.
                if (l.setObj.find(',') != std::string::npos) continue;
                auto lp = l.label.rfind('.');
                if (lp == std::string::npos) continue;
                std::string path = l.label.substr(0, lp);
                if (path.find('@') != std::string::npos) continue;
                if (!objs.insert(l.setObj).second) continue;
                // A path with a LIST INDEX is resolved the way the oracle resolves it: by walking
                // the meta-object list, not by reading the D field that happens to hold that child.
                // They are not the same object — Qt reparents visual children of a Flickable into
                // its content item, and a view INSERTS the items it creates — so comparing our
                // field against the engine's `data[0]` compared two different objects under one
                // label. Only indexed paths: a plain property path has no such ambiguity, and a
                // DECLARED object property is not in the meta-object at all.
                if (path.find('[') != std::string::npos) {
                    std::string expr = "qobjOf(o)";
                    for (size_t i = 0, j; i <= path.size(); i = j + 1) {
                        j = path.find('.', i);
                        if (j == std::string::npos) j = path.size();
                        std::string seg = path.substr(i, j - i);
                        auto br = seg.find('[');
                        if (br != std::string::npos)
                            expr = "listAt(" + expr + ", \"" + seg.substr(0, br) + "\", "
                                 + seg.substr(br + 1, seg.size() - br - 2) + ")";
                        // A segment that names an attached TYPE is not a property of the object
                        // before it — `ContextMenu.menu.contentData[0]` reaches the menu through
                        // Qt's type registry. The NON-indexed branch below never had this problem
                        // (it reuses the D expression the compiler already built), so the two
                        // walkers silently disagreed: `--objpaths` listed those objects and
                        // `--dumpall` resolved a null for them and printed nothing. Measured on
                        // TextField with the attached gate open: 664 of the paths reported as
                        // "the engine has and we do not" were this, not the compiler.
                        else if (g_qmlAttachedCxx.count(seg) || g_attached.count(seg))
                            expr = attachedExprOn(expr, seg);
                        else
                            expr = "propObj(" + expr + ", \"" + seg + "\")";
                        if (j == path.size()) break;
                    }
                    // On an INDEXED path the hint holds only if the list element IS the object we
                    // generated. Usually it is — a bare child appended to `data` — but not always:
                    // a Repeater's items are SIBLINGS of the Repeater, so `data[0]` is a delegate
                    // item on both sides while the field is the Repeater itself. Asked at runtime,
                    // which is the only place the answer exists.
                    std::printf("        { auto __o = %s; qtd_dump_object_as(__o, \"%s.\","
                                " __o is qobjOf(%s) ? \"%s\" : \"\"); }\n",
                                expr.c_str(), path.c_str(), l.setObj.c_str(),
                                g_clsHint[l.setObj].c_str());
                    continue;
                }
                std::printf("        qtd_dump_object_as(qobjOf(%s), \"%s.\", \"%s\");\n",
                            l.setObj.c_str(), path.c_str(), g_clsHint[l.setObj].c_str());
            }
            std::printf("        return;\n    }\n");
        }
        // The RECORDED-label dump — and only it — drops labels whose index a view decides
        // (g_hasComponentBind). `--dumpall` above enumerates OBJECTS, where both sides resolve the
        // same index through the same list: a real comparison rather than a guess. Filtering both
        // would leave the oracle dumping objects our side no longer prints (measured: 23 -> 279
        // paths "absent in ours", which is a harness artefact, not a compiler gap).
        dropGuessedIndices(lines);
        for (auto &l : lines)
            // A double is printed with %.17g on BOTH sides: the default shortest forms disagree on
            // a value that sits exactly between two 6-digit renderings (3.765625 -> D 3.76562,
            // Qt 3.76563), which is a formatting artefact reported as a value mismatch.
            // `+ 0.0` turns a NEGATIVE zero into a positive one (IEEE): -0 and 0 are the same
            // value and differ only in how %.17g prints them, so comparing them as text reported a
            // difference where there is none. The oracle normalises the same way.
            // An OBJECT slot has no text of its own on either side: the oracle's `--props` reads
            // the property as a QVariant and `toString()` of a QObject* is empty, filled or not.
            // Printing the D reference gave "null" against that empty, which is a spelling and not
            // a value. (`--dumpall` is where the two are actually distinguished, as <object> and
            // <null>.)
            std::printf(l.dtype == "double" ? "    writefln(\"%s\\t%%.17g\", (%s) + 0.0);\n"
                      : (l.dtype == "Object" || l.dtype == "QmlObjectList")
                                            ? "    writefln(\"%s\\t\");%.0s\n"
                                            : "    writefln(\"%s\\t%%s\", %s);\n",
                        l.label.c_str(), l.access.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
