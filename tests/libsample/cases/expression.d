// The operators were invoked and their results thrown away, so `a + b` merely COMPILING was the
// whole test: an opBinary that returned a default-constructed Expression, or that swapped its
// operands, still printed OK. Expression::toString() is std::string and is not bound, but the
// struct's layout is, so the node each operator builds is observable directly.
//
// UPSTREAM BUG, deliberately asserted as-is: libsample's Expression::operator- sets
// m_operation = Add (expression.cpp), exactly like operator+. That is pyside-setup's bug, not
// the binding's — the binding is faithful, and pinning the real behaviour is what makes this a
// regression test rather than a wish. (The same file also has `case GreaterThan: s << '<';`.)
// So the two operators are told apart by the OPERANDS they capture, not by the operation code.
//
// Not covered: operator< / operator> are faithful in C++ (LessThan/GreaterThan) but the
// generator does not bind them — D's opCmp must return an int, and these return Expression.
import sample.expression;
import std.stdio;

// m_operation is Expression::Operation, laid out as 4 opaque bytes in the generated struct.
uint opOf(ref Expression e) { return *cast(uint*) e.m_operation.ptr; }
// m_operand1/2 are std::shared_ptr<Expression>; the first word is the pointee.
Expression* operand1(ref Expression e) { return *cast(Expression**) e.m_operand1.ptr; }
Expression* operand2(ref Expression e) { return *cast(Expression**) e.m_operand2.ptr; }

void main() {
    auto a = Expression(5), b = Expression(3);
    assert(a.m_value == 5 && b.m_value == 3, "Expression(int) did not store its value");
    assert(opOf(a) == Expression.Operation.None, "a leaf expression must have Operation.None");

    auto sum = a + b;                      // opBinary!"+" -> C++ operator+
    assert(opOf(sum) == Expression.Operation.Add, "opBinary!\"+\" did not reach operator+");
    assert(operand1(sum) !is null && operand2(sum) !is null,
        "operator+ produced a node with no operands");
    // Operand ORDER is the real check: a swapped binding would give 3 then 5.
    assert(operand1(sum).m_value == 5 && operand2(sum).m_value == 3,
        "operator+ captured its operands in the wrong order");

    auto dif = a - b;                      // opBinary!"-" -> C++ operator- (see UPSTREAM BUG)
    assert(opOf(dif) == Expression.Operation.Add,
        "libsample's operator- sets Add; if this now says Sub, upstream fixed the bug — "
        ~ "update this test rather than the binding");
    assert(operand1(dif) !is null && operand2(dif) !is null,
        "operator- produced a node with no operands");
    assert(operand1(dif).m_value == 5 && operand2(dif).m_value == 3,
        "operator- captured its operands in the wrong order");

    // The two calls must build SEPARATE nodes — one shared return buffer would alias them.
    assert(operand1(sum) !is operand1(dif), "+ and - returned aliased operand nodes");

    auto rev = b - a;                      // operand order must follow the expression
    assert(operand1(rev).m_value == 3 && operand2(rev).m_value == 5,
        "b - a captured operands as if it were a - b");

    writeln("expression OK: Expression(int) stores its value; + and - build distinct nodes "
            ~ "capturing both operands in order (operation code is Add for both — upstream bug)");
}
