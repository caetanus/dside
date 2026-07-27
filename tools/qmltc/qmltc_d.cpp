// qmltc-d — compile a .qml document into D (our analog of Qt's qmltc, which emits C++).
// Frontend = Qt's OWN QQmlJS parser (one unified QML+JS AST, dual-Qt, no new toolchain dep);
// backend emits a D @QObject class that uses the qtmoc runtime, so instantiating the generated
// type reproduces the QML object WITHOUT the QML engine interpreting the document at runtime.
//
// PHASE 1 (this brick): the root object's `property <type>: <literal>` members become
// `@Property <dtype> <name> = <literal>;`. Non-literal bindings, signal handlers, methods,
// child objects and ids are NOT yet handled — each is reported on stderr and skipped, and the
// file is flagged PARTIAL (exit 3) so nothing is silently dropped. Later phases add bindings
// (connect notify + re-eval), a JS-expr->D subset, signal handlers, ids/aliases/children.
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

using namespace QQmlJS;
using namespace QQmlJS::AST;

static std::string qs(const QString &s) { return s.toStdString(); }

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
    std::string body;         // @Property field declarations
    std::string ctorBody;     // binding assignments, evaluated in declaration order in this()
    std::vector<std::string> propNames;   // for the --dump checker (sorted before emit)
    for (auto *m = root->initializer ? root->initializer->members : nullptr; m; m = m->next) {
        auto *mem = m->member;
        auto *pub = cast<UiPublicMember *>(mem);
        if (pub && pub->type == UiPublicMember::Property) {
            QString qmlType = pub->memberType ? pub->memberType->name.toString() : QString("var");
            const char *dt = dtypeOf(qmlType);
            std::string name = qs(pub->name.toString());
            std::string expr;
            if (dt[0] && pub->statement && literalOf(pub->statement, qmlType, expr)) {
                // Pure literal -> D field initializer (Phase 1).
                body += "    @Property " + std::string(dt) + " " + name + " = " + expr + ";\n";
                propNames.push_back(name);
            } else if (dt[0] && pub->statement && cast<ExpressionStatement *>(pub->statement)
                       && compileExpr(cast<ExpressionStatement *>(pub->statement)->expression, qmlType, expr)) {
                // Binding over prop refs/operators -> a field + a ctor assignment evaluated in order
                // (Phase 2). NOTE: this computes the binding's INITIAL value; live re-evaluation on a
                // dependency change (connect NOTIFY -> recompute) is the tracked next step.
                body += "    @Property " + std::string(dt) + " " + name + ";\n";
                ctorBody += "        " + name + " = " + expr + ";\n";
                propNames.push_back(name);
            } else {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' (%s) is an unsupported binding/type — not yet emitted (phase>2)\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType));
                ++partial;
            }
            continue;
        }
        // Everything else (signals, methods, object/script bindings, child objects) is a later phase.
        std::fprintf(stderr, "qmltc-d: %s: a non-property member is not yet handled (phase>2)\n", inPath);
        ++partial;
    }

    // Emit the D module. The generated type is a qtmoc @QObject; construct it with newQObject!T.
    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    std::printf("import qtmoc;\n\n");
    std::printf("@QObject class %s {\n%s", qPrintable(cls), body.c_str());
    if (!ctorBody.empty())   // field initializers run first, so bindings can read literal props.
        std::printf("    this() {\n%s    }\n", ctorBody.c_str());
    std::printf("}\n");

    if (dump) {
        // A checker main: instantiate and print each scalar property as `name\tvalue`, SORTED by
        // name (stable diff). The C++ oracle prints the same lines for the same document; equal
        // output proves the generated D reproduces the QML values (Phase 1 differential).
        std::sort(propNames.begin(), propNames.end());
        std::printf("\nvoid main() {\n    import std.stdio : writefln;\n");
        std::printf("    auto o = newQObject!%s();\n", qPrintable(cls));
        for (const auto &n : propNames)
            std::printf("    writefln(\"%s\\t%%s\", o.%s);\n", n.c_str(), n.c_str());
        std::printf("}\n");
    }
    return partial ? 3 : 0;
}
