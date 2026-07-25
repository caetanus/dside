import sample.objecttype, sample.str; import std.stdio; import std.string : fromStringz;
void main() {
    auto o = ObjectType_new();
    auto n = Str_new("root\0".ptr); o.setObjectName(n);
    assert(o.objectName().cstring().fromStringz == "root");
    auto ch = o.createChild(o);
    auto kn = Str_new("kid\0".ptr); ch.setObjectName(kn);
    auto found = o.findChild(kn);
    assert(found !is null && found is ch);
    writeln("objecttype OK");
}
