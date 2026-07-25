// uiform.d — a compile-time (CTFE) `uic`: turn a Qt Designer `.ui` into a TYPED D
// struct with named-widget fields + `setupUi`, generated at compile time. No external
// tool, no build step — same philosophy as the CTFE moc (`runtime/qtmoc`).
//
//   mixin(uiForm(import("login.ui")));   // -J points at the .ui dir -> `struct Ui_<name>`
//   Ui_LoginForm ui; ui.setupUi(root);
//   ui.okButton.setText("…");            // typed, compile-time-checked
//
// Proof-of-concept subset: a root <widget>, box <layout>s (QVBoxLayout/QHBoxLayout),
// <item><widget/></item> children (nested containers recurse), and the
// <property name="text"><string>…</string></property>. Grows from this core.
module uiform;

// ---------- a tiny CTFE XML parser for the .ui subset ----------

struct Attr { string name, val; }

struct Node {
    string tag;
    Attr[] attrs;
    Node[] kids;
    string text;

    bool ok() { return tag.length != 0; }
    string attr(string n) {
        foreach (a; attrs) if (a.name == n) return a.val;
        return "";
    }
    Node child(string t) {
        foreach (k; kids) if (k.tag == t) return k;
        return Node.init;
    }
    Node[] childrenOf(string t) {
        Node[] r;
        foreach (k; kids) if (k.tag == t) r ~= k;
        return r;
    }
}

private bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

private string strip(string s) {
    size_t a = 0, b = s.length;
    while (a < b && isSpace(s[a])) a++;
    while (b > a && isSpace(s[b - 1])) b--;
    return s[a .. b];
}

private void skipSpace(string s, ref size_t i) {
    while (i < s.length && isSpace(s[i])) i++;
}

// Parse one element; s[i] must be '<' (an open tag, not '</').
private Node parseElem(string s, ref size_t i) {
    Node n;
    i++;                                              // skip '<'
    size_t st = i;
    while (i < s.length && !isSpace(s[i]) && s[i] != '>' && s[i] != '/') i++;
    n.tag = s[st .. i];
    for (;;) {                                        // attributes
        skipSpace(s, i);
        if (i >= s.length) return n;
        if (s[i] == '/') { i += 2; return n; }        // '/>' self-closing
        if (s[i] == '>') { i++; break; }
        size_t as = i;
        while (i < s.length && s[i] != '=' && !isSpace(s[i]) && s[i] != '>') i++;
        string an = s[as .. i];
        skipSpace(s, i);
        if (i < s.length && s[i] == '=') {
            i++; skipSpace(s, i);
            char q = s[i]; i++;                        // opening quote
            size_t vs = i;
            while (i < s.length && s[i] != q) i++;
            n.attrs ~= Attr(an, s[vs .. i]);
            i++;                                       // closing quote
        }
    }
    for (;;) {                                        // content: text + child elements
        size_t ts = i;
        while (i < s.length && s[i] != '<') i++;
        auto tt = strip(s[ts .. i]);
        if (tt.length) n.text ~= tt;
        if (i >= s.length) break;
        if (i + 1 < s.length && s[i + 1] == '/') {    // '</tag>' close
            i += 2;
            while (i < s.length && s[i] != '>') i++;
            i++;
            break;
        }
        if (i + 3 < s.length && s[i + 1] == '!' && s[i + 2] == '-' && s[i + 3] == '-') {
            i += 4;                                    // comment
            while (i + 2 < s.length && !(s[i] == '-' && s[i + 1] == '-' && s[i + 2] == '>')) i++;
            i += 3;
            continue;
        }
        if (i + 1 < s.length && s[i + 1] == '?') {     // <?xml …?>
            while (i < s.length && s[i] != '>') i++;
            i++;
            continue;
        }
        n.kids ~= parseElem(s, i);
    }
    return n;
}

