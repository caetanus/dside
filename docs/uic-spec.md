# CTFE uic — the full `.ui` spec and implementation roadmap

Goal: grow `runtime/uic/uiform.d` (`mixin(uiForm(import("x.ui")))`) from the current
proof-of-concept to the **complete `.ui` spec**, matching what Qt's `uic` / `pyside6-uic`
produce. Source of truth: the observable input→output contract in the PySide corpus at
`../pyside-setup/examples/**` (`*.ui` files + their generated `ui_*.py`) — Qt's uic C++
source is not vendored, but the corpus pins every element→code pattern.

## The key realization: one generic rule covers most of it

uic is mostly mechanical. For `<property name="P"><V>…</V></property>` on a widget `w`:

```
w.set<Capitalize(P)>( value(<V>) )          // geometry -> setGeometry, minimum -> setMinimum, …
```

`value(<V>)` dispatches on the child element tag. So the **core engine** is: depth-first
walk of the `<widget>` tree, and for each property emit `set<Cap(name)>` + a value built by
a small type table. Everything else is a handful of *structural specials*.

### value(<V>) dispatch table

| `<V>` | D value | notes |
|---|---|---|
| `<string>Hi</string>` | `"Hi"` | translatable props go to `retranslateUi` (see skeleton) |
| `<number>5</number>` | `5` | int |
| `<double>0.1</double>` | `0.1` | |
| `<bool>true</bool>` | `true` | |
| `<rect><x/><y/><width/><height/></rect>` | `QRect(x,y,w,h)` | value-type; binding has it |
| `<size><width/><height/></size>` | `QSize(w,h)` | value-type; binding has it |
| `<enum>Qt::Orientation::Horizontal</enum>` | `Orientation.Horizontal` | FQN→D enum (see below) |
| `<set>A::x\|B::y</set>` | `cast(int)(X.x \| Y.y)` | flags OR-ed; QFlags setters take int in the binding |
| `<sizepolicy hsizetype= vsizetype=><horstretch/><verstretch/>` | build `QSizePolicy` then `setSizePolicy` | needs QSizePolicy value-type |
| `<font>…</font>` | build `QFont` (family/pointSize/weight/italic/bold) | have QFont |
| `<iconset resource= theme=><normaloff/>` | `QIcon` + `addFile(":/…")` or `fromTheme(…)` | ties to `.qrc` story |
| `<palette>…</palette>` | `QPalette`/`QBrush`/`QColor` per role/group | rare, complex — last |

**Translatable property names** (value goes to `retranslateUi`, not `setupUi`):
`text`, `title`, `windowTitle`, `toolTip`, `statusTip`, `whatsThis`, `shortcut`,
`placeholderText`, plus `<item>`/tab titles. Everything else stays in `setupUi`.

### FQN enum → D
`Qt::Orientation::Horizontal` → `Orientation.Horizontal`; `QFrame::Shape::Box` →
`Shape.Box`. Rule: take the last two `::` segments as `Enum.Value` (the binding emits each
enum as its own module `enum <Enum>`). A small alias table handles the few that don't map
cleanly. Verify against how the binding actually scopes Qt-namespace enums.

## setupUi / retranslateUi skeleton (the contract)

```d
struct Ui_<class> {
    // one typed field per named widget/layout/action/spacer/buttongroup
    void setupUi(<RootClass> root) {
        if (root.objectName().length == 0) root.setObjectName("<class>");
        root.resize(W, H);                       // from root <property name="geometry">
        // create ALL actions, then widgets+layouts depth-first, set non-translatable props,
        // assemble layouts (addWidget/addLayout/addItem/setWidget), menus/toolbars,
        // setCentralWidget / setMenuBar / addToolBar / setStatusBar,
        // button groups, tab order,
        connectSlotsByName(root);                // needs moc (our qtmoc)
        // explicit <connections> emitted here as sender.sig.connect(recv.slot)
        retranslateUi(root);
    }
    void retranslateUi(<RootClass> root) {
        // every translatable string: root.setWindowTitle("…"); w.setText("…");
        // combo/list: setItemText(i, "…"); tabs: setTabText(i, "…")
    }
}
```
(i18n: emit plain string literals for now; a later pass can route through a `tr()` binding.)

## Structural specials (not the generic rule)

1. **Layouts.** First `<layout>` child of a widget → the widget's layout.
   - `QVBoxLayout`/`QHBoxLayout`: `L = QVBoxLayout_new(parent)`; items → `L.addWidget(w)` /
     `L.addLayout(sub)` / `L.addItem(spacer)`.
   - `QGridLayout`: `addWidget(w, row, col, rowspan, colspan)` from `<item row= column=
     rowspan= colspan=>` (spans default 1); `addItem(spacer, r, c, rs, cs)`.
   - `QFormLayout`: `setWidget(row, QFormLayout.LabelRole/FieldRole, w)` (col 0=label, 1=field).
   - Margins: the 4 props `leftMargin/topMargin/rightMargin/bottomMargin` collapse to
     `setContentsMargins(l,t,r,b)`; `spacing` → `setSpacing`.
   - Nested layout goes to the parent via `addLayout`.
