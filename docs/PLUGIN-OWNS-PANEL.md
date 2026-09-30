# 面板生命周期交给插件（照 NODE.LITE 的模式重做）

## 为什么重做

纯 Papyrus 拥有面板（CreateView/Show/Focus/Unfocus/Hide）+ 插件在旁边"猜"状态，交替出过这一串问题：

- 读档后热键失效约 10 秒（Papyrus 的读档回调被脚本负载推迟，GLOB 里还是旧值）；
- 插件 `panel visible` 判断错一半（实测日志里 16 次热键里 10 次判断为 false，而那几次面板是开着的）；
- Esc 被 PrismaUI 在菜单层吃掉（插件日志里 `escape pressed` 为 0），页面/Papyrus 都收不到 →
  面板卡在"失焦但还画着"的中间态，且暂停菜单被压制（因为插件认为面板还可见）。

NODE.LITE 的做法（它的 DLL 字符串与网页源码都能看到）：
**面板的开关完全在插件里**（`Dashboard opened (HasFocus=…, health=…)`、`ApplyPanelFocus`、`WatchFocus`、
`Dashboard lost Prisma focus …; reclaiming without pausing the game`），
网页按 Esc 调 `nodeCloseRequest()`（插件用 `InteropCall` 注入的原生函数）→ 插件原生 `Hide`+`Unfocus`。
**状态在它自己手里，所以从不"猜"。**

## 新架构

```
                    ┌─────────────── 插件（面板的唯一拥有者）────────────────┐
Papyrus（只管数据）  │  CreateView / Show / Hide / Focus / Unfocus           │
  写 SM_PanelWant ──┤  读 SM_PanelWant（0 关 / 1 开）→ 执行                │
  读 SM_PanelOpen ◄─┤  写 SM_PanelOpen（1 开 / 0 关）                       │
  推数据（Push 保留）│  SetViewOwnsEscape(view, true)  ← Esc 归视图/网页     │
                    │  SetViewRole(view, kPanel)                            │
  事件 SMUI_Event ◄─┤  按下热键 / 网页请求关闭 → 通知 Papyrus                │
                    │  暂停菜单压制（判定读自己的 g_panelOpen，不猜）        │
                    └──────────────────────────────────────────────────────┘
网页：按 Esc → 先调插件注入/绑定 的关闭请求（快），同时照旧发 smCloseEsc（兜底，走 GLOB）
```

### 三个共享变量（ESP 里的 GLOB 记录，tools/add_glob.py 建）

| 记录 | FormID | 方向 | 含义 |
| --- | --- | --- | --- |
| `SM_HotkeyVK` | 000F9D | Papyrus → 插件 | 面板热键（虚拟键码，默认 121 = F10） |
| `SM_PanelWant` | 000F9E | Papyrus → 插件 | 请求：1 = 请打开，0 = 请关闭 |
| `SM_PanelOpen` | 000F9F | 插件 → Papyrus | 状态：1 = 开着，0 = 关着 |

### 职责重划

**插件**（`plugin/src/PanelWatcher.cpp`）

1. 每 tick（250 ms）读 `SM_HotkeyVK` 与 `SM_PanelWant`；`SM_PanelWant` 变化时执行打开/关闭。
2. 打开：无视图则 `CreateView("SimpleSettlementManager/index.html")` → `Show` → `Focus(view, true, false)`
   → 设 `SetViewOwnsEscape(view, true)`、`SetViewRole(view, kPanel)` → `SM_PanelOpen = 1` → 通知 Papyrus `"opened"`。
3. 关闭（三种触发：网页请求 / 热键再次按下时"只开不关"不适用 / Papyrus 的请求）：
   `Unfocus` → `Hide` → `SM_PanelOpen = 0` → 通知 Papyrus `"closed"`。
4. 热键按下：面板关着 → 请求打开（写 `SM_PanelOpen` 前先把 `SM_PanelWant` 设 1 亦可）；
   面板开着 → **什么都不做**（关闭只由 Esc / 关闭按钮）。
