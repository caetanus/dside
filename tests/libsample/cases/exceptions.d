import sample.exceptiontest;
import std.stdio;
void main() {
    auto e = ExceptionTest_new();
    // caminho SEM throw (false) -> retorna 1. (throw C++ atravessando pro D é gap
    //  separado — ABIs de exceção diferentes; não testado aqui.)
    assert(e.intThrowStdException(false) == 1, "exception no-throw path");
    writeln("exceptions OK");
}
