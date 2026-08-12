// RUNTIME BOUNDARY RATCHET (critics r9 #2 / r11 #5).
//
// The audit has said for five rounds that a QML COMPILER's state and lifecycle live inside the
// shared meta-object runtime, and that the fix is a `qmltc_runtime` unit linked only by the
// bindings that need it. It is still not done — and the reason it is still not done is measurable:
// every other finding that closed had a named target following it, and this one had none. Twice in
// one day I made this boundary WORSE while closing findings that did have gates.
//
// So this is the gate. It does not draw the boundary; it stops the boundary from receding. Two
// numbers, both counted from the source and both fail-closed on GROWTH:
//
//   * qml_fns  — `extern "C"` functions in runtime/qtmoc/qtdmoc.cpp whose body touches QQml/QQuick.
//                Today 30 of 62: half of the shared runtime is QML. This is the number the audit
//                is actually complaining about, and it cannot be gamed except by moving code out.
//   * d_state  — module-level MUTABLE globals in runtime/qtmoc/qtmoc.d whose names mark them as
//                compiler state (`__`-prefixed). Today 3, two of which were added on 2026-08-12.
//
// Growth fails. Shrinking passes and asks for the baseline to come down with it, so the ratchet
// only ever turns one way. Raising a baseline is allowed and is meant to be uncomfortable: it takes
// an edit to a checked-in file, which is exactly the deliberate act that was missing.
module runtime_boundary;

import std.file : readText, exists;
import std.stdio : writefln, stderr;
import std.regex : regex, matchFirst, matchAll, ctRegex;
import std.string : strip, startsWith, splitLines;
import std.conv : to;
import std.algorithm : canFind;

// `extern "C" <ret> qtd_name(args) {` … matching brace at column 0. The runtime writes every
// exported function that way, which is what makes a brace-at-column-0 scan exact here rather than
// a guess: a nested `}` is always indented.
int qmlFunctions(string src)
{
    auto lines = src.splitLines;
    auto head = regex(`^extern "C"\s+[\w:<>*&\s]+?\b(qtd_\w+)\s*\(`);
    int hits;
    for (size_t i = 0; i < lines.length; ++i)
    {
        auto m = lines[i].matchFirst(head);
        if (m.empty) continue;
        string body_;
        for (size_t j = i + 1; j < lines.length; ++j)
        {
            if (lines[j].startsWith("}")) break;
            body_ ~= lines[j] ~ "\n";
        }
        if (body_.canFind("QQml") || body_.canFind("QQuick")
                || body_.canFind("qmlEngine") || body_.canFind("qmlContext"))
            ++hits;
    }
    return hits;
}

// A module-level mutable global whose name marks it as runtime state for compiled documents.
// `private <type> __name = …;` or `private <type> __name;` at column 0.
int compilerState(string src)
{
    auto re = regex(`^private\s+[\w!\[\]\*\(\)\.]+\s+__\w+\s*(=|;)`);
    int hits;
    foreach (l; src.splitLines)
        if (!l.matchFirst(re).empty) ++hits;
    return hits;
}

int main(string[] args)
{
    if (args.length < 4)
    {
        stderr.writefln("usage: runtime_boundary <qtdmoc.cpp> <qtmoc.d> <baseline>");
        return 2;
    }
    immutable fns = qmlFunctions(readText(args[1]));
    immutable st  = compilerState(readText(args[2]));

    int baseFns = -1, baseSt = -1;
    if (exists(args[3]))
        foreach (l; readText(args[3]).splitLines)
        {
            auto t = l.strip;
            if (t.length == 0 || t[0] == '#') continue;
            if (t.startsWith("qml_fns")) baseFns = t["qml_fns".length .. $].strip.to!int;
            if (t.startsWith("d_state")) baseSt  = t["d_state".length .. $].strip.to!int;
        }
    if (baseFns < 0 || baseSt < 0)
    {
        stderr.writefln("runtime-boundary: baseline %s is missing qml_fns/d_state", args[3]);
        return 1;
    }

    int rc;
    if (fns > baseFns)
    {
        stderr.writefln("runtime-boundary FAIL: %d extern \"C\" functions in the SHARED runtime now "
                        ~ "touch QQml/QQuick (baseline %d). The boundary the audit has asked for "
                        ~ "since round 9 just receded further. Move it to a qmltc runtime unit, or "
                        ~ "raise the baseline deliberately and say why.", fns, baseFns);
        rc = 1;
    }
    if (st > baseSt)
    {
        stderr.writefln("runtime-boundary FAIL: %d module-level mutable globals of compiler state "
                        ~ "in qtmoc.d (baseline %d). Same boundary, D side.", st, baseSt);
        rc = 1;
    }
    if (rc) return rc;

    if (fns < baseFns || st < baseSt)
    {
        writefln("runtime-boundary OK, AND IT SHRANK: qml_fns %d (baseline %d), d_state %d "
                 ~ "(baseline %d) — lower the baseline so the ratchet keeps its grip.",
                 fns, baseFns, st, baseSt);
        return 0;
    }
    writefln("runtime-boundary OK: qml_fns=%d d_state=%d (at baseline; it may only go down)",
             fns, st);
    return 0;
}
