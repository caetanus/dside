// Authoritative .qmltypes validator: parse a .qmltypes with QQmlJSTypeDescriptionReader —
// the SAME reader qmllint/qmltyperegistrar use — and report parse errors + the discovered
// type shape. Exit 0 iff it parses cleanly and Backend has the expected members.
#include <QtQmlCompiler/private/qqmljstypedescriptionreader_p.h>
#include <QtQmlCompiler/private/qqmljsscope_p.h>
#include <QFile>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc < 2) { printf("usage: %s <file.qmltypes>\n", argv[0]); return 2; }
    QFile f(argv[1]);
    if (!f.open(QIODevice::ReadOnly)) { printf("cannot open %s\n", argv[1]); return 2; }
    QString data = QString::fromUtf8(f.readAll());

    QQmlJSTypeDescriptionReader reader(QString::fromUtf8(argv[1]), data);
    QList<QQmlJSExportedScope> objs;
    QStringList deps;
    bool ok = reader(&objs, &deps);
    if (!ok) { printf("PARSE ERROR: %s\n", qPrintable(reader.errorMessage())); return 1; }
    if (!reader.warningMessage().isEmpty())
        printf("warning: %s\n", qPrintable(reader.warningMessage()));

    bool found = false;
    for (const auto &es : objs) {
        auto scope = es.scope;
        if (!scope) continue;
        printf("type: %s  prototype: %s\n",
               qPrintable(scope->internalName()), qPrintable(scope->baseTypeName()));
        for (const auto &e : es.exports)
            printf("  export: %s %d.%d\n", qPrintable(e.type()),
                   e.version().majorVersion(), e.version().minorVersion());
        auto props = scope->ownProperties();
        for (auto it = props.begin(); it != props.end(); ++it)
            printf("  property: %s : %s\n", qPrintable(it.key()), qPrintable(it.value().typeName()));
        auto methods = scope->ownMethods();
        for (auto it = methods.begin(); it != methods.end(); ++it)
            printf("  method/signal: %s\n", qPrintable(it.key()));
        if (scope->internalName() == QLatin1String("Backend")) {
            bool hasProp = props.contains(QLatin1String("inValue"));
            bool hasSlot = methods.contains(QLatin1String("fromQml"));
            bool hasSig  = methods.contains(QLatin1String("inChanged"));
            found = hasProp && hasSlot && hasSig;
            if (!found) printf("Backend missing members (prop=%d slot=%d sig=%d)\n", hasProp, hasSlot, hasSig);
        }
    }
    printf(found ? "QMLTYPES OK\n" : "QMLTYPES FAIL (Backend shape wrong)\n");
    return found ? 0 : 3;
}
