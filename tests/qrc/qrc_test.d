import qt.widgets.qfile;
import qrc;
import std.stdio;
mixin(qrcRegister(import("app.qrc")));   // registers the CTFE .rcc at module init
void main() {
    assert(QFile.exists(":/app/about"), ":/app/about should resolve");
    assert(QFile.exists(":/app/icons/logo.png"), ":/app/icons/logo.png should resolve");
    assert(!QFile.exists(":/app/nope"), "unknown path must not resolve");
    writeln("qrc OK: CTFE .rcc registered; :/app/about + :/app/icons/logo.png resolve, :/app/nope does not");
}
