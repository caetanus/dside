// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// What using a xiboca-generated binding for YOUR OWN C++ looks like from D.
// Nothing here is Qt-framework code: Shape and Circle are declared in
// examples/userlib/shape.h and implemented in shape.cpp.
//
// Its output is compared against expected.txt by tests/xiboca-quickstart.sh, so
// this file is documentation the build refuses to let go stale.
import userlib.shape, userlib.circle;
import std.stdio;

void main() {
    // __make is the emitted factory: it allocates with C++ `new` and then calls
    // your constructor, so the object is a real C++ object and Qt's parenting
    // works on it exactly as it does in C++.
    auto s = Shape.__make(null);
    s.setSize(4, 4);

    writeln("area      = ", s.area());
    writeln("describe  = ", s.describe().toString);   // QString -> D string
    writeln("isSquare  = ", s.isSquare());
    writeln("counts    = ", s.counts());              // QHash<QString,int> -> int[string]
    writeln("tags      = ", s.tags());                // QMap<QString,QString> -> string[string]

    // A plain C++ value type, no QObject involved.
    auto c = Circle.__make(7);
    writefln("circle    = r%d, circumference %.3f", c.radius(), c.circumference());
}
