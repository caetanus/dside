// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A QAbstractListModel WRITTEN IN D, driving a real QML ListView.
//
// What a model buys over a list property is INCREMENTAL change: a view told "row 2 was inserted"
// or "rows 0..0 moved to 3" keeps every other delegate it already built. That is the whole reason to
// write one, so it is what this asserts — not that the rows show up, which a ListModel rebuilt in
// JavaScript also achieves while destroying and recreating every delegate on each change.
//
// Each delegate takes a creation stamp (`uid`) when it is built. After a move the SAME stamps must
// appear in the new order, the creation count must not grow, and the view must never have been
// reset. After dataChanged the stamp at that row must be unchanged while its value is new.
import qt.quick.qguiapplication, qt.quick.qqmlapplicationengine, qt.quick.qurl;
import qt.quick.qcoreapplication;
import qt.quick.qabstractlistmodel, qt.quick.qmodelindex, qt.quick.qvariant;
import qt.quick.qtvirt;                 // __QAbstractListModel_vnames/_prot for the mixin
import cppq = qt.quick.qobject;         // the C++ QObject (renamed: `@QObject` below is qtmoc's)
import qtmoc, qrc, cxxrt;
import std.stdio, std.conv : to;

mixin(qtdApplication!"QGuiApplication");
mixin(qrcRegister(import("listmodel.qrc"), "qt.quick"));

enum TitleRole = 257, NRole = 258, StarredRole = 259;   // Qt::UserRole + 1 ..
struct Row { string title; int n; bool starred; }

@QObject class Rows {
    mixin QtdWidget!QAbstractListModel;
    Row[] rows;

    // The three a list model must provide: how many, what is in a cell, and the role NAMES the
    // delegate's required properties are matched against.
    int rowCount(const(QModelIndex)* parent) { return parent.isValid() ? 0 : cast(int) rows.length; }
    QVariant data(const(QModelIndex)* idx, int role) {
        auto i = idx.row();
        if (i < 0 || i >= rows.length) return QVariant.__make();
        switch (role) {
            case TitleRole:   return QVariant(rows[i].title);
            case NRole:       return QVariant(rows[i].n);
            case StarredRole: return QVariant(rows[i].starred);
            default:          return QVariant.__make();
        }
    }
    ubyte[][int] roleNames() {
        return [TitleRole: cast(ubyte[]) "title".dup, NRole: cast(ubyte[]) "n".dup,
                StarredRole: cast(ubyte[]) "starred".dup];
    }

    // Mutations, each announced to the views the way Qt requires: begin*, change, end*.
    void insert(int at, Row r) {
        beginInsertRows(QModelIndex.__make(), at, at);
        rows = rows[0 .. at] ~ r ~ rows[at .. $];
        endInsertRows();
    }
    void remove(int at) {
        beginRemoveRows(QModelIndex.__make(), at, at);
        rows = rows[0 .. at] ~ rows[at + 1 .. $];
        endRemoveRows();
    }
    /// Move row `from` so that it ends up at index `to`.
    void move(int from, int to) {
        // Qt's destination is the row the item goes BEFORE, counted before the move: one past `to`
        // when moving down.
        auto dest = to > from ? to + 1 : to;
        assert(beginMoveRows(QModelIndex.__make(), from, from, QModelIndex.__make(), dest),
               "Qt refused the move");
        auto r = rows[from];
        rows = rows[0 .. from] ~ rows[from + 1 .. $];
        rows = rows[0 .. to] ~ r ~ rows[to .. $];
        endMoveRows();
    }
    void retitle(int at, string t) {
        rows[at].title = t;
        auto ix = createIndex(at, 0);
        dataChanged(ix, ix, [TitleRole]);
    }
}

@QObject class Driver {
    Signal!() step;
    Signal!() rowsChanged;
    // Typed as the C++ QObject: `QObject*` is a meta-type every Qt knows, and ListView's `model`
    // casts it to QAbstractItemModel itself. A D class name would reach Qt as `Rows*`, which it
    // does not know, and QML could not read the property at all.
    @Property("rowsChanged") cppq.QObject rows;

