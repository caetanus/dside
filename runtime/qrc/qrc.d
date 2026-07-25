// qrc.d — a compile-time (CTFE) rcc: turn a .qrc + its files (embedded via D's import())
// into the Qt resource blob and register it, so `:/prefix/alias` paths resolve. No rcc
// tool — same philosophy as the CTFE moc/uic.
//
//   mixin(qrcRegister(import("app.qrc")));   // -J points at the .qrc + resource files
//
// The blob is Qt's version-3 .rcc format (as `rcc --binary` produces): a header + a data
// section ([len32][bytes] per file), a name section ([len16][hash32][utf16] per segment),
// and a struct section (22-byte tree entries, children sorted by hash for binary search).
// QResource.registerResource(blob) parses it.
module qrc;

// ---------- big-endian encoders ----------
private ubyte[] be16(uint v) { return [cast(ubyte)(v >> 8), cast(ubyte)(v & 0xff)]; }
private ubyte[] be32(uint v) {
    return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte)(v)];
}
private ubyte[] utf16be(string s) {   // BMP only (resource names are ASCII/BMP)
    ubyte[] r;
    foreach (dchar c; s) { r ~= cast(ubyte)(cast(uint) c >> 8); r ~= cast(ubyte)(cast(uint) c & 0xff); }
    return r;
}

// Qt's classic string hash, used by the resource name tree (verified: "bb" -> 0x682).
private uint qtHash(string s) {
    uint h = 0;
    foreach (dchar c; s) {
        h = (h << 4) + cast(uint) c;
        h ^= (h & 0xf0000000) >> 23;
        h &= 0x0fffffff;
    }
    return h;
}

// ---------- one file in the .qrc ----------
struct QrcFile {
    string[] path;                 // resource path segments, e.g. ["app","icons","logo.png"]
    immutable(ubyte)[] data;       // the file bytes (from import(...))
}

private final class RNode {
    string name;
    RNode[] kids;
    immutable(ubyte)[] data;
    bool isFile;
    int idx, childOff;
    uint nameOff, dataOff;
    RNode kid(string n) { foreach (k; kids) if (k.name == n) return k; return null; }
}

// Build the version-3 .rcc blob from the files. CTFE-evaluable.
immutable(ubyte)[] buildRcc(QrcFile[] files) {
    auto root = new RNode;
    foreach (f; files) {           // grow the tree
        auto cur = root;
        foreach (i, seg; f.path) {
            auto k = cur.kid(seg);
            if (k is null) { k = new RNode; k.name = seg; cur.kids ~= k; }
            cur = k;
        }
        cur.isFile = true;
        cur.data = f.data;
    }

    // Layout: BFS; each dir's children are a contiguous block, sorted by hash.
    RNode[] order = [root];
    for (size_t qi = 0; qi < order.length; qi++) {
        auto n = order[qi];
        if (n.isFile || n.kids.length == 0) continue;
        for (size_t a = 1; a < n.kids.length; a++)   // insertion sort by hash
            for (size_t b = a; b > 0 && qtHash(n.kids[b].name) < qtHash(n.kids[b - 1].name); b--) {
                auto t = n.kids[b]; n.kids[b] = n.kids[b - 1]; n.kids[b - 1] = t;
            }
        n.childOff = cast(int) order.length;
        foreach (k; n.kids) { k.idx = cast(int) order.length; order ~= k; }
    }

    // Name section (deduped by segment) + data section (per file).
    ubyte[] nameSec, dataSec;
    uint[string] nameAt;
    foreach (n; order) {
        if (n is root) { n.nameOff = 0; continue; }
        if (auto p = n.name in nameAt) n.nameOff = *p;
        else {
            n.nameOff = cast(uint) nameSec.length;
            nameAt[n.name] = n.nameOff;
            nameSec ~= be16(cast(uint) n.name.length) ~ be32(qtHash(n.name)) ~ utf16be(n.name);
        }
        if (n.isFile) {
            n.dataOff = cast(uint) dataSec.length;
            dataSec ~= be32(cast(uint) n.data.length) ~ cast(ubyte[]) n.data.dup;
        }
    }

    // Struct section: 22 bytes/entry. dir = name flags(2) childCount(4) childOff(4) mtime(8);
    // file = name flags(0) territory(0) language(1) dataOff(4) mtime(8).  mtime = 0.
    ubyte[] structSec;
    foreach (n; order) {
        structSec ~= be32(n.nameOff);
        if (n.isFile)
            structSec ~= be16(0) ~ be16(0) ~ be16(1) ~ be32(n.dataOff) ~ be32(0) ~ be32(0);
        else
            structSec ~= be16(2) ~ be32(cast(uint) n.kids.length) ~ be32(n.childOff) ~ be32(0) ~ be32(0);
    }

    // Header: "qres" + version 3 + tree/data/name offsets + overall flags. Sections follow.
    enum uint hdr = 24, ver = 3;
    uint dataOff = hdr, nameOff = hdr + cast(uint) dataSec.length;
    uint treeOff = nameOff + cast(uint) nameSec.length;
    ubyte[] blob = cast(ubyte[])"qres".dup ~ be32(ver) ~ be32(treeOff) ~ be32(dataOff)
        ~ be32(nameOff) ~ be32(0) ~ dataSec ~ nameSec ~ structSec;
    return blob.idup;
}

