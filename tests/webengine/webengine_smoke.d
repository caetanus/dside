// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import qt.webengine.qwebengineurlscheme, qt.webengine.qstring;
import cxxrt, std.stdio;
void main() {
    auto s = QWebEngineUrlScheme("myscheme");
    s.setSyntax(QWebEngineUrlScheme.Syntax.Host);
    s.setDefaultPort(1234);
    s.setName("scheme2");
    assert(s.defaultPort() == 1234, "port round-trip falhou");
    assert(s.syntax() == QWebEngineUrlScheme.Syntax.Host, "syntax round-trip falhou");
    assert(s.name().toString() == "scheme2", "name round-trip falhou");
    writefln("webengine OK: QWebEngineUrlScheme link+run — name=%s port=%d syntax=%d",
        s.name().toString(), s.defaultPort(), cast(int) s.syntax());
}
