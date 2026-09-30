#!/usr/bin/env bash
# 构建插件并部署到 MO2 的 mod 目录。
#
# 插件是**可选**的：它只负责"面板聚焦时压住原版暂停菜单"（Esc 干净退出、Alt-Tab 不再
# 冻住暂停菜单指针）。没装它 Papyrus 侧仍会事后把菜单关掉，功能不缺，只是会闪一下。
#
# 为什么用 cmd 而不是 bash 调 xmake：git-bash 里 xmake 会继承 MSYS2 环境、
# 平台被选成 mingw；xmake.lua 里虽然写了 set_plat("windows")，但平台是在读项目文件之前
# 定的。走 cmd（顺便用 tools/build.bat 固定 -p windows -a x64 --toolchain=msvc）最稳。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 本机路径来自 tools/local.conf（不进版本库）
CONF="$ROOT/tools/local.conf"
if [ ! -f "$CONF" ]; then
    echo "✗ 缺少 $CONF（先 cp tools/local.conf.example tools/local.conf 再改路径）"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"
: "${MO2_MODS:?tools/local.conf 里没有 MO2_MODS}"

DEST="$MO2_MODS/SimpleSettlementManager"
DLL="$ROOT/plugin/dist/F4SE/Plugins/SimpleSettlementManagerUI.dll"

echo "== 构建插件 =="
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    cmd.exe /c "$(cygpath -w "$ROOT/plugin/tools/build.bat")" 2>&1 | tail -6

if [ ! -f "$DLL" ]; then
    echo "✗ 没有产物：$DLL"
    exit 1
fi

echo
echo "== 部署 =="
mkdir -p "$DEST/F4SE/Plugins"
cp "$DLL" "$DEST/F4SE/Plugins/SimpleSettlementManagerUI.dll"
ls -l --time-style=+%H:%M:%S "$DEST/F4SE/Plugins/SimpleSettlementManagerUI.dll"
echo "（插件是可选件：删掉这个 DLL 就退回 Papyrus 的事后清理，功能不受影响）"
