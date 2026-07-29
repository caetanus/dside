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

// The root object's `id:` (e.g. `id: root`), so a self-reference `root.x` in an expression
// resolves to the property `x`. Set once in main before any expression is compiled.
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

// Scalar properties of each bound QML type, and each one's notify signature, from qmlprops.tsv
// (written next to qmlmap.tsv by the same generator pass, so the two cannot drift). qmlmap says
// which class backs a name — enough to CONSTRUCT one; this is what lets a member be read.
static std::map<std::string, std::map<std::string, std::string>> g_qmlProps, g_qmlNotify;
// Raw C++ type name of every property, including those with no D scalar mapping — so a
// diagnostic can say WHICH type is unsupported instead of just "unsupported".
static std::map<std::string, std::map<std::string, std::string>> g_qmlCxxType;

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
        if (!nsig.empty()) g_qmlNotify[qml][prop] = nsig;
        if (t4 != std::string::npos) g_qmlCxxType[qml][prop] = line.substr(t4 + 1);
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
        std::string mod = line.substr(t2 + 1);
        // A QML name can export more than one C++ class across import versions (e.g. TextEdit ->
        // QQuickTextEdit and the legacy QQuickPre64TextEdit). `import QtQuick` (latest) resolves to
        // the modern one, so prefer a non-"Pre64" class when a name repeats.
        auto it = g_qmlMap.find(qml);
        if (it != g_qmlMap.end() && cpp.find("Pre64") != std::string::npos) continue;
        g_qmlMap[qml] = {cpp, mod};
    }
}

// Empty D type = not a mapped bound type (a fresh @QObject / local type / unsupported).
static std::pair<std::string, std::string> boundTypeFor(const std::string &qmlType) {
    auto it = g_qmlMap.find(qmlType);
    return it != g_qmlMap.end() ? it->second : std::pair<std::string, std::string>{"", ""};
}

// dotted name of a UiQualifiedId (e.g. a handler id `onCountChanged`, or `a.b.c`).
static std::string qname(UiQualifiedId *id) {
    std::string s;
    for (auto *p = id; p; p = p->next) { if (!s.empty()) s += '.'; s += qs(p->name.toString()); }
    return s;
}

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
static std::set<std::string> g_qualifiedTypes;

// The document's source text, so a diagnostic can quote the expression it refused. Reading a
// cluster of "expression not supported" was guesswork without it: matching a property name back
// to a line picks the FIRST occurrence, which is the root's, even when the failure is in a child.
static QString g_srcText;

// Every document parsed so far, so a node from a local .qml is quoted from ITS file. One global
// text was wrong the moment a local type was loaded: the offsets belong to another document, and
// the bounds check blanked 78 of the snippets rather than quoting the wrong file.
static std::vector<QString> g_allSrc;

