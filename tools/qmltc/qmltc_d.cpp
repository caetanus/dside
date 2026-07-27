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

// If `st` is a literal initializer (number / string / true / false), render it as a D literal
// into `out` and return true. Otherwise (an identifier ref, an arithmetic expr, a call, ...) it
// is a binding for a later phase: return false and leave `out` untouched.
static bool literalOf(Statement *st, const QString &dtype, std::string &out) {
    auto *es = cast<ExpressionStatement *>(st);
    if (!es || !es->expression) return false;
    ExpressionNode *e = es->expression;

    // `-5` / `-3.5` parse as a UnaryMinus over a NumericLiteral.
    bool neg = false;
    if (auto *u = cast<UnaryMinusExpression *>(e)) { neg = true; e = u->expression; }

    if (auto *num = cast<NumericLiteral *>(e)) {
        char buf[64];
        if (dtype == "int") std::snprintf(buf, sizeof buf, "%s%lld", neg ? "-" : "", (long long)num->value);
        else                std::snprintf(buf, sizeof buf, "%s%g",   neg ? "-" : "", num->value);
        out = buf; return true;
    }
    if (neg) return false;   // -"str" / -true are not literals we emit
    if (auto *str = cast<StringLiteral *>(e)) {
        // D and QML string escaping differ in general; Phase 1 emits a plain double-quoted D
        // string and escapes the few characters that would break it.
        std::string s = "\"";
        for (QChar c : str->value.toString()) {
            if (c == '"' || c == '\\') s += '\\';
            if (c == '\n') { s += "\\n"; continue; }
            s += qs(QString(c));
        }
        s += "\""; out = s; return true;
    }
    if (cast<TrueLiteral *>(e))  { out = "true";  return true; }
    if (cast<FalseLiteral *>(e)) { out = "false"; return true; }
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
    std::string body;
    std::vector<std::string> propNames;   // for the --dump checker (sorted before emit)
    for (auto *m = root->initializer ? root->initializer->members : nullptr; m; m = m->next) {
        auto *mem = m->member;
        auto *pub = cast<UiPublicMember *>(mem);
        if (pub && pub->type == UiPublicMember::Property) {
            QString qmlType = pub->memberType ? pub->memberType->name.toString() : QString("var");
            const char *dt = dtypeOf(qmlType);
            std::string lit;
            if (dt[0] && pub->statement && literalOf(pub->statement, qmlType, lit)) {
                body += "    @Property " + std::string(dt) + " " + qs(pub->name.toString()) + " = " + lit + ";\n";
                propNames.push_back(qs(pub->name.toString()));
            } else {
                std::fprintf(stderr, "qmltc-d: %s: property '%s' (%s) is a binding/unsupported type — not yet emitted (phase>1)\n",
                             inPath, qPrintable(pub->name.toString()), qPrintable(qmlType));
                ++partial;
            }
            continue;
        }
        // Everything else (signals, methods, object/script bindings, child objects) is a later phase.
        std::fprintf(stderr, "qmltc-d: %s: a non-property member is not yet handled (phase>1)\n", inPath);
        ++partial;
    }

    // Emit the D module. The generated type is a qtmoc @QObject; construct it with newQObject!T.
    std::printf("// GENERATED by qmltc-d from %s — do not edit.\n", inPath);
    std::printf("module %s;\n", qPrintable(cls));
    std::printf("import qtmoc;\n\n");
    std::printf("@QObject class %s {\n%s}\n", qPrintable(cls), body.c_str());

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
