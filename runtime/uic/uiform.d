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
            n.attrs ~= Attr(an, decodeEntities(s[vs .. i]));
            i++;                                       // closing quote
        }
    }
    for (;;) {                                        // content: text + child elements
        size_t ts = i;
        while (i < s.length && s[i] != '<') i++;
        auto tt = strip(s[ts .. i]);
        if (tt.length) n.text ~= decodeEntities(tt);
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

private string encodeUtf8(uint cp) {
    string r;
    if (cp < 0x80) r ~= cast(char) cp;
    else if (cp < 0x800) { r ~= cast(char)(0xC0 | (cp >> 6)); r ~= cast(char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) {
        r ~= cast(char)(0xE0 | (cp >> 12));
        r ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        r ~= cast(char)(0x80 | (cp & 0x3F));
    } else {
        r ~= cast(char)(0xF0 | (cp >> 18));
        r ~= cast(char)(0x80 | ((cp >> 12) & 0x3F));
        r ~= cast(char)(0x80 | ((cp >> 6) & 0x3F));
        r ~= cast(char)(0x80 | (cp & 0x3F));
    }
    return r;
}

// Decode XML entities (&lt; &gt; &amp; &quot; &apos; and numeric &#N;/&#xN;) — QUiLoader's
// real XML parser does this, so `&amp;File` -> `&File`, `&lt;b&gt;` -> `<b>`, etc.
private string decodeEntities(string s) {
    string r;
    for (size_t i = 0; i < s.length;) {
        if (s[i] != '&') { r ~= s[i]; i++; continue; }
        size_t j = i + 1;
        while (j < s.length && s[j] != ';' && j - i < 12) j++;
        if (j >= s.length || s[j] != ';') { r ~= '&'; i++; continue; }
        string ent = s[i + 1 .. j];
        if (ent == "lt") r ~= '<';
        else if (ent == "gt") r ~= '>';
        else if (ent == "amp") r ~= '&';
        else if (ent == "quot") r ~= '"';
        else if (ent == "apos") r ~= '\'';
        else if (ent.length > 1 && ent[0] == '#') {
            uint cp = 0;
            bool hex = ent.length > 2 && (ent[1] == 'x' || ent[1] == 'X');
            foreach (c; ent[(hex ? 2 : 1) .. $]) {
                if (c >= '0' && c <= '9') cp = cp * (hex ? 16 : 10) + (c - '0');
                else if (hex && c >= 'a' && c <= 'f') cp = cp * 16 + (c - 'a' + 10);
                else if (hex && c >= 'A' && c <= 'F') cp = cp * 16 + (c - 'A' + 10);
            }
            r ~= encodeUtf8(cp);
        } else { r ~= s[i .. j + 1]; }   // unknown entity -> keep literal
        i = j + 1;
    }
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
    string menuNames;   // "|menuFile|menuHelp|" — so an <addaction> tells a submenu from an action
    string[] groupList; // unique <attribute name="buttonGroup"> names -> one QButtonGroup each
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

// FQN enum -> D. A Qt-namespace enum (`Qt::AlignmentFlag::AlignCenter`) is its own
// top-level module -> `AlignmentFlag.AlignCenter` (import alignmentflag). A class-nested
// enum (`QAbstractItemView::SelectionBehavior::SelectRows`) lives in the class module ->
// `QAbstractItemView.SelectionBehavior.SelectRows` (import qabstractitemview).
private string enumRef(ref Gen g, string fqn) {
    auto parts = splitOn(fqn, "::");
    if (parts.length < 2) return fqn;
    string e = parts[$ - 2], v = parts[$ - 1];
    if (parts.length >= 3 && parts[$ - 3] != "Qt") {   // Container::Enum::Value
        string cont = parts[$ - 3];
        need(g, cont);
        return cont ~ "." ~ e ~ "." ~ v;
    }
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

private string itos(size_t n) {
    if (n == 0) return "0";
    string r;
    while (n) { r = cast(char)('0' + (n % 10)) ~ r; n /= 10; }
    return r;
}

// A page's tab title from <attribute name="title"><string>…</string></attribute>.
private string tabTitle(Node page) {
    foreach (a; page.childrenOf("attribute"))
        if (a.attr("name") == "title") return firstElem(a).text;
    return "";
}

private void genProps(ref Gen g, Node w, string var, bool isRoot) {
    foreach (p; w.childrenOf("property")) {
        string name = p.attr("name");
        Node v = firstElem(p);
        if (name == "shortcut" && v.tag == "string") {   // <string>Ctrl+O</string> -> QKeySequence
            need(g, "QKeySequence");
            need(g, "QString");
            g.setup ~= "        { auto _s = qstr(\"" ~ esc(v.text) ~ "\"); auto _ks = QKeySequence_new(_s); "
                ~ var ~ ".setShortcut(_ks); }\n";
            continue;
        }
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
        if (v.tag == "iconset") {   // <iconset theme=…/> or resource (<normaloff>:/…</normaloff>)
            need(g, "QIcon");
            string ex;
            if (v.attr("theme").length) {
                string th = v.attr("theme");
                if (th.length > 2 && splitOn(th, "::").length >= 2)
                    ex = "QIcon.fromTheme(QIcon.ThemeIcon." ~ splitOn(th, "::")[$ - 1] ~ ")";
                else
                    ex = "QIcon.fromTheme(qstr(\"" ~ esc(th) ~ "\"))";
            } else {
                auto no = v.child("normaloff");
                if (no.ok && no.text.length) ex = "QIcon_new(\"" ~ esc(no.text) ~ "\")";
            }
            if (ex.length) {
                need(g, "QString");
                g.setup ~= "        { auto _ic = " ~ ex ~ "; " ~ var ~ ".set" ~ cap(name) ~ "(_ic); }\n";
            }
            continue;
        }
        if (v.tag == "font") {   // <font><family/><pointsize/><bold/><italic/>…</font>
            g.setup ~= genFont(g, v, var);
            continue;
        }
        if (v.tag == "sizepolicy") {   // <sizepolicy hsizetype=… vsizetype=…><horstretch/>…
            string sp = genSizePolicy(g, v, var);
            if (sp.length) { g.setup ~= sp; continue; }
            // stretch != 0 not yet expressible (QSizePolicy stretch setters unbound) -> skip
            continue;
        }
        if (v.tag == "palette") {   // <palette><active><colorrole role=…><brush><color/>…
            g.setup ~= genPalette(g, v, var);
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

// A <font> property -> a local QFont carrying the given sub-fields, then set<Font>(f).
// Absent sub-fields keep QFont defaults (matches QUiLoader, which sets only present ones).
// setBold/setItalic are inline (unbound) -> use setWeight/setStyle equivalents. <weight> in
// the old 0-99 scale is ambiguous across Qt versions -> skipped (bold covers the common case).
private string genFont(ref Gen g, Node f, string var) {
    need(g, "QFont");
    string body;
    foreach (fc; f.kids) {
        switch (fc.tag) {
            case "family":     body ~= " _f.setFamily(\"" ~ esc(fc.text) ~ "\");"; break;   // string overload
            case "pointsize":  body ~= " _f.setPointSize(" ~ fc.text ~ ");"; break;
            case "pointsizef": body ~= " _f.setPointSizeF(" ~ fc.text ~ ");"; break;
            case "bold":       body ~= " _f.setWeight(QFont.Weight."
                ~ (fc.text == "true" ? "Bold" : "Normal") ~ ");"; break;
            case "italic":     body ~= " _f.setStyle(QFont.Style."
                ~ (fc.text == "true" ? "StyleItalic" : "StyleNormal") ~ ");"; break;
            case "underline":  body ~= " _f.setUnderline(" ~ fc.text ~ ");"; break;
            case "strikeout":  body ~= " _f.setStrikeOut(" ~ fc.text ~ ");"; break;
            default: break;    // weight (ambiguous scale) / kerning / stylestrategy -> not yet
        }
    }
    return "        { auto _f = QFont_new();" ~ body ~ " " ~ var ~ ".setFont(_f); }\n";
}

// A <sizepolicy> property. Common case (stretch 0) -> setSizePolicy(hPolicy, vPolicy), the
// QWidget convenience overload. Returns "" when a non-zero stretch is present (that needs the
// QSizePolicy stretch setters, which are inline value-type methods still unbound).
private string genSizePolicy(ref Gen g, Node sp, string var) {
    need(g, "QSizePolicy");
    string hp = sp.attr("hsizetype"), vp = sp.attr("vsizetype");   // modern attribute form
    string hs = "0", vs = "0";
    foreach (c; sp.kids) switch (c.tag) {   // old element form + stretches
        case "hsizetype": hp = c.text; break;
        case "vsizetype": vp = c.text; break;
        case "horstretch": hs = c.text; break;
        case "verstretch": vs = c.text; break;
        default: break;
    }
    if (!hp.length || !vp.length || isDigits(hp) || isDigits(vp)) return "";
    if (hs != "0" || vs != "0") return "";
    return "        " ~ var ~ ".setSizePolicy(QSizePolicy.Policy." ~ hp
        ~ ", QSizePolicy.Policy." ~ vp ~ ");\n";
}

private bool isDigits(string s) {
    if (!s.length) return false;
    foreach (c; s) if (c < '0' || c > '9') return false;
    return true;
}

// A .ui <palette> group tag -> QPalette.ColorGroup member ("" if unknown).
private string groupEnum(string tag) {
    switch (tag) {
        case "active":   return "Active";
        case "inactive": return "Inactive";
        case "disabled": return "Disabled";
        default:         return "";
    }
}

// A <colorrole role="…"> name -> QPalette.ColorRole member. Old .ui uses the deprecated
// Foreground/Background aliases -> map to WindowText/Window.
private string roleEnum(string role) {
    switch (role) {
        case "Foreground": return "WindowText";
        case "Background": return "Window";
        default:           return role;
    }
}

// A <palette> property. Each group (<active>/<inactive>/<disabled>) carries <colorrole>s; each
// holds a <brush> with a <color>. We build QPalette_new() and setBrush(group, role, QBrush(color))
// for every SolidPattern colorrole, then setPalette. Non-solid brushes (gradient/texture) are
// rare and skipped (they'd need QGradient); the harness would flag any that a real form needs.
private string genPalette(ref Gen g, Node pal, string var) {
    need(g, "QPalette"); need(g, "QColor"); need(g, "QBrush");
    string body;
    foreach (grp; pal.kids) {
        string cg = groupEnum(grp.tag);
        if (!cg.length) continue;
        foreach (cr; grp.childrenOf("colorrole")) {
            string role = roleEnum(cr.attr("role"));
            if (!role.length) continue;
            Node brush = cr.child("brush");
            if (!brush.ok) continue;
            string bs = brush.attr("brushstyle");
            if (bs.length && bs != "SolidPattern") continue;   // only color brushes for now
            Node col = brush.child("color");
            if (!col.ok) continue;
            string a = col.attr("alpha").length ? col.attr("alpha") : "255";
            string r = col.child("red").text, gc = col.child("green").text, b = col.child("blue").text;
            if (!r.length || !gc.length || !b.length) continue;
            body ~= "            { auto _c = QColor_new(" ~ r ~ ", " ~ gc ~ ", " ~ b ~ ", " ~ a
                ~ "); auto _b = QBrush_new(_c); _p.setBrush(QPalette.ColorGroup." ~ cg
                ~ ", QPalette.ColorRole." ~ role ~ ", _b); }\n";
        }
    }
    if (!body.length) return "";
    return "        { auto _p = QPalette_new();\n" ~ body ~ "            " ~ var ~ ".setPalette(_p); }\n";
}

// A <spacer> -> QSpacerItem(w, h, hPolicy, vPolicy). Orientation picks which axis expands
// (a horizontal spacer expands horizontally, is Minimum vertically). Not a QObject.
private string genSpacer(ref Gen g, Node sp) {
    need(g, "QSpacerItem");
    need(g, "QSizePolicy");
    string name = sp.attr("name");
    string w = "0", h = "0", orient = "Horizontal";
    foreach (p; sp.childrenOf("property")) {
        string pn = p.attr("name");
        Node v = firstElem(p);
        if (pn == "sizeHint" && v.tag == "size") { w = v.child("width").text; h = v.child("height").text; }
        else if (pn == "orientation" && v.tag == "enum") {
            auto parts = splitOn(v.text, "::");
            orient = parts[$ - 1];
        }
    }
    string hp = orient == "Vertical" ? "Minimum" : "Expanding";
    string vp = orient == "Vertical" ? "Expanding" : "Minimum";
    g.fields ~= "    QSpacerItem " ~ name ~ ";\n";
    g.setup ~= "        " ~ name ~ " = QSpacerItem_new(" ~ w ~ ", " ~ h
        ~ ", QSizePolicy.Policy." ~ hp ~ ", QSizePolicy.Policy." ~ vp ~ ");\n";
    return name;
}

// A <layout> and its <item>s. `parentVar` is the container's D variable; item widgets are
// parented to it. Dispatches on the layout class: box (add order), grid (row/col/span),
// form (LabelRole/FieldRole). Nested layouts recurse and are added via addLayout. Returns
// the layout's D variable name.
private string genLayout(ref Gen g, Node lay, string parentVar) {
    string cls = lay.attr("class");
    string name = lay.attr("name");
    if (!name.length) name = parentVar ~ "_lay";
    bool grid = cls == "QGridLayout";
    bool form = cls == "QFormLayout";
    need(g, cls);
    g.fields ~= "    " ~ cls ~ " " ~ name ~ ";\n";
    g.setup ~= "        " ~ name ~ " = " ~ cls ~ "_new(" ~ parentVar ~ ");\n";
    if (lay.attr("name").length)   // named in the .ui -> QUiLoader sets it too (a nameless one stays nameless)
        g.setup ~= "        " ~ name ~ ".setObjectName(\"" ~ name ~ "\");\n";
    // spacing + the four *Margin props collapse to setContentsMargins(l, t, r, b).
    string ml = "0", mt = "0", mr = "0", mb = "0";
    bool anyMargin;
    foreach (p; lay.childrenOf("property")) {
        string pn = p.attr("name"), pv = firstElem(p).text;
        if (pn == "spacing") g.setup ~= "        " ~ name ~ ".setSpacing(" ~ pv ~ ");\n";
        else if (pn == "leftMargin") { ml = pv; anyMargin = true; }
        else if (pn == "topMargin") { mt = pv; anyMargin = true; }
        else if (pn == "rightMargin") { mr = pv; anyMargin = true; }
        else if (pn == "bottomMargin") { mb = pv; anyMargin = true; }
    }
    if (anyMargin)
        g.setup ~= "        " ~ name ~ ".setContentsMargins(" ~ ml ~ ", " ~ mt ~ ", " ~ mr ~ ", " ~ mb ~ ");\n";
    foreach (item; lay.childrenOf("item")) {
        string row = item.attr("row").length ? item.attr("row") : "0";
        string col = item.attr("column").length ? item.attr("column") : "0";
        string rs = item.attr("rowspan").length ? item.attr("rowspan") : "1";
        string cs = item.attr("colspan").length ? item.attr("colspan") : "1";
        auto w = item.child("widget");
        auto sub = item.child("layout");
        auto sp = item.child("spacer");
        if (w.ok) {
            string wn = genWidget(g, w, parentVar, false);
            if (grid)
                g.setup ~= "        " ~ name ~ ".addWidget(" ~ wn ~ ", " ~ row ~ ", " ~ col
                    ~ ", " ~ rs ~ ", " ~ cs ~ ", 0);\n";
            else if (form)
                g.setup ~= "        " ~ name ~ ".setWidget(" ~ row ~ ", QFormLayout.ItemRole."
                    ~ (col == "0" ? "LabelRole" : "FieldRole") ~ ", " ~ wn ~ ");\n";
            else
                g.setup ~= "        " ~ name ~ ".addWidget(" ~ wn ~ ");\n";
        } else if (sp.ok) {
            string spn = genSpacer(g, sp);
            if (grid)
                g.setup ~= "        " ~ name ~ ".addItem(" ~ spn ~ ", " ~ row ~ ", " ~ col
                    ~ ", " ~ rs ~ ", " ~ cs ~ ", 0);\n";
            else if (!form)
                g.setup ~= "        " ~ name ~ ".addSpacerItem(" ~ spn ~ ");\n";
        } else if (sub.ok) {
            string sn = genLayout(g, sub, parentVar);
            if (grid)
                g.setup ~= "        " ~ name ~ ".addLayout(" ~ sn ~ ", " ~ row ~ ", " ~ col
                    ~ ", " ~ rs ~ ", " ~ cs ~ ", 0);\n";
            else if (!form)
                g.setup ~= "        " ~ name ~ ".addLayout(" ~ sn ~ ", 0);\n";
        }
    }
    return name;
}

// --- QMainWindow chrome (actions, menus, toolbars) ---

private void collectMenus(Node n, ref Gen g) {
    if (n.attr("class") == "QMenu" && n.attr("name").length) g.menuNames ~= "|" ~ n.attr("name") ~ "|";
    foreach (k; n.kids) collectMenus(k, g);
}

private bool isMenu(ref Gen g, string name) {
    string key = "|" ~ name ~ "|";
    foreach (i; 0 .. g.menuNames.length)
        if (i + key.length <= g.menuNames.length && g.menuNames[i .. i + key.length] == key) return true;
    return false;
}

// A widget's <attribute name="buttonGroup"><string>g</string></attribute>, or "".
private string buttonGroupOf(Node w) {
    foreach (a; w.childrenOf("attribute"))
        if (a.attr("name") == "buttonGroup") return firstElem(a).text;
    return "";
}

private void collectGroups(Node n, ref Gen g) {
    string bg = buttonGroupOf(n);
    if (bg.length) {
        bool has = false;
        foreach (x; g.groupList) if (x == bg) { has = true; break; }
        if (!has) g.groupList ~= bg;
    }
    foreach (k; n.kids) collectGroups(k, g);
}

// One QButtonGroup per group name, parented to root (created before the buttons add to it).
private void emitGroups(ref Gen g) {
    if (g.groupList.length) need(g, "QButtonGroup");
    // NB: no setObjectName on the group — QUiLoader leaves it unnamed, and a QButtonGroup
    // is a logical grouping, not a rendered child; naming it would diverge from the oracle.
    foreach (grp; g.groupList) {
        g.fields ~= "    QButtonGroup " ~ grp ~ ";\n";
        g.setup ~= "        " ~ grp ~ " = QButtonGroup_new(root);\n";
    }
}

// <tabstops><tabstop>a</tabstop><tabstop>b</tabstop>…</tabstops> -> setTabOrder(a,b), (b,c)…
private void genTabOrder(ref Gen g, Node tabstops) {
    auto ts = tabstops.childrenOf("tabstop");
    if (ts.length < 2) return;
    need(g, "QWidget");
    for (size_t i = 1; i < ts.length; i++)
        g.setup ~= "        QWidget.setTabOrder(" ~ ts[i - 1].text ~ ", " ~ ts[i].text ~ ");\n";
}

// <addaction name="X"/> -> target.addAction(X) / addAction(X.menuAction()) for a submenu /
// addSeparator() for the "separator" sentinel.
private void genAddActions(ref Gen g, Node node, string target) {
    foreach (aa; node.childrenOf("addaction")) {
        string an = aa.attr("name");
        if (an == "separator") g.setup ~= "        " ~ target ~ ".addSeparator();\n";
        else if (isMenu(g, an)) g.setup ~= "        " ~ target ~ ".addAction(" ~ an ~ ".menuAction());\n";
        else g.setup ~= "        " ~ target ~ ".addAction(" ~ an ~ ");\n";
    }
}

// A top-level <action> -> a QAction field + construction (text/tooltip in retranslateUi).
private void genAction(ref Gen g, Node act, string parentVar) {
    need(g, "QAction");
    string an = act.attr("name");
    g.fields ~= "    QAction " ~ an ~ ";\n";
    g.setup ~= "        " ~ an ~ " = QAction_new(" ~ parentVar ~ ");\n";
    g.setup ~= "        " ~ an ~ ".setObjectName(\"" ~ an ~ "\");\n";
    genProps(g, act, an, false);
}

// A <widget class="QMenu">: create it (+ title), its submenus, then wire its <addaction>s.
private string genMenu(ref Gen g, Node menu, string parentVar) {
    string cn = genWidget(g, menu, parentVar, false);   // QMenu field + QMenu_new + setTitle (retranslate)
    foreach (sub; menu.childrenOf("widget"))
        if (sub.attr("class") == "QMenu") genMenu(g, sub, cn);
    genAddActions(g, menu, cn);
    return cn;
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
    if (!isRoot) {
        string bg = buttonGroupOf(w);   // radio/checkbox membership -> QButtonGroup.addButton
        if (bg.length) g.setup ~= "        " ~ bg ~ ".addButton(" ~ var ~ ", -1);\n";
    }
    string wcls0 = w.attr("class");
    // QMainWindow: its direct children are chrome (central widget, menubar, toolbars,
    // statusbar), not layout items; <action>s are top-level and referenced by <addaction>.
    if (wcls0 == "QMainWindow") {
        foreach (act; w.childrenOf("action")) genAction(g, act, var);
        foreach (child; w.childrenOf("widget")) {
            string ccls = child.attr("class");
            string cn = genWidget(g, child, var, false);
            if (ccls == "QMenuBar") {
                foreach (m; child.childrenOf("widget"))
                    if (m.attr("class") == "QMenu") genMenu(g, m, cn);
                genAddActions(g, child, cn);
                g.setup ~= "        " ~ var ~ ".setMenuBar(" ~ cn ~ ");\n";
            } else if (ccls == "QStatusBar") {
                g.setup ~= "        " ~ var ~ ".setStatusBar(" ~ cn ~ ");\n";
            } else if (ccls == "QToolBar") {
                need(g, "ToolBarArea");
                g.setup ~= "        " ~ var ~ ".addToolBar(ToolBarArea.TopToolBarArea, " ~ cn ~ ");\n";
                genAddActions(g, child, cn);
            } else {
                g.setup ~= "        " ~ var ~ ".setCentralWidget(" ~ cn ~ ");\n";
            }
        }
        return var;
    }
    auto lay = w.child("layout");
    if (lay.ok) genLayout(g, lay, var);
    // QComboBox <item>s -> addItem (each item is a model row, not a child QObject). The
    // QString + empty QVariant are lvalues (the shimmed addItem takes them by const ref).
    string wcls = w.attr("class");
    if (wcls == "QComboBox") {
        need(g, "QVariant");
        need(g, "QString");
        foreach (it; w.childrenOf("item")) {
            string txt;
            foreach (p; it.childrenOf("property"))
                if (p.attr("name") == "text") txt = firstElem(p).text;
            g.setup ~= "        { auto _s = qstr(\"" ~ esc(txt) ~ "\"); auto _v = QVariant_new(); "
                ~ var ~ ".addItem(_s, _v); }\n";
        }
    }
    // Container widgets whose children are direct <widget> pages (not layout items):
    // QTabWidget (addTab + tab title in retranslateUi), QStackedWidget/QSplitter (addWidget).
    if (wcls == "QTabWidget" || wcls == "QStackedWidget" || wcls == "QSplitter") {
        size_t idx = 0;
        foreach (page; w.childrenOf("widget")) {
            string pn = genWidget(g, page, var, false);
            if (wcls == "QTabWidget") {
                g.setup ~= "        " ~ var ~ ".addTab(" ~ pn ~ ", \"\");\n";
                g.trans ~= "        " ~ var ~ ".setTabText(" ~ itos(idx) ~ ", \""
                    ~ esc(tabTitle(page)) ~ "\");\n";
            } else
                g.setup ~= "        " ~ var ~ ".addWidget(" ~ pn ~ ");\n";
            idx++;
        }
    }
    return var;
}

// Turn `.ui` XML into the source of `struct Ui_<name>` (fields + setupUi + retranslateUi),
// preceded by the imports it needs. CTFE-evaluable; use as mixin(uiForm(import("x.ui"))).
string uiForm(string xml) {
    auto root = parseUi(xml).child("widget");
    string rootCls = root.attr("class");
    string className = root.attr("name");
    Gen g;
    collectMenus(root, g);    // so <addaction> can distinguish submenus from actions
    collectGroups(root, g);   // unique buttonGroup names
    need(g, rootCls);
    g.setup ~= "        root.setObjectName(\"" ~ className ~ "\");\n";
    emitGroups(g);            // QButtonGroups exist before the buttons add to them
    genWidget(g, root, "", true);
    genTabOrder(g, parseUi(xml).child("tabstops"));
    return g.imports
        ~ "struct Ui_" ~ className ~ " {\n" ~ g.fields
        ~ "    void setupUi(" ~ rootCls ~ " root) {\n" ~ g.setup
        ~ "        retranslateUi(root);\n    }\n"
        ~ "    void retranslateUi(" ~ rootCls ~ " root) {\n" ~ g.trans ~ "    }\n}\n";
}
