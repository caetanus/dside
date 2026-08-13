// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Render a QQuickItem WE built ourselves — no QQmlEngine, no component — and write the frame.
//
// This exists because the differential's bar is not "the property values match": it is "renders
// and behaves like the interpreted version". Until this helper, nothing in the suite drew a single
// pixel, so a file could agree on every property and still paint differently.
//
// The window is sized the way QQuickView::SizeViewToRootObject sizes it — from the item, clamped
// to at least 1 — because a different fallback made every size-less root differ from the engine by
// window geometry alone, which reads as 20 render defects that are not there.
#include <QQuickWindow>
#include <QQuickView>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QImage>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QCoreApplication>
#include <QElapsedTimer>

// A reinterpret_cast to QQuickItem is a promise the CALLER cannot always keep: a QQuickPopup (and
// every Drawer, Menu, Dialog, ToolTip built on it) is a QObject, not an Item, and Qt walked the
// resulting garbage into a SIGSEGV inside QQuickItem::mapFromScene. Checked through the meta-object
// instead, and refused with a code the caller prints — a document that has no item to render is a
// fact about the document, not a crash.
static QQuickItem *qtd_as_item(void *o) {
    return qobject_cast<QQuickItem *>(reinterpret_cast<QObject *>(o));
}

// A DOCUMENT rendered the way Qt renders a document. At -O0 we are not running compiled code at
// all — the engine builds the .qml — so the frame must be taken the way the engine's own viewer
// takes it, or the comparison measures our start-up instead of the document.
//
// The difference is real and it is not cosmetic: QQuickView parents the root into the scene BEFORE
// completeCreate, while QQmlComponent::create() finishes the object with no window in sight. Qt's
// Imagine GroupBox comes out 1x19 the second way and 40x59 the first, because its implicit size
// comes from a label that has to be laid out in a scene.
static int qtd_render_popup(QObject *o, const char *out);   // defined below; both paths need it

extern "C" int qtd_render_document(const char *url, const char *out) {
    if (!url || !out) return 1;
    // A POPUP first, for the same reason the oracle checks it first: QQuickView refuses a root that
    // is not an Item, and Qt's Popup, Menu and Dialog are exactly that. Adding the popup branch to
    // the item path and not to this one made the -O0 form report `render failed rc=3` on the three
    // Material documents the popup work had just brought under measurement — a gap in MY symmetry,
    // not in theirs.
    {
        QQmlEngine peng;
        QQmlComponent pc(&peng, QUrl(QString::fromUtf8(url)));
        if (!pc.isError()) {
            QObject *proot = pc.create();
            if (proot && !qobject_cast<QQuickItem *>(proot)
                    && proot->metaObject()->indexOfMethod("open()") >= 0
                    && proot->metaObject()->indexOfProperty("contentItem") >= 0)
                return qtd_render_popup(proot, out);
            delete proot;
        }
    }
    QQuickView v;
    v.setResizeMode(QQuickView::SizeViewToRootObject);
    v.setSource(QUrl(QString::fromUtf8(url)));
    if (v.status() != QQuickView::Ready) return 3;
    v.show();
    const QImage img = v.grabWindow();
    if (img.isNull()) return 2;
    return img.save(QString::fromUtf8(out)) ? 0 : 3;
}

// A POPUP: not an Item, so it cannot be parented into a window — but it HAS a frame once it is
// opened inside one. Same detection as the oracle's, through the meta-object rather than by naming
// a type: not an Item, has `open()`, has a `contentItem`. Both halves must build the scene the same
// way or the comparison measures the harness.
static int qtd_render_popup(QObject *o, const char *out) {
    static QQuickWindow *win = nullptr;
    if (!win) { win = new QQuickWindow(); win->setWidth(400); win->setHeight(400); win->show(); }
    o->setProperty("parent", QVariant::fromValue(win->contentItem()));
    QMetaObject::invokeMethod(o, "open");
    QCoreApplication::processEvents();
    const QImage img = win->grabWindow();
    if (img.isNull()) return 2;
    return img.save(QString::fromUtf8(out)) ? 0 : 3;
}

extern "C" int qtd_render_item(void *item, const char *out) {
    if (!item) return 1;
    auto *o = reinterpret_cast<QObject *>(item);
    auto *it = qtd_as_item(item);
    if (!it && o->metaObject()->indexOfMethod("open()") >= 0
            && o->metaObject()->indexOfProperty("contentItem") >= 0)
        return qtd_render_popup(o, out);
    if (!it) return 4;   // not an Item and not a popup: there is genuinely nothing to draw
    // SizeViewToRootObject sizes the root from its IMPLICIT size when it has no explicit one, and
    // then sets the item to that size. A Control's whole geometry comes from there — reading
    // width() alone gave 1x1 for a Pane the engine draws at 24x24, which reads as a render defect
    // and is not one.
    // ...and the IMPLICIT size is read AFTER the item is in a scene, not before. QQuickView sets
    // the source and the item is created inside the view; we create it first and put it in a window
    // second, and for an item whose implicit size comes from a child that has to be laid out the
    // two orders disagree. Measured on Qt's Imagine GroupBox: 1x19 read before, against the
    // engine's 40x59. Sizing below happens once the item has a window (see both branches).
    // An item ALREADY in a scene is grabbed from THAT scene. Moving it into a fresh window drops
    // everything the scene holds — activeFocus above all, which is per-window: `--click` put the
    // item in a window and gave it focus, and `--render` then reparented it away, so the frame
    // showed an unfocused control while the object itself reported activeFocus true. Qt's
    // TextField paints its border with the accent colour when focused, and the click differential
    // was measuring the harness rather than the compiler.
    auto sizeFromImplicit = [](QQuickItem *x) {
        if (x->width() <= 0 && x->implicitWidth() > 0) x->setWidth(x->implicitWidth());
        if (x->height() <= 0 && x->implicitHeight() > 0) x->setHeight(x->implicitHeight());
    };
    if (QQuickWindow *cur = it->window()) {
        sizeFromImplicit(it);
        cur->setWidth(qMax(1, int(it->width())));
        cur->setHeight(qMax(1, int(it->height())));
        const QImage img0 = cur->grabWindow();
        if (img0.isNull()) return 2;
        return img0.save(QString::fromUtf8(out)) ? 0 : 3;
    }
    QQuickWindow win;
    it->setParentItem(win.contentItem());   // in the scene FIRST, so the implicit size is the real one
    win.show();
    sizeFromImplicit(it);
    win.setWidth(qMax(1, int(it->width())));
    win.setHeight(qMax(1, int(it->height())));
    const QImage img = win.grabWindow();
    if (img.isNull()) return 2;
    return img.save(QString::fromUtf8(out)) ? 0 : 3;
}

