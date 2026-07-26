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

// The source string of a direct `"literal".tr` receiver (not a deep grab, so `f("x").tr`
// doesn't misfire). null if the receiver isn't a plain string literal.
string directLiteral(const UnaryExpression u) {
    if (u !is null && u.primaryExpression !is null
        && u.primaryExpression.primary.type == tok!"stringLiteral")
        return unquote(u.primaryExpression.primary.text);
    return null;
}

final class TrVisitor : ASTVisitor {
    Msg[] msgs;
    string modCtx;               // module name -> context for tr()/.tr (matches runtime __MODULE__)
    bool[size_t] seenTr;         // tr-token byte indices already emitted (avoid UFCS double count)
    this(string fileBase) { modCtx = fileBase; }
    alias visit = ASTVisitor.visit;

    // `module a.b.c;` -> the dotted name, exactly what D's __MODULE__ yields at a call site.
    override void visit(const ModuleDeclaration m) {
        if (m.moduleName !is null)
            modCtx = m.moduleName.identifiers.map!(t => t.text.idup).join(".");
        super.visit(m);
    }

    // parenless UFCS: `"literal".tr` (incl. chains like `"literal".tr.writeln`).
    override void visit(const UnaryExpression u) {
        if (u.identifierOrTemplateInstance !is null
            && u.identifierOrTemplateInstance.identifier.text == "tr"
            && u.identifierOrTemplateInstance.identifier.index !in seenTr) {
            auto s = directLiteral(u.unaryExpression);
            if (s !is null) msgs ~= Msg(modCtx, s, "");
        }
        super.visit(u);
    }

    override void visit(const FunctionCallExpression c) {
        if (c.unaryExpression !is null) {
            auto ig = new IdGrab; ig.visit(c.unaryExpression);
            auto callee = ig.ids.length ? ig.ids[$-1] : "";
            auto sg = new StrGrab; if (c.arguments !is null) sg.visit(c.arguments);
            auto recv = directLiteral(c.unaryExpression.unaryExpression);   // UFCS `"lit".tr(...)`
            if (callee == "tr") {
                if (recv !is null) {   // "lit".tr("disambig") -> source in receiver, disambig in args
                    msgs ~= Msg(modCtx, recv, sg.strs.length ? sg.strs[0] : "");
                    if (c.unaryExpression.identifierOrTemplateInstance !is null)
                        seenTr[c.unaryExpression.identifierOrTemplateInstance.identifier.index] = true;
                } else if (sg.strs.length) {   // tr("src","disambig")
                    msgs ~= Msg(modCtx, sg.strs[0], sg.strs.length >= 2 ? sg.strs[1] : "");
                }
            } else if (callee == "translate" && sg.strs.length >= 2) {
                msgs ~= Msg(sg.strs[0], sg.strs[1], sg.strs.length >= 3 ? sg.strs[2] : "");
            }
        }
        super.visit(c);   // recurse AFTER marking, so the callee's UnaryExpression sees the mark
    }
}

Msg[] extractD(string src, string file) {
    LexerConfig cfg; cfg.fileName = file;
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto toks = getTokensForParser(cast(ubyte[]) src.dup, cfg, &cache);
    RollbackAllocator ra;
    auto mod = parseModule(toks, file, &ra);
    auto v = new TrVisitor(file.baseName.stripExtension);   // __MODULE__ default = file base
    v.visit(mod);
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
    // Context is the MODULE (matches the runtime tr()'s __MODULE__ default). translate() takes
    // an explicit context. tr()'s disambiguation is the 2nd arg (tr()) or the arg of "x".tr(...).
    auto m = extractD(`
        module myapp;
        class Backend {
            void f() {
                auto a = tr("Hello");                         // classic tr("x")
                auto b = tr("Bye", "farewell");               // tr("x", disambig)
                auto c = QCoreApplication.translate("Ctx", "Explicit");
                obj.tr("Method call");                        // obj.tr("x")
                auto d = "ufcs".tr;                           // "x".tr (parenless UFCS)
                auto e = "ufcs disambig".tr("plural");        // "x".tr(disambig)
                "chained".tr.length;                          // "x".tr.<...>
            }
        }`, "myapp.d");
    assert(m.canFind!(x => x.context == "myapp" && x.source == "Hello"), "tr -> module context");
    assert(m.canFind!(x => x.source == "Bye" && x.comment == "farewell"), "tr disambiguation");
    assert(m.canFind!(x => x.context == "Ctx" && x.source == "Explicit"), "translate explicit ctx");
    assert(m.canFind!(x => x.context == "myapp" && x.source == "Method call"), "obj.tr");
    assert(m.canFind!(x => x.context == "myapp" && x.source == "ufcs"), "\"x\".tr (UFCS)");
    assert(m.canFind!(x => x.source == "ufcs disambig" && x.comment == "plural"), "\"x\".tr(disambig)");
    assert(m.canFind!(x => x.context == "myapp" && x.source == "chained"), "\"x\".tr.chain");
    // no double-count of the UFCS-with-disambig form
    assert(m.count!(x => x.source == "ufcs disambig") == 1, "UFCS disambig counted once");
}
