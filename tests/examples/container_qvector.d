// Container return that is QVector<QRgb> on Qt5 (distinct QArrayData layout) and
// QList<uint> on Qt6 — QImage::colorTable(). On Qt5 this used to be read with the wrong
// (QListData) layout -> garbage length -> OOM; now the generator emits a separate Qt5
// QVector module (QArrayData: size@4, contiguous data at d+offset). Runs on BOTH versions.
import qt.widgets.qimage;
import std.stdio;
void main() {
    auto img = new QImage(4, 4, QImage.Format.Format_Indexed8);
    img.setColorCount(3);
    img.setColor(0, 0xFFFF0000);
    img.setColor(1, 0xFF00FF00);
    img.setColor(2, 0xFF0000FF);
    auto t = img.colorTable();
    assert(t.length == 3, "colorTable length == 3");
    assert(t[0] == 0xFFFF0000 && t[1] == 0xFF00FF00 && t[2] == 0xFF0000FF, "colorTable values");
    writefln("container_qvector OK: QImage.colorTable() = [%(0x%08X, %)]", t);
}
