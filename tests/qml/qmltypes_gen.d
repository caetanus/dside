// Generates App.qmltypes from D @QObject types via CTFE — the D-side equivalent of
// qmltyperegistrar's type-description output. Emits the same type shape that
// qmlRegisterType!Backend registers at runtime, so qmllint/Creator/qmltc can see it.
// Usage: qmltypes_gen <out.qmltypes>
import qtmoc, std.file, std.stdio;

@QObject class Backend {
    Signal!int inChanged;
    @Property("inChanged") int inValue = 0;
    @Slot void fromQml(int v) {}
}

void main(string[] args) {
    enum doc = qmlTypesModule([qmlTypeComponent!Backend("App", 1, 0, "Backend")]);
    auto outPath = args.length > 1 ? args[1] : "App.qmltypes";
    std.file.write(outPath, doc);
    writeln("wrote ", outPath, " (", doc.length, " bytes)");
}
