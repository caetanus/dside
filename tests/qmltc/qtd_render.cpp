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
#include <QCoreApplication>
#include <QElapsedTimer>

extern "C" int qtd_render_item(void *item, const char *out) {
    auto *it = reinterpret_cast<QQuickItem *>(item);
    if (!it) return 1;
    // SizeViewToRootObject sizes the root from its IMPLICIT size when it has no explicit one, and
    // then sets the item to that size. A Control's whole geometry comes from there — reading
    // width() alone gave 1x1 for a Pane the engine draws at 24x24, which reads as a render defect
    // and is not one.
    if (it->width() <= 0 && it->implicitWidth() > 0) it->setWidth(it->implicitWidth());
    if (it->height() <= 0 && it->implicitHeight() > 0) it->setHeight(it->implicitHeight());
    QQuickWindow win;
    win.setWidth(qMax(1, int(it->width())));
    win.setHeight(qMax(1, int(it->height())));
    it->setParentItem(win.contentItem());
    win.show();
    const QImage img = win.grabWindow();
    if (img.isNull()) return 2;
    return img.save(QString::fromUtf8(out)) ? 0 : 3;
}

// Put the item in a window and deliver a real click, then let the object be inspected as usual.
// This is the BEHAVIOUR half of the criterion: a document can render pixel-identically and still
// not react to input — a MouseArea whose handler never runs looks exactly right in a frame.
extern "C" int qtd_click_item(void *item, int x, int y) {
    auto *it = reinterpret_cast<QQuickItem *>(item);
    if (!it) return 1;
    static QQuickWindow *win = nullptr;      // outlives the call: the item stays in a live scene
    win = new QQuickWindow();
    win->setWidth(qMax(1, int(it->width())));
    win->setHeight(qMax(1, int(it->height())));
    it->setParentItem(win->contentItem());
    win->show();
    const QPointF p(x, y);
    QMouseEvent press(QEvent::MouseButtonPress, p, p, win->mapToGlobal(p.toPoint()),
                      Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QMouseEvent release(QEvent::MouseButtonRelease, p, p, win->mapToGlobal(p.toPoint()),
                        Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
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
    auto *it = reinterpret_cast<QQuickItem *>(item);
    if (!it) return 1;
    static QQuickWindow *win = nullptr;
    win = new QQuickWindow();
    win->setWidth(qMax(1, int(it->width())));
    win->setHeight(qMax(1, int(it->height())));
    it->setParentItem(win->contentItem());
    win->show();
    QElapsedTimer t; t.start();
    while (t.elapsed() < ms) QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    return 0;
}
