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
#include <string>
#include <vector>

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

    // Optional `name=value` mutations (argv[2..]): write via setProperty so the engine's own
    // bindings re-evaluate, matching what the generated D does through the meta-object. The value
    // is passed as a string QVariant; Qt coerces it to the property's declared type.
    for (int i = 2; i < argc; ++i) {
        QString a = QString::fromUtf8(argv[i]);
        int eq = a.indexOf('=');
        if (eq < 0) continue;
        obj->setProperty(a.left(eq).toUtf8().constData(), QVariant(a.mid(eq + 1)));
    }

    // QML-declared properties live at [propertyOffset, propertyCount) — i.e. above everything the
    // C++ base (QObject/QtObject) contributes. That's exactly the set qmltc-d emits.
    const QMetaObject *mo = obj->metaObject();
    std::vector<std::string> lines;
    for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i) {
        QMetaProperty p = mo->property(i);
        lines.push_back(std::string(p.name()) + "\t" + fmt(p.read(obj)));
    }
    std::sort(lines.begin(), lines.end());
    for (const auto &l : lines) std::printf("%s\n", l.c_str());
    return 0;
}
