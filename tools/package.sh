#!/usr/bin/env bash
# 打一个可以直接发布的压缩包（MO2 / Vortex 直接安装，或手动解压进 Data）。
#
# 原则：
#   * 先跑一遍 tools/build.sh，保证包里的东西和源码一致（不发布"改了没编译"的版本）；
#   * 只收玩家需要的文件：esp、脚本 .pex、界面、可选的插件 DLL；
#     **不发脚本源码**（源码在 GitHub 仓库里，见 README 的"从源码构建"）；
#     不收 meta.ini（MO2 本地元数据）、*.bak（构建备份）、
#     SimpleSettlementManagerUI.hotkey（本机热键缓存，每台机器不一样）；
#   * 压缩包内就是 Data 目录结构（esp 在根），MO2 装的时候会自己认出来；
#   * 打包前复查 ESP 的 ESL 标志 —— 没打上的话会白占一个插件槽位，发布前必须拦住。
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
REL="$ROOT/dist/release"

echo "== 1/4 构建（脚本 / 界面 / ESP / 插件）=="
bash "$ROOT/tools/build.sh" | tail -4

echo
echo "== 2/4 取版本号 =="
VER="$(sed -n 's/.*版本 \([0-9][0-9.]*\).*/\1/p' "$ROOT/src/PrismaUI/views/SimpleSettlementManager/index.html" | head -1)"
if [ -z "$VER" ]; then
    echo "  ✗ 没能从界面里读出「版本 x.y.z」（设置页的 about 文案），先把它写上再打包"
    exit 1
fi
NAME="SimpleSettlementManager-$VER"
STAGE="$REL/$NAME"
ZIP="$REL/$NAME.zip"
echo "  $NAME"

echo
echo "== 3/4 整理文件 =="
rm -rf "$STAGE"
mkdir -p "$STAGE"

copy() {
    local rel="$1"
    if [ ! -e "$DEST/$rel" ]; then
        echo "  ✗ 缺文件：$rel（先构建，或检查 MO2 目录）"
        exit 1
    fi
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp -r "$DEST/$rel" "$STAGE/$rel"
    echo "  + $rel"
}

copy SimpleSettlementManager.esp
copy Scripts/SimpleSettlementManager
copy PrismaUI_F4/views/SimpleSettlementManager
copy F4SE/Plugins/SimpleSettlementManagerUI.dll

# ESL 标志复查（TES4 头的 flags 第 8 字节起，0x200 = ESL）
FLAGS_HEX="$(od -An -tx1 -j8 -N4 "$STAGE/SimpleSettlementManager.esp" | tr -d ' \n')"
if [ "${FLAGS_HEX:2:2}" != "02" ]; then
    echo "  ✗ ESP 没有 ESL 标志（flags=$FLAGS_HEX）—— 游戏或 MO2 占着 ESP 时构建会跳过打标，"
    echo "    关掉它们再重新打包。"
    exit 1
fi
echo "  ✓ ESP 带 ESL 标志（flags=$FLAGS_HEX）"

cat > "$STAGE/README.md" <<'READMEEOF'
# 据点管理（Simple Settlement Manager）

> 版本 **@VERSION@**。全息卡带式的据点与居民管理工具，**不需要 Sim Settlements 2**。

## 功能

- **据点页**：所有据点一屏看完（人口 / 床位 / 食物 / 水 / 电 / 防御 / 缺人），供应网络自动分组并合计。
  点开某一行可以看到床位、空闲岗位和居民概况，并直接批量操作。**当前所在据点**的数据实时刷新，
  其他据点显示上次到访时的快照（走过去或快速旅行一次就会更新）。
- **居民页**：按职业分类（农民 / 工人 / 拾荒者 / 商人 / 守卫 / 供应者 / 无业 / 机器人）。
  居民详情里有职业状态、岗位、床位和 S.P.E.C.I.A.L. 表，可以改名、召唤到身边、解除岗位、
  迁往其他据点、开除，也可以给某个人指派工作或运输线。
- **岗位页**：以岗位为主，一键填补空岗 —— 用最少的人填（同一个人可以兼多块同类作物 / 多座哨塔，
  上限跟游戏自身的规则一致）。摊位（商人）支持"顶替"：直接把原来的人换下来。
- 「可指挥 / 可移动 / 可运输」三个开关点击即生效，生效结果另以通知确认。
- 界面中英双语，可在设置页切换；热键（默认 F10）也可在设置页改。

## 依赖（缺一不可）

