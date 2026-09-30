# M0：在 Creation Kit 里建记录

目标：进游戏后，哔哔小子里有一盘「据点管理终端」全息卡带，播放它 → 显示终端菜单 → 点「查看当前据点」→ 弹出你所在据点的汇总报表。

脚本部分我已经写好并编译通过（`dist/Scripts/SimpleSettlementManager/ControllerQuest.pex`）。
这一篇是你在 CK 里要做的部分，**按顺序做**（终端 → 卡带 → 任务，后面依赖前面）。

---

## 0. 前置

* CK 已装到游戏目录：`E:\SteamLibrary\steamapps\common\Fallout 4\CreationKit.exe`
  （原本装在 D: 的那份 Data 里没有游戏主文件，打不开 Fallout4.esm，我把 CK 复制进游戏目录了。D: 那份可以留作备份，也别再从 Steam 启动它。）
* 基础脚本已铺好：`Data\Scripts\Source\Base\`（7833 个文件，含 `Institute_Papyrus_Flags.flg`）。
  CK 编译 Fragment 靠这个目录，缺了会报找不到脚本。
* **在 MO2 里做两件事**：
  1. 左侧列表会出现新 mod 文件夹 **SimpleSettlementManager** —— 勾选启用它（里面已经有编译好的 .pex 和源码，CK 要通过 MO2 才能看到）。
  2. 注册 CK 可执行程序：MO2 顶部齿轮 → *编辑可执行程序* → 加一条：
     * 标题：`Creation Kit`
     * 程序：`E:\SteamLibrary\steamapps\common\Fallout 4\CreationKit.exe`
     * 勾选「使用应用程序目录」（Start in）
     * 在「覆盖」区勾选 **Create files in mod instead of overwrite**，下拉选 `SimpleSettlementManager`
       → 这样 CK 保存的 ESP 会直接落进 mod 文件夹，不用手工搬。
  3. 以后都从 MO2 启动 CK（不要从 Steam 启动，否则看不到我们的脚本）。

---

## 1. 新建插件

1. MO2 里启动 **Creation Kit**。
2. `File → Data…` → 只勾 **Fallout4.esm**（不要勾 DLC，我们不需要）→ OK → 等它加载完（几分钟，硬盘会响）。
3. `File → Save`，文件名输入 `SettlementManager` → 生成 `SimpleSettlementManager.esp`
   （如果提示没有活动文件，用 `Save As` 新建）。
4. 之后每建完几条记录就 `Ctrl+S` 存一次。

---

## 2. 终端记录 `SM_MainMenu`

`Object Window` → 左侧分类树里找 **Terminal**（在 `World Objects` 或 `Miscellaneous` 下；也可以直接在右上搜索框里输 `Terminal`）。

右键 → **`New`**。不要用 `Duplicate`：它会把原版终端的脚本、条件、关联一起复制过来，清理比新建麻烦。

⚠️ 两个前提（错了记录就建歪了）：

1. **先在类别列表里选中 `Terminal`**。CK 的搜索框只过滤"当前类别"，不会切换类别——
   如果当前停在 Furniture / Container 之类，右键 New 出来的是那个类型的记录。截图里那条名字像中文家具的记录就是这种情况。
2. **确认当前活动插件是 `SimpleSettlementManager.esp`**（CK 标题栏能看到）。
   如果 CK 是"无活动文件"状态启动的，New 出来的记录会落到 Fallout4.esm 里——那就毁了游戏主文件。
   不对就先 `File → Save As…` 存成 `SimpleSettlementManager`。

不论哪种，按这张表填（字段名就是记录窗口里的字段名）：

| 字段 | 值 |
| --- | --- |
| `ID` | `SM_MainMenu` |
| `Name` | `据点管理终端` |
| `Header Text` | `据点管理终端`（终端界面顶部那一行） |
| `Welcome Text` | `选择要执行的操作`（开场显示的文字） |
| `Model` | **留空**。WSFW 的设置终端记录就没有模型（我解析过它的 esm）——它只通过卡带进入，从不摆到世界里。以后想让它在工坊里能造，再补模型。 |
| `Holds Holotape` | 不勾（那是世界里的终端用来放卡带的） |
| `Body Text` / `Keywords` / `Actor Values` | 全部留空 |

### 2.1 挂脚本（关键，替代了原先的 Fragment 方案）

⚠️ **CK 的老毛病，先看这条**：**新建的记录在设置 EditorID 并关窗之前，Papyrus Scripts 区整个是灰的（连 `Add` 都点不了）。**
所以顺序必须是：填好 `ID` → `OK` 关窗 → **重新双击打开这条记录** → 这时 `Add` 才可用。
这个规矩对**所有记录**都适用（后面建任务记录挂脚本时一样）。

在记录窗口右上角 `Papyrus Scripts` 区 → **`Add`** → 选 `SimpleSettlementManager:TerminalMenu`
（列表里没有就说明 MO2 没启用 mod，或者 CK 不是从 MO2 启动的）→ 选中它 → **`Properties`** → **Auto-Fill All**：

| 属性 | 期望值 |
| --- | --- |
| `SM_ControllerQuest` | 我们的任务 `SM_ControllerQuest`（第 4 步建好后才有；先存着，回头回来 Auto-Fill） |
| `iMenuID_Report` / `iMenuID_Reissue` | 默认 1 / 2，要和下面菜单项的 `ID` 列一致 |

> 为什么不用 Fragment：哔哔小子播放全息卡带时终端是"表单"而不是世界里的引用（此时 `akTerminalRef` 为 `None`，CK wiki 有明确记载），所以我们用一个脚本的 `OnMenuItemRun` 按菜单项 ID 分派，CK 侧不用生成任何 Fragment 脚本。若实机发现事件不触发，备选方案是把菜单项类型改成 `Submenu` 指向一个占位终端（事件同样会触发）。

### 2.2 加两个菜单项

在上面的 `Menu Items` 列表里加两项（该区域的右键菜单或 `New` 按钮）：

| Item Text | 类型 | ID（记下 CK 给的数字） |
| --- | --- | --- |
| `查看当前据点` | `Display Text`（保持默认即可） | 期望 `1` |
| `重新发放全息卡带` | `Display Text` | 期望 `2` |

* `Display Text` 框里随便填一句占位文字（比如 `（见弹窗）`）——真正的报表是我们脚本现编的弹窗。
* **`ID` 列的数字要告诉我**（或者你在能改的情况下直接设成 1 / 2）。CK 的 ID 如果不是 1/2，两个功能可能对调；脚本里会打日志 `[SM] OnMenuItemRun id=N`，一测就知道。
* `Item Conditions`、`Submenu`、`Display Image` 都不用动。

---

## 3. 全息卡带记录 `SM_Holotape`

**已实测确认的机制**：FO4 的全息卡带是 **NOTE 记录**（不是 Misc），它上面有一个指向终端记录的字段——记录格式里是 `SNAM`。我拿 Workshop Framework 自己的设置卡带验证过：

```
NOTE 010035DE  WSFW_ControlHolotape      ← 卡带
   MODL = "Props\Holotape_Prop.nif"
   SNAM = 010035DA  →  TERM 010035DA "Workshop Framework Controls"   ← 播放时显示的终端