    string snap; int created, resets;
    @Slot void report(string s, int c, int r) { snap = s; created = c; resets = r; }

    // The view builds and lays out delegates from its OWN event handling (polish, incubation), so
    // after each change the event loop runs before the snapshot — as it would between two frames.
    string look() {
        foreach (_; 0 .. 5) QCoreApplication.processEvents(0);
        step.emit();
        return snap;
    }
}

void main() {
    cast(void) createApp("listmodel");
    auto model = new Rows();
    model.rows = [Row("alpha", 1, false), Row("beta", 2, true), Row("gamma", 3, false)];

    auto driver = newQObject!Driver();
    // The D class is not itself a Qt wrapper — QtdWidget builds a C++ trampoline FOR it — so what
    // QML is handed is that trampoline, wrapped as the bound QObject.
    driver.rows = cppq.QObject.wrap(qobjOf(model));

    auto engine = new QQmlApplicationEngine();
    engine.rootContext().setContextProperty("driver", cppq.QObject.wrap(qobjOf(driver)));
    auto url = QUrl("qrc:/listmodel.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);
    assert(engine.rootObjects().length == 1, "the document did not load");

    auto s0 = driver.look();
    writeln("initial:   ", s0, "  created=", driver.created);
    assert(s0 == "d1:alpha:1:false,d2:beta:2:true,d3:gamma:3:false", "rows/roles did not reach the view: " ~ s0);
    assert(driver.created == 3);

    // MOVE: the same three delegates, reordered — nothing rebuilt.
    model.move(0, 2);
    auto s1 = driver.look();
    writeln("move 0->2: ", s1, "  created=", driver.created);
    assert(s1 == "d2:beta:2:true,d3:gamma:3:false,d1:alpha:1:false",
           "a move must reorder the EXISTING delegates, not rebuild them: " ~ s1);
    assert(driver.created == 3, "a move created delegates");

    // DATA CHANGED: the delegate at row 1 keeps its stamp and shows the new title.
    model.retitle(1, "GAMMA");
    auto s2 = driver.look();
    writeln("retitle 1: ", s2, "  created=", driver.created);
    assert(s2 == "d2:beta:2:true,d3:GAMMA:3:false,d1:alpha:1:false",
           "dataChanged must update the delegate in place: " ~ s2);
    assert(driver.created == 3);

    // INSERT: exactly one new delegate, the others untouched.
    model.insert(1, Row("delta", 4, true));
    auto s3 = driver.look();
    writeln("insert 1:  ", s3, "  created=", driver.created);
    assert(s3 == "d2:beta:2:true,d4:delta:4:true,d3:GAMMA:3:false,d1:alpha:1:false",
           "an insert must add ONE delegate and keep the rest: " ~ s3);
    assert(driver.created == 4);

    // REMOVE: the removed delegate goes; the survivors keep their stamps.
    model.remove(0);
    auto s4 = driver.look();
    writeln("remove 0:  ", s4, "  created=", driver.created);
    assert(s4 == "d4:delta:4:true,d3:GAMMA:3:false,d1:alpha:1:false",
           "a remove must drop that delegate only: " ~ s4);
    assert(driver.created == 4);

    assert(driver.resets == 0, "the view was RESET, which throws every delegate away: resets="
           ~ driver.resets.to!string);

    // AFTER QT HAS DESTROYED IT. A D reference can outlive the C++ object (its parent deleted, a
    // deleteLater): the methods that reach C++ — beginInsertRows and the rest — must refuse, not
    // hand Qt the freed address. DeferredDelete is flushed explicitly: with no exec() running, a
    // posted delete is not processed by processEvents alone.
    auto doomed = new Rows();
    cppq.QObject.wrap(qobjOf(doomed)).deleteLater();
    QCoreApplication.sendPostedEvents(null, 52 /* QEvent::DeferredDelete */);
    bool refused;
    try doomed.insert(0, Row("late", 0, false));
    catch (Error e) refused = true;
    assert(refused, "a subclass method reached C++ through a destroyed object");
    writeln("listmodel OK: a D QAbstractListModel drives a ListView incrementally ",
            "(move, dataChanged, insert, remove; 0 resets, delegates preserved)");
}