// ---------- .qrc parsing + mixin generation ----------

// Minimal .qrc reader: <RCC><qresource prefix="/p"><file alias="a">rel/path</file>…
private struct QF { string prefix, alias_, path; }

private string attrVal(string s, size_t tagStart, string attr) {
    // find `attr="…"` within the tag starting at tagStart (up to the next '>')
    size_t end = tagStart;
    while (end < s.length && s[end] != '>') end++;
    string needle = attr ~ "=\"";
    for (size_t i = tagStart; i + needle.length < end; i++)
        if (s[i .. i + needle.length] == needle) {
            size_t v = i + needle.length, e = v;
            while (e < s.length && s[e] != '"') e++;
            return s[v .. e];
        }
    return "";
}

private QF[] parseQrc(string xml) {
    QF[] out_;
    string prefix;
    for (size_t i = 0; i < xml.length;) {
        if (xml[i] != '<') { i++; continue; }
        if (i + 10 < xml.length && xml[i + 1 .. i + 10] == "qresource") {
            prefix = attrVal(xml, i, "prefix");
            i += 10;
        } else if (i + 5 < xml.length && xml[i + 1 .. i + 5] == "file") {
            string al = attrVal(xml, i, "alias");
            size_t t = i;
            while (t < xml.length && xml[t] != '>') t++;   // to end of <file …>
            size_t v = t + 1, e = v;
            while (e < xml.length && xml[e] != '<') e++;    // the path text
            // trim
            while (v < e && (xml[v] == ' ' || xml[v] == '\n' || xml[v] == '\t' || xml[v] == '\r')) v++;
            size_t ee = e;
            while (ee > v && (xml[ee - 1] == ' ' || xml[ee - 1] == '\n' || xml[ee - 1] == '\t' || xml[ee - 1] == '\r')) ee--;
            out_ ~= QF(prefix, al, xml[v .. ee]);
            i = e;
        } else i++;
    }
    return out_;
}

private string[] splitSlash(string s) {
    string[] r;
    size_t start = 0;
    foreach (i, c; s) if (c == '/') { if (i > start) r ~= s[start .. i]; start = i + 1; }
    if (start < s.length) r ~= s[start .. $];
    return r;
}

// Generate the D that embeds every file via import(), builds the blob, and registers it at
// module init. Resource path = prefix + '/' + (alias or the file's basename path).
string qrcRegister(string qrcXml) {
    auto files = parseQrc(qrcXml);
    string entries;
    foreach (f; files) {
        // resource path segments: prefix segments + (alias ? alias : path segments)
        auto segs = splitSlash(f.prefix) ~ (f.alias_.length ? [f.alias_] : splitSlash(f.path));
        string segLit = "[";
        foreach (i, s; segs) segLit ~= (i ? ", " : "") ~ "\"" ~ s ~ "\"";
        segLit ~= "]";
        entries ~= "        qrc.QrcFile(" ~ segLit ~ ", cast(immutable(ubyte)[]) import(\""
            ~ f.path ~ "\")),\n";
    }
    return "import qrc; import qt.widgets.qresource;\n"
        ~ "shared static this() {\n"
        ~ "    static immutable ubyte[] _rccBlob = qrc.buildRcc([\n" ~ entries ~ "    ]);\n"
        ~ "    QResource.registerResource(cast(ubyte*) _rccBlob.ptr, \"\");\n"
        ~ "}\n";
}
