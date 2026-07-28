import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qdialog, qt.widgets.qmainwindow;
import cxxrt, uiform, qrc, std.stdio, std.string;
import std.algorithm : splitter, canFind, all;
import std.array : array;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
extern (C) const(char)* qtd_ui_dump(void*); extern (C) const(char)* qtd_ui_load_and_dump(const(char)*);
mixin(uiForm(import("corpus/addtorrentform.ui")));
mixin(uiForm(import("corpus/authenticationdialog.ui")));
mixin(uiForm(import("corpus/backside.ui")));
mixin(uiForm(import("corpus/batchtranslation.ui")));
mixin(uiForm(import("corpus/bookwindow.ui")));
mixin(uiForm(import("corpus/calculator.ui")));
mixin(uiForm(import("corpus/calculatorform.ui")));
mixin(uiForm(import("corpus/certificateinfo.ui")));
mixin(uiForm(import("corpus/chatdialog.ui")));
mixin(uiForm(import("corpus/chatmainwindow.ui")));
mixin(uiForm(import("corpus/chatsetnickname.ui")));
mixin(uiForm(import("corpus/connectdialog.ui")));
mixin(uiForm(import("corpus/controller.ui")));
mixin(uiForm(import("corpus/default.ui")));
mixin(uiForm(import("corpus/embeddeddialog.ui")));
mixin(uiForm(import("corpus/filespage.ui")));
mixin(uiForm(import("corpus/filterpage.ui")));
mixin(uiForm(import("corpus/finddialog.ui")));
mixin(uiForm(import("corpus/generalpage.ui")));
mixin(uiForm(import("corpus/gridalignment.ui")));
mixin(uiForm(import("corpus/helpdialog.ui")));
mixin(uiForm(import("corpus/identifierpage.ui")));
mixin(uiForm(import("corpus/imagedialog.ui")));
mixin(uiForm(import("corpus/inputpage.ui")));
mixin(uiForm(import("corpus/languagesdialog.ui")));
mixin(uiForm(import("corpus/mydialog.ui")));
mixin(uiForm(import("corpus/newform.ui")));
mixin(uiForm(import("corpus/outputpage.ui")));
mixin(uiForm(import("corpus/passworddialog.ui")));
mixin(uiForm(import("corpus/pathpage.ui")));
mixin(uiForm(import("corpus/phrasebookbox.ui")));
mixin(uiForm(import("corpus/plugindialog.ui")));
mixin(uiForm(import("corpus/previewdialogbase.ui")));
mixin(uiForm(import("corpus/proxy.ui")));
mixin(uiForm(import("corpus/qpagesetupwidget.ui")));
mixin(uiForm(import("corpus/qprintsettingsoutput.ui")));
mixin(uiForm(import("corpus/qprintwidget.ui")));
mixin(uiForm(import("corpus/qsqlconnectiondialog.ui")));
mixin(uiForm(import("corpus/qtgradientview.ui")));
mixin(uiForm(import("corpus/qtresourceeditordialog.ui")));
mixin(uiForm(import("corpus/qttoolbardialog.ui")));
mixin(uiForm(import("corpus/querywidget.ui")));
mixin(uiForm(import("corpus/remotecontrol.ui")));
mixin(uiForm(import("corpus/saveformastemplate.ui")));
mixin(uiForm(import("corpus/signalslotdialog.ui")));
mixin(uiForm(import("corpus/sslerrors.ui")));
mixin(uiForm(import("corpus/statistics.ui")));
mixin(uiForm(import("corpus/stylesheeteditor.ui")));
mixin(uiForm(import("corpus/tabbedbrowser.ui")));
mixin(uiForm(import("corpus/topicchooser.ui")));
mixin(uiForm(import("corpus/translatedialog.ui")));
mixin(uiForm(import("corpus/translationsettings.ui")));
mixin(uiForm(import("corpus/trpreviewtool.ui")));
mixin(uiForm(import("corpus/addlinkdialog.ui")));
mixin(uiForm(import("corpus/filternamedialog.ui")));
mixin(uiForm(import("corpus/bookmarkdialog.ui")));
mixin(uiForm(import("corpus/gridpanel.ui")));
mixin(uiForm(import("corpus/orderdialog.ui")));
mixin(uiForm(import("corpus/validators.ui")));
mixin(uiForm(import("corpus/newactiondialog.ui")));
__gshared int fails, oks, waived;

