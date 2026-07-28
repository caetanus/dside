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
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <map>
#include <set>
#include <cctype>
#include <fstream>

using namespace QQmlJS;
using namespace QQmlJS::AST;

static std::string qs(const QString &s) { return s.toStdString(); }

// The root object's `id:` (e.g. `id: root`), so a self-reference `root.x` in an expression
// resolves to the property `x`. Set once in main before any expression is compiled.
static std::string g_selfId;

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
    auto *mod = program && program->members ? cast<UiObjectDefinition *>(program->members->member) : nullptr;
    if (!mod) { std::fprintf(stderr, "qmltc-d: %s has no Module block\n", path); return false; }
    for (auto *m = mod->initializer ? mod->initializer->members : nullptr; m; m = m->next) {
        auto *comp = cast<UiObjectDefinition *>(m->member);
        if (!comp || qname(comp->qualifiedTypeNameId) != "Component") continue;
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
            if (qname(sub->qualifiedTypeNameId) == "Signal") {
                std::string sn = qmltypesField(sub->initializer, "name");
                std::string ps;
                for (auto *pm = sub->initializer ? sub->initializer->members : nullptr; pm; pm = pm->next)
                    if (auto *par = cast<UiObjectDefinition *>(pm->member);
                            par && qname(par->qualifiedTypeNameId) == "Parameter") {
                        std::string pt = qmltypesField(par->initializer, "type");
                        if (!pt.empty()) ps += (ps.empty() ? "" : ",") + pt;
                    }
                if (!sn.empty()) dt.signalSig[sn] = sn + "(" + ps + ")";
                continue;
            }
            if (qname(sub->qualifiedTypeNameId) != "Property") continue;
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

// QML types (by element name) whose ATTACHED object this document addresses — `TestType.count`.
// Maps the element name to the registry entry of its attached class, whose members type the
// accesses. The attached object itself is fetched at runtime by name, so nothing is hard-coded.
static std::map<std::string, const DType *> g_attached;

// D type of each in-scope name (declared property, base property, function param, local). Lets
// compileExpr decide COERCIONS — notably JS `+` string concatenation, where QML converts the
// non-string side and D's `~` does not. Maintained alongside g_scope.
static std::map<std::string, std::string> g_propType;

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
    if (auto *str = cast<StringLiteral *>(e)) { out = dstr(str->value.toString()); return true; }
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
    if (!g_scope.count(n)) return false;
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
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        // self reference `<id>.<prop>` -> the property; other object member access is a later phase.
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId)
            return readName(qs(fm->name.toString()), out);   // `self.x` reads x however x is stored
        // `TypeName.Green` -> the D enum member `Color.Green` (int-valued).
        if (base && qs(base->name.toString()) == g_className) {
            auto it = g_enumMember.find(qs(fm->name.toString()));
            if (it != g_enumMember.end()) { out = it->second + "." + qs(fm->name.toString()); return true; }
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
    if (auto *str = cast<StringLiteral *>(e)) { out = dstr(str->value.toString()); return true; }
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
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) ids.push_back(qs(fm->name.toString()));
        // `group.member` depends on that member OF THE GROUP OBJECT — kept dotted so the wire
        // connects the group's own notify rather than looking for a property of this class.
        else if (base && g_groups.count(qs(base->name.toString())))
            ids.push_back(qs(base->name.toString()) + "." + qs(fm->name.toString()));
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
            if (ty.empty()) ty = (ret && paramIsString(pn, ret, pt0)) ? "string" : "double";
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
                body += "        " + lv + " = " + val + ";\n";
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
            body += "        " + name + " " + op + " " + rhs + ";\n";
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
                                         std::string *outPath = nullptr) {
    QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
    QString path = dir + "/" + QString::fromStdString(typeName) + ".qml";
    std::string p = qs(path);
    if (g_resolving.count(p)) return nullptr;   // cycle: this file is already being resolved
    if (!QFileInfo::exists(path)) return nullptr;
    if (outPath) *outPath = p;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return nullptr;
    QString code = QString::fromUtf8(f.readAll());
    auto *engine = new Engine();
    auto *lexer = new Lexer(engine);
    lexer->setCode(code, 1, /*qmlMode*/ true);
    auto *parser = new Parser(engine);
    if (!parser->parse()) return nullptr;
    auto *program = cast<UiProgram *>(parser->ast());
    if (!program || !program->members || !program->members->member) return nullptr;
    return cast<UiObjectDefinition *>(program->members->member);
}

