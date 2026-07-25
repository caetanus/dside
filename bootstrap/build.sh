#!/bin/sh
# build.sh — compile the C++ shim, then compile+link the D app against it.
# Proves the toolchain: D -> C ABI shim -> Qt6 -> QML window.
set -e
cd "$(dirname "$0")"

QT_MODS="Qt6Qml Qt6Gui Qt6Core"
CXXFLAGS="$(pkg-config --cflags $QT_MODS) -std=c++17 -fPIC -O2"
QT_LIBS="$(pkg-config --libs $QT_MODS)"

echo ">> compiling C++ shim (clang++)"
clang++ $CXXFLAGS -c qml_shim.cpp -o qml_shim.o

# ldc2 passes each -L<arg> straight to the linker, so prefix every pkg-config
# token (-lQt6Qml, -L/path, ...) with -L. libstdc++ is needed for the C++ shim.
LDC_LIBS=""
for tok in $QT_LIBS -lstdc++; do
    LDC_LIBS="$LDC_LIBS -L$tok"
done

echo ">> compiling + linking D app (ldc2)"
ldc2 app.d qml_shim.o $LDC_LIBS -of=hello

echo ">> built ./hello"
echo "   run:      ./hello"
echo "   headless: QT_QPA_PLATFORM=offscreen ./hello --selftest"
