#!/usr/bin/env bash
# 据点管理终端 —— 编译 + 部署到 MO2
#
# 用法：  bash tools/build.sh
#
# 做三件事：
#   1. 用 CK 自带的 PapyrusCompiler 编译 src 下的全部脚本到 dist/Scripts/
#   2. 把产物（.pex + 源码 + meta.ini）同步进 MO2 的 mod 文件夹，CK 和游戏都能看到
#   3. 汇总状态（含 CK 生成的 ESP 是否就位）
#
# 注意（实测结论，别踩）：
#   * PapyrusCompiler 即使编译失败也返回 0，所以这里自己验证产物。
#   * .ppj 里的路径必须是正斜杠绝对路径（编译器不解析反斜杠和相对路径）。
#   * 不会动 MO2 mod 文件夹里的 ESP —— 那是 CK 生成的，覆盖会丢东西。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODNAME="SimpleSettlementManager"

# 本机路径来自 tools/local.conf（不进版本库）。没有就报错说清楚怎么建。
CONF="$ROOT/tools/local.conf"
if [ ! -f "$CONF" ]; then
    echo "✗ 缺少 $CONF"
    echo "  先执行：cp tools/local.conf.example tools/local.conf，再把里面的路径改成你自己的。"
    exit 1
fi
# shellcheck source=/dev/null
. "$CONF"
: "${FO4_DIR:?tools/local.conf 里没有 FO4_DIR}"
: "${MO2_MODS:?tools/local.conf 里没有 MO2_MODS}"

GAME="$FO4_DIR"
COMPILER="$GAME/Papyrus Compiler/PapyrusCompiler.exe"
DEST="$MO2_MODS/$MODNAME"

# .ppj 是生成物（里面有绝对路径，不进版本库）：按 local.conf 里的路径从模板生成。
# 写进去的是 **cygpath -m 形式**（E:/foo/bar）—— 正斜杠是 PapyrusCompiler 要求的，
# 而盘符形式对它是明确可解的（git-bash 的 /e/foo 虽然在本机侥幸能用，但不保证）。
echo "== 0/4 生成编译工程（.ppj）=="
ROOT_WIN="$(cygpath -m "$ROOT")"
sed "s|@ROOT@|$ROOT_WIN|g" "$ROOT/$MODNAME.ppj.in" > "$ROOT/$MODNAME.ppj"
echo "  $MODNAME.ppj ← $MODNAME.ppj.in（ROOT=$ROOT_WIN）"

echo
echo "== 1/4 编译 =="
"$COMPILER" "$ROOT/$MODNAME.ppj" 2>&1 | tail -4

echo
echo "== 2/4 校验产物 =="
fail=0
while IFS= read -r psc; do
    rel="${psc#$ROOT/src/Scripts/Source/User/}"
    pex="$ROOT/dist/Scripts/${rel%.psc}.pex"
    if [ ! -f "$pex" ]; then
        echo "  ✗ 缺少产物: ${rel%.psc}.pex"
        fail=1
    elif [ "$pex" -ot "$psc" ]; then
        echo "  ! 产物比源码旧（编译可能失败）: ${rel%.psc}.pex"
        fail=1
    else
        echo "  ✓ ${rel%.psc}.pex"
    fi
done < <(find "$ROOT/src/Scripts/Source/User" -name '*.psc')

if [ "$fail" -ne 0 ]; then
    echo
    echo "编译未通过，停止部署。上面编译器输出里应该有具体行号。"
    exit 1
fi

echo
echo "== 3/4 部署到 MO2 =="
# **先清空再同步**：只清我们自己 mod 目录里的三棵子树（$DEST 是本 mod 独占的，安全）。
# 为什么必须清：部署是"只拷贝不删除"的，一旦改过脚本命名空间 / 视图目录名 / 插件 DLL 名，
# 旧文件就会留着 —— 旧 .pex 是死重量，旧 DLL 更糟（F4SE 会两个都加载，热键被处理两次）。
# ESP 与 meta.ini 不在这里清（ESP 是 CK 生成的，见下）。
rm -rf "$DEST/Scripts" "$DEST/PrismaUI_F4" "$DEST/F4SE"
mkdir -p "$DEST/Scripts" "$DEST/Scripts/Source/User" "$DEST/F4SE/Plugins"
cp -r "$ROOT/dist/Scripts/." "$DEST/Scripts/"
cp -r "$ROOT/src/Scripts/Source/User/." "$DEST/Scripts/Source/User/"

# PrismaUI 界面（HTML/CSS/JS）→ mod 文件夹的 PrismaUI_F4/views/…
if [ -d "$ROOT/src/PrismaUI" ]; then
    mkdir -p "$DEST/PrismaUI_F4"
    cp -r "$ROOT/src/PrismaUI/." "$DEST/PrismaUI_F4/"
    echo "  已同步界面: PrismaUI_F4/views/$(ls "$ROOT/src/PrismaUI/views" | head -1)/index.html"
fi

