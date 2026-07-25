import sample.event, sample.brush; import std.stdio;
void main() {
    assert(Event.EventType.SOME_EVENT == 2);
    assert(Event.EventTypeClass.Value2 == 1);
    assert(Brush.Style.Cross == 1);
    writeln("enums OK");
}