| 需要 | 版本 |
| --- | --- |
| Fallout 4 | AE 1.11.137 - 1.11.240（只支持这条线） |
| F4SE | 0.7.4 或更新 |
| PrismaUI F4 | **2.2.0** 或更新 |
| Workshop Framework | 任意近期版本（岗位指派与三个开关走它的接口） |

不依赖 Sim Settlements 2，也不依赖 What's Your Name / NODE.LITE。

## 安装

- **MO2 / Vortex**：直接安装本压缩包即可（包内就是 Data 目录的结构）。
- **手动**：把包里的内容解压到 `Fallout 4/Data/`。

`F4SE/Plugins/SimpleSettlementManagerUI.dll` 是**可选件**：它只负责"面板聚焦时压住原版暂停菜单"，
让按 Esc 退出更干净。删掉它功能不受影响，只是按 Esc 时暂停菜单会闪一下。

## 使用

进游戏后卡带会自动放进背包（丢了也会自动补发）。在哔哔小子的「全息卡带」里播放
**据点管理**即可打开面板；面板打开时按 F10 或 Esc 关闭。

## 许可

GPL-3.0。**源码（含 `F4SE/Plugins/SimpleSettlementManagerUI.dll` 的源码）在本 mod 的项目主页 / 仓库里**
—— 按 GPL 的要求，拿到二进制的人都能拿到对应源码。仓库地址见发布页。

## 已知限制

- 居民 / 床位 / 岗位的**明细**只对当前所在的据点可用，其他据点显示上次到访的快照。
- 被任务或别名固定了名字的居民，改名不会显示出来（面板会明确提示，不会假装成功）。
- 改名一旦生效会写进存档，卸载本 mod 之后名字仍然保留。

## English

Simple Settlement Manager **@VERSION@** — a holotape-based settlement & settler manager for Fallout 4. No Sim Settlements 2 required.

**Requirements:** Fallout 4 AE 1.11.137–1.11.240 · F4SE 0.7.4+ · PrismaUI F4 2.2.0+ · Workshop Framework.

Install with MO2/Vortex, or extract into `Fallout 4/Data`. The bundled
`F4SE/Plugins/SimpleSettlementManagerUI.dll` is optional — it only keeps the vanilla pause menu out of the
way while the panel is focused. The holotape is added to your inventory automatically; play it from
the Pip-Boy to open the panel (default hotkey F10).

**License:** GPL-3.0. The full source (including the F4SE plugin's source) is in the project repository
linked from the mod page.

**Known limits:** per-settlement detail (residents/beds/jobs) is live only for the settlement you are
currently in; others show the snapshot from your last visit. Renames do not show for NPCs whose name is
fixed by a quest alias (the panel tells you instead of pretending it worked).
READMEEOF
# 版本号来自界面里那一条（同一份来源，避免包里写着一个版本、界面显示另一个）
sed -i "s/@VERSION@/$VER/g" "$STAGE/README.md"
echo "  + README.md（版本 $VER）"

echo
echo "== 4/4 打包 =="
rm -f "$ZIP"
# 逐条目写入，**路径分隔符强制用 `/`**。
# 不能用 [ZipFile]::CreateFromDirectory：.NET Framework 那个实现会把目录分隔符写成 `\`，
# 而 zip 规范要求 `/` —— 有些解压器/mod 管理器会把 `\` 当成文件名的一部分，
# 于是装出来是"F4SE\Plugins\SimpleSettlementManagerUI.dll"这么一个怪名字的单文件（踩过）。
powershell -NoProfile -Command "
Add-Type -AssemblyName System.IO.Compression.FileSystem
\$stage = '$(cygpath -w "$STAGE")'
\$zip   = '$(cygpath -w "$ZIP")'
\$z = [System.IO.Compression.ZipFile]::Open(\$zip, 'Create')
try {
    Get-ChildItem -LiteralPath \$stage -Recurse -File | ForEach-Object {
        \$rel = \$_.FullName.Substring(\$stage.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(\$z, \$_.FullName, \$rel) | Out-Null
    }
} finally { \$z.Dispose() }
" || {
    echo "  ✗ 压缩失败"
    exit 1
}

echo "  包内文件："
powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; \$z=[System.IO.Compression.ZipFile]::OpenRead('$(cygpath -w "$ZIP")'); \$z.Entries | ForEach-Object { '{0,10}  {1}' -f \$_.Length, \$_.FullName }; \$z.Dispose()" | sed 's/^/    /'

echo
echo "发布包：$ZIP"
ls -l --time-style=+%Y-%m-%d_%H:%M "$ZIP" | awk '{printf "  大小 %.2f MB\n", $5/1048576}'
