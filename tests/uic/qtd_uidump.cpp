// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
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
#include <QLayout>
#include <QLayoutItem>
#include <QGridLayout>
#include <QBoxLayout>
#include <QFormLayout>
#include <QSpacerItem>
#include <QSize>
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

// ---- layout structure -------------------------------------------------------------------
// walk() alone compares only NAMED QObjects and their properties, which makes a whole class of
// .ui content invisible on BOTH sides: an unnamed layout is skipped entirely, a QSpacerItem is
// not a QObject so it never appears in children(), and per-item alignment / grid cell / stretch
// live on the QLayoutItem, not on any widget property. gridalignment.ui passed with its
// alignment silently dropped for exactly that reason.
//
// So the layout is serialized structurally, anchored on the OWNING WIDGET's name (which is
// always set) rather than on the layout's own name — that covers unnamed layouts too. Item
// order is the layout's own index order, zero-padded so the global sort keeps it stable.
static std::string idx2(int i) {
    return (i < 10 ? "0" : "") + std::to_string(i);
}

static std::string itemLabel(QLayoutItem *it, int i) {
    if (QWidget *w = it->widget()) {
        std::string n = u8(w->objectName());
        return std::string("w:") + w->metaObject()->className() + ":"
             + (n.empty() ? "#" + idx2(i) : n);
    }
    if (QSpacerItem *sp = it->spacerItem()) {
        // QSpacerItem has no sizePolicy() getter, so the policy is observed through the sizes it
        // derives from it: maximumSize is QLAYOUTSIZE_MAX on an axis whose policy can grow.
        QSize h = sp->sizeHint(), mn = sp->minimumSize(), mx = sp->maximumSize();
        return "spacer:" + std::to_string(h.width()) + "x" + std::to_string(h.height())
             + ":exp=" + std::to_string(int(sp->expandingDirections()))
             + ":min=" + std::to_string(mn.width()) + "x" + std::to_string(mn.height())
             + ":max=" + std::to_string(mx.width()) + "x" + std::to_string(mx.height());
    }
    if (QLayout *l = it->layout())
        return std::string("layout:") + l->metaObject()->className();
    return "?";
}

static void walkLayout(const std::string &anchor, QLayout *l, std::vector<std::string> &lines) {
    int lm, tm, rm, bm;
    l->getContentsMargins(&lm, &tm, &rm, &bm);
    lines.push_back(anchor + "|layout|" + l->metaObject()->className()
                    + "|margins=" + std::to_string(lm) + "," + std::to_string(tm) + ","
                    + std::to_string(rm) + "," + std::to_string(bm)
                    + "|spacing=" + std::to_string(l->spacing())
                    + "|count=" + std::to_string(l->count())
                    + "|pw=" + (l->parentWidget()
                        ? u8(l->parentWidget()->objectName()) + ":win="
                          + (l->parentWidget()->isWindow() ? "1" : "0")
                        : std::string("<none>")));
    auto *grid = qobject_cast<QGridLayout *>(l);
    auto *box  = qobject_cast<QBoxLayout *>(l);
    auto *form = qobject_cast<QFormLayout *>(l);
    for (int i = 0; i < l->count(); i++) {
        QLayoutItem *it = l->itemAt(i);
        if (!it) continue;
        std::string line = anchor + "|item" + idx2(i) + "|" + itemLabel(it, i)
                         + "|align=" + std::to_string(int(it->alignment()));
        if (grid) {
            int r, c, rs, cs;
            grid->getItemPosition(i, &r, &c, &rs, &cs);
            line += "|cell=" + std::to_string(r) + "," + std::to_string(c) + ","
                  + std::to_string(rs) + "," + std::to_string(cs);
        }
        if (box)  line += "|stretch=" + std::to_string(box->stretch(i));
        if (form) {
            int r; QFormLayout::ItemRole role;
            form->getItemPosition(i, &r, &role);
            line += "|row=" + std::to_string(r) + "|role=" + std::to_string(int(role));
        }
        lines.push_back(line);
        if (QLayout *sub = it->layout())
            walkLayout(anchor + ">" + idx2(i), sub, lines);
    }
    if (grid) {
        for (int r = 0; r < grid->rowCount(); r++)
            if (int s = grid->rowStretch(r))
                lines.push_back(anchor + "|rowStretch|" + idx2(r) + "=" + std::to_string(s));
        for (int c = 0; c < grid->columnCount(); c++)
            if (int s = grid->columnStretch(c))
                lines.push_back(anchor + "|colStretch|" + idx2(c) + "=" + std::to_string(s));
    }
}

static void walk(QObject *o, std::vector<std::string> &lines) {
    QString name = o->objectName();
    // keep only user-named objects; skip Qt's internal helpers (qt_*), unnamed layouts, etc.
    if (!name.isEmpty() && !name.startsWith("qt_")) {
        QObject *p = o->parent();
        std::string parent = p ? u8(p->objectName()) : std::string();
        lines.push_back(parent + "/" + o->metaObject()->className() + "/" + u8(name)
                        + "/" + textOf(o) + propsOf(o));
        if (auto *w = qobject_cast<QWidget *>(o))
            if (QLayout *l = w->layout()) walkLayout(u8(name), l, lines);
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