// Parse a whole .ui document; returns the <ui> root element.
Node parseUi(string s) {
    size_t i = 0;
    while (i < s.length) {
        skipSpace(s, i);
        if (i >= s.length || s[i] != '<') break;
        if (i + 1 < s.length && s[i + 1] == '?') { while (i < s.length && s[i] != '>') i++; i++; continue; }
        if (i + 1 < s.length && s[i + 1] == '!') { while (i < s.length && s[i] != '>') i++; i++; continue; }
        return parseElem(s, i);
    }
    return Node.init;
}

// ---------- small CTFE string helpers ----------

private string cap(string s) {
    if (!s.length) return s;
    char c = s[0];
    if (c >= 'a' && c <= 'z') c = cast(char)(c - 32);
    return c ~ s[1 .. $];
}

private string low(string s) {                          // ASCII toLower (matches modBase)
    string r;
    foreach (c; s) r ~= (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return r;
}

private string[] splitOn(string s, string sep) {
    string[] r;
    size_t start = 0;
    for (size_t i = 0; i + sep.length <= s.length; ) {
        if (s[i .. i + sep.length] == sep) { r ~= s[start .. i]; i += sep.length; start = i; }
        else i++;
    }
    r ~= s[start .. $];
    return r;
}

private string esc(string s) {                          // for a D "…" literal
    string r;
    foreach (c; s) {
        if (c == '\\' || c == '"') r ~= '\\';
        if (c == '\n') { r ~= "\\n"; continue; }
        r ~= c;
    }
    return r;
}

// ---------- code generation ----------

// Threaded accumulators for one form.
private struct Gen {
    string imports;     // deduped `import qt.widgets.<mod>;`
    string seen;        // "|qpushbutton|qlabel|" — dedup key for imports
    string fields;      // struct fields
    string setup;       // setupUi body
    string trans;       // retranslateUi body
}

// Every generated type lives in the widgets package; ensure its module is imported.
private void need(ref Gen g, string typeName) {
    if (!typeName.length) return;
    string key = "|" ~ low(typeName) ~ "|";
    foreach (i; 0 .. g.seen.length)
        if (i + key.length <= g.seen.length && g.seen[i .. i + key.length] == key) return;
    g.seen ~= key;
    g.imports ~= "import qt.widgets." ~ low(typeName) ~ ";\n";
}

// Translatable properties go to retranslateUi (plain literals for now; tr() is a later pass).
private bool isTr(string name) {
    foreach (t; ["text", "title", "windowTitle", "toolTip", "statusTip", "whatsThis",
                 "shortcut", "placeholderText"])
        if (name == t) return true;
    return false;
}

// `Qt::AlignmentFlag::AlignCenter` -> `AlignmentFlag.AlignCenter`, importing the enum module.
private string enumRef(ref Gen g, string fqn) {
    auto parts = splitOn(fqn, "::");
    if (parts.length < 2) return fqn;
    string e = parts[$ - 2], v = parts[$ - 1];
    need(g, e);
    return e ~ "." ~ v;
}

// A property value element -> a D expression (or "" if unsupported). May add imports.
private string value(ref Gen g, Node v) {
    switch (v.tag) {
        case "number", "double", "float", "longlong", "uInt": return v.text;
        case "bool": return v.text;                     // "true"/"false"
        case "string": return "\"" ~ esc(v.text) ~ "\"";
        case "enum": return enumRef(g, v.text);
        case "set":                                     // flags OR-ed
            string r;
            foreach (i, f; splitOn(v.text, "|")) r ~= (i ? " | " : "") ~ enumRef(g, f);
            return r;
        case "rect":
            need(g, "QRect");
            return "QRect(" ~ v.child("x").text ~ ", " ~ v.child("y").text ~ ", "
                ~ v.child("width").text ~ ", " ~ v.child("height").text ~ ")";
        case "size":
            need(g, "QSize");
            return "QSize(" ~ v.child("width").text ~ ", " ~ v.child("height").text ~ ")";
        default: return "";
    }
}

// First child ELEMENT of a node (skips text).
private Node firstElem(Node n) { return n.kids.length ? n.kids[0] : Node.init; }

private void genProps(ref Gen g, Node w, string var, bool isRoot) {
    foreach (p; w.childrenOf("property")) {
        string name = p.attr("name");
        Node v = firstElem(p);
        if (name == "geometry" && v.tag == "rect") {    // root -> resize; child -> setGeometry
            if (isRoot)
                g.setup ~= "        " ~ var ~ ".resize(" ~ v.child("width").text
                    ~ ", " ~ v.child("height").text ~ ");\n";
            else {
                need(g, "QRect");
                g.setup ~= "        " ~ var ~ ".setGeometry(" ~ value(g, v) ~ ");\n";
            }
            continue;
        }
        if (v.tag == "string" && isTr(name)) {
            g.trans ~= "        " ~ var ~ ".set" ~ cap(name) ~ "(\"" ~ esc(v.text) ~ "\");\n";
            continue;
        }
        string val = value(g, v);
        if (val.length)
            g.setup ~= "        " ~ var ~ ".set" ~ cap(name) ~ "(" ~ val ~ ");\n";
    }
}

// A box <layout> and its item widgets. `parentVar` is the container's D variable.
private void genBoxLayout(ref Gen g, Node lay, string parentVar) {
    string cls = lay.attr("class");
    string name = lay.attr("name");
    if (!name.length) name = parentVar ~ "Layout";
    need(g, cls);
    g.fields ~= "    " ~ cls ~ " " ~ name ~ ";\n";
    g.setup ~= "        " ~ name ~ " = " ~ cls ~ "_new(" ~ parentVar ~ ");\n";
    foreach (item; lay.childrenOf("item")) {
        auto w = item.child("widget");
        if (!w.ok) continue;                            // spacers / nested layouts: Phase B
        string wn = genWidget(g, w, parentVar, false);
        g.setup ~= "        " ~ name ~ ".addWidget(" ~ wn ~ ");\n";
    }
}

// Emit a widget: field + construction (unless root) + properties + its layout. Returns the
// widget's D variable name ("root" for the root).
private string genWidget(ref Gen g, Node w, string parentVar, bool isRoot) {
    string var;
    if (isRoot) {
        var = "root";
    } else {
        string cls = w.attr("class");
        var = w.attr("name");
        need(g, cls);
        g.fields ~= "    " ~ cls ~ " " ~ var ~ ";\n";
        g.setup ~= "        " ~ var ~ " = " ~ cls ~ "_new(" ~ parentVar ~ ");\n";
        g.setup ~= "        " ~ var ~ ".setObjectName(\"" ~ var ~ "\");\n";
    }
    genProps(g, w, var, isRoot);
    auto lay = w.child("layout");
    if (lay.ok) genBoxLayout(g, lay, var);
    return var;
}

// Turn `.ui` XML into the source of `struct Ui_<name>` (fields + setupUi + retranslateUi),
// preceded by the imports it needs. CTFE-evaluable; use as mixin(uiForm(import("x.ui"))).
string uiForm(string xml) {
    auto root = parseUi(xml).child("widget");
    string rootCls = root.attr("class");
    string className = root.attr("name");
    Gen g;
    need(g, rootCls);
    g.setup ~= "        root.setObjectName(\"" ~ className ~ "\");\n";
    genWidget(g, root, "", true);
    return g.imports
        ~ "struct Ui_" ~ className ~ " {\n" ~ g.fields
        ~ "    void setupUi(" ~ rootCls ~ " root) {\n" ~ g.setup
        ~ "        retranslateUi(root);\n    }\n"
        ~ "    void retranslateUi(" ~ rootCls ~ " root) {\n" ~ g.trans ~ "    }\n}\n";
}
