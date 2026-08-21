// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// A COMSPEC that is not cmd.exe.
//
// Every command this build emits is POSIX shell — `&&`, `[ -nt ]`, `flock`, `sh -c '...'`. D's
// std.process.executeShell, which reggae uses to run them, invokes `%COMSPEC% /C <command>`, and on
// Windows COMSPEC is cmd.exe. cmd.exe then parses `&&`, `|`, `>` and `^` ITSELF, before the inner
// program ever runs, so a command written for sh is torn apart on the way in:
//
//     cmd /C "sh -c \"mkdir -p X && [ -d X ] && echo ok\""
//     '/Users/caetano/qtest' is not recognized as an internal or external command
//
// Escaping for both shells at once is not maintainable: the commands contain double quotes, single
// quotes and brackets, and every escape would have to survive two parsers in sequence.
//
// So this program takes cmd.exe's place. It accepts `/C` (or `/c`) and hands everything after it to
// `sh -c` UNTOUCHED — read from the raw command line rather than from `args`, because Windows'
// argv splitting would already have eaten the quoting before main() sees it.
//
// Build it, then point the environment at it:
//
//     ldc2 -of=shcomspec.exe tools/win/shcomspec.d
//     export COMSPEC=/c/path/to/shcomspec.exe
//
// On any other platform this is not needed and not built: POSIX executeShell already uses sh.
version (Windows):

import core.sys.windows.winbase : GetCommandLineW;
import core.sys.windows.winnt : WCHAR;
import std.conv : to;
import std.process : spawnProcess, wait;
import std.stdio : stderr;
import std.string : strip, stripLeft;

int main() {
    // The raw line, exactly as the caller wrote it: "<this.exe>" /C <command...>
    auto raw = GetCommandLineW().to!wstring.to!string;

    // Skip our own program name, quoted or not.
    size_t i;
    if (raw.length && raw[0] == '"') {
        i = 1;
        while (i < raw.length && raw[i] != '"') i++;
        if (i < raw.length) i++;            // the closing quote
    } else {
        while (i < raw.length && raw[i] != ' ') i++;
    }
    auto rest = raw[i .. $].stripLeft;

    // ...and the switch, which is the only part of cmd.exe's contract we honour.
    if (rest.length >= 2 && rest[0] == '/' && (rest[1] == 'C' || rest[1] == 'c'))
        rest = rest[2 .. $].stripLeft;

    // cmd /C strips ONE surrounding pair of double quotes, and callers rely on it: D's spawnShell
    // hands us `/C "…"` and sh would otherwise try to run the quoted string as a command name —
    // measured, `sh: line 1: C:/: Is a directory`.
    rest = rest.strip;
    if (rest.length >= 2 && rest[0] == '"' && rest[$ - 1] == '"')
        rest = rest[1 .. $ - 1];

    if (!rest.length) {
        stderr.writeln("shcomspec: nothing to run (expected `/C <command>`)");
        return 2;
    }

    // `sh -c` receives the command as ONE argument, so nothing re-parses it.
    try
        return spawnProcess(["sh", "-c", rest]).wait();
    catch (Exception e) {
        stderr.writeln("shcomspec: could not run sh: ", e.msg);
        return 127;
    }
}
