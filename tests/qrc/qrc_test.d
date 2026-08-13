// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// The CTFE .rcc must not only make paths RESOLVE — it must serve the right BYTES. Checking
// QFile.exists alone passed an .rcc whose payload was empty, truncated, or offset by one: every
// name was in the tree and nothing read it. So each resource is opened, read in full, and
// compared byte-for-byte against the file on disk that it was built from.
import qt.widgets.qfile, qt.widgets.qstring;
import qrc;
import std.stdio, std.file : read;
mixin(qrcRegister(import("app.qrc")));   // registers the CTFE .rcc at module init

enum ReadOnly = 1;   // QIODeviceBase::ReadOnly

ubyte[] slurpResource(string path) {
    auto qs = qstr(path);
    auto f = new QFile(qs);
    assert(f.open(ReadOnly), "could not open " ~ path ~ " from the registered .rcc");
    scope(exit) f.close();
    auto ba = f.readAll();
    return ba.toBytes();
}

void main() {
    assert(QFile.exists(":/app/about"), ":/app/about should resolve");
    assert(QFile.exists(":/app/icons/logo.png"), ":/app/icons/logo.png should resolve");
    assert(!QFile.exists(":/app/nope"), "unknown path must not resolve");

    // `about` is reached through its ALIAS, so this also proves the alias maps to the right blob
    // and not merely to some blob.
    auto about = slurpResource(":/app/about");
    auto aboutDisk = cast(ubyte[]) read("tests/qrc/data/about.txt");
    assert(about == aboutDisk,
        ":/app/about payload differs from data/about.txt (got " ~ cast(string) about ~ ")");
    // Also pinned literally: if the generator and the on-disk read were ever wrong in the same
    // direction, comparing them to each other would still agree.
    assert(cast(string) about == "hello from qrc", ":/app/about content is not the expected text");

    // Binary, with a NUL-free but non-text header — catches truncation and text mangling.
    auto logo = slurpResource(":/app/icons/logo.png");
    auto logoDisk = cast(ubyte[]) read("tests/qrc/icons/logo.png");
    assert(logo.length == logoDisk.length,
        "logo.png length mismatch: rcc has bytes but not the right count");
    assert(logo == logoDisk, ":/app/icons/logo.png payload differs from icons/logo.png");

    writefln("qrc OK: CTFE .rcc resolves and serves EXACT bytes (about=%d B via alias, "
             ~ "logo.png=%d B binary); :/app/nope does not resolve", about.length, logo.length);
}
