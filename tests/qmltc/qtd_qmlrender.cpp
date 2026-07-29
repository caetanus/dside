// The render side of the differential: draw a .qml through the ENGINE, and compare two frames.
//
// `qmlrender <file.qml> <out.png>`      — render the interpreted version
// `qmlrender --compare <a.png> <b.png>` — compare, and REFUSE a vacuous comparison
//
// The refusal is the point. Most of this project's corpus was written for a property differential,
// so its roots have no visual size: rendering them yields a 1-pixel window, and two blank frames
// compare equal while proving nothing. A render test that cannot fail is worse than no render
// test, so a comparison of images with no area, or with a single colour, is an ERROR here rather
// than a pass.
#include <QGuiApplication>
#include <QQuickView>
#include <QQuickItem>
#include <QImage>
#include <QSet>
#include <QUrl>
#include <QWindow>
#include <QMouseEvent>
#include <QCoreApplication>
#include <cstdio>

// Send a synthetic click at (x, y) to a window and let it be delivered. This is the BEHAVIOUR half
// of the criterion: a document can render identically and still not react to input the same way —
// a MouseArea whose handler never runs, a Button that never toggles. Posting real QMouseEvents (no
// QtTest dependency) exercises the same delivery path the engine uses.
static void clickAt(QWindow *w, int x, int y) {
    const QPointF p(x, y);
    QMouseEvent press(QEvent::MouseButtonPress, p, p, w->mapToGlobal(p.toPoint()),
                      Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    QMouseEvent release(QEvent::MouseButtonRelease, p, p, w->mapToGlobal(p.toPoint()),
                        Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(w, &press);
    QCoreApplication::sendEvent(w, &release);
    QCoreApplication::processEvents();
}

static int compare(const QString &a, const QString &b) {
    QImage ia(a), ib(b);
    if (ia.isNull() || ib.isNull()) { std::fprintf(stderr, "qmlrender: could not read both images\n"); return 3; }
    if (ia.size() != ib.size()) {
        std::fprintf(stderr, "qmlrender: size differs — engine %dx%d, ours %dx%d\n",
                     ia.width(), ia.height(), ib.width(), ib.height());
        return 1;
    }
    if (ia.width() <= 1 || ia.height() <= 1) {
        std::fprintf(stderr, "qmlrender: %dx%d has no area — nothing was drawn, so this comparison "
                     "would pass no matter what the compiler emitted\n", ia.width(), ia.height());
        return 4;
    }
    QSet<QRgb> colours;
    for (int y = 0; y < ia.height(); ++y)
        for (int x = 0; x < ia.width(); ++x) colours.insert(ia.pixel(x, y));
    if (colours.size() < 2) {
        std::fprintf(stderr, "qmlrender: the frame is a single flat colour — this comparison cannot "
                     "distinguish a correct render from an empty one\n");
        return 5;
    }
    for (int y = 0; y < ia.height(); ++y)
        for (int x = 0; x < ia.width(); ++x)
            if (ia.pixel(x, y) != ib.pixel(x, y)) {
                std::fprintf(stderr, "qmlrender: pixel (%d,%d) differs: engine %08x, ours %08x\n",
                             x, y, ia.pixel(x, y), ib.pixel(x, y));
                return 2;
            }
    std::printf("render OK: %dx%d, %d distinct colours, pixel-identical to the interpreted version\n",
                ia.width(), ia.height(), int(colours.size()));
    return 0;
}

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    if (argc == 4 && QString::fromUtf8(argv[1]) == "--compare")
        return compare(QString::fromUtf8(argv[2]), QString::fromUtf8(argv[3]));
    // `--click <qml> <x> <y> <prop>`: load the document, deliver a click, print ONE property.
    // Deliberately one property and one event to start: the value of this test is that it can
    // fail for a reason no property dump or frame comparison can see.
    if (argc == 6 && QString::fromUtf8(argv[1]) == "--click") {
        QQuickView v;
        v.setResizeMode(QQuickView::SizeViewToRootObject);
        v.setSource(QUrl::fromLocalFile(QString::fromUtf8(argv[2])));
        if (v.status() != QQuickView::Ready) { std::fprintf(stderr, "qmlrender: not ready\n"); return 3; }
        v.show();
        clickAt(&v, QString::fromUtf8(argv[3]).toInt(), QString::fromUtf8(argv[4]).toInt());
        QObject *root = v.rootObject();
        if (!root) { std::fprintf(stderr, "qmlrender: no root object\n"); return 4; }
        const QByteArray prop = QString::fromUtf8(argv[5]).toUtf8();
        const QVariant val = root->property(prop.constData());
        if (!val.isValid()) { std::fprintf(stderr, "qmlrender: no property '%s'\n", prop.constData()); return 5; }
        std::printf("%s\t%s\n", prop.constData(), qPrintable(val.toString()));
        return 0;
    }
    if (argc != 3) { std::fprintf(stderr, "usage: qmlrender <qml> <out.png> | --compare <a> <b>\n"); return 64; }
    QQuickView v;
    v.setResizeMode(QQuickView::SizeViewToRootObject);
    v.setSource(QUrl::fromLocalFile(QString::fromUtf8(argv[1])));
    if (v.status() != QQuickView::Ready) { std::fprintf(stderr, "qmlrender: not ready (status %d)\n", (int)v.status()); return 3; }
    v.show();
    const QImage img = v.grabWindow();
    if (img.isNull()) { std::fprintf(stderr, "qmlrender: null frame\n"); return 4; }
    return img.save(QString::fromUtf8(argv[2])) ? 0 : 5;
}