// The window the item is ALREADY in, or a fresh one it is moved into. Every entry point below
// needs the same thing, and creating a NEW window each time is destructive: reparenting an item
// out of a scene drops the scene's state — focus (which is per-window) and any Popup the item has
// open. Measured twice: `--render` after `--click` showed an unfocused TextField whose object
// reported activeFocus true, and `--run` after `--click` closed a ComboBox's popup, so both
// differentials were reading an artefact of the harness.
static QQuickWindow *qtd_scene_for(QQuickItem *it) {
    if (QQuickWindow *cur = it->window()) return cur;
    static QQuickWindow *win = nullptr;   // outlives the call: the item stays in a live scene
    win = new QQuickWindow();
    win->setWidth(qMax(1, int(it->width())));
    win->setHeight(qMax(1, int(it->height())));
    it->setParentItem(win->contentItem());
    win->show();
    return win;
}

// Put the item in a window and deliver a real click, then let the object be inspected as usual.
// This is the BEHAVIOUR half of the criterion: a document can render pixel-identically and still
// not react to input — a MouseArea whose handler never runs looks exactly right in a frame.
extern "C" int qtd_click_item(void *item, int x, int y) {
    if (!item) return 1;
    auto *it = qtd_as_item(item);
    if (!it) return 5;   // not an Item — see qtd_as_item
    QQuickWindow *win = qtd_scene_for(it);
    const QPointF p(x, y);
    // A MOVE first — see the same note in qtd_qmlrender.cpp: `hovered` comes from hover delivery,
    // which only runs off a move, and a press from a pointer that was never over the control
    // leaves the two sides in different states for a reason that is the harness's.
    QMouseEvent move(QEvent::MouseMove, p, p, win->mapToGlobal(p.toPoint()),
                     Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(win, &move);
    QMouseEvent press(QEvent::MouseButtonPress, p, p, win->mapToGlobal(p.toPoint()),
                      Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QMouseEvent release(QEvent::MouseButtonRelease, p, p, win->mapToGlobal(p.toPoint()),
                        Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(win, &press);
    QCoreApplication::sendEvent(win, &release);
    QCoreApplication::processEvents();
    return 0;
}

// Deliver a KEY press+release to the item in a live scene. Keyboard is its own axis: a compiled
// document can carry a perfectly correct Keys.onPressed / focus chain and be pixel-identical, respond
// to a click, and still never see a key — which no frame comparison and no click test can reveal.
// The item must have focus for the scene to route the event to it, so this sets it.
extern "C" int qtd_key_item(void *item, int key, int modifiers) {
    if (!item) return 1;
    auto *it = qtd_as_item(item);
    if (!it) return 5;   // not an Item — see qtd_as_item
    QQuickWindow *win = qtd_scene_for(it);
    // A key only reaches an item in an ACTIVE window with ACTIVE focus: show() alone leaves the scene
    // routing to nobody, and both sides then "pass" having done nothing.
    win->requestActivate();
    QCoreApplication::processEvents();
    it->forceActiveFocus();
    // The TEXT matters: QQuickTextInput inserts event->text(), not the key code, so a key event
    // without it is delivered and does nothing — the test would pass on both sides doing nothing.
    const QString kt = QChar(key).toLower();
    QKeyEvent press(QEvent::KeyPress, key, Qt::KeyboardModifiers(modifiers), kt);
    QKeyEvent release(QEvent::KeyRelease, key, Qt::KeyboardModifiers(modifiers), kt);
    QCoreApplication::sendEvent(win, &press);
    QCoreApplication::sendEvent(win, &release);
    QCoreApplication::processEvents();
    return 0;
}

// Put the item in a live scene and spin the event loop for `ms`. Animations only advance when
// something drives them, so a compiled object can hold a perfectly correct NumberAnimation that
// never ticks — invisible to a property dump (read too early), to a frame comparison (one frame),
// and to a click test. Time is its own axis.
extern "C" int qtd_run_ms(void *item, int ms) {
    if (!item) return 1;
    auto *it = qtd_as_item(item);
    if (!it) return 5;   // not an Item — see qtd_as_item
    QQuickWindow *win = qtd_scene_for(it);
    QElapsedTimer t; t.start();
    while (t.elapsed() < ms) QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    return 0;
}
