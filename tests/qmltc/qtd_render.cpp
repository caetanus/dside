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

extern "C" int qtd_render_item(void *item, const char *out) {
    if (!item) return 1;
    auto *it = qtd_as_item(item);
    if (!it) return 4;   // not an Item (a Popup and friends): nothing to put in a window
    // SizeViewToRootObject sizes the root from its IMPLICIT size when it has no explicit one, and
    // then sets the item to that size. A Control's whole geometry comes from there — reading
    // width() alone gave 1x1 for a Pane the engine draws at 24x24, which reads as a render defect
    // and is not one.
    if (it->width() <= 0 && it->implicitWidth() > 0) it->setWidth(it->implicitWidth());
    if (it->height() <= 0 && it->implicitHeight() > 0) it->setHeight(it->implicitHeight());
    // An item ALREADY in a scene is grabbed from THAT scene. Moving it into a fresh window drops
    // everything the scene holds — activeFocus above all, which is per-window: `--click` put the
    // item in a window and gave it focus, and `--render` then reparented it away, so the frame
    // showed an unfocused control while the object itself reported activeFocus true. Qt's
    // TextField paints its border with the accent colour when focused, and the click differential
    // was measuring the harness rather than the compiler.
    if (QQuickWindow *cur = it->window()) {
        cur->setWidth(qMax(1, int(it->width())));
        cur->setHeight(qMax(1, int(it->height())));
        const QImage img0 = cur->grabWindow();
        if (img0.isNull()) return 2;
        return img0.save(QString::fromUtf8(out)) ? 0 : 3;
    }
    QQuickWindow win;
    win.setWidth(qMax(1, int(it->width())));
    win.setHeight(qMax(1, int(it->height())));
    it->setParentItem(win.contentItem());
    win.show();
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
