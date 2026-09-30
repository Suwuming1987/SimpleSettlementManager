# 开发记录

面向开发/维护。用户向说明在 [README.md](README.md)，CK 建记录的步骤在 [docs/M0-build-records.md](docs/M0-build-records.md)。

## 环境（本机实测）

| 项 | 位置 |
| --- | --- |
| 游戏本体（含 370 个 mod、F4SE 1.11.240） | `E:\SteamLibrary\steamapps\common\Fallout 4` |
| MO2 | `E:\Games\MO2`（mods 在 `E:\Games\MO2\mods`） |
| FO4Edit 4.1.5f | `E:\Games\MO2\mods\FO4Edit 4.1.5f\FO4Edit.exe`（作为 MO2 可执行程序注册） |
| Creation Kit | `E:\SteamLibrary\steamapps\common\Fallout 4\CreationKit.exe` |
| Papyrus 编译器 | `E:\SteamLibrary\steamapps\common\Fallout 4\Papyrus Compiler\PapyrusCompiler.exe` |
| 项目 | `E:\fo4mods\SettlementManager`（ASCII 路径，避免编译器/工具链的 Unicode 坑） |

环境上做过两处修改（都是标准做法，可回退）：

1. **CK 从 D: 拷进了游戏目录。** 原本装在 `D:\Games\Steam\steamapps\common\Fallout 4`，但那边的 `Data` 里只有 `LSData/Scripts/Sound`，没有 `Fallout4.esm` 等主文件，CK 打不开游戏数据。版本核对过（CK 与游戏都是 1.11.240）。
2. **补了 `Data\Scripts\Source\` 下的基础脚本**（CK 安装只建了空目录 + 一个空 Readme）。
   `Base\` 7833 个文件；`DLC01..06`、`CreationClub` 与 `Base` 同级。
   依据：`CreationKit.ini` 的 `[Papyrus] sScriptSourceFolder = ".\Data\Scripts\Source\User"`、`sAdditionalImports = "$(source);.\Data\Scripts\Source\Base"` —— CK 编译 Fragment 就靠这两个目录。

## 构建

```bash
bash tools/build.sh          # 编译 + 校验 + 同步进 E:\Games\MO2\mods\SimpleSettlementManager
```

产物：`dist/Scripts/SimpleSettlementManager/*.pex`（命名空间 = 目录名，游戏按 `Data\Scripts\SimpleSettlementManager\` 加载）。

## 工具链里的两个坑（CK 保存 ESP 时）

CK 在**加载状态不对**时（比如把插件当 master 加载、或没有正确的活动文件）保存出来的 ESP 会有两个问题：

1. **自身记录的 FORM ID 索引用错**：规范是"自身记录索引 = master 数量"（1 个 master → `01000F99`），
   CK 可能写成 `02000F99`。实测本机 257 个插件里只有我们这份有这种写法，所以不能赌引擎容忍。
   → `tools/normalize_esp.py` 定点修正（长度不变，留 .bak）。已集成进 `build.sh`，每次构建自动跑。
2. **两条记录撞号**：上述情况下 CK 会把记录分散在"文件位"里，不同文件位可以有相同的对象序号，
   保存成一个文件后就撞号（我们的卡带和终端都成了 `000F99`）。归并索引解决不了撞号。
   → `tools/repair_esp.py` 重新分配序号并更新引用（带状态断言 + 修后自检）。
   `normalize_esp.py` 现在遇到会撞号的情况会直接拒绝修改并提示用修复工具。

**根因与正确姿势**：重开 CK 时，`File → Data` 里**不能把我们的插件勾成 master**。
要么只勾 `Fallout4.esm`（然后用 `File → Save As` 建/存活动文件），要么用对话框里"设为活动文件"的机制。
另外：CK 重启才会刷新脚本列表（新部署的 .pex 不重启看不到），这点和上面的注意事项要一起记住。

## 已核实的技术事实（都是踩过的）

### Papyrus 编译器

* `.ppj` 里的路径**必须是正斜杠 + 绝对路径**：反斜杠不解析；相对路径也不按 .ppj 所在目录解析（报 `Unable to find flags file`）。
* 编译器**编译失败也返回 0**，所以 `build.sh` 自己校验 .pex 是否存在且比 .psc 新。
* 带命名空间的脚本（`SimpleSettlementManager:Xxx`）**只能走 .ppj**；命令行直接编 .psc 会报 `filename does not match script name`。
* 中文 UTF-8 字面量能正常过编译，.pex 里的字节保持完整（已用 `od` 比对）。游戏里用 `sLanguage=cn` + 中文字体，渲染待实机确认。

### 事件与菜单（决定架构的地方）

* **Quest 的初始化事件是 `OnQuestInit`**，FO4 的 `Quest` 脚本里没有 `OnInit`。
* **`OnPlayerLoadGame` 是 `Actor` 上的事件，Quest 收不到**。正确写法：
  `RegisterForRemoteEvent(Game.GetPlayer(), "OnPlayerLoadGame")` + `Event Actor.OnPlayerLoadGame(Actor akSender)`
  （照抄原版 `inst305RadioRackSlotScript.psc`）。
* **全息卡带播放（Pip-Boy）时 `OnMenuItemRun` 会触发，但 `akTerminalRef` 为 `None`**；
  在 Pip-Boy 上**文本替换不可用**（没有可用的引用）。
  → 所以：菜单项一律用 **Fragment** 触发（WSFW 的设置卡带就是这么做的，已验证可用），
  动态内容一律用 **`Debug.MessageBox(运行时字符串)`**，不依赖文本替换。
* **全息卡带是 `NOTE` 记录，不是 MISC**，播放时显示哪个终端由记录里的 **`SNAM`** 字段决定。
  证据（解析 `WorkshopFramework.esm` 得到）：
  `NOTE 010035DE WSFW_ControlHolotape` 的 `SNAM = 010035DA`，而 `010035DA` 是 `TERM WSFW_MainMenu`。
  卡片模型路径 `Props\Holotape_Prop.nif`。

### 编码（重要，容易踩）

* **CK 按系统 ANSI 代码页写记录里的字符串**（本机是 GBK）。实测我们的 TERM 记录：
  `NAM0`/`FULL` = `beddb5e3b9dcc0edd6d5b6cb` → GBK 解出「据点管理终端」，UTF-8 解不出来。
* **游戏要的是 UTF-8**。证据：能正常显示中文的 `Workshop Framework - CHS` 汉化 esm 里，
  中文字节是标准 UTF-8（`e6a087e8aeb0...` → 「标记物品为失窃」），GBK 解不出来。
  → **在 CK 里直接输入的中文，进游戏会变乱码**；记录里的中文一律用 FO4Edit 补
  （xEdit 写 UTF-8，这也是国内汉化的通行做法）。
* **脚本里的中文不受影响**：编译后的 .pex 是 UTF-8 原字节（已逐字节验证），
  所以 `Debug.MessageBox` / `Notification` 这些动态文本正常显示。
  受影响的只有记录里的静态文本：卡带名、终端 Header/Welcome Text、菜单项 Item Text。
* `tools/inspect_esp.py` 会同时尝试 UTF-8 / GBK 解码，随时可以核对记录里的编码对不对。
* ⚠️ **绝对不要把含 GBK 中文的文件交给 FO4Edit 保存**：xEdit 解不出 GBK 字节，
  界面上显示 `?????`，**保存时会真的写成字面的 `?`**，文字信息永久丢失（我们踩过一次）。
  正确顺序：先用 `tools/fix_text_encoding.py` 把记录里的 GBK 转成 UTF-8，
  之后再用 xEdit 编辑（那时是 UTF-8，安全）；或者直接用 `tools/set_text.py` 写入中文。

### M2 已知问题：面板开着时 Alt-Tab 会让游戏的鼠标指针"卡住"

**现象**：面板打开时切出/切回游戏，游戏自己的暂停菜单会打开并画出它的光标，但那个光标不随鼠标移动，
只在点击时刷新一次位置。按 Esc（PrismaUI 自己的失焦路径）可以完全恢复。

**定位过程与结论**（已排除的原因写在前面，避免重复踩）：
* 不是"终端菜单没关"——那是另一个已修的问题（`TerminalMenu` 必须放进关闭列表）。
* 不是视图生命周期 —— 去掉 `Destroy`（改为保留视图、只 `Unfocus` + `Hide`，符合 PrismaUI 文档建议）后现象不变。
* 不是"没检测到菜单"—— `OnMenuOpenCloseEvent` 能正常收到暂停菜单打开并让路。
* 根因在**框架层的输入状态**：Alt-Tab 后游戏切回菜单模式并画自己的光标，
  而 PrismaUI 仍把鼠标路由进我们的视图，游戏光标拿不到移动事件。
  Papyrus 侧的 `Unfocus` 发生在暂停菜单打开的过程中，框架随后又会恢复它自己的输入状态。

**已确认不是本 mod 的问题**：NODE.LITE（另一个基于 PrismaUI 的 mod）有完全相同的现象 ——
说明这是 PrismaUI 与游戏界面交互的固有行为。

**处置决定：不修。** 理由：
* 玩家按一下 Esc 即可完全恢复（PrismaUI 自己的失焦路径会正确拆掉覆盖层）；
* 面板开着时强关面板会打断玩家，而且 Papyrus 侧本来也够不到框架的输入状态；
* 纯 Papyrus 的"让路"方案（检测到暂停菜单就关面板）已实测撤掉。

**若将来要彻底修**：PrismaUI 为此提供了 `SuppressVanillaMenu("PauseMenu", true)`（V6，**C++ 专有**），
在视图聚焦期间压制会冲突的原版菜单 —— 这也是 NODE.LITE 需要带 DLL 的原因。
需要一个小的 F4SE 插件（约 100~150 行，复用 AutoDisarm 的 xmake + CommonLibF4 工具链），
只需向 Papyrus 暴露 `SMUI_SuppressMenu(String, Bool)` 一类的转发函数。
代价：多一个 DLL，每次游戏更新要重编（换取的能力还包括窗口外点击穿透、把 HTML 画到终端屏幕上等）。

### M2 已知问题：面板"自己又弹出来"（打开来源只有两处，别猜）

`PrismaUI.Show` 全项目只有 `OpenDashboard` 调用一次，所以"面板自己出现"必然是有人调了它。
调用者只有两个：

1. `OnKeyDown` 里的热键（来源字符串 `"热键"`）；
2. 全息卡带终端菜单项 `TerminalMenu.OnMenuItemRun`（来源字符串 `"卡带菜单"`）——
   任何菜单项都打开面板，不按 ID 分派。

历史定位：最先怀疑热键，于是把热键入口临时停用一轮排除；最后确认过一次**读档残留** ——
PrismaUI 的视图活在游戏进程里、跨读档保留，框架会把它重新显示出来。
处置：`OnPlayerLoadGame` 里 `Unfocus` + `Hide` + `Destroy`，并把两个时间戳清零。

**残留风险：全息卡带的重复触发。** 我们从卡带进面板时会关掉 `TerminalMenu` 等原版菜单；
卡带播放结束后游戏有机会把那个菜单项再跑一遍，于是面板被重新打开 ——
玩家看到的就是"关掉几秒后又自己弹出来"。真人不可能在 8 秒内重放一次卡带并再点一次菜单项，
所以 `OpenDashboard` 对「卡带菜单」来源做了 8 秒去重（被挡掉时会 `Debug.Notification` 说明）。
**这一版还带着临时诊断**：每次打开面板都会通知"来源 + 距上次关闭多久"，
用来一次性确认到底是谁触发的（定位完就摘）。日志里对应 `[SM] OpenDashboard 来源=...`。

### 界面侧的坑（Ultralight / PrismaUI 的网页环境）
* **拿不到 `KeyboardEvent.code`**：PrismaUI 用的 Ultralight 不保证给这个字段，
  只认 `e.code` 去查表的结果就是"按任何键都不支持"（玩家实测反馈）。
  现在按 **code → key（键名）→ keyCode/which（虚拟键码）** 三级兜底，三个来源各有一张表
  （`CODE2SC` / `KEY2SC` / `VK2SC`，后两张在启动时由第一张自动推出来）。
  Esc 取消的判断同理，三个字段都要看。
  认不出来时提示里会打出 `[code=… key=… vk=…]`，下次一眼就能看出这个内核到底给了什么。
* 键名表 (`KEY2SC`) 与虚拟键码表 (`VK2SC`) 的换算规则写死在代码里，测试在 `tools/_smoke.js`
  （11 组用例覆盖：只有 code / 只有大写 key / 只有小写 key / 只有 keyCode / 认不出来）。
* **热键要在捕获期间屏蔽**：界面点「更改…」后游戏必须忽略旧热键，否则玩家按到旧热键
  就会触发开/关面板，面板在捕获过程中当场消失。界面发 `smCaptureStart` / `smCaptureEnd`，
  Papyrus 侧用 `bHotkeyCapturing` 在 `OnKeyDown` 里直接返回；面板关闭时也清掉这个标记。
* **词典漏 key 会直接显示成裸 key**：`t('hotkeyOff')` 没定义时界面上就写着 `hotkeyOff`。
  冒烟测试现在会核对 zh/en 两份词典的 key 完全一致，并检查模板里写死的 `t('key')` 都有定义。

### Papyrus 的坑（都踩过，编译器报错很误导）

* **函数调用的参数不能拆到多行**：`Foo(a,\n b)` 报 `missing RPAREN`。要么一行写完（哪怕很长），
  要么别在括号里换行 —— 原版/WSFW 的多参数调用也都是单行的。
* **变量名不能撞类型名**（Papyrus 类型名大小写不敏感）：`ui` 撞 F4SE 的 `UI` 类型、
  `idle` 撞 `Idle`（闲置动画类型）、`key` 撞原版的 `Key` 脚本，**`uI` 也撞 `UI`**（大小写不敏感），
  编译报 `xxx is not a variable` / `cannot name a variable the same as a known type` /
  `cannot get the length of ...`。取名避开类型名（我们改用 `uiMgr`、`idlers`、`cur`、`mxI`）。
  这条尤其阴：名字看着无关（`uI` 里的 i 是大写 I），报错却在 `while` 条件那几行。
* 编译器**失败也返回 0**，所以 `build.sh` 自己校验产物是否存在且比源码新。

### M1 选择器的已知妥协（M2 修）

M1 用 `WorkshopFramework:UIManager.ShowMessageSelectorMenuAndWaitV2` 做所有选择（返回下标，不用新建记录）。
两个限制：

1. **一次只显示一个选项**（按钮：下一个/上一个/更多信息/选择/取消），列表长时要点很多次；
2. 它内部用 `PlaceAtMe` 把选项实例化来取名字，**且没有清理代码** —— 对表单类选项无害，
   但选项是 Actor 时会刷出克隆 NPC（落在 WSFW 的隐藏填充点、不计入据点人口，但属于垃圾引用）。

M2 的改进方向：改用交易列表选择器（真正的可滚动列表），它用"假物品 + 文本替换"显示名字，
不会刷 clone；代价是需要往 ESP 里加一个 **FormList 记录**（用 `tools/add_record.py` 之类新建记录）。

### 数据读取（来自原版脚本本身）

* 据点汇总数值存在 workshop 引用的 ActorValue 上，读法：
  `ws.GetValue(WorkshopParent.WorkshopRatings[i].resourceValue)`，
  索引常量在 `WorkshopParentScript`：`WorkshopRatingFood=0 / Happiness=1 / Population=2 / Safety=3 / Water=4 / Power=5 / Beds=6 / PopulationUnassigned=8 / PopulationRobots=24 / MissingFood=27 / MissingWater=28 / MissingBeds=29`。
  `GetValue` = 当前实际产出（停工/受损会掉），`GetBaseValue` = 总量。
* **完整数据只对"当前已加载"的据点存在** —— `WorkshopParentScript.psc` 头部原话：
  *"in general, full data (actors, objects) is available only for the current (loaded) workshop"*。
  → 跨据点总览只能给汇总数值；居民/床位/岗位明细必须玩家在该据点，用 `ws.Is3DLoaded()` 判断并降级提示。
* 没有 `MoveActorToWorkshop`；**迁居 = 对目标据点再调一次 `AddActorToWorkshop`**（原版主线搬科学家就是这么做的）。
* 床位：`WorkshopParent.GetBeds(ws)`；居民：`GetWorkshopActors(ws)`；岗位对象：`GetResourceObjects(ws)` 里 `RequiresActor()` 为真的。
* **供应线（搬运工）**：`WorkshopParentScript.CaravanActorAliases`（`RefCollectionAlias`，原版自己维护的全部搬运工集合）→ 每个 `WorkshopNPCScript` 的 `GetWorkshopID()`（居所）与 `GetCaravanDestinationID()`（目的地）就是一条边。这个集合**不要求据点已加载**，所以整张供应网都能读出来。界面侧用并查集分连通分量，只给"成员 ≥ 2"的网络出合计行（人口/食物/供水）—— 供应线共享的资源就是食物和水。

### 居民名单：**必须三个来源取并集**（只信一个就会漏掉跑供应线的人）

原版脚本源码在 `Data/Scripts/Source/Base`（CK 版，可直接读），下面几条都是从那里核实的，不是猜的：

* `WorkshopParent.GetWorkshopActors(ws)` 的实现就是
  `ws.GetWorkshopResourceObjects(WorkshopRatings[WorkshopRatingPopulation].resourceValue)` —— 也就是"**人口资源对象**"列表。
  原版**人口管理终端**（`DLC06OverseerHandlerScript.psc:103`）读的正是这个接口：
  `ActorsAll = CurrentWorkshop.GetWorkshopResourceObjects(WorkshopParent.WorkshopRatingValues[2])`
  （`WorkshopRatingPopulation = 2`，所以两者是同一个列表）。**这个列表包含跑供应线的人。**
* **WSFW 的 `WorkshopFramework:WorkshopFunctions.GetWorkshopActors()` 会漏掉在路上的搬运工** —— 玩家反馈："庇护山庄有个跑红火箭的搬运工，界面里查不到他，但原版人口终端能看到"。
  → 名单 = ① WSFW 的 + ② 原版 `WorkshopParent.GetWorkshopActors` 的 + ③ `CaravanActorAliases` 里居所是本据点的，**最后统一去重**（否则同一个人两行）。
* 这个列表里**可能包含婆罗门**（它们同样是 `WorkshopNPCScript`）。原版终端靠 `bCommandable` 挡掉；我们用原版自己的 `WorkshopParent.CaravanBrahminAliases` 挡。
* **界面里的行号必须和推送用同一份名单**：名单统一由 `GetSettlementRoster(ws)` 产出，
  `PushDashboardData`（推送）和 `GetSettlerByIndex`（把界面行号解析回居民，改名/召唤/解除都走它）
  以及自动填岗、全部解除、文本列表全部调它。踩过的坑：并集上线后只改了推送，解析还在用 WSFW 的旧名单，
  而**并集把多出来的人追加在末尾** → 那些行号在旧名单里没有对应 → `PickedSettler` 变成 None，
  改名/召唤/解除静默不执行，界面重绘后名字"自己还原了"（玩家反馈"改名前几秒会自动还原"）。
* 搬运工的判定只有一处 `IsCaravanWorker(a)`（界面标「运输」、自动填岗跳过、解除清账都用它）。
  **自动填岗必须排除搬运工**：WSFW 眼里他们不算 worker，会被当成无业抓去填岗，那等于把玩家的供应线拆掉。
* 搬运工的**权威判据**是派系：`theActor.IsInFaction(workshopCaravanFaction)`（`DLC06OverseerHandlerScript.psc:143`）。
  该派系属性只挂在 DLC06 的脚本上，Papyrus 这边拿不到常量，所以退一步用**"是否在 `CaravanActorAliases` 里"**，
  与目的地判据取"或"（`caravanDestName != ""`）—— 保留已经验过的老判据，同时覆盖目的地读不出名字的情况。
* 指派搬运工时 `AssignCaravanActorPUBLIC` 只做三件事：`workshopID` **保持居所不变**、把目的地写进 actor value
  `WorkshopCaravanDestination`（`GetCaravanDestinationID()` 读的就是它）、并把自己加进 `CaravanActorAliases`。
  所以**非搬运工读这个值是 0**（不是 -1）—— 这就是早期"所有在岗居民都被标成运输"的根因。

### 「能否运输」开关的语义（玩家明确过）

`bAllowCaravan`（WSFW 的 `SetAllowCaravan`）= **这个人能否被指派去跑供应线**：
* 打开 = 可以被派去跑线（原版/工坊菜单里那个选项可用）；
* **关闭时，如果他已经在跑线，必须立刻解除运输身份**（不是只改个标记）：
  我们在 `smFlagV0` 分支里调 `ClearCaravanDuty()` —— 复用"解除岗位"那套清账
  （移出 `CaravanActorAliases`、断线、删婆罗门、清 `WorkshopCaravanDestination` 与两个链接引用、`EvaluatePackage`）。
  注意原版的 `SetAllowCaravan(false)` **只改标记、不动已存在的线**，这一步得我们自己做。

### 解除搬运工：清账要照抄原版 `UnassignActor`，**绝不能调 `AssignCaravanActorPUBLIC(actor, None)`**

**原版把行走包挂在 `CaravanActorAliases` 这个别名集合上**（原版注释：*"NOTE: package on alias uses two
actor values to condition travel between the two workshops"*）。所以"解除不彻底"的残留症状是：
地图连线断了、共享库存取消了，但**人一直保持行走姿态，工坊模式里也仍旧算他跑运输**（玩家反馈）
—— 因为他还在那个集合里。

原版自己清账就一句 `UnassignActor(theActor)`（`ClearCaravansFromWorkshopPUBLIC` 里就是这么做的），
它的搬运工分支是：`CaravanActorAliases.RemoveRef` → `CaravanActorRenameAliases.RemoveRef` →
`startLocation.RemoveLinkedLocation(endLocation, WorkshopCaravanKeyword)` → `SetAsBoss` →
`CaravanActorBrahminCheck`（**必须放在移出集合之后**：那时它才会删掉人名下的婆罗门）→
发 `WorkshopActorCaravanUnassign` 自定义事件。我们照抄了这一段，另外补两样原版不管但我们需要的东西：
`SetValue(WorkshopCaravanDestination, 0)`（我们的界面靠它判"运输"）和清掉
`WorkshopLinkCaravanStart/End` 两个链接引用（DLC06 判"是否跑运输"也看它们），最后 `EvaluatePackage()`
让她当场停止行走。

**踩过的坑**：曾经用 `AssignCaravanActorPUBLIC(wnp, None)` 来解除。传 None 之后它要过几行才报错中止，
而**报错之前**会执行 `if CaravanActorAliases.Find(actor) < 0 → AddRef(actor)` —— 正好把刚清掉的人
**又加回搬运工集合**，于是"连线断了但人还在走"（上一版就是这么引进来的）。

### 面板数据格式（Papyrus → 页面，`PrismaUI.Push`，行 + 竖线分隔）

```
P|pong                                    桥自检回包
K|热键码（VK）                             当前热键（0=关闭），界面据此同步偏好
H|当前据点名                                玩家此刻所在的据点
S|据点ID|名字|人口|无业|食物|水|电|防|床|缺食|缺水|缺床|幸福度|是否已加载
E|搬运工居所ID|目的地ID                      一条供应线边（每个搬运工一条）
W|居民名|状态(0无业/1在岗/2队友)|岗位名|开关(3位标志)|有无床
J|空闲岗位名
B|床位总数|已分配|空床
```

**S 行的 ID 是给界面做供应网络并查集用的**；`H` 行是判断"当前据点"的唯一依据 ——
明细行（W/J/B）永远只描述 `H` 那个据点，所以据点页必须比对 `s.name === state.here`，
否则会拿 A 据点的居民/岗位数据画在 B 据点上（红火箭显示庇护山丘作物就是这个 bug）。

### Workshop Framework（2.6.0，本 mod 的动作层）

指派/迁居**只调它的函数，绝不复制或覆盖原版 workshop 脚本**（WSFW 重写了 `WorkshopParentScript`/`WorkshopObjectScript`/`WorkshopNPCScript`/`WorkshopScript`/`WorkshopRadioBeaconRecruitScript`）：

```
WorkshopFramework:WorkshopFunctions.AssignActorToObject(WorkshopObjectScript, Actor, bool, bool, bool)   ; 注意岗位在前
WorkshopFramework:WorkshopFunctions.UnassignActorFromObject(Actor, WorkshopObjectScript, bool, bool, WorkshopScript)
WorkshopFramework:WorkshopFunctions.AddActorToWorkshop(Actor, WorkshopScript, bool)                     ; 迁居走这条
WorkshopFramework:WorkshopFunctions.RemoveActorFromWorkshop(Actor, WorkshopScript, bool)
WorkshopFramework:WorkshopFunctions.GetWorkshopActors / GetResourceObjects / GetAssignedActor
WorkshopFramework:UIManager.ShowMessageSelectorMenuAndWaitV2(Form[], Form, Message, float)  → 返回下标（-1 失败 / -2 取消）
WorkshopFramework:UIManager.ShowSettlementBarterSelectMenuV2(Form, WorkshopScript[], WorkshopScript[])
```

API 就绪判断：`Game.GetFormFromFile(0x00004CA3, "WorkshopFramework.esm") as WorkshopFramework:WSFW_APIQuest`，
再看 `(API.MasterQuest as WorkshopFramework:MainQuest).bFrameworkReady`。

### 据点下标必须稳定（否则"选中的据点"会变来变去）

界面用**下标**指代据点（迁居目标、批量操作等），而 `WorkshopParent.Workshops` 是 `RefCollectionAlias`，
顺序在读档/增删据点后会变 —— 顺序一变，同一个下标就指向另一个据点，
表现就是"据点名显示错误，而且每次打开都在变"（玩家反馈）。两道保险：

* **Papyrus 侧**：`GetOwnedWorkshops()` 里按 `WorkshopID` 做插入排序，让每条 S 行的下标固定；
  `GetOwnedWorkshopByIndex()` 复用同一个函数，所以下标的含义两边一致。
* **界面侧**：选中项按**据点 ID**（`selSettleId`）记住，每次收到数据重新定位下标；
  只有列表渲染顺序偶然变化时不会影响选中项。

另外：批量操作（一键填补空岗 / 解除全部岗位）游戏侧是作用于**玩家当前所在**的据点，
和据点页选中的那个据点无关 —— 对话框里的名字必须用 `state.here`，用 `selSettle` 会显示错误的据点名。
居民/岗位两页的明细也只描述当前据点，所以页面右上角的提示里直接写明"作用于当前据点 X"。

### 居民/对象的名字要读"显示名"（否则改名 mod 全是白改）

玩家用了 What's Your Name（WYN）给定居者起名，我们的面板仍显示"定居者"。原因：
**改名 mod 不改基础记录**（`ActorBase`）—— 那会让同一基础记录的所有居民同名。WYN 的做法是把名字
挂在**引用**上（源码在它的 BA2 里，`scripts/source/user/pra/prarenamequestscript.psc`）：

```
npc.AddTextReplacementData("PraActualName", 名字对应的 Message)   ; 文本替换数据
placeholderAlias.AddRef(npc)                                     ; 塞进任务的 RefCollectionAlias
npc.AddKeyword(praSettlerRenamed)                                ; 只是"改过名"的标记
```

它自己也不存名字：显示名由引擎按"文本替换 / 别名派生"算出来，Papyrus 侧只有
`ObjectReference.GetDisplayName()` 能读到，`GetActorBase().GetName()` 永远返回通用名。

* 我们的 `ActorName()` / `RefName()` 现在**优先读显示名**，没有改名数据时 `GetDisplayName()`
  返回的就是基础名，行为与以前一致。
* `GetDisplayName` 这个 native 不在原版脚本里（本机的基础脚本 `ObjectReference.psc` 里那行是
  随某个 F4SE 脚本扩展插件补上去的，文件里留着 `; F4SE additions built …` 注释），
  所以调用包了一层 `SafeDisplayName()`：插件不在时失败的只是这个函数，
  调用方拿到空串后回退到基础名，不会把整条数据推送拖垮。

顺带说明：这条路径是**通用**的 —— Rename Anything、任何走引用显示名的改名 mod 都能读出来，
不是只为 WYN 写的兼容。

### 改名（居民）：插件写显示名 + 名字库

* **0.8.0 起改名由配套 F4SE 插件执行**（Garden of Eden 依赖已移除，迁移记录见 `docs/GOE-REMOVAL.md`）：
  Papyrus 把"请求计数器 +1"写进 GLOB `SM_RenameReq`，插件每 250 毫秒看到计数器变了就读
  `PendingRenameFormID` / `PendingRenameName`，写 `ExtraTextDisplayData`（自定义显示名），
  再把结果（1 成功 / 2 失败）写进 `SM_RenameResult` 并发 `SMUI_Event("renamed")` 回来。
* 改完**如实告知**：有的居民显示名被别的 mod 接管（WYN 会把居民放进任务别名，别名派生的显示名优先），
  这时提示玩家先去 WYN 里"忘记名字"再试。
* 名字从界面来：桥的实现是 `emit: function(eventName, data) { data: (typeof data === 'string') ? data : JSON.stringify(...) }`
  —— **字符串原样送**，Papyrus 侧不做任何解析（它也没有字符串方法）。
  所以 `HandleDashboardAction(asEventName, asPayload)` 多接一个参数，`OnPrismaUIEvent` 直接透传。
* **改名输入框的内容要在重绘中活下来**（玩家反馈两次："不快点点确认会被重置""前几秒会自动还原"）：
  数据推送会触发整页重绘，而玩家点了「确定改名」之后焦点已经离开输入框 —— 只"焦点在时"记草稿是不够的。
  现在的做法：输入框 `oninput` 实时记草稿（连"是哪个居民"一起记），`render()` 里只要还是同一个居民就恢复（焦点只在
  本来就是聚焦状态时才抢回来），等推送回来的名字与草稿一致（说明已经落地）再把草稿丢掉。
  冒烟测试锁了这两条（"推送重绘后草稿仍在""落地后草稿被清掉"）。
* 名字库取自 **What's Your Name**（含其简体中文翻译版）：`tools/extract_names.py` 从两个 ESL 的
  FLST/MESG 里按性别抽出名字，存成 `tools/names_en.json` / `tools/names_zh.json`，再由 `tools/make_namelists.py`
  注入到 index.html 的 `NAMES` 块（界面语言决定用哪套，随机时按居民性别选池）。
  这样即使以后卸载 WYN，名字库仍然在。
  **只需要区分男女**：罕见名已经并进主名单（曾经单独建过 Rare 池，玩家说不需要），
  并且做过去重 —— 同一个名字不能同时出现在男名和女名里（否则"按性别抽名字"会抽错）。

### 我的批量补丁曾经"报告成功但没改到"（heredoc 把 `\n` 吃掉）

给 W 行追加职业字段那次，脚本打印了"✓ 已追加"，但**真正那一行的替换没匹配上**（只插进了注释），
于是界面一直收到 7 字段的旧格式，走了"按状态退化推导"的兜底分支 —— 在岗的人全被推成"无业"，
而 Papyrus 侧的诊断日志显示这些人是农民。**日志说农民、界面说无业，两边矛盾了整整两轮。**

根因：我的补丁里用 `\n` 去匹配 Papyrus 源码里的字面量 `"
"`，但 heredoc 会把 `\n` 变成真换行，
模式就永远匹配不上；`str.replace()` 不匹配时**不报错**，脚本照常打印成功。

规矩：**改关键行之后要回读那一行确认**（现在关键改动都用 `sed -n` 或 Python 打印出来核对），
匹配 Papyrus 里的 `
` 字面量一律用 Python 原始字符串 `r'...
'`。

### "在岗/无业"要看居民自己身上的原版标记，不要用 WSFW 的账

玩家反馈：工坊界面里明明有人在种地、原版人口终端也显示「农夫（2）」，但我们面板里那两个人是"无业"、
农民是 0。根因是用 `WorkshopFramework:WorkshopFunctions.IsWorker()` 判在岗 —— 它维护的是 WSFW 自己那套
登记，会和游戏实际状态脱节。

原版判"失业"用的是**居民自己身上的 `bIsWorker`**（`DLC06OverseerHandlerScript.psc:146`：
`elseif ( theActor.bIsWorker == FALSE )`）：原版指派工作时 `SetWorker(true)`、解除时 `SetWorker(false)`
（搬运工走的也是解除那条路，所以搬运工 `bIsWorker == false`）。现在统一走 `IsActorWorker(a)`。

顺带把工作对象列表也换成原版接口：`WorkshopParent.GetResourceObjects(ws)`（= 据点的资源对象列表）+
`WorkshopObjectScript.GetAssignedActor()`，不再经过 WSFW 的封装。**能读原版就读原版** ——
"无业"判错这次就是吃 WSFW 那套账与游戏脱节的亏。

### 居民的 S.P.E.C.I.A.L.：FormID 从游戏自己的 ESM 里读，不猜

详情里要显示七项 SPECIAL，Papyrus 只能 `Actor.GetBaseValue(ActorValue)`（没有按名字取属性的接口），
所以必须拿到那 7 个 AV 的 FormID。**别去网上抄**（CK wiki 会 403、搜索结果也不确认），
直接扫游戏自己的 `Fallout4.esm`：

* TES4 头之后是顶层 GRUP 序列；记录头 **24 字节**（sig+size+flags+formID+ts+ver+unk×2），
  压缩记录（flags & 0x00040000）要先跳过 4 字节再 zlib 解压。
* AV 记录的签名是 **AVIF**，数据以 `EDID`（uint16 长度 + 名字）开头 —— 按编辑器 ID 匹配即可。
* 实测（本机 Fallout4.esm）：`Strength=0x000002C2 / Perception=0x2C3 / Endurance=0x2C4 /
  Charisma=0x2C5 / Intelligence=0x2C6 / Agility=0x2C7 / Luck=0x2C8` ✓ 连号，可交叉验证。
* 运行时用 `Game.GetFormFromFile(id, "Fallout4.esm") as ActorValue` 取（结果缓存在属性里）。
* 显示的是 **GetBaseValue**（基础值），不含食物/药品/装备的临时加成 —— 和人物卡一致。

### 界面行号 → 居民：必须解析到"上次推送出去的那份名单"

玩家反馈"改名前几秒会被还原"。日志给出了真相：整局里**只有一次改名请求到达了插件**（+29 秒那次，成功），
前几秒的尝试在插件日志里**没有任何痕迹** —— 请求根本没发出去，是 Papyrus 侧静默丢掉了。

原因：面板里的行号是照着**某一次推送**画的（`smPickSettler<下标>`），而 Papyrus 拿这个下标去解析
**实时名单**。面板刚打开的几秒里实时名单还在变（居民持续注册进来，WSFW 的 PersistenceManager 也正好
在这个时间点扫描），于是下标解析不到 → `PickedSettler = None` → 改名/召唤/解除全部静默不执行，
界面重绘后名字没变，看起来就是"名字被还原了"。

处置：
* 推送时把那份名单存进 `LastPushedRoster`，`GetSettlerByIndex` **一律按它解析**（没有才退回实时名单），
  这样"界面上看到的第 N 行"就永远是"动作作用的那一位"。
* 解析失败**不再静默**：提示一句 + 重推数据让界面与游戏对齐（可见的失败比静默失败好排错）。
* 读档时清空 `LastPushedRoster`。
* `DoRename` / 选中失败 / 改名无选中都留了 `[SM]` 日志，下次这类问题能直接从日志定位。

### 暂存的两个坑（都踩过）

1. **暂存内容必须配自己的 ID 表**：`DetailCacheData` 和 `JobCacheIDs`（工位缓存）**不能共用一张** ——
   两边由不同函数在不同时机写入，共用会让索引错位、`DetailCacheData[i]` 越界报错，于是暂存**静默失败**
   （症状：快速传送离开据点后，展开该据点看不到"暂存数据"）。现在用 `DetailCacheIDs` ✓。
2. **不在据点范围内也要发"空 H 行"**：`H|据点名` 只在玩家站在据点里时才发 → 走出去之后界面一直拿着
   上一个据点的名字（症状：据点页把庇护山庄一直标成"当前所在"）。做法：`String detail` 提到 `if ws` 块外，
   在块末加 `Else` 写一条空 `H|`，并把 `s += detail` 移到 `EndIf` 之后。
   **别在块中间插 `Else`**（那句 H 行在块中间，插了会把块提前闭合，末尾多出一个 `EndIf`）。

### 跨据点看明细：**离开时暂存**（玩家方案）

明细（居民 / 床位 / 空岗对象）只有据点在游戏里加载（玩家在附近）时才读得到 —— 原版就是这么设计的。
玩家给的方案：**每离开一个据点，就把当时的明细存下来**，别的据点展开时显示这份暂存数据，
回到该据点再刷新。实现：

* 推送当前据点数据时，明细（H/W/B/J 行）拼进独立变量 `detail`，按 WorkshopID 存进
  `DetailCacheData`（与 `JobCacheIDs/JobCacheCounts/JobCacheNeeds` 共用同一张 ID 表）。
* 界面展开某一行时发 `smDetail<下标>`；Papyrus 回推 `CD|<据点ID>` + 该据点的暂存明细；
  界面单独存成 `state.cachedDetail`（**不和"当前据点"的实时数据混在一起**），渲染时带黄色标注条
  "暂存数据 —— 你上次在该据点时的居民 / 床位 / 岗位"。
* 还没有暂存（没去过）的据点，提示"走过去看一次就会有"。
* 预览桩件也模拟了这条回路（收到 `smDetail` 请求就回推一份假数据），这样浏览器里也能验这条分支。

### 页面结构：总览 = 唯一的据点管理页（据点页已合并进来）

玩家反馈"总览和据点两页显示的东西基本雷同" → 决定合并：**点总览里的某一行就地展开**
那个据点的明细与批量操作（床位段、空闲岗位、一键填补空岗、解除全部岗位），
不再单开"据点页"。左侧导航只剩 总览 / 居民 / 岗位 / 设置。

* 展开状态 = `state.selSettle` + `state.expanded`（点同一行再点一次收起）；据点顺序变化时靠
  `selSettleId`（WorkshopID）重新定位，展开不会跟错人。
* 明细（床位/岗位/居民）**只有当前所在据点**有数据，展开别的据点时给的是"明细不可用"提示。
* 合并时删掉了该页专属词条（`mySettles` / `title_settle` / `hint_settle`），补了 `noFreeJobs`
  （顺手消掉一处硬编码中文）。
* 教训：我删词条时循环范围写宽了两格，把 `hint_overview` 一起删了 —— 界面头部直接显示
  `hint_overview` 这个裸键。**词典审计查不出这种**（`t("hint_" + p)` 是动态键，静态扫描看不到），
  靠的是"看一眼预览页"。以后改词典后都要扫一眼预览。

### "缺人"必须按"每人能兼几个"折算，不能一人一岗

玩家一眼看出问题："47 个岗位 → 缺人 37"是错的。原版/WSFW 允许一个居民兼多个**同类型**工位，
上限就是 WSFW 的 MCM 里那两个「每个居民的最大食物/防御工作量」（默认 6），
所以 46 个铃薯岗位只需要 `ceil(46/6)=8` 个人，而不是 46 个人。

现在的算法（`RequiredWorkers`）：把工位按资源类型分组，每组 `ceil(岗位数 ÷ 每人上限)` 相加；
上限读**原版数据** `WorkshopRatings[ratingIndex].maxProductionPerNPC`（读不到就当 1，保守）。
   注意上限是**产量**不是"个数"：原版判据是 `multiResourceProduction + GetResourceRating(av) ≤ 上限`，
   而作物产量常见 0.5 —— 所以"上限 6"往往能管十几个作物。求和用 `JobResourceRating()`，
   按 `ceil(产量之和 ÷ 上限)` 算人数。
界面上显示成 `岗位 46（需 8 人）`，缺人 = 需人数 − 人口 → 这个数是自解释的。

**教训**：凡是"按人头算"的指标，先想清楚"一个人能顶几个"——原版这类上限都在 WorkshopRatings 里。

### 岗位数只能"在据点里数"，所以做了缓存

"这个据点能提供多少个岗位"在原版评分里**没有**对应项（评分只有各资源产量），只能数工位对象
（`GetResourceObjects` 里 `RequiresActor() && !IsBed()` 的个数）。而工位对象**只有据点已加载时读得到**
（玩家在附近），所以：在据点里数到就按 `WorkshopID` 存进 `JobCacheIDs/JobCacheCounts` 两个并行数组
（属性 → 随存档保存），跨据点总览用这份缓存；**没去过的据点返回 -1，界面就不显示岗位数、也不标"缺人"**
（不给玩家猜出来的数字）。S 行第 16 个字段就是这个值。

界面规则：`岗位 N` 显示在数值区；`岗位数 > 人口` 时右侧加一个黄色的「缺人 N」（N = 缺口人数）——
人不随供应线共享，所以这是"要派人过来"的提示，不参与左侧圆点的资源短缺判定。

### 居民页布局与职业分类（玩家要的三栏）

* 布局：左「职业标签栏」（全部/无业/农民/拾荒者/守卫/商人/运输/工人/队友/无床，括号里是人数）
  → 中「人员列表：名字 + 职业状态 + 具体工作」→ 右「居民详情：职业状态/岗位/性别/床位 +
  召唤/解除岗位/迁往其他据点 + 改名 + 三个开关」。浏览器预览用 `tools/_make_preview.py` 生成，
  能直接看布局，不用进游戏。
* **职业分类的判据全部来自原版自己打在居民/工作对象上的状态**，不是我们猜的（`JobKindOfWorker`；
  数值常量 `KIND_*` 与 index.html 的 `kindInfo` 一一对应）：`bIsWorker`／`bIsScavenger`／`bIsGuard`
  是原版指派工作时写的标记（`WorkshopNPCScript`），商人看工作对象的 `VendorType > -1`，
  农民看工作对象是否产出食物（`HasResourceValue(Food)`）。W 行第 8 个字段就是职业类别。
* 界面侧 `kindInfo()` 是唯一把数字变文字的地方：标签栏、行内状态、右侧详情都调它 ——
  以后加职业只改这一处 + 词典两套。

### 时间戳类属性跨局会"落在未来"（热键彻底失灵的真凶之一）

`Utility.GetCurrentRealTime()` 是**"本次进程启动以来的秒数"**（原版 `Utility.psc:23` 原话：
*"the number of seconds since the application started"*）——**每次重启游戏从 0 开始**；
而脚本里 `float Property X Auto` 的时间戳**存在存档里**。于是读档后它们全部落在"未来"，
所有 `if now - X < 阈值` 形式的去抖/去重判断**恒为真**（差值是负数），表现为：

* `LastHotkeyTime`：F10 按多少次都没反应，直到本次运行时长追上存档里那个值才突然恢复
  （实测：进程运行到 188 秒时面板自己开了 —— 正好是上一个存档存下的时间戳）。
* `LastTerminalOpenTime`：卡带菜单 8 秒去重同样会挡。

规则：**凡是拿 `GetCurrentRealTime()` 做"距上次多久"的判断，差值都必须先判非负**
（`diff >= 0.0 && diff < 阈值`，见 `IsRepeatEvent`），并在 `OnPlayerLoadGame` 里把这类属性清零。
不能用"存进存档 + 和进程时钟比较"来做去抖。

### 热键用"松开"触发（F4SE 会派发假的"按下"事件）
实机诊断（通知原文）：`面板打开（来源 热键68，本局还没关过面板）`，而面板里没有任何据点数据
—— 说明**读档时 F4SE 派发了一次"按下"事件**（键码正是我们注册的 68，但没人按过），
事件来得比工坊系统恢复还早。之前的"读档静音 2 秒"没能挡住它，说明它比 `OnPlayerLoadGame` 还早，
或者静音的基准时间在那一刻不可靠。

处置：**触发点从 `OnKeyDown` 换成 `OnKeyUp`** —— 假的按下事件不会带配套的松开事件，天然被排除；
真人松手一定产生 `OnKeyUp`（F4SE 为注册过的键派发），手感只差"松手时才响应"。
`OnKeyDown` 保留下来只做诊断（写日志 + 报告"非当前热键的按下事件"，用来发现没清掉的旧注册）。

配套的四道保险（都在，别删）：
1. 读档/开局后静音 2 秒；2. 换键后静音 0.6 秒（挡住捕获那次按键漏出来的事件）；
3. 连击去抖 0.3 秒；4. `RegisteredCodes` 记下所有注册过的键码，换键/读档时逐个反注册。

**键码空间：虚拟键码（VK），不是扫描码**（定位过程值得记下来）：
玩家报告"在据点里走动就会开面板"，而通知里的键码正是我们注册的 68。
查他的 `CustomControlMap.txt`：`Forward 0x57`、`Back 0x53`、`StrafeLeft 0x41`、`StrafeRight 0x44`
—— 这张表用的是 VK（0x57='W'、0x53='S'、0x41='A'、0x44='D'）；
再看另一个 mod（Real Handcuffs）的源码：`RegisterForKey(Input.GetMappedKey(control, 0))`
—— 把控制表里的键码直接交给 F4SE。
⇒ F4SE 的 `RegisterForKey` / `OnKeyDown` 用的是 **VK**：我们的 68 其实是 'D'，
所以横移走动会开面板，而 F10（VK 0x79）从来没注册上。
界面侧的表（`CODE2VK`/`KEY2VK`）与默认值（121）都已改成 VK；
`KeyboardEvent.keyCode` 本身就是 VK，所以那一层直接用最省事。
老存档里留着的 68 由 `MigrateHotkeyIfNeeded()` 迁到 121。

**迁移踩的两个坑（都踩过）**：
1. 迁移标记不能放在 `cfg` 里 —— `loadCfg()` 是把 `sm_cfg` 的字段**合并**到默认值上
   （`for (var k in o) state.cfg[k] = o[k]`），默认值里已有标记时"是否需要迁移"永远判断错。
   现在标记存在独立的 localStorage 键 `sm_hotkey_ver` 里。
2. 迁移必须在 `loadCfg()` **之后**跑 —— 反过来会被存档里的旧值覆盖。
   这两条一起导致"界面把老键码 68 又推回游戏"，而 68 在 VK 空间里是 'D'，
   于是"按 D/W 走动会开面板、通知显示来源 热键68"。

### 配套 F4SE 插件（`plugin/`）—— 为什么必须有它

纯 Papyrus 做不到"Esc 关面板时不惊动游戏的暂停菜单"：PrismaUI 的相关能力只有 C++ 接口
（`IVPrismaUI6::SuppressVanillaMenu`、`IVPrismaUI7::SuppressVanillaMenuIf`、
`IVPrismaUI9::SetViewOwnsEscape`）。对照 NODE.LITE 也能看出来 —— 它自带 F4SE 插件
（DLL 里有 `NODE::InputHandler::OnButtonEvent(RE::ButtonEvent*)`），Esc 是原生层处理的。

于是加了个自己的小插件（`plugin/`，工具链沿用 AutoDisarm 的 xmake + CommonLibF4）：

* 按 HTML 路径（`EnumerateViewsEx`）找到我们的 PrismaUI 视图，**不需要任何 Papyrus 与原生之间的桥**；
* 视图聚焦时用 `SuppressVanillaMenuIf("PauseMenu", 判定函数)` 压住暂停菜单。判定条件是
  "有 PrismaUI 面板可见 **或** 刚关掉面板的 250 毫秒内" —— 后者必须留着：Esc 关面板与游戏
  处理同一个 Esc 可能错开一两帧，面板已隐藏时若不兜一下，菜单还是会漏出来。
  条件写成"任何面板可见"而不是"只有我们的面板"，是为了不和 NODE.LITE 这类用同一接口的 mod 打架；
* 同时 `SetViewOwnsEscape(view, true)`、`SetViewRole(view, kPanel)`；
* 每 1.5 秒重装一次判定函数（万一别的 mod 后装了它自己的，我们下次抢回来）。

**是可选件**：没装或加载失败时插件什么都不做，Papyrus 侧仍会事后把暂停菜单关掉（会闪一下）。
确认它有没有加载：看 `我的文档/My Games/Fallout4/F4SE/SimpleSettlementManagerUI.log`
（应有 "PrismaUI API acquired" 与 "pause-menu suppression installed"）。

`plugin/build/` 是编译中间产物（约 1.4 GB，CommonLibF4 的 obj），删掉不影响使用，
只是下次构建要从头编几分钟。磁盘紧张时可以直接删。

构建：`bash tools/build_plugin.sh`（`tools/build.sh` 里也带这一步，失败不阻塞主 mod）。

踩过的坑：

1. **git-bash 里 xmake 会选 mingw 平台**（继承 MSYS2 环境），`xmake.lua` 里的 `set_plat` 来不及生效
   —— 所以走 `plugin/tools/build.bat`（cmd），并在命令行固定 `-p windows -a x64 --toolchain=msvc`。
2. 共享的 xmake 仓库缓存（`%LOCALAPPDATA%` 下的 `.xmake/repositories/xmake-repo`）坏过一次：
   它的 `HEAD` 指向 `refs/heads/.invalid`，于是每次启动都去 fetch 并报 `cannot lock ref 'HEAD'`。
   修法：`git symbolic-ref HEAD refs/heads/master` + `git update-ref refs/heads/master FETCH_HEAD`
   + `git reset --hard`（比重克隆快）。
3. **`REX::ERROR` 会被 Windows 头文件搞坏**：wingdi.h 里 `#define ERROR 0`，
   而 PrismaUI 的 API 头会拉进 `Windows.h`，于是 `REX::ERROR(...)` 展开成 `REX::0`。
   那一处改用 `spdlog::error(...)`。

**Esc 与暂停菜单（插件没装时的退路）**：Esc 关面板时，同一个 Esc 还会让游戏打开暂停菜单（PrismaUI 的 Esc 处理在输入层，
页面的 preventDefault 拦不住）。Papyrus 有 `UI.IsMenuOpen` / `UI.CloseMenu`，所以改成事后收拾：
界面按 Esc 时发 `smCloseEsc`，Papyrus 关闭面板后起 `9003` 定时器（4 × 0.3 秒），
暂停菜单冒出来就替玩家关掉（装了配套插件后这条路基本用不上了，留着兜底）。

**0.5.1 又收紧了一次**（玩家反馈"马上再按 Esc 想暂停，菜单可能也被关掉"）：
装了插件之后那次 Esc 本来就不会带出暂停菜单，于是清理窗口里永远"探不到东西"，
却还醒着 0.45 秒 —— 正好能吃掉玩家紧接的那次 Esc。现在窗口缩到 **0.15 秒（两次探测）**，
人手连按（通常 200 毫秒以上）不会被吃掉。根治办法是插件就位后直接不做这件事（下一步）。

**热键"有时要按两次才开"**：`bSwallowHotkeyUp`（吞掉关闭面板那次按键的松开事件）只有
在"松开事件确实送到了"时才被消费掉。如果那次松开根本没送到（暂停中松手、事件丢失），
标记会一直挂着，把玩家**下一次**真心的按键也吞掉 —— 表现就是按两次才开。
0.5.1 起给它加了时限：**只吞 1 秒内**的那次松开，过期就不吞（说明上次的松开没送到）。
这条同样是原生插件能彻底消掉的补丁之一。

**"替玩家关掉"必须是"一次性、找到即收工"**（玩家指出过这里的逻辑问题）：
一开始写成"窗口期内反复关"（4 × 0.3 秒），那会抢玩家之后自己按的 Esc ——
第一次 Esc 已经关掉面板了，第二次 Esc 跟面板无关，凭什么被我们关掉暂停菜单。
现在：发现暂停菜单 → 关掉 → **立刻解除武装**；一直没发现 → 最多探 3 次 × 0.15 秒也解除。
所以我们的清理只覆盖"那一次 Esc 顺带带出来的菜单"，之后就完全不碰玩家的暂停键。

**用热键关面板会"关上又立刻打开"**：同一次按键的**松开**事件常常在面板关闭之后才送到，
而松开正是"开面板"的触发条件。上一版用 0.4 秒静音挡，按住不放就会漏。
现在精确处理：热键关闭时界面发 `smCloseHK`，Papyrus 置 `bSwallowHotkeyUp`，
下一次松开事件无条件丢弃一次（只丢一次，所以之后正常按键不受影响）。

**面板开着时谁能关它**：面板持有焦点时游戏暂停，F4SE 的**松开**事件送不到 Papyrus，
只靠 `OnKeyUp` 会出现"F10 能开不能关"。所以：
界面侧在面板聚焦时自己处理热键（`smAct("smClose")`），Papyrus 侧在面板开着时**按下**也关一次；
关掉后 `CloseDashboard()` 会静音 0.4 秒，挡住同一次按键漏过来的松开事件（否则会被立刻开回来）。

### Papyrus 编译器的坑（补一条）：.ppj 里不能有 XML 注释

`<Imports>` 里插一行 `<!-- … -->`，编译器会报 `Failed to read project file …: 路径中具有非法字符`
或 `不支持给定路径的格式` —— 看起来像路径问题，其实是它不认注释。
（文件顶部的注释在根元素之外，一直没事。）排查时把注释删掉就恢复了。

### 界面改动的自检（不用开游戏）

界面逻辑（Papyrus 数据解析、供应网络并查集、各页渲染、热键换算、词条完整性，以及
"英文模式下是否还有漏翻的中文"）可以在 Node 里用桩件跑一遍，省一轮"改完—进游戏—发现报错"：

```bash
node tools/_smoke.js        # 喂假的 Papyrus 数据，逐项检查解析/渲染/词条
```

想看**版式**（列宽、换行、截断这类肉眼问题）用浏览器预览：脚本会复制界面并注入桩件，
生成一个能直接打开的页面（不进 mod 目录、不影响游戏）。Chromium 与 Ultralight 的布局规则一致，
所以版式问题在这里就能看出来：

```bash
python tools/_make_preview.py     # 生成 tools/_preview.html
```

## 改显示名（居民改名）的三个坑

**① 别手工往附加数据链表里插条目。** 看起来最自然的做法（`new ExtraTextDisplayData` +
`extraList->AddExtra`）有两个硬伤：

* `BaseExtraList::AddExtra` 里有 `assert(!HasType(type))`，而 `RemoveExtra(type)` **只有在链表里
  找得到同类型条目时才会清掉类型标志位**。于是"标志位说有、链表里其实没有"这种状态（引擎自己
  的名称刷新就会造成）永远清不掉 → 按类型删不掉、再 `AddExtra` 就弹断言。
  玩家实测表现：**第一次改名成功，第二次改名必崩**（`BaseExtraList.h Line: 16 !HasType(type)`）。
* `ExtraTextDisplayData` 是 novtable 且没有默认构造，`new` 出来的对象里
  `displayNameText` / `ownerQuest` / `textPairs` **全是野指针**。

正确入口是引擎自己的 `ExtraDataList::SetOverrideName(const char*)`（`ID 2190167`）。
现在的实现（`plugin/src/PanelWatcher.cpp` 的 `SetReferenceDisplayName`）是三层：
先调它 → 已有条目就**就地改字段**（不动链表结构/标志位，绝对安全）→ 只有在
"链里没有 **且** 类型标志位是干净的"时才新建一份（此时 `AddExtra` 才安全）。

**② 判定标准是"显示名变了没有"，不是"逐字等于我们写的字符串"。** 后者会把"改成功了但名字被
别的 mod 装饰/加了前后缀"误报成失败 —— 实测给过玩家一条"被任务或别名固定"的错结论
（那次改的是「哈莫尼」）。所以改名前先记下旧显示名，2 秒后比对**是否变化**，两个名字都写进日志
（`rename: 2s later: before '…', asked '…', the game shows '…'`）。

**③ 提示语里不要点名任何 mod。** 失败原因写成"如果这个居民是用 What's Your Name 命名的…"，
玩家卸载 WYN 之后照样收到这条提示 —— 属于纯粹的错误信息。现在只用"名字被任务或别名固定了"
这类不依赖具体 mod 的说法。

## ESP 里别乱改的两处（都是实测挖出来的）

**① VMAD 的脚本名布局（ver=6 / fmt=2）**，改脚本命名空间必须照这个来：

```
int16 version / int16 objectFormat / uint16 scriptCount
[version >= 4] uint16 对象脚本名长度 + 名字 + 1 个 NUL     ← 长度**不含** NUL
逐脚本：uint16 属性数，然后是属性表
每个属性：uint16 名长度 + 名 / uint8 类型 / uint8 状态 / 值
```

* 名字后面那个 **NUL** 是踩过的坑：只跳到名字末尾会整体差 1 字节，之后要么解析失败，
  要么更糟 —— 把 `ÿÿ`（0xFFFF 别名标记）当成越界 formID 去"修正"，把别名改坏。
* 判定解析对不对的硬标准：**走完必须正好落在 VMAD 末尾**（`normalize_esp.py` 现在就是这么
  校验的，对不上就拒绝修改）。
* 整个 ESP 里"命名空间"只出现在对象脚本名里；`SM_*` 这种属性名/编辑器 ID 不参与改名。
  改名的定点工具是 `tools/rename_vmad_scripts.py`（干跑 `--check` → 真改 → 自校验；
  改完 ESP 只该长 `6 × 出现次数` 字节，本次两处 → 1416 → 1428）。

**② 部署目录必须先清再同步。** 部署只拷贝不删除，所以改过命名空间 / 视图目录名 / 插件 DLL 名
之后旧文件会留着：旧 `.pex` 是死重量，**旧 DLL 更糟 —— F4SE 会把两个都加载，热键被处理两次**。
`build.sh` 现在每次部署前会 `rm -rf` 掉 `$DEST` 里的 `Scripts` / `PrismaUI_F4` / `F4SE`
三棵子树（$DEST 是本 mod 独占目录，安全），ESP 与 meta.ini 不动。

## 构建脚本的一个静默失效

`tools/build.sh` 曾经把"构建配套插件"嵌在"ESP 可写"的分支里：游戏或 MO2 占着 ESP 时整块被跳过，
于是**改了插件源码、脚本报成功，DLL 的 MD5 却一字未变**（一天踩了两次，白让玩家测了两轮旧版本）。
插件构建只碰 `plugin/` 和自己那个 DLL，与 ESP 无关，现在已经移到那个分支外面。
验构建是否真的生效：比对 `plugin/dist` 与 MO2 目录里 DLL 的 MD5。

## 发布打包

```bash
bash tools/package.sh     # → dist/release/SimpleSettlementManager-<版本>.zip
```

一条命令走完：完整构建 → 从界面文案里取版本号（`设置页 about` 里的「版本 x.y.z」，唯一来源）→
按清单收文件 → 复查 ESP 的 ESL 标志 → 打包（包内就是 Data 目录结构，esp 在根）。

- **收**：`SimpleSettlementManager.esp`、`Scripts/SimpleSettlementManager/`（.pex）、
  `Scripts/Source/User/SimpleSettlementManager/`（**源码，故意带上**：Papyrus mod 的惯例，
  方便玩家报错时报行号）、`PrismaUI_F4/views/SimpleSettlementManager/`、
  `F4SE/Plugins/SimpleSettlementManagerUI.dll`（可选件）、自动生成的 `README.md`。
  只发可运行文件的话，把 `copy Scripts/Source/...` 那一行删掉即可。
- **不收**：`meta.ini`（MO2 本地元数据）、`*.esp.bak*`（构建备份）、
  `SimpleSettlementManagerUI.hotkey`（本机热键缓存，每台机器不一样）。
- **ESL 是发布前的硬门槛**：游戏或 MO2 占着 ESP 时，构建会**静默跳过**打标这一步
  （只打印一行"跳过 ESP 处理"），所以打包脚本会自己复查 TES4 flags，
  缺 0x200 就直接中止 —— 免得发出去一个白占插件槽位的版本。

**zip 的路径分隔符必须自己写。** `.NET` 的 `[ZipFile]::CreateFromDirectory` 会把目录分隔符写成
`\`，而 zip 规范要求 `/`；部分解压器/mod 管理器会把 `\` 当成文件名的一部分，装出来是
`F4SE\Plugins\SimpleSettlementManagerUI.dll` 这么个怪名字的单文件。现在改成逐条目
`CreateEntryFromFile` 并手动 `Replace('\','/')`。

## 仓库 / 从源码构建（对外发布的相关约定）

- **命名：显示名与内部标识统一为 `SimpleSettlementManager`**（中文界面「据点管理」）。
  0.8.7 从 `SettlementManager` 全量改名而来 —— 原名和别人的 mod 重名，而那时这个 mod 只有作者
  自己用过，所以连内部标识一起改干净（代价：作者自己的存档里那盘卡带的引用会断一次，脚本会补发）。
  涉及：esp 文件名、脚本命名空间、PrismaUI 视图名与视图目录、插件 DLL 名、MO2 文件夹名、
  热键缓存文件名、各工具里的字符串。
  **改脚本命名空间必须同时改 ESP 的 VMAD**（里面写着脚本名，Papyrus 靠它绑定脚本）——
  用 `tools/rename_vmad_scripts.py` 定点改字节，不必开 CK；改完用 `tools/inspect_esp.py` 复核。
  只改"玩家看得到的显示名"时动四处即可：`index.html` 的 `<title>` 与 en 词条 `brand`、
  `tools/package.sh` 的包名与包内 README、根 `README.md`、`docs/PUBLISH.md` 的发布文案。
- **本机路径一律走 `tools/local.conf`**（不进版本库；模板是 `tools/local.conf.example`）。
  `build.sh` / `build_plugin.sh` / `package.sh` 开头都读它，缺了会直接报错说怎么建。
- **`.ppj` 是生成物**：模板 `SimpleSettlementManager.ppj.in` 里用 `@ROOT@` 占位，构建时用
  `cygpath -m` 替换成 `E:/...` 形式（PapyrusCompiler 要正斜杠；盘符形式对它明确可解，
  git-bash 的 `/e/...` 不保证）。别把生成物提交进去。
- **ESP 要进版本库**（别人 clone 下来才有得用）。CK 把 ESP 保存到 MO2 目录，所以 `build.sh`
  在最后**把处理过的 ESP 拷回仓库**（顺序很重要：先规范化/打 ESL，再拷回）。
- **CommonLibF4 是 submodule**（官方仓库，固定在构建通过的 commit）——
  clone 要用 `--recursive`。`vendor/` 下的原版/第三方脚本源码不进版本库（版权不是我们的），
  README 里写了各自从哪取。
- **`python` 可能是应用商店的占位程序**：Windows 上 `python` 存在、`which` 查得到，
  但一跑就报"未安装"。构建脚本以前把它和"文件被占用"混在同一个判断里，于是 ESP 的
  规范化 / 打 ESL 步骤**长期被静默跳过**，却一直显示"游戏正在运行？"。现在会先在
  `py` / `python` / `python3` 里挑一个真能跑的，并把两种原因分开报。
- 许可：**GPL-3.0**（被 CommonLibF4 决定，插件链接了它）。发布二进制时源码地址必须给出。

## 目录

```
src/Scripts/Source/User/SimpleSettlementManager/   ← 我们的脚本（命名空间 = 目录）
vendor/vanilla/                              ← 原版脚本（编译期依赖，见 vendor/README.md）
vendor/wsfw/                                 ← Workshop Framework 2.6.0 源码（编译期依赖）
dist/                                        ← 编译产物（.pex），由 build.sh 生成
docs/                                        ← CK 建记录步骤
SimpleSettlementManager.ppj                        ← 编译工程
```

## 待实机验证

1. 中文在游戏内的渲染（字体）。
2. 新建的终端记录 → Fragment 是否按预期触发。
3. `Debug.MessageBox` 在 Pip-Boy 播放状态下是否可见。
4. 远处据点的汇总数值是否可读、是否过旧。
5. 供应网络合计：造/拆一条供应线后重开面板，网络成员与合计值应随之变化。
6. 据点页明细：站在 A 据点打开面板 → 移到 B 据点，B 的居民/床位/岗位明细应只在 B 显示（A 显示"只对当前所在据点可用"）。

## 界面改动的自检（不用开游戏）

界面逻辑（Papyrus 数据解析、供应网络并查集、各页渲染）可以在 Node 里用桩件跑一遍，
省一轮"改完—进游戏—发现报错"：

```bash
node tools/_smoke.js     # 喂一份假的 Papyrus 数据，检查解析与渲染结果
```
