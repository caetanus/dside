// COMPILER CONTEXT RATCHET (critics r4 #3 / r9 #4 / r10 #6 / r11 #6).
//
// Twin of tests/runtime_boundary.d, for the other finding that survived five rounds without a
// target behind it. The audit's words, round 11: "dezenas de globais mutáveis… Muitos comentários
// dizem que um campo é 'saved/restored around compileObject'. Isso é um `DocumentContext` implícito
// distribuído pelo arquivo." It was right, it is still true, and the file grew 7% since it said so.
//
// This does not introduce the CompilationContext. It stops the implicit one from spreading, with
// two numbers counted from the source and both fail-closed on GROWTH:
//
//   * globals   — file-scope mutable `static … g_… ;` in tools/qmltc/qmltc_d.cpp. The context that
//                 has no type.
//   * ctxsaves  — sites that save a global to restore it later (`<T> savedX = g_…`). This is the
//                 implicit context MADE VISIBLE: every one of them is a scope that a real
//                 CompilationContext would own. Checked by hand on 2026-08-12: all 51 do restore —
//                 nine of them on multi-assignment lines, which is why a line-anchored count of
//                 restores reads lower and must not be used as the metric.
//
// Growth fails. Shrinking passes and asks for the baseline to come down. Raising it takes an edit
// to a checked-in file plus a reason, which is the deliberate act that was missing for five rounds.
module compiler_context;

import std.file : readText, exists;
import std.stdio : writefln, stderr;
import std.regex : regex, matchFirst;
import std.string : strip, startsWith, splitLines, indexOf;
import std.conv : to;

// `static <type> g_name = …;` / `static <type> g_name;` / `static <type> g_name[…]` at column 0,
// excluding `const`, which is not state.
int fileGlobals(string src)
{
    auto re = regex(`^static\s+[\w:<>,\s\*&]+?\bg_\w+\s*(=|;|\[)`);
    int hits;
    foreach (l; src.splitLines)
    {
        if (l.indexOf(" const ") >= 0 || l.startsWith("static const")) continue;
        if (!l.matchFirst(re).empty) ++hits;
    }
    return hits;
}

// A site that saves a global to put it back later: the implicit context, one scope at a time.
int contextSaves(string src)
{
    auto re = regex(`\b(?:auto|std::\w+[\w:<>,\s]*)\s+saved\w*\s*=\s*g_\w+`);
    int hits;
    foreach (l; src.splitLines)
        if (!l.matchFirst(re).empty) ++hits;
    return hits;
}

int main(string[] args)
{
    if (args.length < 3)
    {
        stderr.writefln("usage: compiler_context <qmltc_d.cpp> <baseline>");
        return 2;
    }
    immutable src = readText(args[1]);
    immutable g = fileGlobals(src);
    immutable c = contextSaves(src);

    int bg = -1, bc = -1;
    if (exists(args[2]))
        foreach (l; readText(args[2]).splitLines)
        {
            auto t = l.strip;
            if (t.length == 0 || t[0] == '#') continue;
            if (t.startsWith("globals"))  bg = t["globals".length .. $].strip.to!int;
            if (t.startsWith("ctxsaves")) bc = t["ctxsaves".length .. $].strip.to!int;
        }
    if (bg < 0 || bc < 0)
    {
        stderr.writefln("compiler-context: baseline %s is missing globals/ctxsaves", args[2]);
        return 1;
    }

    int rc;
    if (g > bg)
    {
        stderr.writefln("compiler-context FAIL: %d file-scope mutable globals in qmltc_d.cpp "
                        ~ "(baseline %d). The implicit DocumentContext the audit named in round 11 "
                        ~ "just grew again. Give the new state an owner, or raise the baseline "
                        ~ "deliberately and say why.", g, bg);
        rc = 1;
    }
    if (c > bc)
    {
        stderr.writefln("compiler-context FAIL: %d save/restore sites of global state (baseline "
                        ~ "%d). Each one is a scope a real CompilationContext would own.", c, bc);
        rc = 1;
    }
    if (rc) return rc;

    if (g < bg || c < bc)
    {
        writefln("compiler-context OK, AND IT SHRANK: globals %d (baseline %d), ctxsaves %d "
                 ~ "(baseline %d) — lower the baseline so the ratchet keeps its grip.", g, bg, c, bc);
        return 0;
    }
    writefln("compiler-context OK: globals=%d ctxsaves=%d (at baseline; it may only go down)", g, c);
    return 0;
}
