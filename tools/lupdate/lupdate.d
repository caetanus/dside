// lupdate-d — a D-aware lupdate (CRITICS/PySide side-car): parse D source with libdparse and
// extract translatable strings from tr("...") / [QCoreApplication.]translate("Ctx","src") calls
// into a Qt .ts file. Qt's own lupdate can't read D; dparse gives us the AST so we don't guess
// with regex. (.ui strings are covered separately via the uic parser — see runtime/uic.)
module lupdate;
import dparse.lexer, dparse.parser, dparse.ast, dparse.rollback_allocator;
import std.stdio, std.file, std.array, std.algorithm, std.string, std.conv, std.process, std.path;

struct Msg { string context, source, comment; }

// Grabs every string-literal token under a node (args are usually a direct literal).
final class StrGrab : ASTVisitor {
    string[] strs;
    alias visit = ASTVisitor.visit;
    override void visit(const PrimaryExpression p) {
        if (p.primary.type == tok!"stringLiteral") strs ~= unquote(p.primary.text);
        super.visit(p);
    }
}
// Grabs identifiers in order (the callee's LAST id is the method name: A.B.translate -> translate).
final class IdGrab : ASTVisitor {
    string[] ids;
    alias visit = ASTVisitor.visit;
    override void visit(const Token t) { if (t.type == tok!"identifier") ids ~= t.text.idup; }
    override void visit(const IdentifierOrTemplateInstance i) {
        if (i.identifier.type == tok!"identifier") ids ~= i.identifier.text.idup;
        super.visit(i);
    }
}

string unquote(string s) {   // "Hello" / `raw` / q{...} -> the text (basic: strip matching quotes)
    if (s.length >= 2 && (s[0] == '"' || s[0] == '`') && s[$-1] == s[0]) {
        s = s[1 .. $-1];
        // minimal unescape for the common cases in .ui-free hand-written tr()
        s = s.replace(`\"`, `"`).replace(`\\`, `\`).replace(`\n`, "\n").replace(`\t`, "\t");
    }
    return s;
}

final class TrVisitor : ASTVisitor {
    Msg[] msgs;
    string ctx = "";                      // enclosing class/struct -> context for bare tr()
    alias visit = ASTVisitor.visit;
    override void visit(const ClassDeclaration d) { auto o = ctx; ctx = d.name.text.idup; super.visit(d); ctx = o; }
    override void visit(const StructDeclaration d) { auto o = ctx; ctx = d.name.text.idup; super.visit(d); ctx = o; }
    override void visit(const FunctionCallExpression c) {
        super.visit(c);   // recurse first (nested calls)
        if (c.unaryExpression is null || c.arguments is null) return;
        auto ig = new IdGrab; ig.visit(c.unaryExpression);
        if (!ig.ids.length) return;
        auto callee = ig.ids[$-1];
        auto sg = new StrGrab; sg.visit(c.arguments);
        if (callee == "tr" && sg.strs.length >= 1)
            msgs ~= Msg(ctx, sg.strs[0], sg.strs.length >= 2 ? sg.strs[1] : "");
        else if (callee == "translate" && sg.strs.length >= 2)
            msgs ~= Msg(sg.strs[0], sg.strs[1], sg.strs.length >= 3 ? sg.strs[2] : "");
    }
}

Msg[] extractD(string src, string file) {
    LexerConfig cfg; cfg.fileName = file;
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto toks = getTokensForParser(cast(ubyte[]) src.dup, cfg, &cache);
    RollbackAllocator ra;
    auto mod = parseModule(toks, file, &ra);
    auto v = new TrVisitor; v.visit(mod);
    return v.msgs;
}

// The Qt companion tools (they own .ui/.qml and the .ts merge). Found on PATH or qt6 bin.
string qtTool(string n) {
    foreach (p; ["/usr/lib/qt6/bin/"~n, "/usr/bin/"~n, n]) if (p == n || exists(p)) return p;
    return n;
}

version (unittest) {} else
void main(string[] args) {
    string[] dfiles, uiqml; string tsOut = "out.ts";
    for (size_t i = 1; i < args.length; i++) {
        auto a = args[i];
        if (a == "-ts" && i + 1 < args.length) { tsOut = args[++i]; continue; }
        if (a.endsWith(".d")) dfiles ~= a;
        else if (a.endsWith(".ui") || a.endsWith(".qml")) uiqml ~= a;   // Qt's lupdate owns these
    }

    string[] parts;   // per-source .ts files to merge

    // D sources -> OUR extractor (dparse). Qt's lupdate can't read D; this is the whole point.
    if (dfiles.length) {
        Msg[] all;
        foreach (f; dfiles) all ~= extractD(readText(f), f);
        auto dts = tsOut ~ ".d.ts";
        std.file.write(dts, tsDoc(all));
        parts ~= dts;
    }
    // .ui / .qml -> Qt's normal lupdate (it handles those natively; the "gotcha" lives there).
    if (uiqml.length) {
        auto qts = tsOut ~ ".ui.ts";
        auto r = execute([qtTool("lupdate")] ~ uiqml ~ ["-ts", qts, "-no-obsolete", "-silent"]);
        if (r.status != 0) stderr.writeln("qt lupdate: ", r.output);
        if (exists(qts)) parts ~= qts;
    }

    // Merge with Qt's lconvert (it dedups + preserves existing translations across .ts files).
    if (parts.length == 1) rename(parts[0], tsOut);
    else if (parts.length > 1) {
        auto r = execute([qtTool("lconvert")] ~ parts ~ ["-o", tsOut]);
        if (r.status != 0) stderr.writeln("lconvert: ", r.output);
        foreach (p; parts) if (exists(p)) remove(p);
    }
    writefln("lupdate-d: %d D source(s), %d ui/qml -> %s", dfiles.length, uiqml.length, tsOut);
}

// Build a Qt .ts document from extracted messages (one <context> per name, sorted/diffable).
string tsDoc(Msg[] all) {
    all.sort!((a,b) => a.context < b.context || (a.context == b.context && a.source < b.source));
    string ts = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE TS>\n<TS version=\"2.1\">\n";
    string cur;
    foreach (m; all) {
        if (m.context != cur) { if (cur.length) ts ~= "</context>\n"; ts ~= "<context>\n    <name>" ~ xesc(m.context) ~ "</name>\n"; cur = m.context; }
        ts ~= "    <message>\n        <source>" ~ xesc(m.source) ~ "</source>\n";
        if (m.comment.length) ts ~= "        <comment>" ~ xesc(m.comment) ~ "</comment>\n";
        ts ~= "        <translation type=\"unfinished\"></translation>\n    </message>\n";
    }
    if (cur.length) ts ~= "</context>\n";
    return ts ~ "</TS>\n";
}

string xesc(string s) { return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;"); }

unittest {
    // tr() takes the enclosing class as context; translate() takes an explicit context;
    // the 2nd arg of tr() is a disambiguation comment.
    auto m = extractD(`
        class Backend {
            void f() {
                auto a = tr("Hello");
                auto b = tr("Bye", "farewell");
                auto c = QCoreApplication.translate("Ctx", "Explicit");
                obj.tr("Method call");
            }
        }`, "t.d");
    assert(m.canFind!(x => x.context == "Backend" && x.source == "Hello"), "tr -> class context");
    assert(m.canFind!(x => x.source == "Bye" && x.comment == "farewell"), "tr disambiguation");
    assert(m.canFind!(x => x.context == "Ctx" && x.source == "Explicit"), "translate explicit ctx");
    assert(m.canFind!(x => x.context == "Backend" && x.source == "Method call"), "obj.tr");
}
