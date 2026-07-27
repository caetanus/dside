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

// QML type name -> (bound D type, its import module), for a non-QtObject root that qmltc-d compiles
// as a D subclass of the bound Qt type. Empty D type = not a mapped bound type.
static std::pair<std::string, std::string> boundTypeFor(const std::string &qmlType) {
    if (qmlType == "Item") return {"QQuickItem", "qt.quick.qquickitem"};
    if (qmlType == "Rectangle") return {"QQuickRectangle", "qt.quick.qquickrectangle"};
    if (qmlType == "Text") return {"QQuickText", "qt.quick.qquicktext"};
    return {"", ""};
}

// QML accesses an enum member via the TYPE name and flattens members into the type scope
// (`TypeName.Green`), while D keeps them under the enum. g_enumMember maps a member name to its D
// enum name, and g_className is the current type name, so `TypeName.Green` -> `Color.Green` (int).
static std::map<std::string, std::string> g_enumMember;
static std::string g_className;

// Base C++ properties this object sets/reads (name -> dtype). A reference to one in an expression
// reads it through the meta-object (propInt/propStr(this, name)), as it has no D field.
static std::map<std::string, std::string> g_baseProps;

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
    if (auto *id = cast<IdentifierExpression *>(e)) {
        std::string n = qs(id->name.toString());
        auto bp = g_baseProps.find(n);   // a base C++ property -> read via meta (no D field)
        if (bp != g_baseProps.end()) { out = (bp->second == "string" ? "propStr(this, \"" : "propInt(this, \"") + n + "\")"; return true; }
        out = n; return true;
    }
    if (auto *fm = cast<FieldMemberExpression *>(e)) {
        // self reference `<id>.<prop>` -> the property; other object member access is a later phase.
        auto *base = cast<IdentifierExpression *>(fm->base);
        if (base && !g_selfId.empty() && qs(base->name.toString()) == g_selfId) { out = qs(fm->name.toString()); return true; }
        // `TypeName.Green` -> the D enum member `Color.Green` (int-valued).
        if (base && qs(base->name.toString()) == g_className) {
            auto it = g_enumMember.find(qs(fm->name.toString()));
            if (it != g_enumMember.end()) { out = it->second + "." + qs(fm->name.toString()); return true; }
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

// (name, D type) for each formal parameter of a no-body-inspected function.
static std::vector<std::pair<std::string, std::string>> funcParams(FunctionExpression *fn, const std::map<std::string, std::string> &pt0) {
    ExpressionNode *ret = nullptr;
    if (fn->body && !fn->body->next) if (auto *r = cast<ReturnStatement *>(fn->body->statement)) ret = r->expression;
    std::vector<std::pair<std::string, std::string>> ps;
    for (auto *f = fn->formals; f; f = f->next)
        if (f->element) {
            std::string pn = qs(f->element->bindingIdentifier.toString());
            ps.push_back({pn, (ret && paramIsString(pn, ret, pt0)) ? "string" : "double"});
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
    // `x++` / `++x` / `x--` / `--x` on a property -> the same in D.
    {
        ExpressionNode *inner = nullptr;
        const char *op = nullptr;
        if (auto *p = cast<PreIncrementExpression *>(es->expression)) { inner = p->expression; op = "++"; }
        else if (auto *p = cast<PostIncrementExpression *>(es->expression)) { inner = p->base; op = "++"; }
        else if (auto *p = cast<PreDecrementExpression *>(es->expression)) { inner = p->expression; op = "--"; }
        else if (auto *p = cast<PostDecrementExpression *>(es->expression)) { inner = p->base; op = "--"; }
        if (inner) {
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
// Resolve a QML type name to a sibling `<dir>/<TypeName>.qml` (a local, .qml-defined type) and parse
// it, returning its root object definition — the engine auto-imports same-directory .qml types and
// we mirror that. Engine/Parser are leaked (process-lifetime) so the returned AST stays valid for
// the rest of compilation.
static UiObjectDefinition *loadLocalType(const std::string &typeName, const char *inPath) {
    QString dir = QFileInfo(QString::fromUtf8(inPath)).absolutePath();
    QString path = dir + "/" + QString::fromStdString(typeName) + ".qml";
    if (!QFileInfo::exists(path)) return nullptr;
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
    std::vector<std::string> notified;                          // props that carry a NOTIFY signal
    std::vector<std::pair<std::string, ObjNode>> kids;          // property-typed children (field, child)
    std::vector<std::pair<std::string, ObjNode>> defaultKids;   // default-property children (field, child)
};

// Compile one QML object (its initializer) into a D @QObject class `cls`, appending the class text
// (and any nested child classes) to `classes`. Recursive: a child object `field: Type { ... }`
// (a UiObjectBinding) becomes a nested @QObject `cls_field` held in a plain field and constructed
// in __qmltcWire, so the whole tree materialises without the QML engine. Returns the ObjNode.
static ObjNode compileObject(UiObjectInitializer *init, const std::string &cls,
                             std::string &classes, int &partial, const char *inPath,
                             const std::string &boundBase = "") {
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
    g_funcRet.clear();
    g_funcReads.clear();
    g_enumMember.clear();
    g_signals.clear();
    g_signalParams.clear();
    g_baseProps.clear();
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
                    if (ty == "int" || ty == "string") g_baseProps[hid] = ty;
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
    }

    std::vector<Prop> props;
    std::vector<std::pair<std::string, Statement *>> rawHandlers;                 // (signal, body)
    std::vector<std::pair<std::string, UiObjectInitializer *>> childBindings;     // (field, init)
    std::vector<UiObjectDefinition *> defaultKids;                               // bare `Type { }` children
    std::vector<std::pair<std::string, ExpressionNode *>> aliases;                // (name, target)
    std::vector<FunctionExpression *> functions;                                  // QML `function`s
    std::vector<std::pair<std::string, ExpressionNode *>> rawBaseAssigns;         // base prop `name: expr`
    std::string enumDecls, signalDecls;                                           // emitted D enums / signals
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
            // A plain `<name>: <expr>` that isn't an id/handler assigns a base C++ Q_PROPERTY.
            if (hid.find('.') == std::string::npos)
                if (auto *es = cast<ExpressionStatement *>(sb->statement)) { rawBaseAssigns.push_back({hid, es->expression}); continue; }
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
        if (cbt.first.empty() && childType != "QtObject") {
            // A local `.qml`-defined type (HelloWorld { }): compile ITS OWN root as this child's
            // class, taking the local definition's base (QtObject -> fresh @QObject, Item -> bound).
            UiObjectDefinition *lt = loadLocalType(childType, inPath);
            if (!lt) {
                std::fprintf(stderr, "qmltc-d: %s: default child of type '%s' in %s not yet supported — skipped (later phase)\n",
                             inPath, childType.c_str(), cls.c_str());
                ++partial; continue;
            }
            std::string ltRoot = lt->qualifiedTypeNameId ? qname(lt->qualifiedTypeNameId) : "";
            childBase = boundTypeFor(ltRoot).first;
            childInit = lt->initializer;
            // Use-site members (`HelloWorld { property string text: ... }`) extend the local type;
            // merging them is a later step, so a non-empty use site is not yet fully compiled.
            if (od->initializer && od->initializer->members) {
                std::fprintf(stderr, "qmltc-d: %s: use-site members on local type '%s' in %s not yet supported — skipped (later phase)\n",
                             inPath, childType.c_str(), cls.c_str());
                ++partial; continue;
            }
        }
        std::string field = "_dc" + std::to_string(di);
        std::string childCls = cls + "_dc" + std::to_string(di);
        ObjNode kid = compileObject(childInit, childCls, classes, partial, inPath, childBase);
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
        bool bodyOk = fnBody ? compileStmtList(fnBody, ptype, hbody) : compileStmt(h.second, ptype, hbody);
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
        std::string ty = inferType(ba.second, ptype), val;
        if ((ty != "int" && ty != "string") || !compileExpr(ba.second, QString::fromStdString(ty), val)) {
            std::fprintf(stderr, "qmltc-d: %s: base property '%s' in %s not yet supported — skipped (later phase)\n", inPath, ba.first.c_str(), cls.c_str());
            ++partial; continue;
        }
        baseWire += "        setProp(this, \"" + ba.first + "\", " + val + ");\n";
        node.baseProps.push_back({ba.first, ty});
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
            for (auto &pp : params) { sig += (sig.empty() ? "" : ", ") + pp.second + " " + pp.first; ptWithParams[pp.first] = pp.second; }
            // A body with a `return` -> a typed method (return type inferred into g_funcRet); the
            // WHOLE body is compiled with g_returnType set, so multi-statement bodies (locals,
            // increments, then `return ...`) work, not just a single return.
            if (auto *rexpr = fn->body ? findReturnExpr(fn->body) : nullptr) {
                std::string rt = g_funcRet.count(name) ? g_funcRet[name] : inferType(rexpr, ptWithParams);
                if (!rt.empty()) {
                    auto savedRT = g_returnType;
                    g_returnType = rt;
                    std::string fbody;
                    bool ok = compileStmtList(fn->body, ptWithParams, fbody);
                    g_returnType = savedRT;
                    if (ok) { methods += "    " + rt + " " + name + "(" + sig + ") {\n" + fbody + "    }\n"; continue; }
                }
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
        for (auto &p : props) if (p.bound) wire += "        __rc_" + p.name + "();\n";
        for (auto &p : props) if (p.bound)
            for (auto &d : p.deps) if (isProp(d))
                wire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_" + p.name + "()\");\n";
        wire += crossConnects;   // live child-alias connects (cross-object)
        wire += handlerWire;
        wire += onCompletedBody;   // Component.onCompleted, last
        wire += "    }\n";
    }

    // A non-QtObject root becomes a D subclass of the bound Qt type via the (generic) QtdWidget
    // mixin; the trampoline + attach come from the binding, base props are set in __qmltcWire.
    std::string mixinLine = boundBase.empty() ? "" : ("    mixin QtdWidget!" + boundBase + ";\n");
    classes += "@QObject class " + cls + " {\n" + mixinLine + enumDecls + signalDecls + body + childFields + methods + recompute + handlerSlots + wire + "}\n";
    g_selfId = savedId;
    g_funcRet = savedFuncRet;
    g_funcReads = savedFuncReads;
    g_enumMember = savedEnumMember;
    g_className = savedClassName;
    g_signals = savedSignals;
    g_signalParams = savedSignalParams;
    g_baseProps = savedBaseProps;
    return node;
}

// Flatten the object tree into dump lines with dotted paths (`kid.y` <- access o.kid.y).
struct DumpLine { std::string label, access, dtype; };
static void collectDump(const ObjNode &n, const std::string &acc, const std::string &lab,
                        std::vector<DumpLine> &out) {
    for (auto &s : n.scalars) out.push_back({lab + s.first, acc + s.first, s.second});
    // Base C++ properties have no D field — read them through the meta-object (prop<Int|Str>).
    for (auto &s : n.baseProps) {
        std::string rd = (s.second == "string") ? "propStr(" + acc.substr(0, acc.size() - 1) + ", \"" + s.first + "\")"
                                                 : "propInt(" + acc.substr(0, acc.size() - 1) + ", \"" + s.first + "\")";
        out.push_back({lab + s.first, rd, s.second});
    }
    for (auto &k : n.kids) collectDump(k.second, acc + k.first + ".", lab + k.first + ".", out);
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

    // Map the root's QML type: a bound Qt type (e.g. Item -> QQuickItem) makes qmltc-d emit a D
    // SUBCLASS of it (via the QtdWidget mixin); QtObject/unmapped stays a fresh @QObject.
    std::string rootType = root->qualifiedTypeNameId ? qname(root->qualifiedTypeNameId) : "";
    auto bt = boundTypeFor(rootType);
    if (!bt.first.empty()) {
        g_extraImports += "import " + bt.second + ";\n";
        // the QtdWidget mixin needs the binding's `qtvirt` module (subclass factory / attach /
        // __<Base>_vnames), which lives at <package>.qtvirt.
        std::string pkg = bt.second.substr(0, bt.second.rfind('.'));
        g_extraImports += "import " + pkg + ".qtvirt;\n";
    }

    int partial = 0;
    std::string classes;
    ObjNode rootNode = compileObject(root->initializer, qs(cls), classes, partial, inPath, bt.first);

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
    std::printf("import qtmoc;\n%s\n%s", g_extraImports.c_str(), classes.c_str());
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
        if (!bt.first.empty()) std::printf("    auto o = new %s();\n", qPrintable(cls));
        else                   std::printf("    auto o = newQObject!%s();\n", qPrintable(cls));
        std::printf("    foreach (a; args[1 .. $]) {\n");
        std::printf("        auto i = a.indexOf('='); if (i < 0) continue;\n");
        std::printf("        auto k = a[0 .. i]; auto v = a[i + 1 .. $];\n");
        for (auto &l : lines) {   // dynamic mutation of any int/string prop (via meta, dotted path)
            if (l.dtype != "string" && l.dtype != "int") continue;
            if (l.label.find('@') != std::string::npos) continue;   // default-child mutation not supported
            auto dot = l.label.rfind('.');   // the PROPERTY PATH (not the read access) -> the setProp target
            std::string obj = (dot == std::string::npos) ? "o" : "o." + l.label.substr(0, dot);
            std::string prop = (dot == std::string::npos) ? l.label : l.label.substr(dot + 1);
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
