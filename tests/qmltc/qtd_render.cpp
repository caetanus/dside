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

extern "C" int qtd_render_item(void *item, const char *out) {
    auto *it = reinterpret_cast<QQuickItem *>(item);
    if (!it) return 1;
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