```

`Object Window` → 分类 `Items` 下找 **Note** / **Holotape**（搜 `Holotape` 最快）→ 右键 New：

| 字段 | 值 |
| --- | --- |
| EditorID | `SM_Holotape` |
| Name | `据点管理终端` |
| Type | `Holotape`（记录格式里 `DNAM` 的那一位；下拉里选带 Holotape 字样的） |
| Model | `Props\Holotape_Prop.nif` |
| **Terminal**（记录格式里的 `SNAM`，就是"播放时显示哪个终端"） | `SM_MainMenu` |
| 拾取/放下声音（YNAM/ZNAM） | 留空即可 |
| Scripts | **不要挂脚本** |

> 同样用 **New**。若实在要复制：只能复制 **Fallout4.esm 里的原版卡带**，且复制后必须清空 `Scripts` 标签（原版卡带常挂任务推进脚本）。复制其他 mod 的卡带会把那个 mod 变成我们 ESP 的 master，不要这么做。

---

## 4. 任务记录 `SM_ControllerQuest`

`Object Window` → `Quests` → 右键 New：

| 字段 | 值 |
| --- | --- |
| EditorID | `SM_ControllerQuest` |
| Quest Name | 可留空 |
| **Start Game Enabled** | ✔ 勾上（这是"加载存档后自动启动"的关键） |
| Quest Type / 其他 | 不动 |

然后 `Scripts` 标签 → `Add` → 选 `SimpleSettlementManager:ControllerQuest`（列表里如果没有，说明 MO2 没启用 mod 或 CK 不是从 MO2 启动的）→ 右键 → **Auto-Fill All**：

| 属性 | 期望自动填成 |
| --- | --- |
| `WorkshopParent` | 原版任务 `WorkshopParent`（据点系统主任务） |
| `SM_Holotape` | 第 3 步的 `SM_Holotape` |
| `bHolotapeGiven` / `SelectedWorkshop` / `bAutoReissueHolotape` | 保持默认，不用动 |

Auto-Fill 不成功就手动在属性里选对应记录（按名字找）。

---

## 5. 回填终端脚本的属性

回到 `SM_MainMenu` 记录 → `Papyrus Scripts` → `SimpleSettlementManager:TerminalMenu` → `Properties` → **Auto-Fill All**：
这次 `SM_ControllerQuest` 能选到我们的任务了 → 设好 → OK 保存。

---

## 6. 保存并进游戏

### 6.0 修中文编码（必须，否则游戏里是乱码）

**CK 按系统 GBK 写记录里的字符串，而游戏按 UTF-8 读** —— 在 CK 里直接打的中文进游戏会变乱码
（实测：CK 存的 `NAM0` 是 `beddb5e3...`（GBK），而能正常工作的汉化 esm 里是 UTF-8 字节）。
脚本里的中文不受影响（.pex 是 UTF-8 原字节），所以只有**记录字段**需要处理。

工具化做法（推荐，一条命令）：

```bash
python tools/set_text.py "E:/Games/MO2/mods/SimpleSettlementManager/SimpleSettlementManager.esp"
```

它把 `SM_Holotape.FULL`、`SM_MainMenu` 的 `FULL`/`NAM0`/`WNAM`、两个菜单项的 `ITXT`/`UNAM`
按 UTF-8 直接写进去（全是重建长度字段的定点修补，会先自检 "8/8 个目标都命中" 才落盘）。
以后新增记录/文本，把新条目加进 `tools/set_text.py` 顶部的 `TARGETS` 再跑一次即可。

> ⚠️ **不要把含 GBK 中文的文件丢给 FO4Edit 保存**：xEdit 解不出 GBK，界面显示 `?????`，
> 保存时会把它们写成字面的 `?`，文字就永久丢了（我们踩过这个坑，最后靠重写文本救回来）。
> 正确顺序：先用 `tools/fix_text_encoding.py` 把 GBK 转成 UTF-8，之后再用 xEdit 编辑中文（UTF-8 是安全的）。

核对：`python tools/inspect_esp.py <esp>` —— 中文那一列应该显示 `utf-8 ✓`。

> 另注：如果**再回 CK 改这些记录并保存**，CK 会把它们重新写成 GBK，需要重跑一次上面的命令。
> 所以结构在 CK 里改，中文文本放在最后一步写。

### 6.1 进游戏

1. `File → Save`（在 MO2 的「Create files in mod」设置下，ESP 会写进 `E:\Games\MO2\mods\SimpleSettlementManager\`）。
2. 用 MO2 启动游戏 → 读任意存档（或新开）。
3. 期望看到：
   * 通知条：`据点管理终端全息卡带已放入背包`
   * 哔哔小子 → 全息卡带 → 播放 `据点管理终端` → 出现终端菜单
   * 点 `查看当前据点`（站在某个据点范围内）→ 弹出报表：据点名、人口/无业/机器人、食物/水/电力/防御/床位（含缺额）、幸福度；据点加载时还会多出床位数/居民数/资源对象数
4. 若没出现，把这些告诉我：
   * 卡带有没有出现在背包里
   * 播放卡带后是菜单、黑屏、还是没反应
   * 报表文字有没有变成乱码/方块（中文编码是否 OK）
   * `Documents\My Games\Fallout4\Logs\Papyrus*.log`（需要先在 `Fallout4Custom.ini` 的 `[Papyrus]` 里开 `bEnableLogging=1`）

---

## 待实测确认的几件事（M0 就是为了把它们试掉）

1. **中文显示**：脚本里的中文以 UTF-8 存进 .pex 已确认，但游戏字体是否正常渲染要你看一眼。
2. **终端菜单项是否触发 `OnMenuItemRun`**：CK wiki 记载该事件在 Pip-Boy 播放时也会触发（只是 `akTerminalRef` 为 `None`），但要实机确认「点一项就弹报表」。不触发就把菜单项类型改成 `Submenu` 指一个占位终端兜底。Papyrus 日志里有 `[SM] OnMenuItemRun id=N` 就是触发成功。
3. **`Debug.MessageBox` 在 Pip-Boy 播放状态下是否正常弹出**：如果被哔哔小子界面挡住，我们改成 `Message` 记录或先关哔哔小子。
4. **未加载据点的数值**：站在远处时汇总数值是否仍有意义（原版靠每日更新刷新，会略旧）。

---

## 之后（M1 及以后）

* 据点列表（选择器）+ 逐据点查看
* 居民名单 → 指派岗位 / 解除岗位（`WorkshopFramework:WorkshopFunctions.AssignActorToObject`）
* 迁居到其他据点（`AddActorToWorkshop` + WSFW 的据点选择器）
* 一键填补空岗、床位视图