if [ ! -f "$DEST/meta.ini" ]; then
    cp "$ROOT/tools/meta.ini" "$DEST/meta.ini"
fi
echo "  已同步到: $DEST"

# ESP 是 CK 生成并保存到 MO2 目录里的，但它也要进版本库（别人 clone 下来才有得用）。
# 这里只处理"MO2 里没有、仓库里有"的情况（补一份过去，让构建能继续）；
# 反方向（MO2 → 仓库）在脚本最后做，因为下面还要对 ESP 做规范化/打 ESL 标记。
if [ ! -f "$DEST/$MODNAME.esp" ] && [ -f "$ROOT/$MODNAME.esp" ]; then
    cp "$ROOT/$MODNAME.esp" "$DEST/$MODNAME.esp"
    echo "  ESP: 已从仓库部署到 MO2（$MODNAME.esp）"
fi

# 可选件：配套的 F4SE 插件（面板聚焦时压住原版暂停菜单）。
# 失败不阻塞主 mod 的部署 —— 插件只是让 Esc 退出更干净，没它照样能用。
#
# **这一步必须放在下面 ESP 处理的外面**：插件只碰 plugin/ 和自己那个 DLL，跟 ESP 无关，
# 以前它被嵌在"ESP 可写"的分支里 → 游戏/MO2 占着 ESP 时整块被跳过，
# 于是"改了插件源码 + 构建成功"其实什么都没编（DLL 的 MD5 一字未变，一天踩了两次）。
if [ -f "$ROOT/plugin/xmake.lua" ]; then
    echo
    echo "== 构建配套插件（可选件）=="
    if ! bash "$ROOT/tools/build_plugin.sh" >/tmp/sm_plugin.log 2>&1; then
        echo "  ! 插件构建/部署失败，本次只部署主 mod。日志末尾："
        tail -5 /tmp/sm_plugin.log | sed 's/^/    /'
    else
        tail -2 /tmp/sm_plugin.log | sed 's/^/  /'
    fi
fi

# CK 在加载状态不对时会写出"自身记录索引 > master 数"的 FORM ID（实测只有这种情况会出问题，
# 且引擎是否容忍不确定）。这里每次构建都顺手校正一次，幂等。
#
# 两个"看起来像成功其实没做"的坑，所以判定要分开写：
#   * Windows 上 `python` 常常是应用商店的占位程序 —— **存在、能查到、一跑就报"未安装"**。
#     以前把它和"文件被占用"混在同一个判断里，于是消息一直说"游戏正在运行？"，
#     实际原因是根本没有可用的 Python（踩过）。现在先挑一个真能跑的。
#   * 游戏/MO2 占着 ESP 时确实会写不进去，这时才该说"被占用"。
PY=""
for c in py python python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then
        PY="$c"; break
    fi
done

echo
if [ -z "$PY" ]; then
    echo "== 跳过 ESP 处理：找不到可用的 Python =="
    echo "   （PATH 里的 python 可能是应用商店占位程序。装一个 Python，或用 py 启动器，然后重新构建）"
elif [ ! -f "$DEST/$MODNAME.esp" ]; then
    echo "== 跳过 ESP 处理：MO2 目录里还没有 $MODNAME.esp（按 docs/M0-build-records.md 在 CK 里建）=="
else
    ESP_WIN="$(cygpath -w "$DEST/$MODNAME.esp")"
    if "$PY" -c "open(r'$ESP_WIN', 'r+b').close()" 2>/dev/null; then
        echo "== 修正 ESP 的 FORM ID 索引 =="
        "$PY" "$ROOT/tools/normalize_esp.py" "$DEST/$MODNAME.esp" | sed 's/^/  /'
        echo
        echo "== 修正记录里的中文编码（GBK -> UTF-8）=="
        "$PY" "$ROOT/tools/fix_text_encoding.py" "$DEST/$MODNAME.esp" | sed 's/^/  /'
        echo
        echo "== 打上 ESL（轻量插件）标记 =="
        # CK 每次保存 ESP 都会重写 TES4 头的 flags，所以这里每次补一遍（幂等）。
        # 记录 ID 必须都在 0x800~0xFFF，脚本会先检查再写。
        "$PY" "$ROOT/tools/set_esl.py" "$DEST/$MODNAME.esp" | sed 's/^/  /'
    else
        echo "== 跳过 ESP 处理：文件被占用（游戏或 MO2 正在运行）—— 脚本已部署，ESP 相关内容本次未检查 =="
    fi
fi

# MUST 放在最后：把处理过的 ESP 拷回仓库（上面可能刚打了 ESL 标记 / 改了编码）。
# 内容是幂等的，所以这里每次都拷，让 git 自己判断有没有变化。
if [ -f "$DEST/$MODNAME.esp" ]; then
    if ! cmp -s "$DEST/$MODNAME.esp" "$ROOT/$MODNAME.esp"; then
        cp "$DEST/$MODNAME.esp" "$ROOT/$MODNAME.esp"
        echo "  ESP: MO2 目录里的版本已拷回仓库 $MODNAME.esp（记得提交）"
    fi
fi

