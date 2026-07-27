// qmltc-d differential ORACLE (analog of tests/uic/qtd_uidump.cpp for uic). Loads a .qml with the
// REAL QML engine (QQmlComponent), instantiates the root object, and prints each QML-declared
// scalar property as `name\tvalue`, SORTED by name. qmltc-d --dump prints the same lines from the
// generated D; equal output proves the compiled-to-D object reproduces what the engine produces.
// Formatting is chosen to match D's writefln("%s", v): int as-is, bool true/false, double via a
// minimal round-trippable form, string raw.
#include <QGuiApplication>
#include <QQmlEngine>
#include <QQmlComponent>
#include <QMetaProperty>
#include <QVariant>
#include <QByteArray>
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

// Recurse the object tree: dump each QML-declared scalar property as `<prefix>name\tvalue`, and
// descend into QObject* properties (a child object) with a dotted prefix — matching qmltc-d's
// generated dump, which reads o.kid.y directly.
static void dumpObj(QObject *obj, const std::string &prefix, std::vector<std::string> &lines);

static std::string fmt(const QVariant &v) {
    switch (v.typeId()) {
    case QMetaType::Bool:   return v.toBool() ? "true" : "false";
    case QMetaType::Int:
    case QMetaType::LongLong: return std::to_string(v.toLongLong());
    case QMetaType::Double:
    case QMetaType::Float: {
        // Match D's default `%s` float text (shortest round-trip). %g is close for the corpus'
        // simple values; QString::number(d) gives the same shortest form D uses here.
        return QString::number(v.toDouble()).toStdString();
    }
    default: return v.toString().toStdString();
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <file.qml>\n", argv[0]); return 2; }
    QGuiApplication app(argc, argv);
    QQmlEngine engine;
    QQmlComponent comp(&engine, QUrl::fromLocalFile(argv[1]));
    if (comp.isError()) {
        for (const auto &e : comp.errors()) std::fprintf(stderr, "%s\n", qPrintable(e.toString()));
        return 1;
    }
    QObject *obj = comp.create();
    if (!obj) { std::fprintf(stderr, "qmlvalues: create() failed for %s\n", argv[1]); return 1; }

    // Args after the .qml: `name=value` mutations, and an optional `--props <file>` listing the
    // exact property PATHS to dump (one per line). With --props we read those (incl. base C++
    // Q_PROPERTYs the QML file set, which auto-discovery misses); without it we auto-discover the
    // QML-declared properties.
    std::string propsFile;
    std::vector<QString> muts;
    for (int i = 2; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--props" && i + 1 < argc) { propsFile = argv[++i]; continue; }
        muts.push_back(QString::fromUtf8(argv[i]));
    }
    // Walk a dotted path to the object holding the leaf property; returns null if a hop is missing.
    auto walk = [](QObject *root, const QStringList &parts) -> QObject * {
        QObject *cur = root;
        for (int j = 0; j < parts.size() - 1 && cur; ++j) cur = cur->property(parts[j].toUtf8().constData()).value<QObject *>();
        return cur;
    };
    for (auto &a : muts) {
        int eq = a.indexOf('=');
        if (eq < 0) continue;
        QStringList parts = a.left(eq).split('.');
        if (QObject *cur = walk(obj, parts)) cur->setProperty(parts.last().toUtf8().constData(), QVariant(a.mid(eq + 1)));
    }

    std::vector<std::string> lines;
    if (!propsFile.empty()) {
        std::ifstream f(propsFile);
        std::string label;
        while (std::getline(f, label)) {
            if (label.empty()) continue;
            QStringList parts = QString::fromStdString(label).split('.');
            if (QObject *cur = walk(obj, parts))
                lines.push_back(label + "\t" + fmt(cur->property(parts.last().toUtf8().constData())));
        }
    } else {
        dumpObj(obj, "", lines);
    }
    std::sort(lines.begin(), lines.end());
    for (const auto &l : lines) std::printf("%s\n", l.c_str());
    return 0;
}

void dumpObj(QObject *obj, const std::string &prefix, std::vector<std::string> &lines) {
    // QML-declared properties live at [propertyOffset, propertyCount) — above everything the C++
    // base (QObject/QtObject) contributes. That's exactly the set qmltc-d emits.
    const QMetaObject *mo = obj->metaObject();
    for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
        QMetaProperty p = mo->property(i);
        QVariant v = p.read(obj);
        if (v.metaType().flags() & QMetaType::PointerToQObject) {
            if (auto *child = v.value<QObject *>()) dumpObj(child, prefix + p.name() + ".", lines);
        } else {
            lines.push_back(prefix + std::string(p.name()) + "\t" + fmt(v));
        }
    }
}
