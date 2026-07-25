// composition: value class that owns an ObjectType* internally; const char* ctor;
// virtual method returning Str by value from the aggregated member.
import sample.objecttypeholder, sample.str;
import std.stdio; import std.string : fromStringz;
void main() {
    auto h = ObjectTypeHolder_new("held\0".ptr);   // const char* ctor (creates the inner ObjectType)
    auto s = h.callPassObjectTypeAsReference();     // Str by value <- member's objectName
    assert(s.cstring().fromStringz == "held", "holder passthrough objectName");
    writeln("objecttypeholder OK");
}