2. **Spacers.** `<spacer>` (not `<widget>`) → `QSpacerItem(w, h, hPolicy, vPolicy)`; added with
   `addItem`. Sizes/policies from `<size>`+`<sizepolicy>`/orientation.
3. **Item-bearing widgets.** `QComboBox`/`QListWidget` `<item><property name="text">` →
   `addItem("")` ×N in setupUi + `setItemText(i,"…")` in retranslateUi. `QTabWidget` child
   `<widget>` pages → `addTab(page,"")` + `setTabText`. `QStackedWidget` → `addWidget(page)`
   + `setCurrentIndex`.
4. **Actions & chrome (QMainWindow).** `<action>` → `QAction_new(root)` + props. `<addaction
   name="X"/>` → `menu.addAction(actionX)` / `menu.addSeparator()` (name `separator`) /
   `menubar.addAction(submenu.menuAction())`. Root: `setCentralWidget`, `setMenuBar`,
   `addToolBar(area, tb)`, `setStatusBar`.
5. **Connections.** `<connection><sender>/<signal>/<receiver>/<slot>` →
   `sender.<signal>.connect(receiver.<slot>)` using our signal/slot binding; emitted right
   before `retranslateUi`.
6. **Button groups.** `<attribute name="buttonGroup"><string>g</string>` → one
   `QButtonGroup_new(root)` per group name + `g.addButton(w)`.
7. **Tab order.** `<tabstops><tabstop>a</tabstop>…` → `QWidget.setTabOrder(a, b)` for each
   consecutive pair.
8. **Custom/promoted.** `<customwidget><class>/<extends>/<header>` → the promoted `<class>`
   is constructed like any widget (`Class_new(parent)`); `<extends>`/`<header>` inform the D
   import, not codegen.
9. **Resources.** `<resources><include location="app.qrc"/>` → ties to the `.qrc → import()`
   story (embed at compile time; register once); the `:/…` icon paths come from here.

## Phased checklist

- [ ] **A — generic engine (biggest leverage).** Depth-first widget walk; `set<Cap(name)>`
      + `value()` dispatch (string/number/double/bool/rect/size/enum/set); retranslateUi
      split; objectName/resize/connectSlotsByName skeleton; box-layout parenting. Covers
      simple dialogs + most forms. (`dialog.ui`, `device.ui`.)
- [x] **B — layouts.** QGridLayout (row/col/span) + QFormLayout (Label/FieldRole) + nested
      layouts (addLayout) done; verified on the real `dialog.ui` (grid). Needed a generator
      fix first: derived overloads sharing an inherited name (QGridLayout::addWidget(w,r,c,…))
      were being dropped. Still TODO in B: contentsMargins/spacing, spacers.
- [ ] **C — item widgets.** combo/list items, tab/stacked pages, groupbox. (`camera.ui`,
      `documentviewer`.)
- [ ] **D — mainwindow chrome.** actions, menus, toolbars, statusbar. (`documentviewer`.)
- [ ] **E — advanced.** connections, button groups, tab order, sizePolicy/font/iconset/
      palette, custom widgets, resources/`.qrc`, connectSlotsByName via moc.

## Binding gaps this surfaces (fill as tiers need them)

- Value-types in the cxx binding: `QRect`/`QSize` (have), `QSizePolicy`, `QFont` (have),
  `QIcon`, `QPalette`/`QBrush`/`QColor`.
- Qt-namespace enum/flag access shape (confirm `Enum.Value` scoping; flag setters take int).
- `connect` for arbitrary signal→slot by name, and `QMetaObject.connectSlotsByName` (moc /
  `runtime/qtmoc`).
- `.qrc` → `import()` resource embedding (its own small converter) for `:/…` icons.

## Reference files (pattern → corpus)

| Pattern | `.ui` | generated |
|---|---|---|
| minimal dialog | `corelib/ipc/sharedmemory/dialog.ui` | `ui_dialog.py:22-56` |
| QMainWindow (complex) | `serialbus/modbus/modbusclient/mainwindow.ui` | `ui_mainwindow.py:27-376` |
| QFormLayout | `sql/books/bookwindow.ui` | `ui_bookwindow.py:48-94` |
| QGridLayout + spacers | `serialbus/modbus/modbusclient/mainwindow.ui` | `ui_mainwindow.py:59-86` |
| menus/toolbars/actions | `demos/documentviewer/mainwindow.ui` | `ui_mainwindow.py:114-148` |
| connections | `bluetooth/btscanner/device.ui` | `ui_device.py:75-76` |
| button groups | `widgets/animation/easing/form.ui` | `ui_form.py:54-69` |
| palette/brush | `multimedia/camera/camera.ui` | `ui_camera.py:112-123` |
| combo items | `serialbus/modbus/modbusclient/mainwindow.ui` | `ui_mainwindow.py:97-102,335` |
| tab order | `serialbus/modbus/modbusclient/mainwindow.ui` | `ui_mainwindow.py:295-307` |
