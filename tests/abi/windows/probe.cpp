// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
struct Sz { int w, h; };
class Widget {
public:
    Widget(int a, int b);
    Sz size() const;          // value return: needs an sret slot
    int area() const;         // plain const member
    void grow(int by);        // mutates
private:
    int w, h;
};