struct ObjNode {
    std::string id;                                             // this object's QML `id:` (if any)
    std::vector<std::pair<std::string, std::string>> scalars;   // custom @Property (name, dtype)
    std::vector<std::pair<std::string, std::string>> baseProps; // base C++ Q_PROPERTYs set (name, dtype)
    std::vector<std::pair<std::string, std::string>> groupProps;// grouped members set ("group.member", dtype)
    std::vector<std::pair<std::string, std::string>> attachedProps;// attached members set ("Type.member", dtype)
    std::vector<std::string> notified;                          // props that carry a NOTIFY signal
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
    std::vector<std::pair<std::string, ObjNode>> defaultKids;   // default-property children (field, child)
};

// Compile one QML object (its initializer) into a D @QObject class `cls`, appending the class text
// (and any nested child classes) to `classes`. Recursive: a child object `field: Type { ... }`
// (a UiObjectBinding) becomes a nested @QObject `cls_field` held in a plain field and constructed
// in __qmltcWire, so the whole tree materialises without the QML engine. Returns the ObjNode.
static ObjNode compileObject(UiObjectInitializer *init, const std::string &cls,
                             std::string &classes, int &partial, const char *inPath,
                             const std::string &boundBase = "", const DType *dBase = nullptr) {
    std::string savedId = g_selfId;
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
    auto savedAliasRead = g_aliasRead;
    auto savedAliasDep = g_aliasDep;
    auto savedAliasWrite = g_aliasWrite;
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
        // Base C++ properties: a plain `<name>: <expr>` whose name isn't a declared property (nor an
        // id/handler) sets a base Q_PROPERTY; record name -> value type so references resolve to a
        // meta read. Only meaningful for a bound-type root, but harmless otherwise.
        for (auto *m = init ? init->members : nullptr; m; m = m->next)
            if (auto *sb = cast<UiScriptBinding *>(m->member)) {
                std::string hid = qname(sb->qualifiedId);
                if (hid == "id" || hid == "Component.onCompleted" || hid.find('.') != std::string::npos || pt0.count(hid)) continue;
                if (hid.size() > 2 && hid[0] == 'o' && hid[1] == 'n' && std::isupper((unsigned char)hid[2])) continue;
                if (auto *es = cast<ExpressionStatement *>(sb->statement)) {
                    std::string ty = inferType(es->expression, pt0);
                    if (!g_baseProps.count(hid)                       // a declared type already won
                            && (ty == "int" || ty == "string" || ty == "double" || ty == "bool"))
                        g_baseProps[hid] = ty;
                }
            }
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
    }

    std::vector<Prop> props;
    std::vector<std::pair<std::string, Statement *>> rawHandlers;                 // (signal, body)
    std::vector<std::pair<std::string, UiObjectInitializer *>> childBindings;     // (field, init)
    std::vector<std::pair<std::string, UiObjectInitializer *>> groupKidBindings;  // ("group.member", init)
    std::vector<std::pair<std::string, UiObjectInitializer *>> attachedKidBindings; // ("Type.member", init)
    std::vector<UiObjectDefinition *> defaultKids;                               // bare `Type { }` children
    std::vector<std::pair<std::string, ExpressionNode *>> aliases;                // (name, target)
    std::vector<FunctionExpression *> functions;                                  // QML `function`s
    std::vector<std::pair<std::string, ExpressionNode *>> rawBaseAssigns;         // base prop `name: expr`
    std::vector<std::pair<std::string, ExpressionNode *>> rawGroupAssigns;        // `group.member: expr`
    std::vector<std::pair<std::string, Statement *>> rawGroupHandlers;            // `group.on<Sig>: body`
    std::vector<std::pair<std::string, ExpressionNode *>> rawAttachedAssigns;     // `Type.member: expr`
    std::vector<std::pair<std::string, Statement *>> rawAttachedHandlers;         // `Type.on<Sig>: body`
    std::string enumDecls, signalDecls;                                           // emitted D enums / signals
    Statement *onCompleted = nullptr;                                            // Component.onCompleted body
    bool hasCustomDefaultProp = false;                                           // a `default property` declared
    for (auto *m = init ? init->members : nullptr; m; m = m->next) {
        if (auto *sb = cast<UiScriptBinding *>(m->member)) {
            std::string hid = qname(sb->qualifiedId);
            if (hid == "id") continue;
            if (hid == "Component.onCompleted") { onCompleted = sb->statement; continue; }   // runs at construction
            if (hid.size() > 2 && hid[0] == 'o' && hid[1] == 'n' && std::isupper((unsigned char)hid[2])) {
                std::string sig = hid.substr(2);
                sig[0] = (char)std::tolower((unsigned char)sig[0]);
                rawHandlers.push_back({sig, sb->statement});
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
                    if (dot == std::string::npos) { rawBaseAssigns.push_back({hid, es->expression}); continue; }
                    if (g_groups.count(head)) { rawGroupAssigns.push_back({hid, es->expression}); continue; }
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
                             inPath, qname(ob->qualifiedTypeNameId).c_str(), qname(ob->qualifiedId).c_str(), cls.c_str());
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
            childBindings.push_back({qname(ob->qualifiedId), ob->initializer});
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
            if (pub->isDefaultMember()) hasCustomDefaultProp = true;
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
            // `property Type kid: Type { ... }` — the child object hangs off pub->binding.
            if (pub->binding) {
                if (auto *ob = cast<UiObjectBinding *>(pub->binding)) { childBindings.push_back({name, ob->initializer}); continue; }
                if (auto *od = cast<UiObjectDefinition *>(pub->binding)) { childBindings.push_back({name, od->initializer}); continue; }
            }
            if (!dt[0] && !pub->statement) continue;   // bare `property Type kid` declaration -> skip
            if (dt[0] && pub->statement && literalOf(pub->statement, qmlType, expr)) {
                props.push_back({name, dt, expr, false, {}});
            } else if (dt[0] && es && compileExpr(es->expression, qmlType, expr)) {
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
        std::vector<std::pair<std::string, UiObjectInitializer *>> dedup;
        for (auto it = childBindings.rbegin(); it != childBindings.rend(); ++it) {
            bool seen = false;
            for (auto &d : dedup) if (d.first == it->first) { seen = true; break; }
            if (!seen) dedup.push_back(*it);
        }
        std::reverse(dedup.begin(), dedup.end());
        childBindings.swap(dedup);
    }

    // A child target `<childId>.<prop>` for an alias -> (dtype, D access `<field>.<prop>`, notified?).
    std::map<std::string, std::string> childType, childAccess;
    std::map<std::string, bool> childNotified;
    for (auto &cb : childBindings) {
        std::string childCls = cls + "_" + cb.first;
        ObjNode kid = compileObject(cb.second, childCls, classes, partial, inPath);   // restores g_selfId
        childFields += "    " + childCls + " " + cb.first + ";\n";
        childWire += "        " + cb.first + " = newQObject!" + childCls + "();\n";
        if (!kid.id.empty()) {
            for (auto &s : kid.scalars) {
                childType[kid.id + "." + s.first] = s.second;
                childAccess[kid.id + "." + s.first] = cb.first + "." + s.first;
            }
            for (auto &n : kid.notified) childNotified[kid.id + "." + n] = true;
        }
        node.kids.push_back({cb.first, kid});
    }

    // A custom `default property` redirects bare children into that list, not the object's QObject
    // children — so `@N` = children()[N] no longer holds. Only a problem when there ARE bare
    // children; flag PARTIAL for each rather than emit a wrong dump.
    if (hasCustomDefaultProp && !defaultKids.empty()) {
        std::fprintf(stderr, "qmltc-d: %s: bare children under a custom default property in %s not yet supported — skipped (later phase)\n",
                     inPath, cls.c_str());
        partial += (int)defaultKids.size();
        defaultKids.clear();
    }

    // Default-property children: a bare `Type { }`. The child type is mapped to a bound Qt type
    // (Item -> QQuickItem) and compiled as a nested subclass in its own field, built in __qmltcWire.
    // For the differential we don't need to reparent (the D dump reads the field directly; the
    // oracle reads childItems()[i]) — only the declaration order must match.
    for (size_t di = 0; di < defaultKids.size(); ++di) {
        auto *od = defaultKids[di];
        std::string childType = od->qualifiedTypeNameId ? qname(od->qualifiedTypeNameId) : "";
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
            std::string ltRoot = lt->qualifiedTypeNameId ? qname(lt->qualifiedTypeNameId) : "";
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
        ObjNode kid = compileObject(childInit, childCls, classes, partial, inPath, childBase);
        if (!childResolvedPath.empty()) g_resolving.erase(childResolvedPath);
        childFields += "    " + childCls + " " + field + ";\n";
        childWire += "        " + field + " = " + (childBase.empty() ? "newQObject!" + childCls + "()" : "new " + childCls + "()") + ";\n";
        node.defaultKids.push_back({field, kid});
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
                std::fprintf(stderr, "qmltc-d: %s: alias '%s' target is unsupported — skipped (later phase)\n", inPath, al.first.c_str());
                ++partial; continue;
            }
            node.aliasLines.push_back({al.first, read, atype, setObj, setProp});
        }
    }

    std::vector<std::string> propNames, needsNotify;
    for (auto &p : props) propNames.push_back(p.name);
    auto isProp = [&](const std::string &n){ return std::find(propNames.begin(), propNames.end(), n) != propNames.end(); };

    std::map<std::string, std::string> ptype;
    for (auto &p : props) ptype[p.name] = p.dtype;
    std::string handlerSlots, handlerWire;
    for (auto &h : rawHandlers) {
        // `on<Prop>Changed` connects to a property's change signal (mark the prop notified);
        // `on<Signal>` connects to a declared signal directly.
        std::string notifyProp, hbody;
        bool isCustom = g_signals.count(h.first) > 0;
        if (!isCustom && h.first.size() > 7 && h.first.compare(h.first.size() - 7, 7, "Changed") == 0)
            notifyProp = h.first.substr(0, h.first.size() - 7);
        // A handler body may be a statement, or a function expression `function(a, b) { ... }`
        // whose formals name the signal's arguments.
        StatementList *fnBody = nullptr;
        std::vector<std::string> fnParams;
        if (auto *es = cast<ExpressionStatement *>(h.second))
            if (auto *fe = es->expression->asFunctionDefinition()) {
                fnBody = fe->body;
                for (auto *f = fe->formals; f; f = f->next) if (f->element) fnParams.push_back(qs(f->element->bindingIdentifier.toString()));
            }
        bool bodyOk;
        {
            ScopeGuard sg;   // the signal's arguments are named in the body (formals override)
            if (auto sp0 = g_signalParams.find(h.first); sp0 != g_signalParams.end()) {
                int i = 0;
                for (auto &pp : sp0->second) {
                    auto pn = i < (int)fnParams.size() ? fnParams[i] : pp.first;
                    g_scope.insert(pn);
                    g_propType[pn] = pp.second;   // typed: `stringProp = x + y` can coerce y
                    ++i;
                }
            }
            bodyOk = fnBody ? compileStmtList(fnBody, ptype, hbody) : compileStmt(h.second, ptype, hbody);
        }
        if ((!isCustom && (notifyProp.empty() || !isProp(notifyProp))) || !bodyOk) {
            std::fprintf(stderr, "qmltc-d: %s: signal handler in %s not yet supported — skipped (later phase)\n", inPath, cls.c_str());
            ++partial; continue;
        }
        if (!notifyProp.empty() && std::find(needsNotify.begin(), needsNotify.end(), notifyProp) == needsNotify.end())
            needsNotify.push_back(notifyProp);
        // A custom signal handler takes the signal's parameters (accessible by name in the body);
        // param NAMES come from the handler function's formals when present, TYPES from the signal.
        std::string dparams, cppsig;
        auto sp = g_signalParams.find(h.first);
        if (sp != g_signalParams.end()) {
            int i = 0;
            for (auto &pp : sp->second) {
                std::string pn = (i < (int)fnParams.size()) ? fnParams[i] : pp.first;
                dparams += (dparams.empty() ? "" : ", ") + pp.second + " " + pn;
                cppsig += (cppsig.empty() ? "" : ",") + cppTypeOf(pp.second);
                ++i;
            }
        }
        handlerSlots += "    @Slot void __h_" + h.first + "(" + dparams + ") {\n" + hbody + "    }\n";
        handlerWire += "        connectMeta(this, \"" + h.first + "(" + cppsig + ")\", this, \"__h_" + h.first + "(" + cppsig + ")\");\n";
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
        std::string ty = inferType(ba.second, ptype), val;
        if ((ty != "int" && ty != "string" && ty != "double" && ty != "bool") || !compileExpr(ba.second, QString::fromStdString(ty), val)) {
            std::fprintf(stderr, "qmltc-d: %s: base property '%s' in %s not yet supported — skipped (later phase)\n", inPath, ba.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        // A D base's property is an inherited FIELD -> assign it; a bound C++ base's is a
        // Q_PROPERTY reachable only through the meta-object.
        baseWire += g_baseIsD ? ("        " + ba.first + " = " + val + ";\n")
                              : ("        setProp(this, \"" + ba.first + "\", " + val + ");\n");
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
        childFields += "    " + childCls + " " + field + ";\n";
        childWire += "        " + field + " = newQObject!" + childCls + "();\n";
        childWire += "        setPropObj(propObj(this, \"" + gname + "\"), \"" + mem + "\", " + field + ");\n";
        node.groupKids.push_back({field, kid});
        node.groupKidPaths.push_back(path);
    }

    // A child object bound to an ATTACHED member: built in D, then attached through the attached
    // object. Same field-vs-path split as a group child — the D field can't be the dotted path.
    for (auto &ak : attachedKidBindings) {
        auto dot = ak.first.find('.');
        std::string tn = ak.first.substr(0, dot), mem = ak.first.substr(dot + 1);
        std::string field = "_a_" + tn + "_" + mem;
        std::string childCls = cls + "_" + tn + "_" + mem;
        ObjNode kid = compileObject(ak.second, childCls, classes, partial, inPath);
        childFields += "    " + childCls + " " + field + ";\n";
        childWire += "        " + field + " = newQObject!" + childCls + "();\n";
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
                    if (ok) { methods += "    " + rt + " " + name + "(" + sig + ") {\n" + fbody + "    }\n"; done = true; }
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

    std::string body, recompute;
    bool anyBound = false;
    for (auto &p : props) {
        node.scalars.push_back({p.name, p.dtype});
        std::string notifyUda = notified(p.name) ? "@Property(\"" + p.name + "Changed\") " : "@Property ";
        if (p.bound) {
            body += "    " + notifyUda + p.dtype + " " + p.name + ";\n";
            if (notified(p.name)) body += "    Signal!() " + p.name + "Changed;\n";
            recompute += "    @Slot void __rc_" + p.name + "() {\n"
                       + "        auto _v = " + p.expr + ";\n"
                       + "        if (" + p.name + " != _v) { " + p.name + " = _v;"
                       + (notified(p.name) ? " " + p.name + "Changed.emit();" : "") + " }\n    }\n";
            anyBound = true;
        } else {
            body += "    " + notifyUda + p.dtype + " " + p.name + " = " + p.expr + ";\n";
            if (notified(p.name)) body += "    Signal!() " + p.name + "Changed;\n";
        }
    }

    std::string wire;
    if (anyBound || !handlerWire.empty() || !childWire.empty() || !onCompletedBody.empty() || !baseWire.empty()) {
        wire = "    void __qmltcWire() {\n";
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
                // A property of a D BASE: its notify signal is whatever the type declared, which
                // the registry records — don't assume the <prop>Changed spelling.
                if (!dBase) continue;
                auto n = dBase->propNotify.find(d);
                if (n == dBase->propNotify.end()) continue;
                // Use the signal's REAL signature — a NOTIFY may carry parameters
                // (TypeWithProperties::dSignal(QString,int)), and connecting it as `name()`
                // silently matches nothing, leaving the binding dead.
                auto sg = dBase->signalSig.find(n->second);
                std::string sig = sg != dBase->signalSig.end() ? sg->second : (n->second + "()");
                wire += "        connectMeta(this, \"" + sig + "\", this, \"__rc_" + p.name + "()\");\n";
            }
        wire += crossConnects;   // live child-alias connects (cross-object)
        for (auto &p : props) if (p.bound) wire += "        __rc_" + p.name + "();\n";
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
    classes += "@QObject class " + cls + ext + " {\n" + mixinLine + enumDecls + signalDecls + body
             + childFields + methods + recompute + handlerSlots + groupHandlerSlots
             + attachedHandlerSlots + wire + "}\n";
    g_selfId = savedId;
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
    return node;
}

// Flatten the object tree into dump lines with dotted paths (`kid.y` <- access o.kid.y).
// `setObj`/`setProp` are the target of a MUTATION, which is not always derivable from the label:
// a child object path is a D field chain (`o.kid`), a grouped property is reached through the
// meta-object (`propObj(o, "group")`). Deriving it from the dotted label alone got that wrong.
struct DumpLine { std::string label, access, dtype, setObj, setProp; };
static void collectDump(const ObjNode &n, const std::string &acc, const std::string &lab,
                        std::vector<DumpLine> &out) {
    std::string self = acc.substr(0, acc.size() - 1);
    for (auto &s : n.scalars) out.push_back({lab + s.first, acc + s.first, s.second, self, s.first});
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
                    lab + "@" + std::to_string(i) + ".", out);
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
        else if (std::strcmp(argv[i], "--qmlmap") == 0 && i + 1 < argc) loadQmlMap(argv[++i]);   // QML-name->class table
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
    if (!program || !program->members || !program->members->member) {
        std::fprintf(stderr, "qmltc-d: %s has no root object\n", inPath); return 1;
    }
    auto *root = cast<UiObjectDefinition *>(program->members->member);
    if (!root) { std::fprintf(stderr, "qmltc-d: %s: root is not a plain object definition (unsupported)\n", inPath); return 3; }

    // Map the root's QML type: a bound Qt type (e.g. Item -> QQuickItem) makes qmltc-d emit a D
    // SUBCLASS of it (via the QtdWidget mixin); QtObject/unmapped stays a fresh @QObject.
    std::string rootType = root->qualifiedTypeNameId ? qname(root->qualifiedTypeNameId) : "";
    auto bt = boundTypeFor(rootType);
    UiObjectInitializer *rootInit = root->initializer;
    std::string rootResolvedPath;
    if (bt.first.empty() && rootType != "QtObject") {
        // A local `.qml`-defined ROOT type (e.g. `LocallyImported { ... }`): take the local
        // definition's base and MERGE this file's use-site members onto the local definition's.
        if (UiObjectDefinition *lt = loadLocalType(rootType, inPath, &rootResolvedPath)) {
            g_localMerged = true;
            std::string ltRoot = lt->qualifiedTypeNameId ? qname(lt->qualifiedTypeNameId) : "";
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

    int partial = 0;
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
    ObjNode rootNode = compileObject(rootInit, qs(cls), classes, partial, inPath, bt.first, rootD);
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
    std::printf("import qtmoc;\nimport std.conv : to;   // JS `+` string concatenation coerces\n%s\n%s",
                g_extraImports.c_str(), classes.c_str());
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
        std::printf("    import std.stdio : writefln; import std.conv : to; import std.string : indexOf;\n");
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
        std::printf("        auto i = a.indexOf('='); if (i < 0) continue;\n");
        std::printf("        auto k = a[0 .. i]; auto v = a[i + 1 .. $];\n");
        for (auto &l : lines) {   // dynamic mutation of any int/double/bool/string prop (via meta, dotted path)
            if (l.dtype != "string" && l.dtype != "int" && l.dtype != "double" && l.dtype != "bool") continue;
            if (l.label.find('@') != std::string::npos) continue;   // default-child mutation not supported
            std::string val = (l.dtype == "int") ? "v.to!int" : (l.dtype == "double") ? "v.to!double"
                            : (l.dtype == "bool") ? "v.to!bool" : "v";
            std::printf("        if (k == \"%s\") setProp(%s, \"%s\", %s);\n",
                        l.label.c_str(), l.setObj.c_str(), l.setProp.c_str(), val.c_str());
        }
        std::printf("    }\n");
        for (auto &l : lines)
            std::printf("    writefln(\"%s\\t%%s\", %s);\n", l.label.c_str(), l.access.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
