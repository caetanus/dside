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

// ---------- code generation ----------

// Emit a container widget's <layout> + its item widgets; `parentVar` is the container's
// D variable. Nested containers recurse. Appends field decls and setupUi body.
private void genContainer(Node widget, string parentVar, ref string fields, ref string code) {
    auto lay = widget.child("layout");
    if (!lay.ok) return;
    string layCls = lay.attr("class");                 // QVBoxLayout / QHBoxLayout
    string layName = lay.attr("name");
    code ~= "        auto " ~ layName ~ " = " ~ layCls ~ "_new(" ~ parentVar ~ ");\n";
    foreach (item; lay.childrenOf("item")) {
        auto w = item.child("widget");
        if (!w.ok) continue;
        string wc = w.attr("class");                   // QPushButton / QLabel / …
        string wn = w.attr("name");
        fields ~= "    " ~ wc ~ " " ~ wn ~ ";\n";
        code ~= "        " ~ wn ~ " = " ~ wc ~ "_new(" ~ parentVar ~ ");\n";
        foreach (p; w.childrenOf("property"))
            if (p.attr("name") == "text")
                code ~= "        " ~ wn ~ ".setText(\"" ~ p.child("string").text ~ "\");\n";
        code ~= "        " ~ layName ~ ".addWidget(" ~ wn ~ ");\n";
        genContainer(w, wn, fields, code);             // nested layout inside this widget
    }
}

// Turn `.ui` XML into the source of `struct Ui_<name>` (fields + setupUi). CTFE-evaluable.
string uiForm(string xml) {
    auto root = parseUi(xml).child("widget");          // the root <widget>
    string cls = root.attr("class");                   // e.g. QWidget
    string name = root.attr("name");                   // e.g. LoginForm
    string fields, code;
    genContainer(root, "root", fields, code);
    return "struct Ui_" ~ name ~ " {\n" ~ fields
        ~ "    void setupUi(" ~ cls ~ " root) {\n" ~ code ~ "    }\n}\n";
}