5. 暂停菜单压制：判定条件是 `g_panelOpen`（自己的状态，不再用 IsHidden/IsAnyPanelVisible 猜）。
6. `SetViewOwnsEscape(view, true)` 必须在视图创建后调用一次，并每 tick 校验（重建视图后要重设）。

**Papyrus**（`ControllerQuest.psc`）

1. 删掉所有 `PrismaUI.*` 视图调用与 9001/9002 定时器（不再拥有视图、不再看焦点）。
2. `OpenDashboard`：写 `SM_PanelWant = 1`（并记 `DashboardOpen = true` 以便数据推送门控）。
   `CloseDashboard`：写 `SM_PanelWant = 0`、`DashboardOpen = false`。
3. 数据推送保留（`PushDashboardData`）；页面加载后会 ping，Papyrus 照旧回推。
4. `OnSMUIEvent`：`"opened"` → 推一次数据；`"closed"` → `DashboardOpen = false`；
   `"hotkey"` → `OpenDashboard`（只开）；`"esc"`/`"close"` → `CloseDashboard`。
5. Esc/关闭按钮：都只写 `SM_PanelWant = 0`，由插件执行真正的隐藏。

**网页**（`index.html`）

1. Esc → `smAct("smCloseEsc")`（保持）；`smClose` 按钮保持。
2. 若插件通过 `BindUIEvent` 绑定了 `smNativeClose`，页面在 Esc 时也可直接 `smAct("smNativeClose")`（快路径）。

### 迁移顺序（每步都要能编译 + 部署）

1. ✅ 三个 GLOB 记录（已完成）。
2. 插件：加面板拥有者的逻辑（CreateView/Show/Hide/Focus/Unfocus + SM_PanelWant/SM_PanelOpen + ownsEscape），
   但**先不启用**（Papyrus 仍在拥有视图时两边会打架 → 所以这一步和下一步必须同一轮完成）。
3. Papyrus：删视图调用 + 定时器，改成写 `SM_PanelWant`。
4. 网页：Esc 快路径（可选）。
5. 验证：Esc 一次关闭且不暂停；第二次 Esc 正常暂停；F10 只开不关；读档后热键立即可用。

### 已知风险

* `SetViewOwnsEscape` 之前和"Papyrus 事后清理暂停菜单"叠加时疑似导致过一次崩溃。
  那套清理已删除，所以这次单独引入它；若再崩，第一件事就是撤掉它（保持其余不动），
  这样能一刀切出是不是它。
* `BindUIEvent` 的触发方式（页面怎么调用绑定的名字）未实测；所以网页侧保留走 Papyrus 的兜底路径。

## 进度（用这份文件接着做，别再从零推）

* ✅ 三个 GLOB 记录已建（tools/add_glob.py：000F9D / 000F9E / 000F9F）。
* ✅ **插件侧已完成并编译通过**（`plugin/src/PanelWatcher.cpp`）：
  * 拥有面板：`EnsureView()`（自己 `CreateView("SimpleSettlementManager/index.html")`）、`OpenPanel()`（Show + Focus +
    `SetViewOwnsEscape(view,true)` + `SetViewRole(view,kPanel)`）、`ClosePanel()`（Unfocus + Hide）；
  * 读 `SM_PanelWant`（1 开 / 0 关）执行动作；写 `SM_PanelOpen` 回报状态；两者保持同步；
  * 热键只开不关（面板开着时什么都不做）；暂停菜单压制用 `g_panelOpen`（不再猜）；
  * 读档时收起面板并把状态归零；
  * 通知 Papyrus 的事件：`ready` / `opened` / `closed` / `esc` / `hotkey`。
  * 注意：`PanelWatcher.cpp` 里 `NowMs()` 是 static 定义，别在前置声明里重复声明（会 LNK2019）；
    需要时间戳的地方直接写 `std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()`。
