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
