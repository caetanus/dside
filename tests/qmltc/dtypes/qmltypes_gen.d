// Writes the app's D QML types as a `.qmltypes` registry — the CTFE document from apptypes.d,
// which qmltc-d then reads to compile a .qml against those types. Qt's own reader validates the
// same file (qmltypes-check-*), so the registry is not a private side-format.
// Usage: qmltypes_gen <out.qmltypes>
module qmltypes_gen;

import apptypes, std.file, std.stdio;

void main(string[] args) {
    auto outPath = args.length > 1 ? args[1] : "AppTypes.qmltypes";
    std.file.write(outPath, appTypesDoc);
    stderr.writeln("wrote ", outPath, " (", appTypesDoc.length, " bytes)");
}