// Two forms where the ORACLE (QUiLoader) diverges from Qt's own `uic`, and we match `uic`.
// Verified by running `uic` on each file and reading the generated setupUi:
//   addtorrentform  — <property name="margin">8</property> on a QGroupBox's grid: uic emits
//                     setContentsMargins(8,8,8,8), we emit the same, QUiLoader applies 0.
//   qprintsettings  — no margin in the .ui at all: neither uic nor we emit setContentsMargins,
//                     so the value stays lazy and resolves to the style's child margin (9).
//                     QUiLoader materializes it while the tab page is still parentless (a
//                     window -> 11) and freezes that. The dump shows both sides ending with the
//                     SAME parent and isWindow=0, which is what proves it is a freeze, not us.
// Only lines containing one of these markers may differ, and only in these files. Any other
// difference — or a difference in any other file — is still a hard failure.
struct Waiver { string file; string[] markers; }
immutable Waiver[] WAIVERS = [
    Waiver("tests/uic/corpus/addtorrentform.ui",       ["groupBox|layout|QGridLayout"]),
    Waiver("tests/uic/corpus/qprintsettingsoutput.ui", ["copiesTab|layout|QHBoxLayout",
                                                        "optionsTab|layout|QGridLayout"]),
];

// True when every line that differs is covered by a waiver marker for this file.
bool onlyWaived(string p, string a, string b) {
    const(string)[] markers;
    foreach (w; WAIVERS) if (w.file == p) markers = w.markers;
    if (!markers.length) return false;
    auto la = a.splitter('\n').array, lb = b.splitter('\n').array;
    bool covered(string line) {
        foreach (m; markers) if (line.canFind(m)) return true;
        return false;
    }
    foreach (l; la) if (l.length && !lb.canFind(l) && !covered(l)) return false;
    foreach (l; lb) if (l.length && !la.canFind(l) && !covered(l)) return false;
    return true;
}
// Differential check: the tree WE build must serialize identically to QUiLoader's. On a
// mismatch, set DIFF=<path> to dump both serializations to /tmp for inspection.
void ck(T, R)(string p, R root){ T ui; ui.setupUi(root); auto a=qtd_ui_dump(cast(void*)root).fromStringz.idup; auto b=qtd_ui_load_and_dump(p.toStringz).fromStringz.idup; if(a==b){oks++;} else if(onlyWaived(p,a,b)){oks++; waived++; writefln("WAIVED (known QUiLoader-vs-uic margin divergence) %s",p);} else {fails++; writefln("MISMATCH %s",p); if(environment.get("DIFF")==p){ import std.file; std.file.write("/tmp/ours.txt",a); std.file.write("/tmp/oracle.txt",b);} } }
import std.process : environment;
void main(){ int argc=1; char*[2] argv=[cast(char*)"c".ptr,null]; auto app=cast(QApplication)__cpp_new(__traits(classInstanceSize,QApplication)); __qapp_ctor(app,argc,argv.ptr,0);
  ck!Ui_AddTorrentFile("tests/uic/corpus/addtorrentform.ui", QDialog_new());
  ck!Ui_Dialog("tests/uic/corpus/authenticationdialog.ui", QDialog_new());
  ck!Ui_BackSide("tests/uic/corpus/backside.ui", QWidget_new());
  ck!Ui_databaseTranslationDialog("tests/uic/corpus/batchtranslation.ui", QDialog_new());
  ck!Ui_BookWindow("tests/uic/corpus/bookwindow.ui", QMainWindow_new());
  ck!Ui_Calculator("tests/uic/corpus/calculator.ui", QWidget_new());
  ck!Ui_CalculatorForm("tests/uic/corpus/calculatorform.ui", QWidget_new());
  ck!Ui_CertificateInfo("tests/uic/corpus/certificateinfo.ui", QDialog_new());
  ck!Ui_ChatDialog("tests/uic/corpus/chatdialog.ui", QDialog_new());
  ck!Ui_ChatMainWindow("tests/uic/corpus/chatmainwindow.ui", QMainWindow_new());
  ck!Ui_NicknameDialog("tests/uic/corpus/chatsetnickname.ui", QDialog_new());
  ck!Ui_ConnectDialog("tests/uic/corpus/connectdialog.ui", QDialog_new());
  ck!Ui_Controller("tests/uic/corpus/controller.ui", QWidget_new());
  ck!Ui_MainWindow("tests/uic/corpus/default.ui", QMainWindow_new());
  ck!Ui_embeddedDialog("tests/uic/corpus/embeddeddialog.ui", QDialog_new());
  ck!Ui_FilesPage("tests/uic/corpus/filespage.ui", QWidget_new());
  ck!Ui_FilterPage("tests/uic/corpus/filterpage.ui", QWidget_new());
  ck!Ui_FindDialog("tests/uic/corpus/finddialog.ui", QDialog_new());
  ck!Ui_GeneralPage("tests/uic/corpus/generalpage.ui", QWidget_new());
  ck!Ui_Form("tests/uic/corpus/gridalignment.ui", QWidget_new());
  ck!Ui_HelpDialog("tests/uic/corpus/helpdialog.ui", QWidget_new());
  ck!Ui_IdentifierPage("tests/uic/corpus/identifierpage.ui", QWidget_new());
  ck!Ui_ImageDialog("tests/uic/corpus/imagedialog.ui", QDialog_new());
  ck!Ui_InputPage("tests/uic/corpus/inputpage.ui", QWidget_new());
  ck!Ui_LanguagesDialog("tests/uic/corpus/languagesdialog.ui", QDialog_new());
  ck!Ui_MyDialog("tests/uic/corpus/mydialog.ui", QDialog_new());
  ck!Ui_NewForm("tests/uic/corpus/newform.ui", QDialog_new());
  ck!Ui_OutputPage("tests/uic/corpus/outputpage.ui", QWidget_new());
  ck!Ui_PasswordDialog("tests/uic/corpus/passworddialog.ui", QDialog_new());
  ck!Ui_PathPage("tests/uic/corpus/pathpage.ui", QWidget_new());
  ck!Ui_PhraseBookBox("tests/uic/corpus/phrasebookbox.ui", QDialog_new());
  ck!Ui_PluginDialog("tests/uic/corpus/plugindialog.ui", QDialog_new());
  ck!Ui_PreviewDialogBase("tests/uic/corpus/previewdialogbase.ui", QDialog_new());
  ck!Ui_ProxyDialog("tests/uic/corpus/proxy.ui", QDialog_new());
  ck!Ui_QPageSetupWidget("tests/uic/corpus/qpagesetupwidget.ui", QWidget_new());
  // qprintsettingsoutput.ui specifically guards the override-virtual fix: its QVBoxLayout has an
  // explicit spacing=4. QBoxLayout::setSpacing OVERRIDES QLayout::setSpacing, so the binding must
  // dispatch virtually (via the C++ method shim) — a non-virtual call to QLayout's symbol would
  // write the wrong storage and leave the real spacing at the style default. See emit_cxx.d
  // (the "route through a C++ trampoline shim" block) and memory: uic-feature-complete.
  ck!Ui_QPrintSettingsOutput("tests/uic/corpus/qprintsettingsoutput.ui", QWidget_new());
  ck!Ui_QPrintWidget("tests/uic/corpus/qprintwidget.ui", QWidget_new());
  ck!Ui_QSqlConnectionDialogUi("tests/uic/corpus/qsqlconnectiondialog.ui", QDialog_new());
  ck!Ui_QtGradientView("tests/uic/corpus/qtgradientview.ui", QWidget_new());
  ck!Ui_QtResourceEditorDialog("tests/uic/corpus/qtresourceeditordialog.ui", QDialog_new());
  ck!Ui_QtToolBarDialog("tests/uic/corpus/qttoolbardialog.ui", QDialog_new());
  ck!Ui_QueryWidget("tests/uic/corpus/querywidget.ui", QMainWindow_new());
  ck!Ui_RemoteControlClass("tests/uic/corpus/remotecontrol.ui", QMainWindow_new());
  ck!Ui_SaveFormAsTemplate("tests/uic/corpus/saveformastemplate.ui", QDialog_new());
  ck!Ui_SignalSlotDialogClass("tests/uic/corpus/signalslotdialog.ui", QDialog_new());
  ck!Ui_SslErrors("tests/uic/corpus/sslerrors.ui", QDialog_new());
  ck!Ui_Statistics("tests/uic/corpus/statistics.ui", QDialog_new());
  ck!Ui_StyleSheetEditor("tests/uic/corpus/stylesheeteditor.ui", QWidget_new());
  ck!Ui_TabbedBrowser("tests/uic/corpus/tabbedbrowser.ui", QWidget_new());
  ck!Ui_TopicChooser("tests/uic/corpus/topicchooser.ui", QDialog_new());
  ck!Ui_TranslateDialog("tests/uic/corpus/translatedialog.ui", QDialog_new());
  ck!Ui_TranslationSettings("tests/uic/corpus/translationsettings.ui", QDialog_new());
  ck!Ui_TrPreviewToolClass("tests/uic/corpus/trpreviewtool.ui", QMainWindow_new());
  ck!Ui_AddLinkDialog("tests/uic/corpus/addlinkdialog.ui", QDialog_new());
  ck!Ui_FilterNameDialogClass("tests/uic/corpus/filternamedialog.ui", QDialog_new());
  ck!Ui_BookmarkDialog("tests/uic/corpus/bookmarkdialog.ui", QDialog_new());
  ck!Ui_GridPanel("tests/uic/corpus/gridpanel.ui", QWidget_new());
  ck!Ui_OrderDialog("tests/uic/corpus/orderdialog.ui", QDialog_new());
  ck!Ui_ValidatorsForm("tests/uic/corpus/validators.ui", QWidget_new());
  ck!Ui_NewActionDialog("tests/uic/corpus/newactiondialog.ui", QDialog_new());
  writefln("corpus: %d OK (%d waived), %d MISMATCH", oks, waived, fails);
  assert(waived == 2, "a waiver stopped applying — re-verify it against `uic` instead of widening it");
  if (fails) { writeln("corpus_check: FAIL"); assert(false); }
  writefln("corpus_check OK: our uic == QUiLoader across the baseline corpus (%d waived, see WAIVERS)", waived); }
