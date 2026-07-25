import sample.bytearray; import std.stdio;
void main() {
    auto b = ByteArray("abc\0".ptr);
    assert(b.size()==3 && b.at(0)=='a' && b.at(2)=='c');
    auto h1 = ByteArray.hash(b);
    auto b2 = ByteArray("abc\0".ptr);
    assert(b == b2 && ByteArray.hash(b2)==h1);
    writeln("bytearray OK");
}