* ⚠️ **Papyrus 侧只做了一半**，工作副本在 `backups/CQ.pluginside-WIP.psc`（**编译不过**，勿直接用）：
  * 已完成：两个 GLOB 属性 + `WritePanelWant()`；`OpenDashboard`/`CloseDashboard` 改成写请求；
    删掉 `OnTimer` 看门狗；`OnSMUIEvent` 加 `opened`/`closed`；清掉 `PrismaUI.*` 视图调用。
  * **剩下两处结构残留**：编译器报 `missing EndOfFile at 'return'`（约 883 行）与更早的
    `mismatched input 'EndIf' expecting ENDEVENT`（约 199 行）——都是"删掉 if 行、留下 EndIf/return"造成的。
    做法：直接看这两处上下文，删掉孤立的 `EndIf` / `return` / 空 if，再编译。
  * 校验标准（编译通过后）：脚本里搜不到 `PrismaUI.`（除 `PrismaUI_Event` 这个外部事件名）与 `StartTimer`。
* 未做：网页侧 Esc 快路径（`BindUIEvent("smNativeClose")`）——先不做，等 Papyrus 侧通过、实机验证后再考虑。

## 现状（这一节描述线上生效的架构，别再照上面那套 A/B 直接改）

（2026-09-27 本轮结束时的状态）

**分工**
* **Papyrus 拥有视图**：`OpenDashboard` 里 `PrismaUI.CreateView`（保留名字，数据推送 `Push` 需要它）+
  `PrismaUI.Show`/`Focus`；`CloseDashboard` 里 `Unfocus` + `Hide`。**所有框架调用都在 Papyrus 侧**
  —— 实测从原生侧驱动 Show/Focus 会断 PrismaUI 的双向通道（页面显示"✗ 事件未到达游戏"）。
* **插件**（`SimpleSettlementManagerUI.dll`）只管三件事：
  1. 原生热键（只开不关）：按 F10 → `NotifyPapyrus("SMUI_Event", "hotkey")` → Papyrus 打开面板；
  2. 面板状态判定：读 GLOB `SM_PanelOpen`（Papyrus 在开/关时写 0x00000F9F）；
  3. **状态自愈**：若 `SM_PanelOpen == 1` 但视图实际隐藏/失焦持续 0.4 秒 → 纠正状态为 0
     并 `NotifyPapyrus("SMUI_Event", "close")` → Papyrus 真正关闭面板。
     这条是 Esc 能退出的关键：PrismaUI 收到 Esc 只做"取消聚焦"（面板还画着），页面收不到 Esc，
     只能由插件发现"失焦"并补上关闭动作。
* **外部事件通道**（插件 → Papyrus）：`ready` / `hotkey` / `opened` / `closed` / `close` / `esc`。

**已完成（2026-09-27 晚）**
* **Esc 一次即关**：认领视图时加了 `SetViewOwnsEscape(view, true)`（+ `kPanel` 角色）——
  让 PrismaUI 别把 Esc 吃掉，页面就能收到并走正常关闭流程。只加了这一个调用；
  `RegisterJSListener` 是上次断桥的元凶，禁止再引入（那一次它是和另外两个一起加的）。
* **读档后的热键空窗已消除**：插件把热键值写在 DLL 旁边的 `SimpleSettlementManagerUI.hotkey`，
  启动先读它 → 热键当场可用；GLOB 只在玩家改键时才起作用（那次会同步写文件）。
* 临时诊断通知（面板打开来源、读档诊断）已全部删除。

**仍然存在的已知问题**
* 热键打开面板偶尔有延迟（跨了一次 VM 外部事件队列：插件 → 事件 → Papyrus → 打开）。
  要零延迟只能让插件自己 Show（会断桥），所以维持现状。
* 状态自愈（0.4 秒）保留作为兜底：即使将来某条关闭路径失效，也不会再出现"关不掉+暂停/热键全乱"的死锁。
* 读档后热键约有 10 秒空窗（Papyrus 的读档回调被脚本负载推迟，GLOB 里是上一局的旧值）
  ——解法是把绑定搬进插件（自己的配置文件，启动即读），见上文的"照 NODE.LITE"部分。
* 插件 DLL 部署会被运行中的游戏锁住：**先关游戏**再跑 `bash tools/build_plugin.sh`。

**调试入口**
* 插件日志：`<Documents>\My Games\Fallout4\F4SE\SimpleSettlementManagerUI.log`
* 脚本日志：`<Documents>\My Games\Fallout4\Logs\Papyrus.0.log`（`[SM]` 开头的行；注意该日志可能被 ini 关掉）
