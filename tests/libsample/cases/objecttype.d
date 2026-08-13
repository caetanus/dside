// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import cxxrt : make;
import sample.objecttype, sample.str; import std.stdio; import std.string : fromStringz;
void main() {
    auto o = make!ObjectType();
    auto n = make!Str("root\0".ptr); o.setObjectName(n);
    assert(o.objectName().cstring().fromStringz == "root");
    auto ch = o.createChild(o);
    auto kn = make!Str("kid\0".ptr); ch.setObjectName(kn);
    auto found = o.findChild(kn);
    assert(found !is null && found is ch);
    writeln("objecttype OK");
}
