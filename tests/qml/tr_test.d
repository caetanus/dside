// Runtime translation, the way it should read: no _new, no hand-built app — just install a
// translator and use a free UFCS tr(). Proves the runtime end of the loop
// (lupdate-d -> .ts -> lrelease -> .qm -> tr()). Given a .qm path (argv[1], built by lrelease)
// it checks the translation; otherwise the identity (untranslated -> source).
module tr_test;   // free tr()'s context is __MODULE__ -> "tr_test", matching the .ts below
import qtmoc : QTranslator, tr;
import std.stdio, std.path : stripExtension;

void main(string[] args) {
    bool haveQm = args.length > 1;
    QTranslator.install(haveQm ? args[1].stripExtension : "");   // builds QTranslator + app in C++

    auto got = "test: hello world".tr;   // free, UFCS — context is application-global
    if (haveQm) {
        assert(got == "teste: oi mundo", "tr() did not translate: got '" ~ got ~ "'");
        writeln("tr OK: \"test: hello world\".tr -> '", got, "' (QTranslator.install + lrelease .qm)");
    } else {
        assert(got == "test: hello world", "tr() identity failed: got '" ~ got ~ "'");
        writeln("tr OK: \"test: hello world\".tr identity (lrelease absent -> translation skipped)");
    }
}
