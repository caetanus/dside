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
#include <cctype>

using namespace QQmlJS;
using namespace QQmlJS::AST;

static std::string qs(const QString &s) { return s.toStdString(); }

// The root object's `id:` (e.g. `id: root`), so a self-reference `root.x` in an expression
// resolves to the property `x`. Set once in main before any expression is compiled.
static std::string g_selfId;

// dotted name of a UiQualifiedId (e.g. a handler id `onCountChanged`, or `a.b.c`).
static std::string qname(UiQualifiedId *id) {
    std::string s;
    for (auto *p = id; p; p = p->next) { if (!s.empty()) s += '.'; s += qs(p->name.toString()); }
    return s;
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
static bool compileExpr(ExpressionNode *e, const QString &dtype, std::string &out) {
    if (!e) return false;
    if (auto *nested = cast<NestedExpression *>(e)) {
        std::string inner;
        if (!compileExpr(nested->expression, dtype, inner)) return false;
        out = "(" + inner + ")"; return true;
    }
    if (auto *id = cast<IdentifierExpression *>(e)) { out = qs(id->name.toString()); return true; }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        // self reference `<id>.<prop>` -> the property; other object member access is a later phase.
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) { out = qs(fm->name.toString()); return true; }
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
        if (!compileExpr(bin->left, sub, l) || !compileExpr(bin->right, sub, r)) return false;
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
    if (auto *id = cast<IdentifierExpression *>(e)) { ids.push_back(qs(id->name.toString())); return; }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) ids.push_back(qs(fm->name.toString()));
        else collectIds(fm->base, ids);   // e.g. `title.length` depends on title
        return;
    }
    if (auto *call = cast<CallExpression *>(e)) {
        for (auto *a = call->arguments; a; a = a->next) collectIds(a->expression, ids);
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
static bool compileStmt(Statement *st, const std::map<std::string, std::string> &ptype, std::string &body) {
    // A brace block `{ a = ...; b = ...; }` -> each assignment in order. `statement` is a Node*
    // (FunctionDeclaration doesn't inherit Statement); the list is linear in the finished AST.
    if (auto *blk = cast<Block *>(st)) {
        for (auto *s = blk->statements; s; s = s->next) {
            auto *inner = cast<ExpressionStatement *>(s->statement);
            if (!inner || !compileStmt(inner, ptype, body)) return false;
        }
        return true;
    }
    // A single assignment `prop = <expr>`.
    auto *es = cast<ExpressionStatement *>(st);
    if (!es) return false;
    auto *bin = cast<BinaryExpression *>(es->expression);
    if (!bin || bin->op != QSOperator::Assign) return false;
    auto *lhs = cast<IdentifierExpression *>(bin->left);
    if (!lhs) return false;
    std::string name = qs(lhs->name.toString());
    auto it = ptype.find(name);
    if (it == ptype.end()) return false;
    std::string rhs;
    if (!compileExpr(bin->right, QString::fromStdString(it->second), rhs)) return false;
    body += "        " + name + " = " + rhs + ";\n";
    return true;
}

// The emitted shape of an object: its scalar properties (name+type) and its child objects
// (field name + subtree). Used to generate the differential dump with dotted paths (`kid.y`).
struct ObjNode {
    std::string id;                                             // this object's QML `id:` (if any)
    std::vector<std::pair<std::string, std::string>> scalars;   // (name, dtype)
    std::vector<std::string> notified;                          // props that carry a NOTIFY signal
    std::vector<std::pair<std::string, ObjNode>> kids;          // (field name, child)
};

// Compile one QML object (its initializer) into a D @QObject class `cls`, appending the class text
// (and any nested child classes) to `classes`. Recursive: a child object `field: Type { ... }`
// (a UiObjectBinding) becomes a nested @QObject `cls_field` held in a plain field and constructed
// in __qmltcWire, so the whole tree materialises without the QML engine. Returns the ObjNode.
static ObjNode compileObject(UiObjectInitializer *init, const std::string &cls,
                             std::string &classes, int &partial, const char *inPath) {
    std::string savedId = g_selfId;
    g_selfId = "";
    for (auto *m = init ? init->members : nullptr; m; m = m->next)   // pre-scan this object's id
        if (auto *sb = cast<UiScriptBinding *>(m->member))
            if (qname(sb->qualifiedId) == "id")
                if (auto *es = cast<ExpressionStatement *>(sb->statement))
                    if (auto *idn = cast<IdentifierExpression *>(es->expression))
                        g_selfId = qs(idn->name.toString());

    std::vector<Prop> props;
    std::vector<std::pair<std::string, Statement *>> rawHandlers;                 // (signal, body)
    std::vector<std::pair<std::string, UiObjectInitializer *>> childBindings;     // (field, init)
    std::vector<std::pair<std::string, ExpressionNode *>> aliases;                // (name, target)
    Statement *onCompleted = nullptr;                                            // Component.onCompleted body
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
        }
        // `field: Type { ... }` re-binding an existing property to a child object.
        if (auto *ob = cast<UiObjectBinding *>(m->member)) {
            childBindings.push_back({qname(ob->qualifiedId), ob->initializer});
            continue;
        }
        if (auto *pub = cast<UiPublicMember *>(m->member); pub && pub->type == UiPublicMember::Property) {
            QString qmlType = pub->memberType ? pub->memberType->name.toString() : QString("var");
            std::string name = qs(pub->name.toString());
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

    // Resolve `property alias <name>: <target>`. A SELF target (`<id>.<prop>` or bare `<prop>`)
    // becomes a reactive bound property. A CHILD target (`kid.y`) becomes an initial-value read of
    // the child field (kid built first in __qmltcWire); live re-evaluation of a child target needs
    // the child prop to carry a NOTIFY and is a later step.
    {
        std::map<std::string, std::string> t;
        for (auto &p : props) t[p.name] = p.dtype;
        for (auto &al : aliases) {
            std::string expr, atype;
            std::vector<std::string> deps;
            if (auto *fm = cast<FieldMemberExpression *>(al.second)) {
                auto *base = cast<IdentifierExpression *>(fm->base);
                std::string bn = base ? qs(base->name.toString()) : "";
                std::string mem = qs(fm->name.toString());
                if (base && !g_selfId.empty() && bn == g_selfId && t.count(mem)) {
                    atype = t[mem]; expr = mem; deps.push_back(mem);            // reactive self alias
                } else if (base && childType.count(bn + "." + mem)) {
                    atype = childType[bn + "." + mem];
                    expr = childAccess[bn + "." + mem];   // "field.prop"
                    // If the child prop carries a NOTIFY, the alias is LIVE: connect the child's
                    // change signal to this alias's recompute (cross-object connect).
                    if (childNotified.count(bn + "." + mem)) {
                        std::string field = expr.substr(0, expr.find('.'));
                        crossConnects += "        connectMeta(" + field + ", \"" + mem + "Changed()\", this, \"__rc_" + al.first + "()\");\n";
                    }
                }
            } else if (auto *id = cast<IdentifierExpression *>(al.second)) {
                std::string bn = qs(id->name.toString());
                if (t.count(bn)) { atype = t[bn]; expr = bn; deps.push_back(bn); }
            }
            if (atype.empty()) {
                std::fprintf(stderr, "qmltc-d: %s: alias '%s' target is unsupported — skipped (later phase)\n", inPath, al.first.c_str());
                ++partial; continue;
            }
            props.push_back({al.first, atype, expr, true, deps});
        }
    }

    std::vector<std::string> propNames, needsNotify;
    for (auto &p : props) propNames.push_back(p.name);
    auto isProp = [&](const std::string &n){ return std::find(propNames.begin(), propNames.end(), n) != propNames.end(); };

    std::map<std::string, std::string> ptype;
    for (auto &p : props) ptype[p.name] = p.dtype;
    std::string handlerSlots, handlerWire;
    for (auto &h : rawHandlers) {
        std::string notifyProp, hbody;
        if (h.first.size() > 7 && h.first.compare(h.first.size() - 7, 7, "Changed") == 0)
            notifyProp = h.first.substr(0, h.first.size() - 7);
        if (notifyProp.empty() || !isProp(notifyProp) || !compileStmt(h.second, ptype, hbody)) {
            std::fprintf(stderr, "qmltc-d: %s: signal handler in %s not yet supported — skipped (later phase)\n", inPath, cls.c_str());
            ++partial; continue;
        }
        if (std::find(needsNotify.begin(), needsNotify.end(), notifyProp) == needsNotify.end())
            needsNotify.push_back(notifyProp);
        handlerSlots += "    @Slot void __h_" + h.first + "() {\n" + hbody + "    }\n";
        handlerWire += "        connectMeta(this, \"" + h.first + "()\", this, \"__h_" + h.first + "()\");\n";
    }
    // Component.onCompleted runs once at construction — emit its body at the tail of __qmltcWire
    // (after children built, bindings initialised, handlers connected), matching QML's timing.
    std::string onCompletedBody;
    if (onCompleted && !compileStmt(onCompleted, ptype, onCompletedBody)) {
        std::fprintf(stderr, "qmltc-d: %s: Component.onCompleted in %s not yet supported — skipped (later phase)\n", inPath, cls.c_str());
        ++partial; onCompletedBody.clear();
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
    if (anyBound || !handlerWire.empty() || !childWire.empty() || !onCompletedBody.empty()) {
        wire = "    void __qmltcWire() {\n";
        wire += childWire;   // build children first
        for (auto &p : props) if (p.bound) wire += "        __rc_" + p.name + "();\n";
        for (auto &p : props) if (p.bound)
            for (auto &d : p.deps) if (isProp(d))
                wire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_" + p.name + "()\");\n";
        wire += crossConnects;   // live child-alias connects (cross-object)
        wire += handlerWire;
        wire += onCompletedBody;   // Component.onCompleted, last
        wire += "    }\n";
    }

    classes += "@QObject class " + cls + " {\n" + body + childFields + recompute + handlerSlots + wire + "}\n";
    g_selfId = savedId;
    return node;
}

// Flatten the object tree into dump lines with dotted paths (`kid.y` <- access o.kid.y).
struct DumpLine { std::string label, access, dtype; };
static void collectDump(const ObjNode &n, const std::string &acc, const std::string &lab,
                        std::vector<DumpLine> &out) {
    for (auto &s : n.scalars) out.push_back({lab + s.first, acc + s.first, s.second});
    for (auto &k : n.kids) collectDump(k.second, acc + k.first + ".", lab + k.first + ".", out);
}

int main(int argc, char **argv) {
    // --dump: also emit a `main` that instantiates the type, applies `name=value` mutations, and
    // prints each scalar property (dotted path for children) as `name\tvalue` sorted — the
    // corpus-check-style differential vs the QQmlComponent oracle.
    bool dump = false;
    std::vector<char *> pos;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--dump") == 0) dump = true;
        else pos.push_back(argv[i]);
    }
    if (pos.empty()) { std::fprintf(stderr, "usage: %s [--dump] <file.qml> [ClassName]\n", argv[0]); return 2; }
    QFile f(pos[0]);
    if (!f.open(QIODevice::ReadOnly)) { std::fprintf(stderr, "qmltc-d: cannot open %s\n", pos[0]); return 2; }
    QString code = QString::fromUtf8(f.readAll());
    const char *inPath = pos[0];
    QString cls = pos.size() >= 2 ? QString::fromUtf8(pos[1]) : QFileInfo(inPath).completeBaseName();

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

    int partial = 0;
    std::string classes;
    ObjNode rootNode = compileObject(root->initializer, qs(cls), classes, partial, inPath);

    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    std::printf("import qtmoc;\n\n%s", classes.c_str());

    if (dump) {
        std::vector<DumpLine> lines;
        collectDump(rootNode, "o.", "", lines);
        std::sort(lines.begin(), lines.end(), [](const DumpLine &a, const DumpLine &b){ return a.label < b.label; });
        std::printf("\nvoid main(string[] args) {\n");
        std::printf("    import std.stdio : writefln; import std.conv : to; import std.string : indexOf;\n");
        std::printf("    auto o = newQObject!%s();\n", qPrintable(cls));
        std::printf("    foreach (a; args[1 .. $]) {\n");
        std::printf("        auto i = a.indexOf('='); if (i < 0) continue;\n");
        std::printf("        auto k = a[0 .. i]; auto v = a[i + 1 .. $];\n");
        for (auto &l : lines) {   // dynamic mutation of any int/string prop (dotted path -> o.kid.y)
            if (l.dtype != "string" && l.dtype != "int") continue;
            auto dot = l.access.rfind('.');
            std::string obj = l.access.substr(0, dot), prop = l.access.substr(dot + 1);
            std::string val = (l.dtype == "int") ? "v.to!int" : "v";
            std::printf("        if (k == \"%s\") setProp(%s, \"%s\", %s);\n", l.label.c_str(), obj.c_str(), prop.c_str(), val.c_str());
        }
        std::printf("    }\n");
        for (auto &l : lines)
            std::printf("    writefln(\"%s\\t%%s\", %s);\n", l.label.c_str(), l.access.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
