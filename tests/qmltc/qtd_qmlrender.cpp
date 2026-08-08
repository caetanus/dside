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
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QKeyEvent>
#include <QQuickItem>
#include <QImage>
#include <QSet>
#include <QUrl>
#include <QWindow>
#include <QMouseEvent>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <cstdio>

// Send a synthetic click at (x, y) to a window and let it be delivered. This is the BEHAVIOUR half
// of the criterion: a document can render identically and still not react to input the same way —
// a MouseArea whose handler never runs, a Button that never toggles. Posting real QMouseEvents (no
// QtTest dependency) exercises the same delivery path the engine uses.
static void clickAt(QWindow *w, int x, int y) {
    const QPointF p(x, y);
    // A MOVE first, so the pointer is THERE before it presses. Qt derives `hovered` from hover
    // delivery, which only runs off a move: without one the control is pressed by a pointer that
    // was never over it, and `hovered` stays false on whichever side happens not to synthesise it.
    // Both harnesses send the same three events now, so the state after a click is defined.
    QMouseEvent move(QEvent::MouseMove, p, p, w->mapToGlobal(p.toPoint()),
                     Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    QCoreApplication::sendEvent(w, &move);
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
    // The EXTENT and the DEPTH, not just the first pixel. Reporting only where the scan happened to
    // stop reads as "one pixel of antialiasing" for a difference that covers two thirds of the
    // frame — which is how a wide, shallow difference (a fill one step off everywhere) got written
    // down twice as noise. How many pixels differ and by how much is what tells those apart.
    int nDiff = 0, maxDelta = 0, fx = -1, fy = -1;
    for (int y = 0; y < ia.height(); ++y)
        for (int x = 0; x < ia.width(); ++x) {
            const QRgb pa = ia.pixel(x, y), pb = ib.pixel(x, y);
            if (pa == pb) continue;
            if (fx < 0) { fx = x; fy = y; }
            ++nDiff;
            maxDelta = qMax(maxDelta, qMax(qMax(qAbs(qRed(pa) - qRed(pb)), qAbs(qGreen(pa) - qGreen(pb))),
                                           qMax(qAbs(qBlue(pa) - qBlue(pb)), qAbs(qAlpha(pa) - qAlpha(pb)))));
        }
    if (nDiff) {
        std::fprintf(stderr, "qmlrender: %d of %d pixels differ, max channel delta %d; first at "
                     "(%d,%d): engine %08x, ours %08x\n", nDiff, ia.width() * ia.height(), maxDelta,
                     fx, fy, ia.pixel(fx, fy), ib.pixel(fx, fy));
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
    // `--run <qml> <ms> <prop>`: let TIME pass in the interpreted version, then read a property.
    if (argc == 5 && QString::fromUtf8(argv[1]) == "--run") {
        QQuickView v;
        v.setResizeMode(QQuickView::SizeViewToRootObject);
        v.setSource(QUrl::fromLocalFile(QString::fromUtf8(argv[2])));
        if (v.status() != QQuickView::Ready) { std::fprintf(stderr, "qmlrender: not ready\n"); return 3; }
        v.show();
        QElapsedTimer t; t.start();
        const int ms = QString::fromUtf8(argv[3]).toInt();
        while (t.elapsed() < ms) QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
        QObject *root = v.rootObject();
        const QByteArray prop = QString::fromUtf8(argv[4]).toUtf8();
        std::printf("%s\t%s\n", prop.constData(), qPrintable(root->property(prop.constData()).toString()));
        return 0;
    }
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
    // `--key <qml> <key> <prop>`: load the document, deliver a key press+release to the root, print ONE
    // property. The engine half of the keyboard axis; the compiled half is qtd_key_item.
    // `--key <qml> <key> <prop>`: the ENGINE half of the keyboard axis. Built the same way the compiled
    // half is (own QQuickWindow, root reparented into contentItem, activate, focus, send) — going
    // through QQuickView instead left the view inactive and the key went nowhere, while the compiled
    // side already received it. An asymmetric harness would have read that as a compiler defect.
    if (argc == 5 && QString::fromUtf8(argv[1]) == "--key") {
        QQmlEngine eng;
        QQmlComponent comp(&eng, QUrl::fromLocalFile(QString::fromUtf8(argv[2])));
        QObject *root = comp.create();
        if (!root) { std::fprintf(stderr, "qmlrender: %s\n", qPrintable(comp.errorString())); return 3; }
        auto *item = qobject_cast<QQuickItem *>(root);
        if (!item) { std::fprintf(stderr, "qmlrender: root is not an Item\n"); return 4; }
        QQuickWindow win;
        win.setWidth(qMax(1, int(item->width())));
        win.setHeight(qMax(1, int(item->height())));
        item->setParentItem(win.contentItem());
        win.show();
        win.requestActivate();
        QCoreApplication::processEvents();
        item->forceActiveFocus();
        const int key = QString::fromUtf8(argv[3]).toInt();
        const QString kt = QChar(key).toLower();
        QKeyEvent press(QEvent::KeyPress, key, Qt::NoModifier, kt);
        QKeyEvent release(QEvent::KeyRelease, key, Qt::NoModifier, kt);
        QCoreApplication::sendEvent(&win, &press);
        QCoreApplication::sendEvent(&win, &release);
        QCoreApplication::processEvents();
        const QByteArray prop = QString::fromUtf8(argv[4]).toUtf8();
        const QVariant val = root->property(prop.constData());
        if (!val.isValid()) { std::fprintf(stderr, "qmlrender: no property '%s'\n", prop.constData()); return 5; }
        std::printf("%s\t%s\n", prop.constData(), qPrintable(val.toString()));
        return 0;
    }
    // `--clickrender <qml> <x> <y> <out.png>`: load, deliver a click, THEN grab the frame. The
    // plain render compares the document at rest and the property dump compares it after a
    // MUTATION; neither sees what a control looks like once it has been pressed, which is the half
    // of "behaves like the interpreted version" that a user actually touches. No property is
    // picked, so nothing chooses what counts as behaviour.
    if (argc == 6 && QString::fromUtf8(argv[1]) == "--clickrender") {
        QQuickView v;
        v.setResizeMode(QQuickView::SizeViewToRootObject);
        v.setSource(QUrl::fromLocalFile(QString::fromUtf8(argv[2])));
        if (v.status() != QQuickView::Ready) { std::fprintf(stderr, "qmlrender: not ready (status %d)\n", (int)v.status()); return 3; }
        v.show();
        QCoreApplication::processEvents();
        clickAt(&v, QString::fromUtf8(argv[3]).toInt(), QString::fromUtf8(argv[4]).toInt());
        // Let whatever the click started SETTLE before the frame is taken. A document with a
        // `Behavior` animates from the old value to the new one, and grabbing mid-flight compares
        // two stopwatches rather than two renderers — the phase depends on how long each side took
        // to get here, which is not a property of the compiler. The END state is the well-defined
        // thing, and it is what "behaves like the interpreted version" means for a toggle.
        {
            QElapsedTimer t; t.start();
            while (t.elapsed() < 400) QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
        }
        const QImage img = v.grabWindow();
        if (img.isNull()) { std::fprintf(stderr, "qmlrender: null frame\n"); return 4; }
        return img.save(QString::fromUtf8(argv[5])) ? 0 : 5;
    }
    if (argc != 3) { std::fprintf(stderr, "usage: qmlrender <qml> <out.png> | --compare <a> <b>\n"); return 64; }
    // A POPUP has a frame, it just has nowhere to be: QQuickView refuses a root that is not an
    // Item, and 25 of Qt's documents (Popup, Menu, Dialog, Drawer, ToolTip in five styles) are
    // exactly that. They were counted as "the engine draws nothing for this", which is not the same
    // as "this cannot be drawn" — it is the harness having no place to put it.
    //
    // Detected through the META-OBJECT, not by naming a type: something that is not an Item and
    // has both `open()` and a `contentItem` is a popup as far as this is concerned, and Qt's own
    // machinery does the rest.
    {
        QQmlEngine peng;
        QQmlComponent pc(&peng, QUrl::fromLocalFile(QString::fromUtf8(argv[1])));
        if (!pc.isError()) {
            QObject *proot = pc.create();
            if (proot && !qobject_cast<QQuickItem *>(proot)
                    && proot->metaObject()->indexOfMethod("open()") >= 0
                    && proot->metaObject()->indexOfProperty("contentItem") >= 0) {
                QQuickWindow win;
                win.setWidth(400); win.setHeight(400);
                win.show();
                proot->setProperty("parent", QVariant::fromValue(win.contentItem()));
                QMetaObject::invokeMethod(proot, "open");
                QCoreApplication::processEvents();
                const QImage img = win.grabWindow();
                if (img.isNull()) { std::fprintf(stderr, "qmlrender: null popup frame\n"); return 4; }
                return img.save(QString::fromUtf8(argv[2])) ? 0 : 5;
            }
            delete proot;
        }
    }
    QQuickView v;
    v.setResizeMode(QQuickView::SizeViewToRootObject);
    v.setSource(QUrl::fromLocalFile(QString::fromUtf8(argv[1])));
    if (v.status() != QQuickView::Ready) { std::fprintf(stderr, "qmlrender: not ready (status %d)\n", (int)v.status()); return 3; }
    v.show();
    const QImage img = v.grabWindow();
    if (img.isNull()) { std::fprintf(stderr, "qmlrender: null frame\n"); return 4; }
    return img.save(QString::fromUtf8(argv[2])) ? 0 : 5;
}
