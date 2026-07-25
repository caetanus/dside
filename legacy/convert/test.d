// Proves the conversion layer: QString<->string and QList<int> as a D range.
import qtd_convert;
import std.stdio : writeln;
import std.algorithm : map, filter, sum;
import std.array : array;

void main() {
    // QString <-> string (utf8, incl. multibyte)
    void* q = toQString("héllo qt");
    string back = toDString(q);
    assert(back == "héllo qt");
    qtd_qstring_delete(q);
    writeln("QString<->string OK: '", back, "'");

    // QList<int> exposed as a native D range
    void* lst = qtd_qlist_int_new();
    scope (exit) qtd_qlist_int_delete(lst);
    foreach (v; [1, 2, 3, 4, 5]) qtd_qlist_int_append(lst, v);

    int[] collected;
    foreach (x; QListIntRange(lst)) collected ~= x;      // foreach over Qt container
    assert(collected == [1, 2, 3, 4, 5]);

    auto evensSquared = QListIntRange(lst)
        .filter!(x => x % 2 == 0)
        .map!(x => x * x)
        .sum;                                            // std.algorithm just works
    assert(evensSquared == 4 + 16);                      // 2^2 + 4^2

    writeln("QList<int> as D range OK: foreach + filter+map+sum = ", evensSquared);

    // QHash<QString,QString> <-> string[string]  (the "QHashMap = AA" case)
    string[string] aa = ["host": "localhost", "port": "6379", "db": "0"];
    void* qh = toQHashSS(aa);
    scope (exit) qtd_qhashss_delete(qh);
    assert(qtd_qhashss_size(qh) == 3);
    string[string] rt = fromQHashSS(qh);
    assert(rt == aa);
    writeln("QHash<QString,QString> <-> string[string] OK: ", rt);

    writeln("ALL CONVERSIONS OK");
}
