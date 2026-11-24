#!/bin/sh
# 一键构建 mkxp-z 的 iOS 静态库（给 GameShelf 的 RGSS / VX Ace 兼容分支用）。
#
# 产物（iOS arm64 真机）：
#   build/libmkxpz-core.a      引擎核心（渲染/音频/事件循环/文件系统/宿主桥）
#   build/mkxp18-merged.o      Ruby 1.8 绑定（RGSS1 / RPG Maker XP）
#   build/mkxp19-merged.o      Ruby 1.9 绑定（RGSS2/RGSS3 / VX / VX Ace）
#   build/mkxp31-merged.o      Ruby 3.1 绑定（新版游戏 / Pokemon Essentials）
#
# 依赖全部走 mateo-m/empo-deps 的预编译包（SDL2 / ANGLE / OpenAL / physfs /
# freetype / openssl / 各版本 libruby），不需要自己交叉编译 Ruby。
#
# 用法：sh build-mkxp-ios.sh [输出目录, 默认 ./build]
set -eu

OUT="$(cd "$(dirname "$0")" && pwd)/${1:-build}"
WORK="${MKXP_WORK:-/tmp/mkxp-ios-build}"
ENGINE_REPO="https://github.com/genexix05/mkxp-z-apple-mobile.git"
HMODE7_REPO="https://github.com/mateo-m/hmode7-apple-mobile.git"
SDK_NAME="${SDK_NAME:-iphoneos}"
ARCH="${ARCH:-arm64}"
MIN_OS="${MIN_OS:-17.0}"

echo "==> 1/5 拉取源码到 $WORK"
mkdir -p "$WORK"
if [ ! -d "$WORK/mkxp-mobile/.git" ]; then
    rm -rf "$WORK/mkxp-mobile"
    git clone --depth 1 "$ENGINE_REPO" "$WORK/mkxp-mobile"
fi
cd "$WORK/mkxp-mobile"

# hmode7 在上游是 SSH 子模块，这里改用 https 直取
if [ ! -f hmode7/src/hm7_apply_opacity.h ]; then
    rm -rf hmode7
    git clone --depth 1 "$HMODE7_REPO" hmode7
fi

echo "==> 2/5 下载预编译依赖（SDL2/ANGLE/OpenAL/Ruby...）"
sh tools/fetch-deps-ios.sh --sdk "$SDK_NAME"

TREE="deps/build-$SDK_NAME-$ARCH"
ANGLE="deps/ANGLE/$SDK_NAME"
INCLUDES="--include $TREE/include --include $TREE/include/AL --include $TREE/include/SDL2 \
 --include $TREE/include/pixman-1 --include $TREE/include/uchardet \
 --include $TREE/include/freetype2 --include $ANGLE/include"

mkdir -p "$OUT"

echo "==> 3/5 构建引擎核心 libmkxpz-core.a"
sh tools/build-core-ios.sh --sdk "$SDK_NAME" --arch "$ARCH" --min-os "$MIN_OS" \
    --obj "$WORK/obj/core" --out "$OUT" $INCLUDES

echo "==> 4/5 构建 Ruby 绑定（1.8 / 1.9 / 3.1）"
build_binding() {
    # $1=18|19|31  $2=头文件目录  $3=static 库  $4=ext 库
    sh tools/build-binding-ios.sh --ruby "$1" --sdk "$SDK_NAME" --arch "$ARCH" --min-os "$MIN_OS" \
        --obj "$WORK/obj/binding$1" --out "$OUT" --scratch "$WORK/scratch$1" \
        --ruby-include "$TREE/include/$2" \
        --static-lib "$TREE/lib/$3" --ext-lib "$TREE/lib/$4" $INCLUDES
}
build_binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a
build_binding 19 ruby19 libruby19-static.a libruby19-ext.a
build_binding 18 ruby18 libruby18-static.a libruby18-ext.a

echo "==> 5/5 完成，产物在 $OUT"
ls -la "$OUT"
echo
echo "依赖库路径（链接时用 -L 指向）："
echo "  $WORK/mkxp-mobile/$TREE/lib"
echo "  $WORK/mkxp-mobile/$ANGLE/lib"
echo "头文件路径："
echo "  $WORK/mkxp-mobile/$TREE/include{,/AL,/SDL2,/pixman-1,/uchardet,/freetype2}"
echo "  $WORK/mkxp-mobile/$ANGLE/include"
