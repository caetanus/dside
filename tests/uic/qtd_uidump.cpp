// qtd_uidump.cpp — test-only oracle harness for the CTFE uic.
//
// Two entry points, both returning a canonical serialization of a widget tree so the D
// side can diff our uic against Qt's own uic without needing children()/findChild bound:
//   qtd_ui_dump(root)          — dump a tree WE built (uiForm + setupUi)
//   qtd_ui_load_and_dump(path) — QUiLoader.load(path) then dump (the ORACLE)
//
// A dump line is  <parentName>/<className>/<objectName>/<text>  for every NAMED, non-Qt-
// internal descendant; lines are sorted so sibling order doesn't matter. Identical trees
// (same widgets, classes, parents, visible text) -> identical dumps.
#include <QObject>
#include <QWidget>
#include <QMetaObject>
#include <QString>
#include <QVariant>
#include <QIcon>
#include <QFont>
#include <QSizePolicy>
#include <QPalette>
#include <QColor>
#include <QLabel>
#include <QFile>
#include <QUiLoader>
#include <QList>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
#include <typeinfo>

static std::string u8(const QString &q) { return std::string(q.toUtf8().constData()); }

// Exercises the Lippincott path the generator emits: a C++ exception in a trampoline is
// classified and re-raised as a D QtCppException via qtd_throw_d, unwinding back to D.
extern "C" void qtd_throw_d(const char *type, const char *msg);
extern "C" void qtd_test_throw() {
    try { throw std::out_of_range("synthetic C++ exception"); }
    catch (const std::exception &e) { qtd_throw_d(typeid(e).name(), e.what()); }
}

// A widget's visible text: the first of text / title / windowTitle that is set.
static std::string textOf(QObject *o) {
    for (const char *p : {"text", "title", "windowTitle"}) {
        QVariant v = o->property(p);
        if (v.isValid() && !v.toString().isEmpty()) return u8(v.toString());
    }
    return std::string();
}

// Render-affecting, .ui-settable properties (NOT geometry/size — those are layout-managed
// and 0 before show). A widget only carries the ones its class declares; defaults are the
// same in both trees so they never cause a false mismatch — only a prop one side sets and
// the other skips shows up. Sorted for a canonical line.
static std::string propsOf(QObject *o) {
    static const char *keys[] = {
        "alignment", "wordWrap", "enabled", "checkable", "checked", "readOnly", "flat",
        "orientation", "echoMode", "frameShape", "frameShadow", "lineWidth", "maximum",
        "minimum", "singleStep", "pageStep", "value", "decimals", "currentIndex", "maxLength",
        "placeholderText", "autoDefault", "default", "spacing", "toolTip",
        "shortcut", "sizePolicy", "iconSize", "movable", "floatable", "scaledContents",
    };
    std::vector<std::string> kv;
    for (const char *k : keys) {
        QVariant v = o->property(k);
        if (v.isValid()) kv.push_back(std::string(k) + "=" + u8(v.toString()));
    }
    // QIcon has no toString -> compare whether it is set (catches the icon gap).
    for (const char *ik : {"icon", "windowIcon"}) {
        QVariant v = o->property(ik);
        if (v.isValid() && v.canConvert<QIcon>())
            kv.push_back(std::string(ik) + "Null=" + (v.value<QIcon>().isNull() ? "1" : "0"));
    }
    // QFont has no toString -> dump render-affecting sub-fields (catches the font gap).
    // Defaults match on both trees; only a font one side sets shows up.
    {
        QVariant v = o->property("font");
        if (v.isValid() && v.canConvert<QFont>()) {
            QFont f = v.value<QFont>();
            kv.push_back("font.family=" + u8(f.family()));
            kv.push_back("font.pointSize=" + std::to_string(f.pointSize()));
            kv.push_back("font.weight=" + std::to_string(int(f.weight())));
            kv.push_back(std::string("font.italic=") + (f.italic() ? "1" : "0"));
            kv.push_back(std::string("font.underline=") + (f.underline() ? "1" : "0"));
            kv.push_back(std::string("font.strikeOut=") + (f.strikeOut() ? "1" : "0"));
        }
    }
    // QSizePolicy has no toString -> dump policies + stretches (catches the sizePolicy gap).
    {
        QVariant v = o->property("sizePolicy");
        if (v.isValid() && v.canConvert<QSizePolicy>()) {
            QSizePolicy sp = v.value<QSizePolicy>();
            kv.push_back("sp.h=" + std::to_string(int(sp.horizontalPolicy())));
            kv.push_back("sp.v=" + std::to_string(int(sp.verticalPolicy())));
            kv.push_back("sp.hs=" + std::to_string(sp.horizontalStretch()));
            kv.push_back("sp.vs=" + std::to_string(sp.verticalStretch()));
        }
    }
    // QLabel::buddy is a QWidget* (property toString is empty) -> dump the buddy's objectName.
    if (auto lbl = qobject_cast<QLabel *>(o))
        if (QWidget *bud = lbl->buddy())
            kv.push_back("buddy=" + u8(bud->objectName()));
    // QPalette: dump ONLY the (group, role) brushes explicitly set (isBrushSet) with their
    // ARGB — both trees start from the same default palette, so the set-brush set is exactly
    // what each side applied. A role our uic misses (or over-sets) shows up as a diff.
    {
        QVariant v = o->property("palette");
        if (v.isValid() && v.canConvert<QPalette>()) {
            QPalette p = v.value<QPalette>();
            const QPalette::ColorGroup groups[] = {QPalette::Active, QPalette::Inactive, QPalette::Disabled};
            for (QPalette::ColorGroup gr : groups)
                for (int r = 0; r < QPalette::NColorRoles; r++) {
                    QPalette::ColorRole role = QPalette::ColorRole(r);
                    if (p.isBrushSet(gr, role))
                        kv.push_back("pal." + std::to_string(int(gr)) + "." + std::to_string(r)
                                     + "=" + u8(p.color(gr, role).name(QColor::HexArgb)));
                }
        }
    }
    std::sort(kv.begin(), kv.end());
    std::string out;
    for (auto &s : kv) { out += ";"; out += s; }
    return out;
}

static void walk(QObject *o, std::vector<std::string> &lines) {
    QString name = o->objectName();
    // keep only user-named objects; skip Qt's internal helpers (qt_*), unnamed layouts, etc.
    if (!name.isEmpty() && !name.startsWith("qt_")) {
        QObject *p = o->parent();
        std::string parent = p ? u8(p->objectName()) : std::string();
        lines.push_back(parent + "/" + o->metaObject()->className() + "/" + u8(name)
                        + "/" + textOf(o) + propsOf(o));
    }
    const QObjectList &kids = o->children();
    for (QObject *k : kids) walk(k, lines);
}

static const char *dump(QObject *root) {
    std::vector<std::string> lines;
    walk(root, lines);
    std::sort(lines.begin(), lines.end());
    static thread_local std::string out;     // caller must copy before the next call
    out.clear();
    for (auto &l : lines) { out += l; out += '\n'; }
    return out.c_str();
}

extern "C" const char *qtd_ui_dump(void *root) {
    return dump(reinterpret_cast<QObject *>(root));
}

extern "C" const char *qtd_ui_load_and_dump(const char *path) {
    QFile f(QString::fromUtf8(path));
    if (!f.open(QIODevice::ReadOnly)) return "";
    QUiLoader loader;
    QWidget *w = loader.load(&f, nullptr);
    f.close();
    return w ? dump(w) : "";
}
