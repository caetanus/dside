// CRITICS round-4 #6 — "silêncio puro tem que acabar". A @Slot invoked by Qt must be nothrow
// (a D exception can't cross the C++ frame), but swallowing it silently hides bugs. The policy
// (qtmoc.qtdOnCallbackError) records it instead: a count + last-error + optional hook. This test
// makes a slot throw during real signal dispatch and asserts the policy SAW it — not a crash,
// not silence.
import qtmoc;
import cxxrt, std.stdio;

@QObject class Src { Signal!int go; }

@QObject class Boom {
    int calls = 0;
    @Slot void explode(int v) { calls++; throw new Exception("boom in a slot"); }
}

void main() {
    auto src  = newQObject!Src();
    auto boom = newQObject!Boom();
    connectMeta(src, "go(int)", boom, "explode(int)");   // D signal -> D slot (direct dispatch)

    // opt-in hook: prove the global sink fires too.
    __gshared int hookHits = 0;
    qtdCallbackErrorHook = (Throwable e) nothrow { hookHits++; };

    auto before = qtdCallbackErrors;
    src.go.emit(42);   // -> explode() throws -> policy catches at the boundary (no crash)

    assert(boom.calls == 1, "o slot foi de fato invocado");
    assert(qtdCallbackErrors == before + 1, "a policy tem que CONTAR a exceção do slot, não engolir");
    assert(qtdLastCallbackError !is null && qtdLastCallbackError.msg == "boom in a slot", "last-error registrado");
    assert(hookHits == 1, "o hook global tem que ter disparado");

    writeln("cannon/t11 OK: slot exception -> policy counted+recorded (no crash, no silent swallow)");
}
