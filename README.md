# 据点管理终端（Simple Settlement Manager）

Fallout 4 的据点 / 居民管理 mod：一盘全息卡带打开管理面板，把**所有据点**的产出、床位、居民、
岗位放在一屏里看和改。**不依赖 Sim Settlements 2。**

<!-- 截图：进仓库前把三张图放进 docs/ 并在这里引用，例如：
![据点页](docs/preview-settlements.png) -->

## 做什么

- **据点页**：所有据点一屏看完（人口 / 床位 / 食物 / 水 / 电 / 防御 / 缺人），供应网络自动分组
  并合计。点开某一行看床位、空闲岗位、居民概况，并直接批量操作。当前所在据点的数据实时刷新，
  其他据点显示上次到访时的快照。
- **居民页**：按职业分类（农民 / 工人 / 拾荒者 / 商人 / 守卫 / 供应者 / 无业 / 机器人）。
  居民详情有职业状态、岗位、床位和 S.P.E.C.I.A.L. 表，可改名、召唤、解除岗位、迁往其他据点、
  开除，也能给某个人指派工作或运输线。
- **岗位页**：以岗位为主，一键填补空岗 —— 用最少的人填（同一人可以兼多块同类作物 / 多座哨塔，
  上限跟游戏自身规则一致）。摊位（商人）支持顶替：直接把原来的人换下来。
- 「可指挥 / 可移动 / 可运输」三个开关点击即生效，生效结果另以通知确认。
- 界面中英双语（设置页可切），热键（默认 F10）可改。

开发笔记（技术要点与原版行为的一些实测结论）见 [DEVELOPMENT.md](DEVELOPMENT.md)；
CK 建记录的步骤见 [docs/M0-build-records.md](docs/M0-build-records.md)。

## 依赖（运行 mod）

| 需要 | 版本 |
| --- | --- |
| Fallout 4 | AE 1.11.137 - 1.11.240（只支持这条线） |
| F4SE | 0.7.4 或更新 |
| PrismaUI F4 | **2.2.0** 或更新（界面层，必需；Nexus 上搜 PrismaUI） |
| [Workshop Framework](https://www.nexusmods.com/fallout4/mods/35004) | 任意近期版本（岗位指派与三个开关走它的接口） |

不需要 Sim Settlements 2。

## 安装

- **MO2 / Vortex**：安装发布页的 `SimpleSettlementManager-<版本>.zip`；或者直接指向本仓库构建出的
  mod 文件夹（`tools/build.sh` 会部署到你的 MO2 mods 目录）。
- **手动**：把包里的内容解压到 `Fallout 4/Data/`。

`F4SE/Plugins/SimpleSettlementManagerUI.dll` 是**可选件**：它只负责"面板聚焦时压住原版暂停菜单"，
让按 Esc 退出更干净。删掉它功能不受影响，只是按 Esc 时暂停菜单会闪一下。

## 从源码构建

仓库不含第三方代码，clone 后先补齐两样：

```bash
git clone --recursive https://github.com/Suwuming1987/SimpleSettlementManager
cd SimpleSettlementManager

# 1) Papyrus 编译要用的第三方脚本源码（不进版本库，从各自发行包 / 游戏目录取）
#    vendor/vanilla/Source/…      官方脚本压缩包里的 Source（含 Institute_Papyrus_Flags.flg）
#    vendor/wsfw/Source/User/…    Workshop Framework 自带
#    vendor/prismaui/Source/…     PrismaUI F4 自带
# 2) 本机路径
cp tools/local.conf.example tools/local.conf   # 改里面的 FO4_DIR / MO2_MODS
```

然后（在 git-bash 里执行）：

```bash
bash tools/build.sh      # 编译 Papyrus + 同步界面 → MO2 + 构建插件 + ESP 规范化 / 打 ESL
bash tools/package.sh    # 打一个可以直接发布的 zip（→ dist/release/）
```

插件（C++）用 portable xmake + [CommonLibF4](https://github.com/libxse/commonlibf4)
（Git submodule，已固定在构建通过的 commit 上）。xmake 本体不在版本库里：按
[plugin/tools/build.bat](plugin/tools/build.bat) 的说明把 xmake 放到 `plugin/tools/xmake/`，
或者直接删掉整个 `plugin/` —— 插件是可选件，没有它 mod 照样能用。

## 许可

GPL-3.0，见 [LICENSE](LICENSE)。这是被 CommonLibF4 决定的：插件链接了 GPL-3.0 的 CommonLibF4，
所以整个仓库按 GPL-3.0 发布。发布二进制（含那个可选的插件 DLL）时，"对应源码"就是本仓库 ——
请在发布页给出仓库地址。Papyrus 脚本 / ESP / 界面本身并不链接 CommonLibF4。

## 致谢

- [CommonLibF4](https://github.com/libxse/commonlibf4)（GPL-3.0）—— 插件的工具链与运行时
- PrismaUI F4 —— 界面层
- [Workshop Framework](https://www.nexusmods.com/fallout4/mods/35004) —— 岗位指派 / 据点脚本接口