// The source snippet an AST node came from, single-lined and clipped.
static std::string srcOf(Node *n) {
    if (!n) return "";
    auto a = n->firstSourceLocation(), b = n->lastSourceLocation();
    int from = (int)a.offset, to = (int)(b.offset + b.length);
    if (from < 0 || to <= from) return "";
    const QString *src = nullptr;
    if (to <= g_srcText.size()) src = &g_srcText;
    else for (auto &t : g_allSrc) if (to <= t.size()) { src = &t; break; }
    if (!src) return "";
    const QString &g_srcText = *src;
    QString t = g_srcText.mid(from, to - from).simplified();
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
// The chain of ENCLOSING objects, innermost first. `__outer` is always the IMMEDIATE parent, so an
// id further up is reached by hopping: `__outer.__outer.gap`. Without this the field was declared
// as the id-bearing ancestor's class while the value published was the immediate parent's — and
// since `cast(T) someVoidPtr` in D is an unchecked reinterpret, that read a different object's
// fields rather than failing. Qt's Controls nest two and three deep routinely.
struct OuterFrame { std::string id, cls, qmlType;
                    std::map<std::string, std::string> propType, baseProps; };
static std::vector<OuterFrame> g_outerChain;
static int g_outerHopsNeeded = -1;   // deepest hop this object used; drained by its parent
// Out-channel: a child that connects to `__outer.<prop>` needs that property to CARRY a notify,
// and only the parent's own emission can create the signal. The child records the name here and
// the parent drains it immediately after compileObject returns.
// (hops-still-to-travel, property). A child that connects to `__outer.__outer.gap` needs the
// GRANDparent to carry gapChanged, so each level drains what is addressed to it and forwards the
// rest one hop further up.
static std::vector<std::pair<int, std::string>> g_outerNeedsNotify;

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

static bool outerHop(const std::string &name, std::string &prefix, const OuterFrame **frame) {
    for (size_t k = 0; k < g_outerChain.size(); ++k)
        if (!g_outerChain[k].id.empty() && g_outerChain[k].id == name) {
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

// Records `as X` aliases from a document's import headers.
static void collectImportAliases(UiProgram *program) {
    for (auto *h = program ? program->headers : nullptr; h; h = h->next)
        if (auto *imp = cast<UiImport *>(h->headerItem)) {
            std::string a = qs(imp->importId.toString());
            if (!a.empty()) g_importAliases.insert(a);
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

// Properties a PARENT binding depends on, per child id. The child decides which of its properties
// get a change signal, but only the parent knows it reads them — so the requirement is recorded
// here while the parent's bindings compile, and consulted when the child is compiled.
static std::map<std::string, std::set<std::string>> g_forceNotify;

// Collect `id:` and declared property types of every child object bound to a named property, so
// `<id>.<prop>` resolves in this object's bindings.
static void prescanChildIds(UiObjectInitializer *init) {
    for (auto *m = init ? init->members : nullptr; m; m = m->next) {
        auto *pub = cast<UiPublicMember *>(m->member);
        if (!pub || pub->type != UiPublicMember::Property || !pub->binding) continue;
        UiObjectInitializer *ci = nullptr;
        if (auto *ob = cast<UiObjectBinding *>(pub->binding)) ci = ob->initializer;
        else if (auto *od = cast<UiObjectDefinition *>(pub->binding)) ci = od->initializer;
        if (!ci) continue;
        std::string field = qs(pub->name.toString()), cid;
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
                const char *dt = dtypeOf(cp->memberType->name.toString());
                if (dt[0]) pts[qs(cp->name.toString())] = dt;
                continue;
            }
            if (auto *cp = cast<UiPublicMember *>(cm->member);
                    cp && cp->type == UiPublicMember::Signal) {
                std::vector<std::pair<std::string, std::string>> ps;
                bool ok = true;
                for (auto *pp = cp->parameters; pp; pp = pp->next) {
                    const char *dt = pp->type ? dtypeOf(pp->type->toString()) : "";
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
        if (!cid.empty()) g_childIds[cid] = {field, pts, bps, bns, sigs, meths};
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
            if (!g_selfId.empty() && tid == g_selfId) continue;      // target: this object
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
                b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId
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
                b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId
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
                b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId
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
static std::string attachedExpr(const std::string &typeName) {
    g_needsModuleRegistration = true;
    return "attachedObj(this, \"" + g_qmlUri + "\", \"" + typeName + "\")";
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

static bool readName(const std::string &n, std::string &out) {
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
        return false;
    }
    out = n; return true;
}

static bool compileExpr(ExpressionNode *e, const QString &dtype, std::string &out) {
    if (!e) return false;
    if (auto *nested = cast<NestedExpression *>(e)) {
        std::string inner;
        if (!compileExpr(nested->expression, dtype, inner)) return false;
        out = "(" + inner + ")"; return true;
    }
    if (auto *id = cast<IdentifierExpression *>(e)) return readName(qs(id->name.toString()), out);
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
        return false;
    }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        // `nums.length` -> D's .length, but QML's is an int and D's is a size_t: cast so the
        // property's declared int type and any arithmetic on it stay int.
        if (auto *b = cast<IdentifierExpression *>(fm->base);
                b && qs(fm->name.toString()) == "length" && g_valueLists.count(qs(b->name.toString()))) {
            out = "cast(int) " + qs(b->name.toString()) + ".length"; return true;
        }
        // self reference `<id>.<prop>` -> the property; other object member access is a later phase.
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId)
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
                return false;   // unknown member of that enclosing object: refused, not guessed
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
                if (m == g->second->propType.end()) return false;
                const char *rd = m->second == "string" ? "propStr(" : m->second == "double" ? "propDouble("
                               : m->second == "bool" ? "propBool(" : "propInt(";
                out = rd + std::string("propObj(this, \"") + qs(base->name.toString()) + "\"), \""
                    + qs(fm->name.toString()) + "\")";
                return true;
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
            if (fn == "max" && args.size() == 2) { out = "(" + args[0] + " > " + args[1] + " ? " + args[0] + " : " + args[1] + ")"; return true; }
            if (fn == "min" && args.size() == 2) { out = "(" + args[0] + " < " + args[1] + " ? " + args[0] + " : " + args[1] + ")"; return true; }
            if (fn == "abs" && args.size() == 1) { out = "(" + args[0] + " < 0 ? -(" + args[0] + ") : (" + args[0] + "))"; return true; }
            return false;
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
        // `control.checkState === Qt.Checked` — comparing an ENUM property to an enum member. The
        // numeric value is not knowable here, but an enum property READ AS A STRING gives its KEY
        // (QVariant::toString goes through QMetaEnum), and the member's key is its own name. So
        // the comparison is done on keys, which needs no table of enum values at all.
        if (bin->op == QSOperator::StrictEqual || bin->op == QSOperator::Equal
                || bin->op == QSOperator::StrictNotEqual || bin->op == QSOperator::NotEqual) {
            auto enumKey = [&](ExpressionNode *x, std::string &key) {
                auto *fm2 = cast<FieldMemberExpression *>(x);
                if (!fm2) return false;
                auto *b2 = cast<IdentifierExpression *>(fm2->base);
                if (!b2) return false;
                std::string tn = qs(b2->name.toString()), mem = qs(fm2->name.toString());
                if (mem.empty() || !std::isupper((unsigned char)mem[0])) return false;
                // A type name or the `Qt` global — never an object in scope, which would be a
                // plain property read and must keep compiling as one.
                if (g_childIds.count(tn) || g_singletons.count(tn)) return false;
                if (!g_outerId.empty() && tn == g_outerId) return false;
                if (!g_selfId.empty() && tn == g_selfId) return false;
                if (tn != "Qt" && !g_qmlCxxType.count(tn)) return false;
                key = mem; return true;
            };
            // ...and the other side must be a property whose type we do NOT map to a D scalar,
            // which is exactly what an enum property looks like in the tables.
            auto enumRead = [&](ExpressionNode *x, std::string &outRead) {
                std::string tmp;
                auto *fm2 = cast<FieldMemberExpression *>(x);
                if (!fm2) return false;
                auto *b2 = cast<IdentifierExpression *>(fm2->base);
                if (!b2) return false;
                std::string bn = qs(b2->name.toString()), mem = qs(fm2->name.toString()), pre;
                const OuterFrame *fr = nullptr;
                std::string obj;
                if (outerHop(bn, pre, &fr)) obj = pre.substr(0, pre.size() - 1);
                else if (auto ci = g_childIds.find(bn); ci != g_childIds.end()) obj = ci->second.field;
                else if (!g_selfId.empty() && bn == g_selfId) obj = "this";
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
            std::string key, read;
            if ((enumKey(bin->right, key) && enumRead(bin->left, read))
                    || (enumKey(bin->left, key) && enumRead(bin->right, read))) {
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
                      || (!g_selfId.empty() && bn == g_selfId);
            if (!isObj)
                for (auto &f : g_outerChain) if (!f.id.empty() && f.id == bn) isObj = true;
            if (!isObj && !mem.empty() && std::isupper((unsigned char)mem[0])
                    && (bn == "Qt" || g_qmlCxxType.count(bn)))
                return;
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
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) ids.push_back(qs(fm->name.toString()));
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
    if (auto *b = cast<BinaryExpression *>(e)) { collectIds(b->left, ids); collectIds(b->right, ids); return; }
}

struct Prop { std::string name, dtype, expr; bool bound; std::vector<std::string> deps; };

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
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) { auto it = ptype.find(qs(fm->name.toString())); return it != ptype.end() ? it->second : ""; }
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
                    b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId
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
static UiObjectDefinition *loadLocalType(const std::string &typeName, const char *inPath,
                                         std::string *outPath = nullptr, bool *isSingleton = nullptr) {
    QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
    QString path = dir + "/" + QString::fromStdString(typeName) + ".qml";
    std::string p = qs(path);
    if (g_resolving.count(p)) return nullptr;   // cycle: this file is already being resolved
    if (!QFileInfo::exists(path)) return nullptr;
    if (outPath) *outPath = p;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return nullptr;
    QString code = QString::fromUtf8(f.readAll());
    g_srcText = code;   // this document's text, for the snippet a diagnostic quotes
    g_allSrc.push_back(code);
    auto *engine = new Engine();
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
    std::vector<std::pair<std::string, ObjNode>> kids;          // property-typed children (field, child)
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
struct StateEntry { std::string name; std::vector<StateOverride> overrides; };

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
                if (qname(sb->qualifiedId) != "name") return false;
                auto *es = cast<ExpressionStatement *>(sb->statement);
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
    std::string savedSelfQmlType = g_selfQmlType;
    std::string savedId = g_selfId;
    // Everything still in the globals belongs to the ENCLOSING object: capture it as the outer
    // scope before it is overwritten. Only an enclosing object with an `id` is addressable.
    std::string savedOuterId = g_outerId, savedOuterClass = g_outerClass,
                savedOuterQmlType = g_outerQmlType, savedSelfClass = g_selfClass;
    auto savedOuterPropType = g_outerPropType;
    auto savedOuterBaseProps = g_outerBaseProps;
    bool savedOuterUsed = g_outerUsed;
    // Push the enclosing object onto the chain — WITH or WITHOUT an id, because an anonymous
    // level still costs a hop. Its base properties are kept apart from the declared ones:
    // g_propType also carries base names the document assigns (`width: 100`), and those are
    // Q_PROPERTYs on the C++ base, not D fields — reading them as `__outer.width` won't compile.
    auto savedOuterChain = g_outerChain;
    if (!g_selfClass.empty())
        g_outerChain.insert(g_outerChain.begin(),
                            OuterFrame{savedId, g_selfClass, savedSelfQmlType, g_propType, g_baseProps});
    if (!g_outerChain.empty()) {
        g_outerId = g_outerChain[0].id;
        g_outerClass = g_outerChain[0].cls;
        g_outerQmlType = g_outerChain[0].qmlType;
        g_outerPropType = g_outerChain[0].propType;
        g_outerBaseProps = g_outerChain[0].baseProps;
    }
    g_outerUsed = false;
    int savedHops = g_outerHopsNeeded;
    g_outerHopsNeeded = -1;
    g_selfClass = cls;
    // Declared here rather than beside propNames: children are compiled BEFORE the property
    // emission and drain their `__outer.<prop>` notify requirements into it.
    std::vector<std::string> needsNotify;
    if (!qmlType.empty()) g_selfQmlType = qmlType;
    g_selfId = "";
    for (auto *m = init ? init->members : nullptr; m; m = m->next)   // pre-scan this object's id
        if (auto *sb = cast<UiScriptBinding *>(m->member))
            if (qname(sb->qualifiedId) == "id")
                if (auto *es = cast<ExpressionStatement *>(sb->statement))
                    if (auto *idn = cast<IdentifierExpression *>(es->expression))
                        g_selfId = qs(idn->name.toString());

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
    g_childIds.clear();
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
                const char *dt = p->type ? dtypeOf(p->type->toString()) : "";
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
                if (pub->memberType) { const char *dt = dtypeOf(pub->memberType->name.toString()); if (dt[0]) pt0[qs(pub->name.toString())] = dt; }
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
            if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Property)
                g_scope.insert(qs(pub->name.toString()));
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
            if (!g_selfId.empty() && bn == g_selfId && pt0.count(mem)) { ty = pt0[mem]; rd = mem; }
            else if (!g_selfId.empty() && bn == g_selfId && g_baseProps.count(mem)) {
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
    std::vector<StateEntry> stateTable;          // `states:` compiled as data, not as objects
    std::string initialState;                    // the document's `state: "..."`, if any
    std::vector<std::pair<std::string, UiObjectInitializer *>> groupKidBindings;  // ("group.member", init)
    std::vector<std::pair<std::string, UiObjectInitializer *>> attachedKidBindings; // ("Type.member", init)
    struct ArrayElem { std::string prop; int idx; UiObjectDefinition *def; };
    std::vector<ArrayElem> arrayBindings;                                        // `listProp: [ … ]`
    std::vector<UiObjectDefinition *> defaultKids;                               // bare `Type { }` children
    std::vector<std::pair<std::string, ExpressionNode *>> aliases;                // (name, target)
    std::vector<FunctionExpression *> functions;                                  // QML `function`s
    std::vector<std::pair<std::string, ExpressionNode *>> rawBaseAssigns;         // base prop `name: expr`
    std::vector<std::pair<std::string, ExpressionNode *>> rawGroupAssigns;        // `group.member: expr`
    std::vector<std::pair<std::string, ExpressionNode *>> rawValueGroupAssigns;   // `vgroup.member: expr`
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
                if (auto *es = cast<ExpressionStatement *>(sb->statement)) {
                    if (dot == std::string::npos) {
                        // `state: "big"` selects which State's overrides apply. It is recorded
                        // rather than assigned: assigning the base property would set the name
                        // without applying anything, which reads as a state that silently did
                        // nothing.
                        if (hid == "state")
                            if (auto *sl = cast<StringLiteral *>(es->expression)) {
                                initialState = qs(sl->value.toString());
                                rawBaseAssigns.push_back({hid, es->expression});
                                continue;
                            }
                        rawBaseAssigns.push_back({hid, es->expression}); continue;
                    }
                    if (g_groups.count(head)) { rawGroupAssigns.push_back({hid, es->expression}); continue; }
                    // `vgroup.member: <expr>` — same shape, but it must compile to a
                    // read-modify-write on the VALUE (see rawValueGroupAssigns below).
                    if (g_vgroups.count(head)) { rawValueGroupAssigns.push_back({hid, es->expression}); continue; }
                    // `font.pixelSize: 22` on a BOUND type. g_vgroups is populated only for
                    // D-registered types, so this was refused outright — but no compile-time
                    // table is needed: setVgroup resolves the member BY NAME through the gadget's
                    // meta-object at runtime and QMetaType converts the value. The compiler only
                    // has to know that `font` is a property whose type is not a scalar.
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
                std::fprintf(stderr, "qmltc-d: %s: '%s on %s' value source in %s not yet supported — skipped (later phase)\n",
                             inPath, typeName(ob->qualifiedTypeNameId).c_str(), qname(ob->qualifiedId).c_str(), cls.c_str());
                ++partial; continue;
            }
            // A DOTTED target (`group.object: QtObject { … }`) binds a child to a member of a
            // GROUPED property: build the child, then attach it THROUGH the group object. The D
            // field cannot be named after the dotted path (`class X_group.object` is not valid D),
            // so field and QML path are tracked separately from here on.
            {
                std::string qid = qname(ob->qualifiedId);
                auto dot = qid.find('.');
                if (dot != std::string::npos) {
                    if (g_attached.count(qid.substr(0, dot))) {
                        attachedKidBindings.push_back({qid, ob->initializer});
                        continue;
                    }
                    if (!g_groups.count(qid.substr(0, dot))) {
                        std::fprintf(stderr, "qmltc-d: %s: child object bound to '%s' in %s is not a grouped "
                                     "property — skipped (later phase)\n", inPath, qid.c_str(), cls.c_str());
                        ++partial; continue;
                    }
                    groupKidBindings.push_back({qid, ob->initializer});
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
            QString qmlType = pub->memberType ? pub->memberType->name.toString() : QString("var");
            std::string name = qs(pub->name.toString());
            // A custom `default property` (typically `list<QtObject>`) redirects bare children into
            // that list rather than the object's QObject children; whether that breaks our `@N` =
            // children()[N] dump model depends on there being bare children, which we only know after
            // the scan — record it and decide below.
            if (pub->isDefaultMember()) {
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
                                    b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId)
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
            std::string expr;
            auto *es = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr;
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
            if (dt[0] && pub->typeModifier == QLatin1String("list") && !pub->isDefaultMember()) {
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
                    childBindings.push_back({name, ob->initializer,
                                             ob->qualifiedTypeNameId ? typeName(ob->qualifiedTypeNameId) : ""}); continue;
                }
                if (auto *od = cast<UiObjectDefinition *>(pub->binding)) { childBindings.push_back({name, od->initializer,
                                        od->qualifiedTypeNameId ? typeName(od->qualifiedTypeNameId) : ""}); continue; }
            }
            if (!dt[0] && !pub->statement) continue;   // bare `property Type kid` declaration -> skip
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
            } else if (dt[0] && es && compileExpr(es->expression, effType, expr)) {
                std::vector<std::string> ids; collectIds(es->expression, ids);
                props.push_back({name, dt, expr, true, ids});
            } else {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' (%s) is an unsupported binding/type — skipped (later phase)\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType));
                ++partial;
            }
            continue;
        }
        std::fprintf(stderr, "qmltc-d: %s: a member of %s is not yet handled — skipped (later phase)\n", inPath, cls.c_str());
        ++partial;
    }

    // Child objects FIRST, so aliases can target a child property and __qmltcWire builds each child
    // before anything reads it. Each child is a recursively-compiled nested @QObject in a plain field.
    ObjNode node;
    node.id = g_selfId;   // still this object's id here (the loop doesn't touch g_selfId)
    std::string childFields, childWire, crossConnects;
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

    // A child target `<childId>.<prop>` for an alias -> (dtype, D access `<field>.<prop>`, notified?).
    std::map<std::string, std::string> childType, childAccess;
    std::map<std::string, bool> childNotified;
    for (auto &cb : childBindings) {
        std::string childCls = cls + "_" + cb.field;
        // Resolve the child's BOUND base, exactly as the default-child path already does, and
        // import its module (plus the package's qtvirt, which the trampoline mixin needs).
        auto cbt = boundTypeFor(cb.type);
        if (!cbt.first.empty() && !cbt.second.empty()) {
            std::string imp = "import " + cbt.second + ";\n";
            if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
            std::string vimp = "import " + cbt.second.substr(0, cbt.second.rfind('.')) + ".qtvirt;\n";
            if (g_extraImports.find(vimp) == std::string::npos) g_extraImports += vimp;
        }
        ObjNode kid = compileObject(cb.init, childCls, classes, partial, inPath, cbt.first, nullptr, cb.type);
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
        childFields += "    " + childCls + " " + cb.field + ";\n";
        childWire += std::string(kid.usesOuter ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + cb.field + " = "
                   + (cbt.first.empty() ? "newQObject!" + childCls + "()" : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + cb.field + ", this);\n"
                   + ""
                   + "        classBegin(" + cb.field + ");\n";
        if (!kid.id.empty()) {
            for (auto &s : kid.scalars) {
                childType[kid.id + "." + s.first] = s.second;
                childAccess[kid.id + "." + s.first] = cb.field + "." + s.first;
            }
            for (auto &n : kid.notified) childNotified[kid.id + "." + n] = true;
        }
        node.kids.push_back({cb.field, kid});
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
    if (defaultKidLabel.empty() && !boundBase.empty() && !defaultKids.empty()) {
        defaultKidLabel = "data";
        defaultKidIsList = true;
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
        std::string childResolvedPath;                       // local-type file path (for the cycle guard)
        if (cbt.first.empty() && childType != "QtObject") {
            // A local `.qml`-defined type (HelloWorld { }): compile ITS OWN root as this child's
            // class, taking the local definition's base (QtObject -> fresh @QObject, Item -> bound).
            UiObjectDefinition *lt = loadLocalType(childType, inPath, &childResolvedPath);
            if (!lt) {
                std::fprintf(stderr, "qmltc-d: %s: default child of type '%s' in %s not yet supported — skipped (later phase)\n",
                             inPath, childType.c_str(), cls.c_str());
                ++partial; continue;
            }
            std::string ltRoot = lt->qualifiedTypeNameId ? typeName(lt->qualifiedTypeNameId) : "";
            childBase = boundTypeFor(ltRoot).first;
            childBaseImport = boundTypeFor(ltRoot).second;
            childInit = lt->initializer;
            // Use-site members (`HelloWorld { property string text: ... }`) EXTEND the local type:
            // append the use-site member list onto the local definition's, so the merged class carries
            // both. lt is a fresh per-use parse (not shared), so splicing its list in place is safe;
            // both ASTs are leaked, so the cross-pool `next` link stays valid.
            if (od->initializer && od->initializer->members) {
                if (!childInit) childInit = od->initializer;
                else if (!childInit->members) childInit->members = od->initializer->members;
                else {
                    auto *tail = childInit->members;
                    while (tail->next) tail = tail->next;
                    tail->next = od->initializer->members;
                }
            }
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
        if (!childResolvedPath.empty()) g_resolving.insert(childResolvedPath);
        ObjNode kid = compileObject(childInit, childCls, classes, partial, inPath, childBase, nullptr, childType);
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
        if (!childResolvedPath.empty()) g_resolving.erase(childResolvedPath);
        childFields += "    " + childCls + " " + field + ";\n";
        childWire += std::string(kid.usesOuter ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (childBase.empty() ? "newQObject!" + childCls + "()" : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + field + ", this);\n"
                   + ""
                   + "        classBegin(" + field + ");\n";
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
                if (base && !g_selfId.empty() && bn == g_selfId && t.count(mem)) {
                    atype = t[mem]; read = SELF + "." + mem; setObj = SELF; setProp = mem;   // own property
                } else if (base && !g_selfId.empty() && bn == g_selfId && g_baseProps.count(mem)) {
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
                            b && !g_selfId.empty() && qs(b->name.toString()) == g_selfId
                            && g_scope.count(qs(fm->name.toString())))
                        objectAlias = true;
                if (objectAlias) continue;
                std::fprintf(stderr, "qmltc-d: %s: alias '%s' target is unsupported — skipped (later phase)\n", inPath, al.first.c_str());
                ++partial; continue;
            }
            node.aliasLines.push_back({al.first, read, atype, setObj, setProp});
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
    std::string handlerSlots, handlerWire;
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
    for (auto &ba : rawBaseAssigns) {
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
        std::string val;
        std::string copyAssign;   // set when the value is a plain property read (a QVariant copy)
        bool scalar = (ty == "int" || ty == "string" || ty == "double" || ty == "bool");
        // A property we cannot type as a D scalar (QColor, QFont, an enum, a model) is still
        // perfectly reachable when the VALUE is just another property: the QVariant carries the
        // type and QMetaType converts on write. `font: control.font` and `color:
        // control.palette.text` are the two commonest lines in Qt's own Controls, and neither
        // needs the generator to know what a QFont is.
        if (!scalar) {
            std::string srcObj, srcProp, srcGroup;
            // The source object is resolved through the SAME hop chain as a scalar read, so an
            // enclosing id two levels up works here too.
            auto resolveObj = [&](IdentifierExpression *b) -> std::string {
                std::string bn = qs(b->name.toString()), pre;
                const OuterFrame *fr = nullptr;
                if (outerHop(bn, pre, &fr)) return pre.substr(0, pre.size() - 1);
                if (auto ci = g_childIds.find(bn); ci != g_childIds.end()) return ci->second.field;
                if (!g_selfId.empty() && bn == g_selfId) return "this";
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
            if (srcObj.empty())
                if (auto *cond = cast<ConditionalExpression *>(ba.second)) {
                    std::string o1, g1, p1, o2, g2, p2, cexpr;
                    readSrc(cond->ok, o1, g1, p1);
                    readSrc(cond->ko, o2, g2, p2);
                    if (!o1.empty() && !o2.empty() && compileExpr(cond->expression, "bool", cexpr)) {
                        copyAssign = "        if (" + cexpr + ") " + copyStmt(o1, g1, p1) + "\n"
                                   + "        else " + copyStmt(o2, g2, p2) + "\n";
                        ty = "string";
                    }
                }
            // `verticalAlignment: Text.AlignVCenter` — an ENUM member of a bound QML type. The
            // meta-object converts a KEY STRING through QMetaEnum on write, so the numeric value
            // never has to be known here.
            if (srcObj.empty())
                if (auto *fme = cast<FieldMemberExpression *>(ba.second))
                    if (auto *tb = cast<IdentifierExpression *>(fme->base)) {
                        std::string tn = qs(tb->name.toString()), mem = qs(fme->name.toString());
                        if (resolveObj(tb).empty() && !g_singletons.count(tn) && !mem.empty()
                                && std::isupper((unsigned char)mem[0]) && g_qmlCxxType.count(tn)) {
                            baseWire += "        setProp(this, \"" + ba.first + "\", \"" + mem + "\");\n";
                            node.baseProps.push_back({ba.first, "string"});
                            continue;
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
        if (copyAssign.empty() && (!scalar || !compileExpr(ba.second, QString::fromStdString(ty), val))) {
            // Two very different gaps used to share one message, which made the cluster
            // unreadable: a declared TYPE we don't route (color, font, an enum) is not the same
            // problem as an EXPRESSION we can't compile into a type we do route.
            std::fprintf(stderr, "qmltc-d: %s: base property '%s' in %s not yet supported: %s '%s' [%s] — skipped (later phase)\n",
                         inPath, ba.first.c_str(), cls.c_str(),
                         scalar ? "expression for" : "declared type", ty.empty() ? "?" : ty.c_str(),
                         srcOf(ba.second).c_str());
            ++partial; continue;
        }
        // A D base's property is an inherited FIELD -> assign it; a bound C++ base's is a
        // Q_PROPERTY reachable only through the meta-object.
        // The copy is a BINDING like any other: it goes through the same recompute+connect path
        // below, which also fixes ordering — children are constructed before the parent assigns
        // its own properties, so the first copy reads a default and the notify corrects it.
        std::string assign = !copyAssign.empty() ? copyAssign
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
            for (auto &d : deps) {
                if (d == ba.first || !seen.insert(d).second) continue;   // self-reference is not a dep
                if (d.rfind("__outer.", 0) == 0) {   // reads an enclosing object
                    std::string obj, mem, sig; const OuterFrame *fr = nullptr;
                    if (!splitOuterDep(d, obj, mem, &fr)) { ++partial; continue; }
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
                std::string sig;
                if (auto qn = g_qmlNotify.find(g_selfQmlType); qn != g_qmlNotify.end()) {
                    auto nt = qn->second.find(d);
                    if (nt != qn->second.end() && !nt->second.empty()) sig = nt->second;
                }
                if (!sig.empty()) {
                    conns += "        connectMeta(this, \"" + sig + "\", this, \"__rcb_"
                           + ba.first + "()\");\n";
                    continue;
                }
                if (g_valueLists.count(d) || g_singletons.count(d)) continue;   // nothing mutates these
                std::fprintf(stderr, "qmltc-d: %s: base binding '%s' in %s depends on '%s', which has "
                             "no known notify — it would not update (later phase)\n",
                             inPath, ba.first.c_str(), cls.c_str(), d.c_str());
                ++partial;
            }
            if (!conns.empty()) {
                handlerSlots += "    @Slot void __rcb_" + ba.first + "() {\n" + "    " + assign + "    }\n";
                handlerWire += conns;
            }
        }
        node.baseProps.push_back({ba.first, ty});
    }

    // Children attached to a grouped property's member: compile like any child, but the D field is
    // named after the sanitised path (a dotted name is not a valid D identifier) and the object is
    // attached THROUGH the group rather than held by a property of this class.
    for (auto &gk : groupKidBindings) {
        std::string path = gk.first;
        auto dot = path.find('.');
        std::string gname = path.substr(0, dot), mem = path.substr(dot + 1);
        std::string field = "_g_" + gname + "_" + mem;
        std::string childCls = cls + "_" + gname + "_" + mem;
        ObjNode kid = compileObject(gk.second, childCls, classes, partial, inPath);
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
        childWire += std::string(kid.usesOuter ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = newQObject!" + childCls + "();\n"
                   + "        setQtParent(" + field + ", this);\n"
                   + "";
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
        childWire += std::string(kid.usesOuter ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = " + (cbt.first.empty() ? "newQObject!" + childCls + "()"
                                                                     : "new " + childCls + "()") + ";\n"
                   + "        setQtParent(" + field + ", this);\n"
                   + "";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(ae.prop + "[" + std::to_string(ae.idx) + "]");
    }

    // A child object bound to an ATTACHED member: built in D, then attached through the attached
    // object. Same field-vs-path split as a group child — the D field can't be the dotted path.
    for (auto &ak : attachedKidBindings) {
        auto dot = ak.first.find('.');
        std::string tn = ak.first.substr(0, dot), mem = ak.first.substr(dot + 1);
        std::string field = "_a_" + tn + "_" + mem;
        std::string childCls = cls + "_" + tn + "_" + mem;
        ObjNode kid = compileObject(ak.second, childCls, classes, partial, inPath);
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
        childWire += std::string(kid.usesOuter ? "        __qmltcOuter = cast(void*) this;\n" : "")
                   + "        " + field + " = newQObject!" + childCls + "();\n"
                   + "        setQtParent(" + field + ", this);\n"
                   + "";
        childWire += "        setPropObj(" + attachedExpr(tn) + ", \"" + mem + "\", " + field + ");\n";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(ak.first);
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
    std::string body, recompute, stateFields, stateMethods;
    bool anyBound = false;
    for (auto &p : props) {
        node.scalars.push_back({p.name, p.dtype});
        std::string notifyUda = notified(p.name) ? "@Property(\"" + p.name + "Changed\") " : "@Property ";
        if (p.bound) {
            body += "    " + notifyUda + p.dtype + " " + p.name + ";\n";
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
                           + "        if (" + p.name + " != _v) { " + p.name + " = _v;"
                           + (notified(p.name) ? " " + p.name + "Changed.emit();" : "") + " }\n    }\n";
                anyBound = true;
                continue;
            }
            recompute += "    @Slot void __rc_" + p.name + "() {\n"
                       + "        auto _v = " + coerceTo(p.dtype, p.expr) + ";\n"
                       + "        if (" + p.name + " != _v) { " + p.name + " = _v;"
                       + (notified(p.name) ? " " + p.name + "Changed.emit();" : "") + " }\n    }\n";
            anyBound = true;
        } else {
            // An empty expr means the value is written through the meta-object (see metaAssigns):
            // the field is declared bare and QMetaType fills it.
            body += "    " + notifyUda + p.dtype + " " + p.name
                  + (p.expr.empty() ? "" : " = " + p.expr) + ";\n";
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
                    handlerWire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_"
                                 + rb.first + "_" + std::to_string(b.idx) + "()\");\n";
        }
    }

    std::string wire;
    if (anyBound || !handlerWire.empty() || !childWire.empty() || !onCompletedBody.empty() || !baseWire.empty()) {
        wire = "    void __qmltcWire() {\n";
        // classBegin() BEFORE any property is assigned, which is the order the engine uses: a
        // type implementing QQmlParserStatus may need to know it is being built from a document
        // (rather than constructed directly) before it sees its first assignment.
        wire += "        classBegin(this);\n";
        wire += childWire;   // build children first
        wire += baseWire;    // set base C++ properties
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
        wire += handlerWire;
        for (auto &p : props) if (p.bound)
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
                if (d.rfind("__outer.", 0) == 0) {
                    std::string obj, mem, sig; const OuterFrame *fr = nullptr;
                    if (!splitOuterDep(d, obj, mem, &fr)) { ++partial; continue; }
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
                    auto qn = g_qmlNotify.find(g_selfQmlType);
                    if (qn != g_qmlNotify.end()) {
                        auto nt = qn->second.find(d);
                        if (nt != qn->second.end() && !nt->second.empty()) {
                            wire += "        connectMeta(this, \"" + nt->second
                                  + "\", this, \"__rc_" + p.name + "()\");\n";
                            continue;
                        }
                    }
                    // A value list is a plain D field, not a meta-object property: it has no
                    // notify by construction and nothing mutates it, so a binding reading it is
                    // correct as a one-shot. Not a dead dependency.
                    if (g_valueLists.count(d)) continue;
                    // A SINGLETON name is an object, not a property — `number: Fixture.value`
                    // records the singleton as the dependency. Reacting to a singleton's property
                    // changing is a real gap, but it is a missing DEPENDENCY (the member is never
                    // recorded), not a missing notify, so it does not belong to this diagnostic.
                    if (g_singletons.count(d)) continue;
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
        // Entering a state OVERRIDES properties; leaving it must put the previous values BACK,
        // which the engine does on exit. The base values are captured when a state is entered
        // (not at compile time — a binding may have changed them since), so switching states
        // restores what was there before rather than what the document literally wrote.
        if (!stateTable.empty()) {
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
        for (auto &k : node.kids) wire += "        componentComplete(" + k.first + ");\n";
        for (auto &dk : node.defaultKids) wire += "        componentComplete(" + dk.first + ");\n";
        wire += "        componentComplete(this);\n";
        wire += onCompletedBody;   // Component.onCompleted, last
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
    if (g_outerUsed && !g_outerClass.empty())   // taken BEFORE this object constructs its own kids
        wire.insert(wire.find("classBegin(this);\n") + 18,
                    "        __outer = cast(" + g_outerClass + ") __qmltcOuter;\n");
    node.usesOuter = g_outerUsed && !g_outerClass.empty();
    classes += "@QObject class " + cls + ext + " {\n" + mixinLine + outerField + enumDecls + signalDecls + valueListDecls + stateFields + body + stateMethods
             + childFields + methods + recompute + handlerSlots + groupHandlerSlots
             + attachedHandlerSlots + wire + "}\n";
    g_selfId = savedId;
    g_selfQmlType = savedSelfQmlType;
    g_outerId = savedOuterId; g_outerClass = savedOuterClass; g_outerQmlType = savedOuterQmlType;
    g_outerPropType = savedOuterPropType; g_outerBaseProps = savedOuterBaseProps;
    g_selfClass = savedSelfClass;
    node.outerHops = g_outerHopsNeeded;
    g_outerHopsNeeded = savedHops;
    g_outerChain = savedOuterChain;
    g_outerUsed = savedOuterUsed;
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
static void collectDump(const ObjNode &n, const std::string &acc, const std::string &lab,
                        std::vector<DumpLine> &out) {
    std::string self = acc.substr(0, acc.size() - 1);
    for (auto &s : n.scalars) {
        // A value type has no meaningful default text (a QColor prints its raw struct), so it is
        // dumped the way the engine formats it: QColor as #rrggbb, which is what QVariant gives
        // on the oracle side. Comparing the struct text against that would fail on formatting
        // while the colours were in fact identical.
        // A value-typed property is read back THROUGH the meta-object: QMetaType renders a
        // QColor as #rrggbb, which is exactly what the oracle's QVariant gives. Reading the D
        // field directly would print the raw struct and fail on formatting alone.
        if (s.second == "QColor") {
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
        const char *fn = (s.second == "string") ? "propStr(" : (s.second == "double") ? "propDouble("
                       : (s.second == "bool") ? "propBool(" : "propInt(";
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
    for (auto &k : n.kids) collectDump(k.second, acc + k.first + ".", lab + k.first + ".", out);
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
    bool dump = false, labels = false;
    std::vector<char *> pos;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--dump") == 0) dump = true;
        else if (std::strcmp(argv[i], "--labels") == 0) labels = true;   // print the dump labels (for the oracle --props)
        else if (std::strcmp(argv[i], "--qmlmap") == 0 && i + 1 < argc) {
            loadQmlMap(argv[i + 1]);                       // QML-name -> class table
            // qmlprops.tsv sits beside it and is written by the same pass, so it is never given
            // separately and the two cannot be mismatched.
            std::string pp(argv[++i]);
            auto slash = pp.find_last_of('/');
            pp = (slash == std::string::npos ? std::string() : pp.substr(0, slash + 1)) + "qmlprops.tsv";
            loadQmlProps(pp.c_str());
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
    g_allSrc.push_back(code);
    const char *inPath = pos[0];
    QString cls = pos.size() >= 2 ? QString::fromUtf8(pos[1]) : QFileInfo(inPath).completeBaseName();
    g_trContext = qs(QFileInfo(inPath).completeBaseName());   // qsTr's context is the file's name

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
    if (bt.first.empty() && rootType != "QtObject" && rootResolvedPath.empty() && !rootD) {
        std::fprintf(stderr, "qmltc-d: %s: root type '%s' is not a bound Qt type, QtObject, or local .qml type — skipped (later phase)\n",
                     inPath, rootType.c_str());
        ++partial;
    }
    std::string classes;
    if (!rootResolvedPath.empty()) g_resolving.insert(rootResolvedPath);
    g_selfQmlType = rootType;   // so base-property notifies resolve in g_qmlNotify
    ObjNode rootNode = compileObject(rootInit, qs(cls), classes, partial, inPath, bt.first, rootD);
    // A `property color` is a QColor FIELD, so the module declaring the type must be imported.
    // Only the CONVERSION is unnecessary: a colour literal is written through the meta-object and
    // QMetaType turns the string into a QColor, so nothing calls QColor.fromString. Emitted after
    // compiling, since that is when the document is known to mention one.
    if (classes.find("QColor ") != std::string::npos && !bt.second.empty()) {
        std::string pkg = bt.second.substr(0, bt.second.rfind('.'));
        std::string imp = "import " + pkg + ".qcolor;\n";
        if (g_extraImports.find(imp) == std::string::npos) g_extraImports += imp;
    }
    if (!rootResolvedPath.empty()) g_resolving.erase(rootResolvedPath);

    // --labels: print the sorted dump labels (property paths) for the oracle's --props mode.
    if (labels) {
        std::vector<DumpLine> lines;
        collectDump(rootNode, "o.", "", lines);
        std::sort(lines.begin(), lines.end(), [](const DumpLine &a, const DumpLine &b){ return a.label < b.label; });
        for (auto &l : lines) std::printf("%s\n", l.label.c_str());
        return partial ? 3 : 0;
    }

    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    std::printf("import qtmoc;\nimport std.conv : to;   // JS `+` string concatenation coerces\n%s\n%s%s",
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

    if (dump) {
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
        for (auto &l : lines)
            // A double is printed with %.17g on BOTH sides: the default shortest forms disagree on
            // a value that sits exactly between two 6-digit renderings (3.765625 -> D 3.76562,
            // Qt 3.76563), which is a formatting artefact reported as a value mismatch.
            std::printf(l.dtype == "double" ? "    writefln(\"%s\\t%%.17g\", %s);\n"
                                            : "    writefln(\"%s\\t%%s\", %s);\n",
                        l.label.c_str(), l.access.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
