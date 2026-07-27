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
    // A single assignment `prop = <expr>`. Brace blocks of several statements are a later step.
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

int main(int argc, char **argv) {
    // --dump: also emit a `main` that instantiates the type and prints each scalar property as
    // `name\tvalue` (sorted), so the generated D can be diffed against the QQmlComponent oracle
    // over the same document (the corpus-check-style differential for qmltc-d).
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
    // Class/module name defaults to the file base name (QML's own convention: File.qml -> File).
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

    int partial = 0;   // count of things we saw but can't emit yet -> exit 3 (PARTIAL), never silent.
    std::vector<Prop> props;
    std::vector<std::pair<std::string, Statement *>> rawHandlers;   // (signal name, handler body)
    for (auto *m = root->initializer ? root->initializer->members : nullptr; m; m = m->next) {
        auto *pub = cast<UiPublicMember *>(m->member);
        // A property-change handler `on<Prop>Changed: <stmt>` is a UiScriptBinding whose id begins
        // with `on` + an uppercase letter. Signal = lowercase-first of the rest (onCountChanged ->
        // countChanged). Collect it; compile after the property types are known.
        if (auto *sb = cast<UiScriptBinding *>(m->member)) {
            std::string hid = qname(sb->qualifiedId);
            if (hid.size() > 2 && hid[0] == 'o' && hid[1] == 'n' && std::isupper((unsigned char)hid[2])) {
                std::string sig = hid.substr(2);
                sig[0] = (char)std::tolower((unsigned char)sig[0]);
                rawHandlers.push_back({sig, sb->statement});
                continue;
            }
        }
        if (pub && pub->type == UiPublicMember::Property) {
            QString qmlType = pub->memberType ? pub->memberType->name.toString() : QString("var");
            const char *dt = dtypeOf(qmlType);
            std::string name = qs(pub->name.toString());
            std::string expr;
            auto *es = pub->statement ? cast<ExpressionStatement *>(pub->statement) : nullptr;
            if (dt[0] && pub->statement && literalOf(pub->statement, qmlType, expr)) {
                props.push_back({name, dt, expr, /*bound*/false, {}});
            } else if (dt[0] && es && compileExpr(es->expression, qmlType, expr)) {
                std::vector<std::string> ids;
                collectIds(es->expression, ids);
                props.push_back({name, dt, expr, /*bound*/true, ids});
            } else {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' (%s) is an unsupported binding/type — not yet emitted (phase>3)\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType));
                ++partial;
            }
            continue;
        }
        std::fprintf(stderr, "qmltc-d: %s: a non-property member is not yet handled (phase>3)\n", inPath);
        ++partial;
    }

    // A property needs a NOTIFY signal iff it is bound (to notify its own dependents) OR it is a
    // dependency of some binding (so that binding can connect and re-evaluate on its change). Props
    // that are neither stay a plain @Property — literal-only classes are byte-identical to Phase 1.
    std::vector<std::string> propNames;
    std::vector<std::string> needsNotify;
    for (auto &p : props) propNames.push_back(p.name);
    auto isProp = [&](const std::string &n){ return std::find(propNames.begin(), propNames.end(), n) != propNames.end(); };

    // Signal handlers: compile each body (property types now known) and require the source
    // property's change signal, connected in __qmltcWire. Only `on<Prop>Changed` over a known
    // property is handled; anything else is reported and skipped.
    std::map<std::string, std::string> ptype;
    for (auto &p : props) ptype[p.name] = p.dtype;
    std::string handlerSlots, handlerWire;
    for (auto &h : rawHandlers) {
        std::string notifyProp, hbody;
        if (h.first.size() > 7 && h.first.compare(h.first.size() - 7, 7, "Changed") == 0)
            notifyProp = h.first.substr(0, h.first.size() - 7);
        if (notifyProp.empty() || !isProp(notifyProp) || !compileStmt(h.second, ptype, hbody)) {
            std::fprintf(stderr, "qmltc-d: %s: signal handler 'on%c%s' not yet supported — skipped (phase>4)\n",
                         inPath, std::toupper((unsigned char)h.first[0]), h.first.c_str() + 1);
            ++partial; continue;
        }
        if (std::find(needsNotify.begin(), needsNotify.end(), notifyProp) == needsNotify.end())
            needsNotify.push_back(notifyProp);
        handlerSlots += "    @Slot void __h_" + h.first + "() {\n" + hbody + "    }\n";
        handlerWire += "        connectMeta(this, \"" + h.first + "()\", this, \"__h_" + h.first + "()\");\n";
    }

    for (auto &p : props) {
        if (p.bound && std::find(needsNotify.begin(), needsNotify.end(), p.name) == needsNotify.end())
            needsNotify.push_back(p.name);
        for (auto &d : p.deps)
            if (isProp(d) && std::find(needsNotify.begin(), needsNotify.end(), d) == needsNotify.end())
                needsNotify.push_back(d);
    }
    auto notified = [&](const std::string &n){ return std::find(needsNotify.begin(), needsNotify.end(), n) != needsNotify.end(); };

    // Emit the D module. The generated type is a qtmoc @QObject; construct it with newQObject!T.
    std::string body, recompute, wire;
    bool anyBound = false;
    for (auto &p : props) {
        std::string notifyUda = notified(p.name) ? "@Property(\"" + p.name + "Changed\") " : "@Property ";
        if (p.bound) {
            body += "    " + notifyUda + p.dtype + " " + p.name + ";\n";
            if (notified(p.name)) body += "    Signal!() " + p.name + "Changed;\n";
            // recompute slot: re-evaluate, and if the value changed, store it and notify dependents.
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
    if (anyBound || !handlerWire.empty()) {
        // Compute binding initials in declaration order, then wire each binding to its
        // dependencies' change signals so a later write re-evaluates it (a live QML binding), and
        // connect each signal handler to its source property's change signal.
        wire = "    void __qmltcWire() {\n";
        for (auto &p : props) if (p.bound) wire += "        __rc_" + p.name + "();\n";
        for (auto &p : props) if (p.bound)
            for (auto &d : p.deps) if (isProp(d))
                wire += "        connectMeta(this, \"" + d + "Changed()\", this, \"__rc_" + p.name + "()\");\n";
        wire += handlerWire;
        wire += "    }\n";
    }

    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    std::printf("import qtmoc;\n\n");
    std::printf("@QObject class %s {\n%s%s%s%s}\n", qPrintable(cls),
                body.c_str(), recompute.c_str(), handlerSlots.c_str(), wire.c_str());

    if (dump) {
        // A checker main: optionally apply `name=value` mutations (via the meta-object, so a write
        // fires the NOTIFY and any live binding re-evaluates), then print each property as
        // `name\tvalue`, SORTED by name (stable diff). The C++ oracle does the same over the same
        // document; equal output proves the generated D matches the engine — statically (no args)
        // AND dynamically (with a mutation, exercising live bindings).
        std::vector<Prop> sorted = props;
        std::sort(sorted.begin(), sorted.end(), [](const Prop &a, const Prop &b){ return a.name < b.name; });
        std::printf("\nvoid main(string[] args) {\n");
        std::printf("    import std.stdio : writefln; import std.conv : to; import std.string : indexOf;\n");
        std::printf("    auto o = newQObject!%s();\n", qPrintable(cls));
        std::printf("    foreach (a; args[1 .. $]) {\n");
        std::printf("        auto i = a.indexOf('='); if (i < 0) continue;\n");
        std::printf("        auto k = a[0 .. i]; auto v = a[i + 1 .. $];\n");
        for (auto &p : sorted) {   // meta writes only for the types qtmoc has setters for
            if (p.dtype == "string")
                std::printf("        if (k == \"%s\") setProp(o, \"%s\", v);\n", p.name.c_str(), p.name.c_str());
            else if (p.dtype == "int")
                std::printf("        if (k == \"%s\") setProp(o, \"%s\", v.to!int);\n", p.name.c_str(), p.name.c_str());
        }
        std::printf("    }\n");
        for (auto &p : sorted)
            std::printf("    writefln(\"%s\\t%%s\", o.%s);\n", p.name.c_str(), p.name.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
