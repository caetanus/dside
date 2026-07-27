// qtd_qmlparse — the first brick of qmltc-d. Proves QQmlJS::Parser (Qt's OWN QML/JS parser,
// the exact grammar QML uses) hands us ONE unified AST for a whole .qml: the object tree
// (UiObjectDefinition / UiPublicMember / UiScriptBinding) AND the JS binding expressions as a
// sub-AST. Here we just walk it and dump structure + binding source — the analog of
// tests/uic/qtd_uidump.cpp (which shells to QUiLoader). No Node, no PEG: one frontend.
#include <QtQml/private/qqmljsengine_p.h>
#include <QtQml/private/qqmljslexer_p.h>
#include <QtQml/private/qqmljsparser_p.h>
#include <QtQml/private/qqmljsast_p.h>
#include <QtQml/private/qqmljsastvisitor_p.h>
#include <QFile>
#include <cstdio>

using namespace QQmlJS;
using namespace QQmlJS::AST;

static QString qname(UiQualifiedId *id) {
    QString s;
    for (auto *p = id; p; p = p->next) { if (!s.isEmpty()) s += '.'; s += p->name.toString(); }
    return s;
}

struct Dumper : Visitor {
    QString src;
    int depth = 0;
    void ind() { for (int i = 0; i < depth; ++i) printf("  "); }
    // source text of a node span (offset..end) — this is how we recover a binding expression.
    QString span(SourceLocation a, SourceLocation b) {
        if (!a.isValid()) return QString();
        quint32 end = b.isValid() ? b.offset + b.length : a.offset + a.length;
        return src.mid(a.offset, end - a.offset);
    }
    void throwRecursionDepthError() override { fprintf(stderr, "recursion too deep\n"); }

    bool visit(UiObjectDefinition *n) override {
        ind(); printf("Object %s {\n", qPrintable(qname(n->qualifiedTypeNameId))); ++depth; return true;
    }
    void endVisit(UiObjectDefinition *) override { --depth; ind(); printf("}\n"); }

    bool visit(UiPublicMember *n) override {
        ind();
        const char *kind = (n->type == UiPublicMember::Signal) ? "signal" : "property";
        printf("%s %s %s", kind, qPrintable(n->memberType ? qname(n->memberType) : QString("var")),
               qPrintable(n->name.toString()));
        if (n->statement)
            printf("  := %s", qPrintable(span(n->statement->firstSourceLocation(),
                                              n->statement->lastSourceLocation())));
        printf("\n");
        return true;
    }
    bool visit(UiScriptBinding *n) override {
        ind();
        printf("bind %s := %s\n", qPrintable(qname(n->qualifiedId)),
               qPrintable(span(n->statement->firstSourceLocation(), n->statement->lastSourceLocation())));
        return true;
    }
    bool visit(UiObjectBinding *n) override {
        ind(); printf("bind %s : Object %s {\n", qPrintable(qname(n->qualifiedId)),
                      qPrintable(qname(n->qualifiedTypeNameId))); ++depth; return true;
    }
    void endVisit(UiObjectBinding *) override { --depth; ind(); printf("}\n"); }
};

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <file.qml>\n", argv[0]); return 2; }
    QFile f(argv[1]);
    if (!f.open(QIODevice::ReadOnly)) { printf("cannot open %s\n", argv[1]); return 2; }
    QString code = QString::fromUtf8(f.readAll());

    Engine engine;
    Lexer lexer(&engine);
    lexer.setCode(code, 1, /*qmlMode*/ true);
    Parser parser(&engine);
    if (!parser.parse()) {
        for (const auto &e : parser.diagnosticMessages())
            fprintf(stderr, "%s:%d:%d: %s\n", argv[1], e.loc.startLine, e.loc.startColumn, qPrintable(e.message));
        return 1;
    }
    Dumper d; d.src = code;
    Node::accept(parser.ast(), &d);
    printf("QMLPARSE OK\n");
    return 0;
}
