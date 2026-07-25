import sample.listuser; import std.stdio;
void main() {
    auto lu = ListUser_new();
    assert(lu !is null);
    writeln("listuser OK");
}
