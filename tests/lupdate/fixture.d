// Fixture for the lupdate-d extraction golden test. Exercises every form the runtime tr()
// produces, so the .ts lupdate-d emits from THIS file must match the golden checked in beside it.
module fixture;
import qtmoc : tr, translate;

class Dialog {
    void build() {
        auto a = tr("Open file");              // tr("x")        -> context = module "fixture"
        auto b = tr("Delete?", "confirm");     // tr("x", d)     -> disambiguation "confirm"
        auto c = "Save".tr;                    // "x".tr (UFCS)  -> context "fixture"
        auto d = "Cancel".tr("button");        // "x".tr(d)      -> disambiguation "button"
        auto e = translate("Menu", "Quit");    // explicit context "Menu"
    }
}
