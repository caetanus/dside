// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CONSUMER: an application that is not part of this repository's test graph.
//
// Everything else here is built by reggae, from inside the checkout, with paths the build knows.
// That proves the binding COMPILES; it does not prove anyone else can use it, and round 12 of the
// audit was right that nothing had ever tried. This file is copied to a temporary directory and
// built there against nothing but the generated import path and the two archives — the same three
// arguments a real project would put in its dub.json.
//
// It is deliberately the most ordinary program there is. The two frictions it found on the first
// attempt are recorded in docs/FEATURES.md, and both are the kind only a consumer meets:
//   * `new QWidget(null)` does not compile — a literal null is ambiguous between the adopt ctor
//     `this(void*)` and `this(QWidget parent = null, ...)`. `new QWidget()` is the spelling.
//   * `w.width()` does not exist. QWidget inherits it from QPaintDevice, its SECOND base, so it is
//     reached through `asQPaintDevice()`. The manifest calls it `inherited`, which is true and
//     surprising.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlabel;
import cxxrt;
import std.stdio : writeln;

import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void* self, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "hello\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    auto w = new QWidget(null);   // a literal null used to be ambiguous with the adopt ctor
    auto l = new QLabel(w);          // parented: Qt owns it, the wrapper is pinned
    l.setText("hello from D");
    w.resize(200, 60);

    assert(l.text() == "hello from D", "the label did not keep its text");
    assert(w.asQPaintDevice().width() == 200 && w.asQPaintDevice().height() == 60,
           "resize did not take effect");
    writeln("consumer OK: ", l.text(), " / widget ",
            w.asQPaintDevice().width(), "x", w.asQPaintDevice().height());
}
