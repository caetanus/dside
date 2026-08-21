// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
#include "probe.cpp"
Widget::Widget(int a, int b) : w(a), h(b) {}
Sz  Widget::size() const { return Sz{w, h}; }
int Widget::area() const { return w * h; }
void Widget::grow(int by) { w += by; h += by; }
extern "C" Widget* mk(int a, int b) { return new Widget(a, b); }
