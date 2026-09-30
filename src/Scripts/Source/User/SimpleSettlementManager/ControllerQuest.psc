Scriptname SimpleSettlementManager:ControllerQuest extends Quest
{ 据点管理终端 —— 控制器脚本（M0）

  M0 范围：
    * 首次进入游戏时把全息卡带放进玩家背包（丢失后自动补发）
    * 「查看当前据点」：把玩家所在据点的汇总数值与明细数量显示出来

  设计约束（来自原版脚本本身）：
    Bethesda 在 WorkshopParentScript.psc 头部写明：完整数据（居民 / 对象）
    只对“当前已加载”的据点存在。所以汇总数值（写在 workshop 引用的
    ActorValue 上）任何据点都能读，逐个居民/床位的明细只在据点加载时可读。
    本脚本用 ws.Is3DLoaded() 区分这两种情况。

  所有动作（指派 / 迁居）都走 Workshop Framework 的 WorkshopFunctions，
  不要直接调用原版 WorkshopParentScript 的指派函数，也不要覆盖原版脚本。
}

Group Required_Properties
	WorkshopParentScript Property WorkshopParent Auto Const Mandatory
	{ 原版据点管理任务（EditorID: WorkshopParent），CK 里 Auto-Fill All 会自动填 }

	Holotape Property SM_Holotape Auto Const Mandatory
	{ 本 mod 的全息卡带（EditorID: SM_Holotape），玩家用它打开管理终端 }
EndGroup

Group Persistent_State
	bool Property bHolotapeGiven = false Auto
	{ 是否已经发放过卡带。脚本属性会随存档保存 }

	WorkshopScript Property SelectedWorkshop = None Auto
	{ 玩家在菜单里选中的据点 }

	Actor Property PickedSettler = None Auto
	{ 管理面板里当前选中的居民（只有运行时意义，不需要写进 VMAD） }

	bool Property DashboardOpen = false Auto
	{ 管理面板是否打开（Papyrus 侧没有 IsHidden，只能自己记） }

	int Property HotkeyCode = 121 Auto
	{ 打开/关闭面板的热键（**虚拟键码 VK**）：121 = 0x79 = F10，0 = 关闭热键。
	  面板在设置里改；由界面通过 smSetHotkey<键码> 事件告知。

	  为什么是 VK 而不是扫描码（踩过，别改回去）：
	  热键的键码是虚拟键码（和 CustomControlMap.txt、Input.GetMappedKey 同一套）——
	  Input.GetMappedKey 同一套空间（0x57='W'、0x53='S'、0x44='D'）。
	  我们曾经按扫描码填 68，而 68 在 VK 空间里正是 'D'，于是"在据点里横移走动"就会开面板，
	  而 F10 从来没能生效。 }

	float Property LastCloseTime = 0.0 Auto
	{ 上次关闭面板的真实时间（Utility.GetCurrentRealTime）—— 只用于诊断和去重 }

	float Property LastTerminalOpenTime = 0.0 Auto
	{ 上次由「卡带菜单」打开面板的真实时间。
	  全息卡带播放结束后游戏可能把菜单项再跑一遍（玩家看到的就是"面板自己又弹出来"），
	  这个时间戳用来把重复触发挡掉。 }

	float Property OpenDashboardTime = 0.0 Auto
	{ 上次打开面板的时刻（给 9002 看门狗用：刚打开的头几秒不急着关） }

	bool Property bPluginReady = false Auto
	{ 配套插件（SimpleSettlementManagerUI.dll）已经接管热键。
	  它通过外部事件 SMUI_Event/"ready" 告知 —— 收到后本脚本就不再注册 F4SE 热键、
	  本脚本不再自己注册/处理按键，避免两边同时处理同一次按键。 }

	GlobalVariable Property PanelState = None Auto
	{ SM_PanelOpen（本地 0x00000F9F）：面板状态，1 = 开着、0 = 关着。
	  本脚本在开/关时写它；插件读它来做"压暂停菜单"和"热键只开不关"的判断
	  （不再用 IsHidden / IsAnyPanelVisible / HasFocus 猜 —— 实测那三个错一半）。 }

	int Property PendingRenameFormID = 0 Auto
	{ 待改名的居民 FormID —— 与名字一起交给配套插件执行 }

	String Property PendingRenameName = "" Auto
	{ 待改的新名字（插件改完回读确认，再由本脚本发提示） }

	GlobalVariable Property RenameReq = None Auto
	{ SM_RenameReq（本地 0x00000FA0）：改名请求号，每次 +1 插件就会去执行 }

	GlobalVariable Property RenameResult = None Auto
	{ SM_RenameResult（本地 0x00000FA1）：0 待处理 / 1 成功 / 2 失败（插件写） }

	GlobalVariable Property HotkeyGlobal = None Auto
	{ ESP 里的 GLOB 记录 SM_HotkeyVK（本地 FormID 0x00000F9D）：插件每帧读它拿热键。
	  运行时用 Game.GetFormFromFile 取一次并缓存，不需要 CK 填属性。 }

	bool Property bHotkeyCapturing = false Auto
	{ 面板正在"等待玩家按新热键"。
	  这期间插件那边的热键事件会被忽略 —— 否则玩家按到旧热键时面板会当场开/关，
	  面板会在捕获过程中当场消失（界面用 smCaptureStart / smCaptureEnd 告知）。 }

	float Property LastHotkeyTime = 0.0 Auto
	{ 上次处理热键事件的时间，用来做连击去抖。

	  陷阱（玩家反馈"读档后 F10 失效，按多少次都没用，过一阵自己又好了"）：
	  `Utility.GetCurrentRealTime()` 是**"本次进程启动以来的秒数"**（原版 Utility.psc 原话：
	  "the number of seconds since the application started"），每次重启游戏都从 0 开始；
	  而这个属性**存在存档里**。于是读档后它落在"未来"，`now - LastHotkeyTime` 是负数、
	  恒 < 0.3 → 每一次按键都被当成"重复投递"丢掉，直到本次运行时长追上存档里那个值。
	  两道防线：① OnPlayerLoadGame 里清零；② 去抖只在差值落在 [0, 0.3) 时才认（见 IsRepeatEvent）。 }

	; 最近一次推送给界面的那份居民名单（界面里的行号就是照着它的顺序画的）。
	; 为什么需要它：动作（改名/召唤/解除）是"行号 → 居民"，必须按**界面看到的那份**解析。
	; 用实时名单解析会错位：面板刚打开的几秒里居民名单还在变（居民在不断注册、
	; WSFW 也正好在这个时间点扫描），行号可能解析不到 → 动作静默失效，
	; 表现就是"改名前几秒会被还原"（玩家反馈，日志里那些请求根本没到插件）。
	ObjectReference[] Property LastPushedRoster = None Auto

	; 最近推送出去的**工位对象**列表（岗位页的行号 → 工位对象，见 GetPushedJobByIndex）。
	; 和名单同理：界面按行号发回来的操作必须对着"界面看到的那一份"解析。
	ObjectReference[] Property LastPushedJobs = None Auto

	; 岗位页"先点工位、再点人"用：选了工位先记下标，等人也选了就派活
	int Property PickedJobRow = -1 Auto

	; 岗位页"类别合并行"（农民 / 守卫：同类工位一人可多岗）用：记下类别，等人选了批量派活
	int Property PickedKindRow = -1 Auto

	bool Property bCleanupPauseMenu = false Auto
	{ 正在替玩家收拾"被 Esc 顺带打开的那一个"暂停菜单。
	  找到就关掉并立刻解除武装；找不到也很快解除 —— 绝不影响玩家之后自己按的 Esc。 }

	int Property EscCleanupTries = 0 Auto
	{ 上面的探测次数（最多 3 次 × 0.15 秒） }
EndGroup

Group Settings
	bool Property bAutoReissueHolotape = true Auto
	{ 读档时卡带不在背包里就自动补发 }
EndGroup

; ======================================================================
; 生命周期
; ======================================================================

; Quest 的启动事件是 OnQuestInit（FO4 的 Quest 脚本里没有 OnInit）
Event OnQuestInit()
	EnsureHolotape()

	; OnPlayerLoadGame 是 Actor 上的事件，Quest 收不到，必须注册远程事件。
	; 写法照抄原版 inst305RadioRackSlotScript.psc：RegisterForRemoteEvent + Event Actor.OnPlayerLoadGame
	RegisterForRemoteEvent(Game.GetPlayer(), "OnPlayerLoadGame")

	; M2：接收 PrismaUI 管理面板发来的动作（JS 里 window.prisma.emit(...)）
	; PrismaUI 会把 JS 的 emit 派发成固定外部事件 PrismaUI_Event，带两个字符串参数
	RegisterForExternalEvent("PrismaUI_Event", "OnPrismaUIEvent")
	; 配套插件用这个事件告诉我们"插件就位/热键被按下"（见 OnSMUIEvent）
	RegisterForExternalEvent("SMUI_Event", "OnSMUIEvent")

	; 热键：打开/关闭面板。默认 F10（0x44）。
	; 注册前先反注册：初始化与读档都会走注册，叠加会变成"按一次触发两次"（踩过）。
	MigrateHotkeyIfNeeded()
	; GLOB 是插件读热键的唯一来源 —— 开局/读档都立刻用当前值覆盖它，
	; 免得记录里那个初值变成"第二个真相"（玩家反馈：读档先是 F10，过会儿跳成 F11）
	WriteHotkeyGlob(HotkeyCode)
EndEvent

; 热键：F10 开/关管理面板
; 按下事件**不再触发任何动作** —— 只做诊断。
; 原因（实机诊断）：读档时 F4SE 会派发一次"按下"事件（键码等于我们注册的热键，但没人按过），
; 面板于是自己弹出来。改用"松开"触发就能天然排除这类假事件（假按下没有配套的松开）。




; 注册当前热键（先反注册，避免叠加）


; 反注册我们注册过的每一个扫描码（反注册没注册过的也没有副作用）


; 把扫描码记进"注册过的表"（去重，自己做 —— Papyrus 的 int[] 上没有 Find）




; 把居民拉到你身边。
; 用途：搬运工（跑供应线的人）常在路上，找不到就没法操作（解除岗位之类）。
; 这套动作和 NODE.LITE 一样：MoveTo 玩家 → 落到最近的导航网格（免得卡在墙里）→ 重估 AI 包。
Function DoSummonActor(Actor who)
	if !who
		return
	EndIf
	Actor player = Game.GetPlayer()
	if !player
		return
	EndIf
	who.MoveTo(player)
	who.MoveToNearestNavmeshLocation()
	who.EvaluatePackage()
	Debug.Notification(ActorName(who) + " 已被拉到你身边")
EndFunction

; 给居民改名。
; 名字挂在**引用**的显示名上（不是基础记录）—— 与 WYN / Rename Anything 的做法一致，
; 所以面板刷新出来的名字立刻就是新名字（我们读显示名的，见 ActorName）。
Function DoRename(Actor who, String asName)
	if !who || asName == ""
		return
	EndIf

	; **执行者是配套插件**：这里只记下"改谁、改成什么"并把请求号 +1。
	; 插件写显示名（ExtraTextDisplayData，与 Garden of Eden 做的是同一件事）→ 回读确认
	; → 写 SM_RenameResult → 发 "renamed" 事件回来，由 OnSMUIEvent 发提示。
	Debug.Trace("[SM] DoRename " + ActorName(who) + " → " + asName)
	PendingRenameFormID = who.GetFormID()
	PendingRenameName = asName

	if !RenameResult
		RenameResult = Game.GetFormFromFile(0x00000FA1, "SimpleSettlementManager.esp") as GlobalVariable
	EndIf
	if RenameResult
		RenameResult.SetValue(0)          ; 0 = 待处理
	EndIf

	if !RenameReq
		RenameReq = Game.GetFormFromFile(0x00000FA0, "SimpleSettlementManager.esp") as GlobalVariable
	EndIf
	if RenameReq
		RenameReq.SetValue(RenameReq.GetValue() + 1)   ; 请求号 +1 → 插件下一 tick 执行
	EndIf
EndFunction

; 设置热键（0 = 关闭）。由界面通过 smSetHotkey<键码> 触发。
; 热键全在配套插件里实现（原生按键事件）：这里只更新属性 + 把值写进 GLOB（插件读它）。
Function ApplyHotkey(int aiCode)
	bHotkeyCapturing = false
	HotkeyCode = aiCode
	WriteHotkeyGlob(HotkeyCode)
	if HotkeyCode > 0
		String bound = Input.GetMappedControl(HotkeyCode)
		if bound != ""
			Debug.Notification("注意：这个键在游戏里已绑定到「" + bound + "」，操作时可能会误开面板")
		Else
			Debug.Notification("面板热键已更新")
		EndIf
	Else
		Debug.Notification("面板热键已关闭")
	EndIf
	PushDashboardData()
EndFunction


; 打开面板后延迟一下再确认一次聚焦 —— 我们要先让哔哔小子菜单真正关掉，焦点才拿得到
Event OnTimer(int aiTimerID)
	String view = DashboardViewName()

	if aiTimerID == 9001
		; 只有面板还开着才重新聚焦 —— 否则玩家在 0.4 秒内关掉面板后，
		; 这个定时器会把已经隐藏/销毁的视图又拉起来（连带把鼠标指针弄回来）
		if DashboardOpen && PrismaUI.IsValid(view)
			PrismaUI.Focus(view, true, false)
			PushDashboardData()
		EndIf
	elseif aiTimerID == 9003
		; Esc 关面板后，游戏常会因为**同一个** Esc 打开暂停菜单 —— 替玩家关掉，然后立刻收工。
		; 只处理"这一次 Esc 顺带打开的那一个"菜单：
		;   * 发现暂停菜单 → 关掉 → 解除武装（玩家之后自己按 Esc 暂停，我们绝不插手）
		;   * 一直没发现（那次 Esc 没漏给游戏）→ 盯 3 次 × 0.15 秒也解除武装，
		;     所以玩家紧跟着按的第二次 Esc 不会被吃掉。
		if bCleanupPauseMenu
			if UI.IsMenuOpen("PauseMenu")
				UI.CloseMenu("PauseMenu")
				bCleanupPauseMenu = false
				Debug.Trace("[SM] 关掉被 Esc 顺带打开的暂停菜单，这次 Esc 的收尾结束")
			Else
				EscCleanupTries += 1
				; 总共只看 0.15 秒（两次 0.05/0.10 的探测）：这是个"玩家紧接着又按一次 Esc
				; 想暂停"绝不会被我们吃掉的长度（人手连按通常 200 毫秒以上）。
				if EscCleanupTries < 2
					StartTimer(0.05, 9003)
				Else
					bCleanupPauseMenu = false
					Debug.Trace("[SM] 没看到被 Esc 带出来的暂停菜单，收尾结束")
				EndIf
			EndIf
		EndIf
	elseif aiTimerID == 9002
		if DashboardOpen
			; 只做一件事：焦点没了（玩家按 Esc 让 PrismaUI 取消聚焦）就把面板一起收掉。
			; 不去看原版菜单 —— Alt-Tab 冻指针那个现象 NODE.LITE 同样存在，
			; 是 PrismaUI 与游戏界面的交互问题，不是我们该管的；强关面板会打断玩家。
			if !PrismaUI.HasFocus(view) && (Utility.GetCurrentRealTime() - OpenDashboardTime < 0.6)
				; 刚打开的头 3 秒里焦点可能还没建立（PrismaUI 的聚焦是排队执行的，
				; 从游戏内按热键打开时会比从卡带打开慢一拍）—— 这时候要再聚焦一次，
				; 而不是判定"玩家取消了"就把面板关掉（那表现就是"打开一下马上关"）。
				PrismaUI.Focus(view, true, false)
				StartTimer(0.5, 9002)
			elseif PrismaUI.IsValid(view) && PrismaUI.HasFocus(view)
				StartTimer(0.5, 9002)      ; 还在用，继续盯着
			Else
				CloseDashboard()           ; 焦点没了 → 一并关掉（视图保留，只隐藏）
			EndIf
		EndIf
	EndIf
EndEvent

Event Actor.OnPlayerLoadGame(Actor akSender)
	; **第一件事就是重新注册外部事件**（玩家反馈过"读档后 F10 失效"）。
	; 为什么必须放在最前面：这个函数后面任何一句抛错，都会让整段函数当场中止 ——
	; 如果注册排在后面，一次无关的报错就把热键彻底打死（插件还在发事件，但没人接）。
	; 顺序也不能省：F4SE 会把重复注册记成多条，叠加后一次事件收到两遍。
	UnregisterForExternalEvent("PrismaUI_Event")
	RegisterForExternalEvent("PrismaUI_Event", "OnPrismaUIEvent")
	UnregisterForExternalEvent("SMUI_Event")
	RegisterForExternalEvent("SMUI_Event", "OnSMUIEvent")
	Debug.Trace("[SM] 读档：外部事件已重新注册")

	EnsureHolotape()

	; 读档时先把面板彻底清掉。
	; 原因：PrismaUI 的视图活在游戏进程里、会跨读档保留 —— 如果存档时面板开着，
	; 读档后框架会把那个视图重新显示出来，看起来就像"面板自己冒出来"（玩家反馈）。
	; 每次都销毁一遍，保证读档后是干净状态。
	String view = DashboardViewName()
	if PrismaUI.IsValid(view)
		PrismaUI.Unfocus(view)
		PrismaUI.Hide(view)
		PrismaUI.Destroy(view)
	EndIf
	DashboardOpen = false
	; GLOB 也要一起归零：它是**存在存档里**的，如果存档时面板是开的，读档后它还留着 1 ——
	; 插件据此认为"面板正开着"，于是热键静默失效、暂停菜单还被压着（玩家反馈过这一串症状）。
	WritePanelState(0)
	; 读档算新的一段使用：把两个时间戳清掉，免得上一段留下的"8 秒去重窗口"
	; 把读档后第一次点卡带菜单挡掉。
	LastCloseTime = 0.0
	LastTerminalOpenTime = 0.0
	; 热键去抖的时间戳也必须清零：它是"本次进程启动以来的秒数"，读档后存档里的旧值
	; 会落在未来，不清掉的话每一次按键都会被当成重复投递丢掉（玩家反馈的"读档后 F10 失效"）。
	LastHotkeyTime = 0.0
	OpenDashboardTime = 0.0
	LastPushedRoster = None      ; 上一局的名单对不上这一局的界面

	MigrateHotkeyIfNeeded()
	; 读档也一样：立刻把当前热键同步进 GLOB（插件 0.25 秒后读到并接管）
	WriteHotkeyGlob(HotkeyCode)
	; 按当前设置重新注册热键（先反注册，避免叠加）
	; 注：外部事件的注册已经挪到本函数最前面（见开头），这里不再重复 ——
	; 曾经在这里注册两次，F4SE 记成两条，一次事件收到两遍（热键"开一下马上又关上"，踩过）。

	; 注：曾经在暂停菜单打开（Alt-Tab 造成）时自动关闭面板，现已撤掉 ——
	; 实测 NODE.LITE 也有同样的"指针冻住"现象，说明那是 PrismaUI 与游戏界面的交互问题，
	; 不是我们引起的；强关面板既没必要也会打断玩家，交给玩家自己按 Esc / 点关闭即可。
EndEvent

; ======================================================================
; 全息卡带发放
; ======================================================================

Function EnsureHolotape()
	if !SM_Holotape
		Debug.Trace("[SM] SM_Holotape 属性为空，无法发放卡带", 2)
		return
	EndIf

	Actor player = Game.GetPlayer()
	if !player
		return
	EndIf

	if player.GetItemCount(SM_Holotape) > 0
		bHolotapeGiven = true
		return
	EndIf

	if !bHolotapeGiven || bAutoReissueHolotape
		player.AddItem(SM_Holotape, 1, True)
		bHolotapeGiven = true
		Debug.Notification("据点管理终端全息卡带已放入背包")
	EndIf
EndFunction

Function ReissueHolotape()
	Actor player = Game.GetPlayer()
	if !player || !SM_Holotape
		return
	EndIf

	if player.GetItemCount(SM_Holotape) > 0
		Debug.Notification("你已经有这张全息卡带了")
		return
	EndIf

	player.AddItem(SM_Holotape, 1, True)
	bHolotapeGiven = true
	Debug.Notification("据点管理终端全息卡带已放入背包")
EndFunction

; ======================================================================
; 菜单入口（由 Terminal 记录上的 Fragment 调用）
; ======================================================================


; 找玩家当前所在的据点。
; 原版没有"这个坐标属于哪个据点"的直接 API，所以分三层找，越靠前越可信：
;   1) 玩家当前 Location 及其父级链 —— 据点内的建筑往往是子位置，必须往上找
;   2) 原版记录的"当前据点"(WorkshopParent.CurrentWorkshop)，带距离校验防过时
;   3) 附近最近的、已加载的据点
WorkshopScript Function GetPlayerSettlement()
	Actor player = Game.GetPlayer()
	if !player
		return None
	EndIf

	; 1) 位置链
	Location loc = player.GetCurrentLocation()
	int guard = 0
	While loc && guard < 8
		int idx = WorkshopParent.WorkshopLocations.Find(loc)
		if idx >= 0
			WorkshopScript ws = WorkshopParent.Workshops[idx]
			if ws
				return ws
			EndIf
		EndIf
		loc = loc.GetParent()
		guard += 1
	EndWhile

	; 2) 原版的当前据点标记（只在进入工坊模式/到达据点时更新，所以要用距离筛掉过时的）
	WorkshopScript current = WorkshopParent.CurrentWorkshop.GetRef() as WorkshopScript
	if current && player.GetDistance(current) < 6000.0
		return current
	EndIf

	; 3) 附近已加载的据点
	return GetNearestLoadedWorkshop(player, 4096.0)
EndFunction

WorkshopScript Function GetNearestLoadedWorkshop(Actor player, float maxDist)
	WorkshopScript best = None
	float bestDist = maxDist
	int i = 0
	While i < WorkshopParent.Workshops.Length
		WorkshopScript ws = WorkshopParent.Workshops[i]
		if ws && ws.Is3DLoaded()
			float d = player.GetDistance(ws)
			if d > 0.0 && d < bestDist
				bestDist = d
				best = ws
			EndIf
		EndIf
		i += 1
	EndWhile
	return best
EndFunction

; ======================================================================
; 报表
; ======================================================================



String Function SettlementName(WorkshopScript ws)
	String n = ""
	if ws.myLocation
		n = ws.myLocation.GetName()
	EndIf

	if n == ""
		n = "未命名据点"
	EndIf

	return n
EndFunction

; 读据点汇总数值。GetValue = 当前实际产出（停工/受损会掉），GetBaseValue = 总量
int Function RatingInt(WorkshopScript ws, int aiRatingIndex)
	return ws.GetValue(WorkshopParent.WorkshopRatings[aiRatingIndex].resourceValue) as int
EndFunction

; ======================================================================
; M1：批量操作与报表
;
; 为什么 M1 没有"选某个居民"的交互：
;   Workshop Framework 的两个现成选择器对我们的场景都不可用 ——
;   * 交易列表把选项当物品塞进容器来显示，Actor 塞不进去（列表是空的）
;   * 消息选择器的"选项行"不显示传入的内容（实测显示 "... ..."）
;   要列出运行时生成的居民名字，需要自定义 SWF 界面（走 F4SE），那是 M2 的工作。
;   所以 M1 先做不需要挑选的批量操作 + 纯文字报表，这些机制都已实机验证。
; ======================================================================

; 刷新"无业人数"。原版只在每日更新/据点重置时算它，所以玩家刚指派完看到的是旧值。
; 主动调一次，让报表和实际一致（这是原版自己的函数，游戏也这么调）。
Function RefreshUnassignedRating(WorkshopScript ws)
	if ws
		WorkshopParent.SetUnassignedPopulationRating(ws)
	EndIf
EndFunction

; 引用当前的"显示名"（含改名 mod 挂上的名字）。
; **单独一层包装是故意的**：GetDisplayName 这个 native 不是原版脚本自带的
; （本机是随某个 F4SE 脚本扩展插件注入到 ObjectReference 上的），
; 万一插件不在、VM 找不到它，失败的只是这个函数，调用方拿到空串后回退到基础名。
String Function SafeDisplayName(ObjectReference r)
	return r.GetDisplayName()
EndFunction

; 居民名。**优先用显示名**：改名类 mod（What's Your Name、Rename Anything 等）不改基础记录，
; 而是把名字挂在引用上（WYN 是 AddTextReplacementData + 把居民放进任务别名的办法），
; 所以 GetActorBase().GetName() 永远是通用名"定居者" —— 那正是玩家看到老名字的原因。
; 没有改名数据时 GetDisplayName 返回的就是基础名，行为与以前一致。
String Function ActorName(Actor a)
	if !a
		return "居民"
	EndIf
	String shown = SafeDisplayName(a)
	if shown != ""
		return shown
	EndIf
	ActorBase b = a.GetActorBase()
	if b && b.GetName() != ""
		return b.GetName()
	EndIf
	return "居民"
EndFunction

; 老存档的热键迁移：以前的键码属于**扫描码**空间，68（当时表示 F10）在 VK 空间里是 'D'。
; 68 是我们自己的老默认值，凡是还留着的 68 一律迁成 VK 的 F10（121）；
; 其它值不动 —— 玩家在面板里改过的由界面侧统一迁一次（界面配置里有 hotkeyVer）。
Function MigrateHotkeyIfNeeded()
	if HotkeyCode == 68
		HotkeyCode = 121
		Debug.Trace("[SM] 热键从扫描码空间的 68 迁移到 VK 空间的 121（F10）")
	EndIf
EndFunction

; 搬运工的目的地据点名：按 WorkshopID 在 WorkshopParent.Workshops 里找。
; 读不到就返回空串（界面会退化成显示 ID，至少能看出这个人在跑供应线）。
String Function CaravanDestinationName(int aiWorkshopID)
	if aiWorkshopID < 0
		return ""
	EndIf
	int i = 0
	while i < WorkshopParent.Workshops.Length
		WorkshopScript w = WorkshopParent.Workshops[i]
		if w && w.OwnedByPlayer && w.GetWorkshopID() == aiWorkshopID
			return SettlementName(w)
		EndIf
		i += 1
	endWhile
	return ""
EndFunction

; 居民的性别（0=男 1=女）。
; 关键是**读哪一个 ActorBase**：工坊刷出来的居民用 GetActorBase() 会拿到共享的模板记录
; （性别是模板的，常见为男），于是女性居民被显示成男性（玩家反馈）。
; WYN 抽名字时用的就是 GetLeveledActorBase().GetSex() == 1（女），这里跟它保持一致，
; 面板里的性别才会和你看到的名字对得上。
int Function ActorSex(Actor a)
	if !a
		return 0
	EndIf
	ActorBase lv = a.GetLeveledActorBase()
	if lv
		return lv.GetSex()
	EndIf
	ActorBase b = a.GetActorBase()
	if b
		return b.GetSex()
	EndIf
	return 0
EndFunction

String Function RefName(ObjectReference r)
	if !r
		return "?"
	EndIf
	String shown = SafeDisplayName(r)
	if shown != ""
		return shown
	EndIf
	Form b = r.GetBaseObject()
	if b && b.GetName() != ""
		return b.GetName()
	EndIf
	return "对象"
EndFunction

; 该据点的居民（全部，含机器人）
Form[] Function GetSettlerForms(WorkshopScript ws)
	Form[] out = new Form[0]
	ObjectReference[] actors = GetSettlementRoster(ws)
	int i = 0
	while i < actors.Length
		out.Add(actors[i])
		i += 1
	endWhile
	return out
EndFunction

; 该据点空闲的"工作岗位"（需要居民才能工作的对象，且当前没人）
; 注意排除床：床在记录上也带"可指派"标记，但它不是工作岗位，
; 算进来会让居民被派去"看床"而浪费产能（实测明细里出现过 "→ 床、瓜、…"）。
Form[] Function GetFreeJobForms(WorkshopScript ws)
	Form[] out = new Form[0]
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.RequiresActor() && !obj.IsBed()
			; 空闲 = 原版两种"占用者"读法都为空（GetActorRefOwner 是终端用的那个）
			if !obj.GetActorRefOwner() && !obj.GetAssignedActor()
				out.Add(obj)
			EndIf
		EndIf
		i += 1
	endWhile
	return out
EndFunction

; 某个居民被指派的工作对象（同样排除床 —— 说明见 GetFreeJobForms）
WorkshopObjectScript[] Function GetOwnedJobObjects(WorkshopScript ws, Actor a)
	WorkshopObjectScript[] out = new WorkshopObjectScript[0]
	if !ws || !a
		return out
	EndIf

	; **占用者怎么读**：照抄原版人口终端 —— `WorkshopResources[i].GetActorRefOwner()`
	;（DLC06OverseerHandlerScript.psc 的 CountUnowned：`aTarg = ...GetActorRefOwner()`，
	; `aTarg != NONE && !aTarg.IsDead()` 就算"这个人在干这个活"）。
	; 以前用的 `GetAssignedActor()` 在玩家存档里读不到占用者（于是种地的人全被当成无业、
	; 空闲岗位也虚报），WSFW 的封装同样读不到 —— 这就是"工坊里有人在种地、面板说无业"的根因。
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.RequiresActor() && !obj.IsBed()
			Actor refOwner = obj.GetActorRefOwner()
			if refOwner == a
				out.Add(obj)
			Else
				Actor asg = obj.GetAssignedActor()
				if asg == a
					out.Add(obj)
				EndIf
			EndIf
		EndIf
		i += 1
	endWhile
	return out
EndFunction

; ----------------------------------------------------------------------
; 岗位数（"这个据点能提供多少个岗位"）
;
; 原版评分里**没有**这一项（只有各资源产量），岗位数只能靠数工位对象，
; 而工位对象**只有据点已加载（玩家在附近）时才读得到**。
; 所以：在据点里数到就按 WorkshopID 记下来（属性，随存档保存），总览用这份缓存显示；
; 没去过的据点返回 -1，界面就不显示岗位数、也不标"缺人"（不给猜出来的数字）。
; ----------------------------------------------------------------------
int[] Property JobCacheIDs = None Auto
int[] Property JobCacheCounts = None Auto
int[] Property JobCacheNeeds = None Auto       ; 覆盖这些岗位至少需要几名居民（按每人能兼几个算）
String[] Property DetailCacheData = None Auto  ; 据点明细暂存（居民/床位/空岗行的原文）
int[] Property DetailCacheIDs = None Auto      ; 暂存**专用**的 ID 表：不能和 JobCacheIDs 共用 ——
                                               ; 两边由不同函数在不同时机写入，共用会索引错位、越界报错

Function RememberJobCount(int aiWorkshopID, int aiJobs, int aiNeeds)
	if JobCacheIDs == None || JobCacheCounts == None || JobCacheNeeds == None
		JobCacheIDs = new int[0]
		JobCacheCounts = new int[0]
		JobCacheNeeds = new int[0]
	EndIf
	int i = JobCacheIDs.Find(aiWorkshopID)
	if i >= 0
		JobCacheCounts[i] = aiJobs
		JobCacheNeeds[i] = aiNeeds
		return
	EndIf
	JobCacheIDs.Add(aiWorkshopID)
	JobCacheCounts.Add(aiJobs)
	JobCacheNeeds.Add(aiNeeds)
	Debug.Trace("[SM] 记录岗位：据点 " + aiWorkshopID + " 共 " + aiJobs + " 个岗位，需要 " + aiNeeds + " 名居民")
EndFunction

int Function CachedJobNeed(int aiWorkshopID)
	if JobCacheIDs == None || JobCacheNeeds == None
		return -1
	EndIf
	int i = JobCacheIDs.Find(aiWorkshopID)
	if i >= 0
		return JobCacheNeeds[i]
	EndIf
	return -1
EndFunction

int Function CachedJobCount(int aiWorkshopID)
	if JobCacheIDs == None || JobCacheCounts == None
		return -1
	EndIf
	int i = JobCacheIDs.Find(aiWorkshopID)
	if i >= 0
		return JobCacheCounts[i]
	EndIf
	return -1
EndFunction

; 数一个（已加载的）据点的岗位：需要居民的工位（排除床）。读不到对象时返回 -1。
int Function CountJobObjects(WorkshopScript ws)
	if !ws
		return -1
	EndIf
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int n = 0
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.RequiresActor() && !obj.IsBed()
			n += 1
		EndIf
		i += 1
	endWhile
	return n
EndFunction
; 这类工位"一个居民最多能干几个" —— 读**原版自己**的上限数据
; （WorkshopRatings[i].maxProductionPerNPC；WSFW 的 MCM 里那两个"每个居民的最大食物/防御工作量"默认就是 6）。
; 读不到就当 1（保守：宁可把需要人数算多，也不要让玩家以为人够了）。
int Function CapacityForKind(int aiKind)
	int ratingIndex = -1
	if aiKind == KIND_FARMER
		ratingIndex = WorkshopParent.WorkshopRatingFood
	ElseIf aiKind == KIND_GUARD
		ratingIndex = WorkshopParent.WorkshopRatingSafety
	ElseIf aiKind == KIND_SCAVENGER
		ratingIndex = WorkshopParent.WorkshopRatingScavengeGeneral
	ElseIf aiKind == KIND_VENDOR
		ratingIndex = WorkshopParent.WorkshopRatingVendorIncome
	EndIf
	if ratingIndex < 0 || ratingIndex >= WorkshopParent.WorkshopRatings.Length
		return 1
	EndIf
	int cap = WorkshopParent.WorkshopRatings[ratingIndex].maxProductionPerNPC as int
	if cap < 1
		; **读不出来就返回 0 = "未知"**，别假装是 1：拾荒工作台的产量是 2，按 1 会被永远判成
		; "到上限"（玩家实测：给拾荒台派无业人员一律提示"已经到上限了"）。
		; 0 的含义由调用方决定：不做预检、交给游戏自己判，我们只保留"派完复核归属"这一层。
		return 0
	EndIf
	return cap
EndFunction

; 这个工位在"某类资源"上的产量（原版判一个人能兼几个，用的就是产量之和）。
; 作物常见是 0.5，变种果/铃薯之类可能是 1 —— 所以"上限 6"不等于"能管 6 个作物"。
float Function JobResourceRating(WorkshopObjectScript obj, int aiKind)
	if !obj
		return 0.0
	EndIf
	if aiKind == KIND_FARMER
		return obj.GetResourceRating(WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingFood].resourceValue)
	ElseIf aiKind == KIND_GUARD
		return obj.GetResourceRating(WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingSafety].resourceValue)
	ElseIf aiKind == KIND_SCAVENGER
		return obj.GetResourceRating(WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingScavengeGeneral].resourceValue)
	ElseIf aiKind == KIND_VENDOR
		return obj.GetResourceRating(WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingVendorIncome].resourceValue)
	EndIf
	return 0.0
EndFunction

; 覆盖这个据点的全部岗位，**至少需要几名居民**：按资源类型分组，每组"岗位数 ÷ 每人上限"向上取整后相加。
; 为什么不是"岗位数就是人数"：一个人能兼多个同类工位（WSFW 默认 6 个），
; 46 个铃薯岗位只需要 8 个人 —— 直接拿岗位数当人数会得出"缺人 37"这种吓人的错数（玩家反馈）。
; 这个人**在自己那个工种上还能不能再接一个空位**？
; 判据就是原版那一条：同类工位的产量之和 ≤ 每人上限（`maxProductionPerNPC`，WSFW 的
; "每个居民的最大食物/防御工作量"就是它）。用于挑人面板：只列"无业的 + 同类还没满的"，
; 免得玩家把已经满了的农民也派上去（游戏会拒绝，白点一下）。
bool Function HasSpareCapacity(Actor a, WorkshopScript ws)
	WorkshopNPCScript wnp = a as WorkshopNPCScript
	if !wnp || !ws
		return false
	EndIf
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int kind = KIND_WORKER
	float used = 0.0
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.GetActorRefOwner() == a
			kind = JobResourceKind(obj)
			used += JobResourceRating(obj, kind)
		EndIf
		i += 1
	endWhile
	if used <= 0.0
		return false                     ; 没在岗的人不算（无业的人由界面另算）
	EndIf
	int cap = CapacityForKind(kind)
	i = 0
	while i < objs.Length
		WorkshopObjectScript obj2 = objs[i] as WorkshopObjectScript
		if obj2 && obj2.RequiresActor() && !obj2.IsBed() && JobResourceKind(obj2) == kind
			if !obj2.GetActorRefOwner()
				if used + JobResourceRating(obj2, kind) <= (cap as float)
					return true          ; 还有塞得下的空位
				EndIf
			EndIf
		EndIf
		i += 1
	endWhile
	return false
EndFunction

int Function RequiredWorkers(WorkshopScript ws)
	if !ws
		return -1
	EndIf
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int[] kinds = new int[0]
	float[] totals = new float[0]      ; 该类工位的**产量之和**（不是个数）
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.RequiresActor() && !obj.IsBed()
			int k = JobResourceKind(obj)
			int idx = kinds.Find(k)
			if idx < 0
				kinds.Add(k)
				totals.Add(0.0)
				idx = kinds.Length - 1
			EndIf
			float rating = JobResourceRating(obj, k)
			if rating <= 0.0
				rating = 1.0           ; 产量读不出来就当 1（保守：宁可多算人）
			EndIf
			totals[idx] += rating
		EndIf
		i += 1
	endWhile
	int need = 0
	i = 0
	while i < kinds.Length
		int cap = CapacityForKind(kinds[i])
		int n = 1
		if cap > 0 && totals[i] > 0.0
			n = Math.Ceiling(totals[i] / cap) as int
		EndIf
		if n < 1
			n = 1
		EndIf
		need += n
		i += 1
	endWhile
	return need
EndFunction

; 暂存一个据点的明细（居民 W 行 + 床位 B 行 + 空岗 J 行）。
; 玩家方案：**离开据点后仍然显示上次看到的数据**，回到该据点再刷新 ——
; 明细（居民/床位/岗位对象）只有据点在游戏里加载时才有，暂存是唯一能跨据点看到它们的办法。
Function RememberSettlementDetail(int aiWorkshopID, String asDetail)
	; **用暂存自己的 ID 表**：以前和 JobCacheIDs（工位缓存）共用一张，
	; 但两张表由不同函数在不同时机写入 → 索引错位 → DetailCacheData[i] 越界报错、
	; 暂存静默失败（玩家反馈：快速传送走之后看不到暂存数据）。
	if DetailCacheIDs == None || DetailCacheData == None
		DetailCacheIDs = new int[0]
		DetailCacheData = new String[0]
	EndIf
	int i = DetailCacheIDs.Find(aiWorkshopID)
	if i >= 0
		DetailCacheData[i] = asDetail
		return
	EndIf
	DetailCacheIDs.Add(aiWorkshopID)
	DetailCacheData.Add(asDetail)
EndFunction

String Function CachedSettlementDetail(int aiWorkshopID)
	if DetailCacheIDs == None || DetailCacheData == None
		return ""
	EndIf
	int i = DetailCacheIDs.Find(aiWorkshopID)
	if i >= 0
		return DetailCacheData[i]
	EndIf
	return ""
EndFunction

WorkshopScript[] Function GetOwnedWorkshops()
	WorkshopScript[] out = new WorkshopScript[0]
	int i = 0
	while i < WorkshopParent.Workshops.Length
		WorkshopScript ws = WorkshopParent.Workshops[i]
		if ws && ws.OwnedByPlayer
			out.Add(ws)
		EndIf
		i += 1
	endWhile

	; 按 WorkshopID 排序 —— 必须稳定：界面用**下标**指代据点（迁居目标等），
	; 而 WorkshopParent.Workshops 是 RefCollectionAlias，顺序在读档/增删据点后会变，
	; 顺序一变"选中的据点"就会指向另一个（玩家反馈：据点名每次打开都在变）。
	; 插入排序就够了：原版据点最多几十个。
	; 变量名别叫 key —— 和原版的 Key 脚本重名（Papyrus 类型名大小写不敏感），编译不过。
	int a = 1
	while a < out.Length
		WorkshopScript cur = out[a]
		int curID = cur.GetWorkshopID()
		int b = a - 1
		while b >= 0 && out[b].GetWorkshopID() > curID
			out[b + 1] = out[b]
			b -= 1
		endWhile
		out[b + 1] = cur
		a += 1
	endWhile
	return out
EndFunction

; ------------------------------------------------------------------ 菜单项 3：居民与岗位明细

; ------------------------------------------------------------------ 菜单项 4：一键填补空岗

; 原版的"当过队友"派系（FACT 000A1B85）。队友被招募时会永久加入它
; （FollowersScript 里的 AddToFaction(HasBeenCompanionFaction)），
; 所以他们即使住在据点里、甚至不在队伍中，也能被这个标记认出来。
Faction Function GetHasBeenCompanionFaction()
	return Game.GetFormFromFile(0x000A1B85, "Fallout4.esm") as Faction
EndFunction

bool Function IsCompanion(Actor a)
	if !a
		return false
	EndIf
	Faction beenCompanion = GetHasBeenCompanionFaction()
	if beenCompanion && a.IsInFaction(beenCompanion)
		return true
	EndIf
	return false
EndFunction

; 能不能给这个居民自动派活：
;   * 队友不派（原版自己也会给他们派，但我们不主动添乱）
;   * 尊重 Workshop Framework 的"排除在分配规则之外"名单（玩家自己排掉的人）
bool Function CanAutoAssign(Actor a)
	if !a || IsCompanion(a)
		return false
	EndIf
	if WorkshopFramework:WorkshopFunctions.IsExcludedFromAssignmentRules(a)
		return false
	EndIf
	return true
EndFunction

; 一个工位属于哪种"资源类型"（分组用，编号沿用职业分类那套，不参与界面显示）。
; 为什么需要它：原版规则是**一个居民只能干一种资源类型的活**（派不同资源类型会把他前一个顶掉），
; 所以想"一人多岗"就必须把同类型的工位连着派给同一个人。
int Function JobResourceKind(WorkshopObjectScript obj)
	if !obj
		return KIND_WORKER
	EndIf
	if obj.VendorType > -1
		return KIND_VENDOR
	EndIf
	ActorValue foodAV = WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingFood].resourceValue
	if obj.HasResourceValue(foodAV)
		return KIND_FARMER
	EndIf
	ActorValue safetyAV = WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingSafety].resourceValue
	if obj.HasResourceValue(safetyAV)
		return KIND_GUARD
	EndIf
	ActorValue scavAV = WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingScavengeGeneral].resourceValue
	if obj.HasResourceValue(scavAV)
		return KIND_SCAVENGER
	EndIf
	return KIND_WORKER
EndFunction

; 一键填补空岗：**用尽量少的居民**把空岗填满。
;
; 为什么不一人一岗（玩家反馈"把无业的人全塞进去了"）：
; 原版/WSFW 允许一个居民兼多个**同类型**工位，上限就是 MCM 里那两个"每个居民的最大食物/防御工作量"
; （WSFW 默认 6）。所以正确做法是：把同类型的空岗**连续派给同一个人**，派到人家不再接受为止，再换下一个。
;
; 怎么知道"到上限了"：派完回读工位的占用者（GetActorRefOwner，原版终端用的那个读法），
; 不是他就说明这次没派成 —— 不去猜上限数字，让游戏自己说（WSFW 改了上限我们也跟着走）。
Function MenuAutoFillJobs()
	WorkshopScript ws = GetPlayerSettlement()
	if !ws
		Debug.MessageBox("没有找到你所在的据点。\n\n请站到据点的工坊范围内再试。")
		return
	EndIf

	; ① 无业居民（队友不派活；搬运工派了会拆掉供应线）
	Form[] idlers = new Form[0]
	ObjectReference[] actors = GetSettlementRoster(ws)
	int i = 0
	while i < actors.Length
		Actor a = actors[i] as Actor
		if a && !IsActorWorker(a) && !IsCaravanWorker(a) && CanAutoAssign(a)
			idlers.Add(a)
		EndIf
		i += 1
	endWhile

	Form[] jobs = GetFreeJobForms(ws)
	int jobCount = jobs.Length
	if idlers.Length == 0 || jobCount == 0
		Debug.Notification(SettlementName(ws) + "：没有可配对的（无业居民 " + idlers.Length + " / 空岗 " + jobCount + "）")
		return
	EndIf

	; ② 先把空岗按资源类型排好序（同类相邻），这样"连续派给同一个人"才成立。
	;    插入排序足够：一个据点最多几十个工位。
	int a1 = 1
	while a1 < jobCount
		WorkshopObjectScript cur = jobs[a1] as WorkshopObjectScript
		int curKind = JobResourceKind(cur)
		int b1 = a1 - 1
		while b1 >= 0 && JobResourceKind(jobs[b1] as WorkshopObjectScript) > curKind
			jobs[b1 + 1] = jobs[b1]
			b1 -= 1
		endWhile
		jobs[b1 + 1] = cur
		a1 += 1
	endWhile

	; ③ 派活：同一个人连着吃同类型的工位；类型一变、或这个人派不动了，就换下一个居民。
	int si = 0                  ; 当前在填的居民下标
	int k = 0                   ; 当前派到第几个空岗
	int lastKind = -1           ; 当前居民正在吃哪种资源类型（-1 = 还没开始）
	int used = 0                ; 用掉了几名居民
	int filled = 0              ; 填掉了几个空岗
	while k < jobCount && si < idlers.Length
		WorkshopObjectScript job = jobs[k] as WorkshopObjectScript
		Actor a = idlers[si] as Actor
		if !job
			k += 1
		ElseIf !a
			si += 1
		Else
			int kind = JobResourceKind(job)
			if lastKind != -1 && kind != lastKind
				; 换资源类型：一个人只能干一种，换下一个人（他是新人，肯定吃得下）
				si += 1
				lastKind = kind
			EndIf
				if si < idlers.Length
					Actor worker = idlers[si] as Actor
					if worker
						; **先算上限**：加了这一个会不会超过他的产能上限？会就别派。
						; 原版超上限时会把前面派的**全部解掉只留新的**，硬派等于白派，
						; 还会让产量忽上忽下（玩家实测：食物 12 → 18 → 回 12 再往上）。
						float wUsed = 0.0
						WorkshopObjectScript[] wOwned = GetOwnedJobObjects(ws, worker)
						int wk = 0
						while wk < wOwned.Length
							if wOwned[wk]
								wUsed += JobResourceRating(wOwned[wk], JobResourceKind(wOwned[wk]))
							EndIf
							wk += 1
						endWhile
						float wAdd = JobResourceRating(job, kind)
						if wAdd <= 0.0
							wAdd = 1.0
						EndIf
						if wUsed + wAdd > (CapacityForKind(kind) as float)
							si += 1              ; 他满了 → 换下一个人（这个工位先留着）
						Else
							; 注意：状态刷新必须保持开启（abAutoUpdateActorStatus = true），
							; 否则 bIsWorker 不会更新，"无业人数"也就不会变 —— 上一版就是这里出的错
							WorkshopFramework:WorkshopFunctions.AssignActorToObject(job, worker, abAutoHandleAssignmentRules = true, abAutoUpdateActorStatus = true, abRecalculateWorkshopResources = false)
							if job.GetActorRefOwner() == worker
								; 派成了 → 这个居民还能继续吃同类型的下一个
								lastKind = kind
								filled += 1
								used = si + 1
								k += 1
							Else
								; 他没吃下（被其它规则挡了）→ 换下一个人，同一个工位再试
								si += 1
							EndIf
						EndIf
					Else
						si += 1
					EndIf
				EndIf
			EndIf
		endWhile

	if filled == 0
		Debug.Notification(SettlementName(ws) + "：没能派出去（无业居民 " + idlers.Length + " / 空岗 " + jobCount + "）")
		return
	EndIf

	ws.RecalculateWorkshopResources(false)
	RefreshUnassignedRating(ws)
	PushDashboardData()
	Debug.Notification(SettlementName(ws) + "：用了 " + used + " 名居民，填满 " + filled + " 个岗位")
EndFunction

; ------------------------------------------------------------------ 菜单项 5：解除本据点全部岗位
Function MenuUnassignAll()
	WorkshopScript ws = GetPlayerSettlement()
	if !ws
		Debug.MessageBox("没有找到你所在的据点。\n\n请站到据点的工坊范围内再试。")
		return
	EndIf

	int n = 0
	int skipped = 0
	; 名单与界面一致：界面上看着在岗（含跑供应线的）就该被解除，否则会出现"列表里有他、
	; 点了全部解除却没动"的错位感。
	ObjectReference[] actors = GetSettlementRoster(ws)
	int i = 0
	while i < actors.Length
		Actor a = actors[i] as Actor
		if a && (IsActorWorker(a) || IsCaravanWorker(a))
			if IsCompanion(a)
				skipped += 1        ; 队友的岗位不主动解除，免得把原版给他们排的活也清掉
			else
				; 搬运工没有工坊物件，光靠 WSFW 那句清不干净（她会一直走、工坊模式里还挂着运输）
				ClearCaravanDuty(a)
				WorkshopFramework:WorkshopFunctions.UnassignActorSkipExclusions(a, ws)
				ClearWorkshopJobs(a, ws)
				n += 1
			EndIf
		EndIf
		i += 1
	endWhile

	ws.RecalculateWorkshopResources(false)
	RefreshUnassignedRating(ws)
	if skipped > 0
		Debug.Notification(SettlementName(ws) + "：已解除 " + n + " 名居民的岗位（" + skipped + " 名队友已跳过）")
	Else
		Debug.Notification(SettlementName(ws) + "：已解除 " + n + " 名居民的岗位")
	EndIf
EndFunction

; ------------------------------------------------------------------ 菜单项 6：所有据点总览

; ======================================================================
; M2 预备：界面无关的动作与数据接口
;
; 这些函数不关心"谁在调用"（世界终端的菜单项、Papyrus 控制台、还是 M2 的自定义
; 界面都行），只负责做事和出数据 —— 这样界面层怎么改都不用动游戏逻辑。
; ======================================================================

; 把一个居民指派到指定工作岗位
; 这个人在"某一类工位"上的当前产量。**只算这一类** ——
; 原版的产能上限（maxProductionPerNPC）是按资源类型分别算的，
; 把所有工位的产量混在一起会把"从种地改去看守"误判成超上限。
float Function KindProduction(Actor a, WorkshopScript ws, int aiKind)
	float total = 0.0
	if !a || !ws
		return total
	EndIf
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.GetActorRefOwner() == a && JobResourceKind(obj) == aiKind
			total += JobResourceRating(obj, aiKind)
		EndIf
		i += 1
	endWhile
	return total
EndFunction

Function DoAssignJob(Actor who, WorkshopObjectScript job)
	if !who || !job
		return
	EndIf
	WorkshopScript ws = GetPlayerSettlement()
	int kind = JobResourceKind(job)

	; 目标是"有人占着的工位"也没关系：原版指派时会**自动把原占用者解下来**（他变无业），
	; 并把 A 从原来的活上解下来（他原来的岗位空出来）—— 正是玩家要的"顶岗"。
	; 但有两件事得我们先做：
	;   ① A 若是搬运工，先清掉运输身份（别名上的行走包 / 目的地 AV / 链接引用会留残留）；
	ClearCaravanDuty(who)
	;   ② 产能预检按**目标类型**算：超了就别派 —— 原版超上限时会把 A 前面的工位全解掉，
	;      硬派等于白派（还会让产量忽上忽下）。
	if ws
		float used = KindProduction(who, ws, kind)
		float add = JobResourceRating(job, kind)
		if add <= 0.0
			add = 1.0
		EndIf
		int capNow = CapacityForKind(kind)
		; 上限未知（=0）时不预检，交给游戏判断（我们仍会复核派完的归属）
		if capNow >= 1 && used + add > (capNow as float)
			Debug.Notification(ActorName(who) + " 在这个工种上已经到上限了（换个人或先解除别的工位）")
			return
		EndIf
	EndIf

	; 记下原来的占用者：顶岗成功的话他就是被顶掉的那位（通知里说清楚）
	Actor prevOwner = job.GetActorRefOwner()

	; 参数和"一键填补空岗"严格一致：**状态刷新必须开着**（abAutoUpdateActorStatus = true），
	; 否则 bIsWorker 不更新，界面上的"在岗 / 无业"就不会变（这个坑踩过）。
	WorkshopFramework:WorkshopFunctions.AssignActorToObject(job, who, abAutoHandleAssignmentRules = true, abAutoUpdateActorStatus = true, abRecalculateWorkshopResources = false)

	; 派成功的判据 = 这个工位现在归他（顶岗时同样成立）。没归他说明被原版规则挡住了。
	if job.GetActorRefOwner() != who
		Debug.Notification(ActorName(who) + " 没派上这个工位（原版规则不允许）")
		PushDashboardData()
		return
	EndIf

	if ws
		ws.RecalculateWorkshopResources(false)
		RefreshUnassignedRating(ws)
	EndIf
	PushDashboardData()
	if prevOwner && prevOwner != who
		Debug.Notification(ActorName(who) + " → " + RefName(job) + "（顶掉了 " + ActorName(prevOwner) + "，他变成无业）")
	Else
		Debug.Notification(ActorName(who) + " → " + RefName(job))
	EndIf
EndFunction

; 把一个人派到"某一类工位"的空位上：农民 / 守卫这类工位**一人可以多岗**
; （上限由原版 `maxProductionPerNPC` / WSFW 的"每个居民的最大食物/防御工作量"决定），
; 所以一路派下去，直到游戏不再接受为止 —— 和"一键填补空岗"用的是同一套判法：
; 派完**回读工位的占用者**（GetActorRefOwner），不是他就说明到上限了，立刻收工。
int Function AssignWorkerToKind(Actor who, WorkshopScript ws, int aiKind)
	if !who || !ws
		return 0
	EndIf
	int filled = 0
	ObjectReference[] objs = WorkshopParent.GetResourceObjects(ws)
	int cap = CapacityForKind(aiKind)

	; **先把他现在的产量算出来**（这一步是关键）：原版在"加了这一个就超上限"时的做法是
	; **把前面派的全部解掉、只留新的这一个**。所以不能"派一个看看行不行" ——
	; 那样每派一次都会顶掉前一个，产量就升一下掉一下
	; （玩家实测：食物 12 → 18 → 又回 12 再往上，就是反复顶替造成的）。
	float used = 0.0
	int i = 0
	while i < objs.Length
		WorkshopObjectScript own = objs[i] as WorkshopObjectScript
		; 只算**这一类**的产量（原版按资源类型分别算上限，混着算会误判）
		if own && own.GetActorRefOwner() == who && JobResourceKind(own) == aiKind
			used += JobResourceRating(own, aiKind)
		EndIf
		i += 1
	endWhile

	; 只派"加了也不超上限"的空位；一塞不下就收工（剩下的留给别人）
	i = 0
	while i < objs.Length
		WorkshopObjectScript obj = objs[i] as WorkshopObjectScript
		if obj && obj.RequiresActor() && !obj.IsBed() && JobResourceKind(obj) == aiKind
			if !obj.GetActorRefOwner()          ; 只填空位
				float r = JobResourceRating(obj, aiKind)
				if r <= 0.0
					r = 1.0                      ; 产量读不出来就按 1 保守估
				EndIf
				; 上限未知时只派一个（不盲目连派，免得触发原版的"顶替"行为）
				if (cap < 1 && filled == 0) || (cap >= 1 && used + r <= (cap as float))
					WorkshopFramework:WorkshopFunctions.AssignActorToObject(obj, who, abAutoHandleAssignmentRules = true, abAutoUpdateActorStatus = true, abRecalculateWorkshopResources = false)
					if obj.GetActorRefOwner() == who
						used += r
						filled += 1
					Else
						i = objs.Length + 1      ; 被其它规则挡了 → 收工
					EndIf
				Else
					i = objs.Length + 1          ; **再加就超上限** → 收工，绝不硬塞
				EndIf
			EndIf
		EndIf
		i += 1
	endWhile
	return filled
EndFunction

; 把某个居民派去跑运输线（居民页的"指派运输线"入口）。
; 用原版的 `AssignCaravanActorPUBLIC` —— 它内部会先解除现有工作、写目的地 actor value、
; 把他加进 CaravanActorAliases、把两个据点连起来，正是我们要的全套。
; 注意：**这个函数必须传有效的据点 Location** —— 传 None 会在中途报错（以前踩过，
; 还顺手把人又加回了搬运工集合）。
Function DoAssignCaravan(Actor who, WorkshopScript dest)
	if !who || !dest
		return
	EndIf
	WorkshopNPCScript wnp = who as WorkshopNPCScript
	if !wnp
		return
	EndIf
	if !WorkshopFramework:WorkshopFunctions.AllowCaravan(who)
		Debug.Notification(ActorName(who) + " 的「能否运输」是关着的 —— 先在居民页把它打开")
		return
	EndIf
	WorkshopScript home = WorkshopParent.GetWorkshop(wnp.GetWorkshopID())
	if home && home == dest
		Debug.Notification("他就在这个据点 —— 换个目的地吧")
		return
	EndIf
	WorkshopParent.AssignCaravanActorPUBLIC(wnp, dest.myLocation)
	Debug.Trace("[SM] 派去跑运输线：" + ActorName(who) + " → " + SettlementName(dest))
	if home
		home.RecalculateWorkshopResources(false)
	EndIf
	PushDashboardData()
	Debug.Notification(ActorName(who) + " 开始跑运输：" + SettlementName(dest))
EndFunction

; 解除一个居民的全部岗位
; 把"跑供应线"彻底清掉。返回 true = 她本来确实在跑运输。
;
; 顺序照抄原版 WorkshopParentScript.UnassignActor 的搬运工分支（原版自己解供应线就一句
; UnassignActor，ClearCaravansFromWorkshopPUBLIC 里就是这么做的），不能重排：
;   ① 从 CaravanActorAliases 移出 —— **原版把行走包挂在那个别名上**，不移出她会一直保持
;      行走姿态，工坊模式里也仍旧算她跑运输（玩家反馈的残留就是这个）。
;   ② 婆罗门必须在移出集合**之后**检查：那时它才会把人名下的婆罗门删掉。
;   ③ 绝不能改调 `AssignCaravanActorPUBLIC(actor, None)`：它传 None 之后要过几行才报错中止，
;      而报错**之前**会执行 `if CaravanActorAliases.Find(...) < 0 → AddRef(actor)`，
;      正好把刚清掉的人又加回搬运工集合（上一版就是这么把残留引进来的）。
; 另外补两样原版不管但我们需要的东西：目的地 actor value 归零（界面靠它判"运输"）、
; 清掉两个链接引用（DLC06 判"是否跑运输"也看它们），最后 EvaluatePackage 让她当场停下。
; 参数 abSummon：清账之后要不要把这个人**拉回玩家身边**（默认要）。
; 玩家要求："解除运输工作"这一步要绑一个召唤 —— 免得他停在前不着村后不着店的地方出意外
; （比如被关在某个刷新掉的区域、或者玩家找不到他去重新派活）。
; 必须放在**清账之后**：那时他才移出 CaravanActorAliases，别名上的行走包失效，
; 拉过去才不会立刻又被走回原来那条线上。
bool Function ClearCaravanDuty(Actor who, bool abSummon = true)
	WorkshopNPCScript wnp = who as WorkshopNPCScript
	if !wnp
		return false
	EndIf
	if WorkshopParent.CaravanActorAliases.Find(wnp) < 0
		return false
	EndIf

	WorkshopScript startWs = WorkshopParent.GetWorkshop(wnp.GetWorkshopID())
	WorkshopScript endWs = WorkshopParent.GetWorkshop(wnp.GetCaravanDestinationID())

	WorkshopParent.CaravanActorAliases.RemoveRef(wnp)
	WorkshopParent.CaravanActorRenameAliases.RemoveRef(wnp)

	; 断开两个据点之间的供应线（地图上的连线）
	if startWs && endWs
		startWs.myLocation.RemoveLinkedLocation(endWs.myLocation, WorkshopParent.WorkshopCaravanKeyword)
	EndIf
	; 交还"头目"身份（原版在这里 SetAsBoss）
	if startWs && wnp.IsCreated()
		wnp.SetAsBoss(startWs.myLocation)
	EndIf

	; 删掉她名下的婆罗门（要在移出集合之后）
	WorkshopParent.CaravanActorBrahminCheck(wnp)

	; 通知原版系统（DLC 的终端、WSFW 的记账都靠这个事件同步）
	Var[] ckargs = new Var[2]
	ckargs[0] = wnp
	ckargs[1] = startWs
	WorkshopParent.SendCustomEvent("WorkshopActorCaravanUnassign", ckargs)

	; 目的地归零（普通居民读出来就是 0）+ 清掉两个链接引用
	wnp.SetValue(WorkshopParent.WorkshopCaravanDestination, 0)
	wnp.SetLinkedRef(None, WorkshopParent.WorkshopLinkCaravanStart)
	wnp.SetLinkedRef(None, WorkshopParent.WorkshopLinkCaravanEnd)

	; 把人拉回玩家身边（默认；开除时不需要），再让他就地重新评估一次包
	if abSummon
		Actor player = Game.GetPlayer()
		if player
			wnp.MoveTo(player)
			wnp.MoveToNearestNavmeshLocation()
			Debug.Trace("[SM] 解除运输后已把他拉回玩家身边：" + ActorName(who))
		EndIf
	EndIf

	; 立刻换回普通包 —— 否则她要等到下一次重新评估才会停止行走
	wnp.EvaluatePackage()
	Debug.Trace("[SM] 已清掉搬运工状态：" + ActorName(who))
	return true
EndFunction

; 解除岗位时的"工位清账"：照抄原版 WorkshopParentScript.UnassignActor 里工位那一段 ——
; 逐个解除他的工作对象归属（WorkshopParent.UnassignObject），再把身上的标记清掉
; （SetMultiResource(NONE) / SetWorker(false)）。
; 为什么必须自己来：只调 WSFW 的 UnassignActorSkipExclusions，对**有工位对象**的居民
; （农民 / 守卫 / 商人 / 拾荒者）清不干净 —— 工坊界面里他还在种地（玩家反馈，
; 和搬运工那次的残留是同一类问题：解除动作只改了一半状态）。
Function ClearWorkshopJobs(Actor who, WorkshopScript ws)
	WorkshopNPCScript wnp = who as WorkshopNPCScript
	if !wnp || !ws
		return
	EndIf
	ObjectReference[] owned = ws.GetWorkshopOwnedObjects(wnp)
	int i = 0
	while i < owned.Length
		WorkshopObjectScript obj = owned[i] as WorkshopObjectScript
		if obj && obj.RequiresActor()
			WorkshopParent.UnassignObject(obj)
		EndIf
		i += 1
	endWhile
	wnp.SetMultiResource(None)
	wnp.SetWorker(false)
	Debug.Trace("[SM] 已清掉工位归属：" + ActorName(who) + "（" + owned.Length + " 个对象）")
EndFunction

; 解除一个居民的岗位（搬运工走 ClearCaravanDuty 的那套清账，其余交给 WSFW）。
Function DoUnassignActor(Actor who, WorkshopScript ws)
	if !who
		return
	EndIf
	bool wasCaravan = ClearCaravanDuty(who)

	; 通用解除（未分配评级、原版事件）交给 WSFW
	WorkshopFramework:WorkshopFunctions.UnassignActorSkipExclusions(who, ws)
	; 工位归属与身上的标记**我们自己再清一遍**（WSFW 那句对有工位的人不够，见函数注释）
	ClearWorkshopJobs(who, ws)

	ws.RecalculateWorkshopResources(false)
	RefreshUnassignedRating(ws)
	; 推一次数据：以前这里只弹通知，界面（居民页的状态、总览的供应网络合计）拿不到新状态，
	; 于是"解除了但还显示在岗/还显示在供应网络里"（玩家反馈）。
	PushDashboardData()
	if wasCaravan
		Debug.Notification(ActorName(who) + " 已解除运输工作，并已叫回你身边")
	Else
		Debug.Notification(ActorName(who) + " 已解除岗位")
	EndIf
EndFunction

; 开除一名居民：从据点里彻底移出去。
; 用**原版自己的** `UnassignActor(theActor, true)` —— 它的注释里写得明白：
; bRemoveFromWorkshop 会把工作物件、未分配评级、别名集合一起清掉，然后 SetWorkshopID(-1)
; 并解除据点所有权（游戏在"据点丢失"时走的就是这条路，所以是权威做法）。
; 先清供应线：跑运输的人如果不断线，地图上会留下一条断不掉的线。
Function DoDismissActor(Actor who, WorkshopScript ws)
	if !who
		return
	EndIf
	ClearCaravanDuty(who, false)      ; 开除的人本来就要离开这里，不用拉回来
	WorkshopNPCScript wnp = who as WorkshopNPCScript
	if wnp
		WorkshopParent.UnassignActor(wnp, true)
		Debug.Trace("[SM] 已开除居民：" + ActorName(who))
	EndIf
	if ws
		ws.RecalculateWorkshopResources(false)
		RefreshUnassignedRating(ws)
	EndIf
	PushDashboardData()
	Debug.Notification(ActorName(who) + " 已被开除，不再属于本据点")
EndFunction

; 把一个居民迁往另一个据点
Function DoMigrateActor(Actor who, WorkshopScript dest)
	if !who || !dest
		return
	EndIf
	WorkshopFramework:WorkshopFunctions.AddActorToWorkshop(who, dest)
	PushDashboardData()
	Debug.Notification(ActorName(who) + " 已迁往 " + SettlementName(dest))
EndFunction

; 把某据点的"居民 → 岗位"整理成一段文本。
; M1 的明细弹窗用它；M2 的界面（世界终端或自定义 UI）也用它，保证两边数据一致。
; 每行格式：居民名|岗位名（无岗时岗位名是「（无业）」）

; 供界面调用：列出当前据点（或指定据点）的居民，每行一个名字
String Function BuildSettlerListString(WorkshopScript ws)
	if !ws
		return ""
	EndIf
	String s = ""
	ObjectReference[] actors = GetSettlementRoster(ws)
	int i = 0
	while i < actors.Length
		Actor a = actors[i] as Actor
		if a
			s += ActorName(a) + "\n"
		EndIf
		i += 1
	endWhile
	return s
EndFunction

; 供界面调用：按序号取居民（0 基）
Actor Function GetSettlerByIndex(WorkshopScript ws, int aiIndex)
	if !ws || aiIndex < 0
		return None
	EndIf
	; **按"上次推送出去的那份名单"解析**（界面里的行号就是照它画的）：
	; 面板刚打开的几秒里实时名单还在变（居民持续注册进来），拿实时名单解析会错位、
	; 甚至解析不到 → 改名/召唤/解除静默失效（玩家反馈"改名前几秒会还原"）。
	ObjectReference[] roster = LastPushedRoster
	if roster == None || roster.Length == 0
		roster = GetSettlementRoster(ws)      ; 还没推过（理论上界面也没行可点）→ 退回实时名单
	EndIf
	if aiIndex >= roster.Length
		return None
	EndIf
	Actor a = roster[aiIndex] as Actor
	if a
		return a
	EndIf
	; 兜底：那份名单里这一位不是 Actor（理论上不会）→ 用实时名单同一下标试试
	ObjectReference[] live = GetSettlementRoster(ws)
	if aiIndex < live.Length
		return live[aiIndex] as Actor
	EndIf
	return None
EndFunction

; 供界面调用：按序号取**刚推送出去的那个工位**（0 基）——
; 岗位页的行号就是按它画的，必须和推送用同一份列表（同 GetSettlerByIndex 的道理）。
WorkshopObjectScript Function GetPushedJobByIndex(int aiIndex)
	if LastPushedJobs == None || aiIndex < 0 || aiIndex >= LastPushedJobs.Length
		return None
	EndIf
	return LastPushedJobs[aiIndex] as WorkshopObjectScript
EndFunction

; 供界面调用：按序号取空闲岗位（0 基）
WorkshopObjectScript Function GetFreeJobByIndex(WorkshopScript ws, int aiIndex)
	Form[] jobs = GetFreeJobForms(ws)
	if aiIndex < 0 || aiIndex >= jobs.Length
		return None
	EndIf
	return jobs[aiIndex] as WorkshopObjectScript
EndFunction

; ======================================================================
; M2：PrismaUI 管理面板（Papyrus 侧）
;
; 两个方向：
;   游戏 → 界面：PrismaUI.Push(视图名, "smOnData", 数据)   ← 界面里 window.smOnData(数据)
;   界面 → 游戏：window.prisma.emit("smAction", 动作)      → 外部事件 PrismaUI_Event → 本脚本
;
; 数据格式刻意不用 JSON：Papyrus 没有 JSON 解析，用"行 + 竖线"分隔，界面侧拆开即可。
;   S|据点名|人口|无业|食物|水|电|防|床
;   W|居民名|状态(0无业 1在岗 2队友)|岗位名（顿号分隔）
;   J|空闲岗位名
; ======================================================================

String Function DashboardViewName()
	; 这个名字同时是 Data/PrismaUI_F4/views/<名字>/ 目录名，要一致
	return "SimpleSettlementManager"
EndFunction

WorkshopScript Function GetOwnedWorkshopByIndex(int aiIndex)
	WorkshopScript[] owned = GetOwnedWorkshops()
	if aiIndex < 0 || aiIndex >= owned.Length
		return None
	EndIf
	return owned[aiIndex]
EndFunction

; ----------------------------------------------------------------------
; S.P.E.C.I.A.L.（居民详情里显示的那七项）
;
; FormID 是从游戏自己的 Fallout4.esm 里读出来的（AVIF 记录的编辑器 ID：
; Strength=0x2C2 / Perception=0x2C3 / Endurance=0x2C4 / Charisma=0x2C5 /
; Intelligence=0x2C6 / Agility=0x2C7 / Luck=0x2C8），不是猜的。
; 显示的是**基础值**（GetBaseValue）——不含食物/药品/装备的临时加成，和人物卡一致。
; ----------------------------------------------------------------------
ActorValue[] Property CachedSpecialAVs = None Auto

ActorValue[] Function SpecialActorValues()
	if CachedSpecialAVs != None && CachedSpecialAVs.Length == 7
		return CachedSpecialAVs
	EndIf
	ActorValue[] avs = new ActorValue[7]
	avs[0] = Game.GetFormFromFile(0x000002C2, "Fallout4.esm") as ActorValue     ; Strength
	avs[1] = Game.GetFormFromFile(0x000002C3, "Fallout4.esm") as ActorValue     ; Perception
	avs[2] = Game.GetFormFromFile(0x000002C4, "Fallout4.esm") as ActorValue     ; Endurance
	avs[3] = Game.GetFormFromFile(0x000002C5, "Fallout4.esm") as ActorValue     ; Charisma
	avs[4] = Game.GetFormFromFile(0x000002C6, "Fallout4.esm") as ActorValue     ; Intelligence
	avs[5] = Game.GetFormFromFile(0x000002C7, "Fallout4.esm") as ActorValue     ; Agility
	avs[6] = Game.GetFormFromFile(0x000002C8, "Fallout4.esm") as ActorValue     ; Luck
	CachedSpecialAVs = avs
	return avs
EndFunction

; 七项打包成 "5-4-3-2-1-6-7"（界面按 - 拆开；顺序就是力量/感知/耐力/魅力/智力/敏捷/幸运）
String Function ActorSpecialPacked(Actor a)
	if !a
		return ""
	EndIf
	ActorValue[] avs = SpecialActorValues()
	String out = ""
	int i = 0
	while i < avs.Length
		if !avs[i]
			return ""            ; 取不到属性就整体不给（宁可不显示，也不给错的）
		EndIf
		if i > 0
			out += "-"
		EndIf
		out += (a.GetBaseValue(avs[i]) as int)
		i += 1
	endWhile
	return out
EndFunction

; ----------------------------------------------------------------------
; 职业类别（界面居民页用；数值要和 index.html 里的 kindInfo 一一对应）
;   **判据全部来自原版自己打在居民/工作对象上的状态**，不是我们猜的：
;   bIsWorker / bIsScavenger / bIsGuard 是原版指派工作时写的标记（WorkshopNPCScript），
;   商人看工作对象的 VendorType > -1，农民看工作对象是否产出食物（HasResourceValue(Food)）。
; ----------------------------------------------------------------------
int KIND_IDLE = 0 const
int KIND_FARMER = 1 const
int KIND_SCAVENGER = 2 const
int KIND_GUARD = 3 const
int KIND_VENDOR = 4 const
int KIND_CARAVAN = 5 const       ; 搬运工（跑供应线）
int KIND_WORKER = 6 const        ; 在岗但不属于上面任何一类（饮料机、理发椅……）
int KIND_COMPANION = 7 const

; 在岗居民的具体职业。ownedJobs 由调用方传入（那里已经取过一次，别重复取）。
int Function JobKindOfWorker(Actor a, WorkshopObjectScript[] ownedJobs)
	WorkshopNPCScript wnp = a as WorkshopNPCScript
	if wnp
		if wnp.bIsScavenger
			return KIND_SCAVENGER
		EndIf
		if wnp.bIsGuard
			return KIND_GUARD
		EndIf
	EndIf
	ActorValue foodAV = WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingFood].resourceValue
	bool hasFood = false
	int k = 0
	while k < ownedJobs.Length
		WorkshopObjectScript job = ownedJobs[k]
		if job
			if job.VendorType > -1
				return KIND_VENDOR
			EndIf
			if job.HasResourceValue(foodAV)
				hasFood = true
			EndIf
		EndIf
		k += 1
	endWhile
	if hasFood
		return KIND_FARMER
	EndIf
	return KIND_WORKER
EndFunction

; 本据点的居民名单 —— **界面里看到的顺序就是这里的顺序**。
; 所以凡是"按行号找居民"的地方（GetSettlerByIndex 等）都必须用这一个函数，
; 否则界面显示的是并集、动作却按另一个名单解析行号，点到多出来的人（例如跑供应线的）
; 就会解析失败 → 改名/召唤/解除静默不执行（玩家反馈"改名过几秒又还原"）。
;
; 三个来源取并集（只信一个会漏人）：
;   ① WSFW 的 GetWorkshopActors（WSFW 自己维护的清单）
;   ② 原版 WorkshopParent.GetWorkshopActors —— 据点的"人口资源对象"列表，
;      原版人口管理终端（DLC06OverseerHandlerScript.psc:103）读的就是它，**包含跑供应线的人**
;   ③ 原版搬运工集合 CaravanActorAliases 里"居所是本据点"的成员
; 并集顺序：WSFW 的在前、补充的追加在后面（去重保留首次出现），
; 这样原本就在 WSFW 名单里的人行号不变。
ObjectReference[] Function GetSettlementRoster(WorkshopScript ws)
	ObjectReference[] actors = WorkshopFramework:WorkshopFunctions.GetWorkshopActors(ws)
	if !ws
		return actors
	EndIf

	ObjectReference[] allActors = new ObjectReference[0]
	int mxI = 0
	while mxI < actors.Length
		allActors.Add(actors[mxI])
		mxI += 1
	endWhile

	; ② 原版人口列表。注意它可能包含婆罗门（同样是 WorkshopNPCScript）——
	; 原版终端靠 bCommandable 挡掉，这里用原版自己的婆罗门集合挡。
	ObjectReference[] vanillaActors = WorkshopParent.GetWorkshopActors(ws)
	RefCollectionAlias brahminAlias = WorkshopParent.CaravanBrahminAliases
	mxI = 0
	while mxI < vanillaActors.Length
		Actor vActor = vanillaActors[mxI] as Actor
		if vActor
			if !(brahminAlias && brahminAlias.Find(vActor) >= 0)
				allActors.Add(vActor)
			EndIf
		EndIf
		mxI += 1
	endWhile

	; ③ 机器人（管家这类机器人居民）：原版把机器人**单独计数**
	;    （WorkshopRatingPopulationRobots = 24），不在上面那份"人口资源对象"里，
	;    所以玩家反馈"庇护山庄的名单里没有管家"—— 单独把这一份并进来（照旧去重）。
	ObjectReference[] robotActors = ws.GetWorkshopResourceObjects(WorkshopParent.WorkshopRatings[WorkshopParent.WorkshopRatingPopulationRobots].resourceValue)
	mxI = 0
	while mxI < robotActors.Length
		Actor rActor = robotActors[mxI] as Actor
		if rActor
			allActors.Add(rActor)
		EndIf
		mxI += 1
	endWhile

	; ⑤ 原版"被搬进据点的非工坊居民"集合（PermanentActorAliases）——
	;    **退到据点里住的队友**（Codsworth 这类）就在这一份里：他们不是工坊刷出来的居民，
	;    所以上面几份都读不到（玩家反馈：庇护山庄名单里一直没有噶抓）。
	;    原版自己判"某据点还有没有常驻居民"用的也是它（PermanentActorsAliveAndPresent）。
	RefCollectionAlias permanentActors = WorkshopParent.PermanentActorAliases
	if permanentActors
		int pa = 0
		while pa < permanentActors.GetCount()
			WorkshopNPCScript pNpc = permanentActors.GetAt(pa) as WorkshopNPCScript
			if pNpc && pNpc.GetWorkshopID() == ws.GetWorkshopID()
				allActors.Add(pNpc)
			EndIf
			pa += 1
		endWhile
	EndIf

	; ④ 原版搬运工集合里居所是本据点的（人在路上时前两个接口都可能漏）
	RefCollectionAlias extraCaravan = WorkshopParent.CaravanActorAliases
	if extraCaravan
		int mxC = 0
		while mxC < extraCaravan.GetCount()
			WorkshopNPCScript mxCa = extraCaravan.GetAt(mxC) as WorkshopNPCScript
			if mxCa
				if mxCa.GetWorkshopID() == ws.GetWorkshopID()
					allActors.Add(mxCa)
				EndIf
			EndIf
			mxC += 1
		endWhile
	EndIf

	; 去重（三个来源必然重叠，不去重同一个人会出现两行）
	ObjectReference[] dedup = new ObjectReference[0]
	int mxD = 0
	while mxD < allActors.Length
		bool mxSeen = false
		int mxK = 0
		while mxK < dedup.Length
			if dedup[mxK] == allActors[mxD]
				mxSeen = true
			EndIf
			mxK += 1
		endWhile
		if !mxSeen
			dedup.Add(allActors[mxD])
		EndIf
		mxD += 1
	endWhile
	return dedup
EndFunction

; 在岗吗？**读居民自己身上的原版标记 `bIsWorker`**，而不是 WSFW 的账。
;
; 为什么（玩家反馈）：工坊界面里明明有人在种地、原版人口终端也显示「农夫（2）」，
; 但我们面板里那两个人是"无业"、农民是 0 —— 因为判据用的是 `WSFW.IsWorker()`，
; 它维护的是 WSFW 自己那套登记，会和游戏实际状态脱节。
; 原版人口终端判"失业"用的就是这个标记（DLC06OverseerHandlerScript.psc:146：
; `elseif ( theActor.bIsWorker == FALSE )`），指派工作时原版写 `SetWorker(true)`，
; 解除时写 `SetWorker(false)`（搬运工走的也是解除那条路，所以搬运工 bIsWorker = false）。
bool Function IsActorWorker(Actor a)
	WorkshopNPCScript wnp = a as WorkshopNPCScript
	if !wnp
		return false
	EndIf
	return wnp.bIsWorker
EndFunction

; 是不是"跑供应线的居民"（搬运工）。界面标「运输」、自动填岗要跳过、解除时要清账，都看它。
; 判据（任一成立即算）：① 在原版搬运工集合 CaravanActorAliases 里（原版的权威名单）；
; ② 目的地 actor value 指向另一个能解析出名字的据点（老判据，保留）。
; 前提：不能是 WSFW 眼里的在岗工人（搬运工本来就不算 worker），也不能是队友。
bool Function IsCaravanWorker(Actor a)
	if !a || IsCompanion(a)
		return false
	EndIf
	if IsActorWorker(a)
		return false
	EndIf
	WorkshopNPCScript wnp = a as WorkshopNPCScript
	if !wnp
		return false
	EndIf
	if WorkshopParent.CaravanActorAliases.Find(wnp) >= 0
		return true
	EndIf
	int destID = wnp.GetCaravanDestinationID()
	if destID > 0 && destID != wnp.GetWorkshopID()
		if CaravanDestinationName(destID) != ""
			return true
		EndIf
	EndIf
	return false
EndFunction

Function PushDashboardData(bool abPong = false)
	; 没开着就别推：视图被隐藏/销毁后推数据没有任何用处，
	; 而且"往没显示的视图推"是唯一可能被框架解释成"显示它"的动作（"面板自己弹出来"排查）。
	if !DashboardOpen
		return
	EndIf

	String s = ""
	if abPong
		; 自检回应：界面收到 P|pong 说明"页面 → 游戏"这条路是通的
		s += "P|pong\n"
	EndIf

	WorkshopScript[] owned = GetOwnedWorkshops()
	; 当前据点：S 行与明细段都要用（提到循环前，免得重复取）
	WorkshopScript here = GetPlayerSettlement()
	int i = 0
	while i < owned.Length
		WorkshopScript w = owned[i]
		RefreshUnassignedRating(w)
		String loadedFlag = "0"
		if w.Is3DLoaded()
			loadedFlag = "1"
		EndIf
		; 岗位数：当前据点现场数（并记进缓存），别的据点用上次在那边数到的（没有是 -1）
		int jobCount = CachedJobCount(w.GetWorkshopID())
		int jobNeed = CachedJobNeed(w.GetWorkshopID())
		if here && here == w
			int freshJobs = CountJobObjects(w)
			if freshJobs >= 0
				jobCount = freshJobs
				jobNeed = RequiredWorkers(w)
				RememberJobCount(w.GetWorkshopID(), jobCount, jobNeed)
			EndIf
		EndIf
		s += "S|" + w.GetWorkshopID() + "|" + SettlementName(w) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingPopulation) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingPopulationUnassigned) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingFood) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingWater) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingPower) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingSafety) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingBeds) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingMissingFood) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingMissingWater) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingMissingBeds) + "|" + RatingInt(w, WorkshopParent.WorkshopRatingHappiness) + "|" + loadedFlag + "|" + jobCount + "|" + jobNeed + "\n"
		i += 1
	endWhile

	; K 行：当前面板热键的 DX 扫描码（0 = 关闭），界面用来显示与同步
	s += "K|" + HotkeyCode + "\n"

	; E 行：供应线的一条边 —— 搬运工的居所据点 ID | 目的地据点 ID。
	; CaravanActorAliases 是原版跟踪全部搬运工的集合，据点没加载也能读到，
	; 所以整张供应网都能画出来。
	RefCollectionAlias caravanActors = WorkshopParent.CaravanActorAliases
	int ci = 0
	while ci < caravanActors.GetCount()
		WorkshopNPCScript prov = caravanActors.GetAt(ci) as WorkshopNPCScript
		if prov
			int homeID = prov.GetWorkshopID()
			int destID = prov.GetCaravanDestinationID()
			if homeID >= 0 && destID >= 0
				s += "E|" + homeID + "|" + destID + "\n"
			EndIf
		EndIf
		ci += 1
	endWhile

	WorkshopScript ws = here
	; 明细字符串在块外声明：没有据点时也要写一条**空 H 行**（见块尾的 Else）
	String detail = ""
	if ws
		detail += "H|" + SettlementName(ws) + "\n"

		ObjectReference[] actors = GetSettlementRoster(ws)
		; 记下这一份：界面之后按行号发回来的动作都要对回它（见 GetSettlerByIndex）
		LastPushedRoster = actors
		i = 0
		while i < actors.Length
			Actor a = actors[i] as Actor
			if a
				int status = 0
				String jobs = ""

				; 跑运输线的居民（搬运工）：原版**不把他们算作 worker**，所以以前被当成"无业"（玩家反馈）。
				; 判据用原版自己维护的搬运工集合 CaravanActorAliases —— 只靠 GetCaravanDestinationID()
				; 不可靠：非搬运工也可能读出 0，于是把无业的人误标成运输（玩家反馈"运输和无业混了"）。
				WorkshopNPCScript asProvisioner = a as WorkshopNPCScript
				int caravanDestID = -1
				String caravanDestName = ""
				if asProvisioner
					caravanDestID = asProvisioner.GetCaravanDestinationID()
				EndIf
				if caravanDestID >= 0
					caravanDestName = CaravanDestinationName(caravanDestID)
				EndIf
				; 判据：目的地必须能对一个已拥有的据点，而且不是自己所在的据点。
				; 只看 ID >= 0 不行 —— 非搬运工也会读出 0，结果所有人都被标成"运输"（玩家反馈）。
				; 硬条件三条：① 不能是 worker（搬运工本来就不算 worker，这条最硬）；
				; ② 目的地要能解析出名字；③ 目的地不是自己所在的据点。
				; 之前只靠 GetCaravanDestinationID() >= 0，结果普通居民也返回 0，
				; 而 0 又会撞上某个据点的 ID → 所有在岗居民都被标成"运输"（玩家反馈）。
				; 搬运工判定收敛到 IsCaravanWorker（界面标记、自动填岗、解除清账都用同一个判据）
				bool isProvisioner = IsCaravanWorker(a)

				int jobKind = KIND_IDLE
				if isProvisioner && !IsCompanion(a)
					status = 3
					jobKind = KIND_CARAVAN
					String destName = caravanDestName
					if destName != ""
						jobs = "→ " + destName
					Else
						jobs = "→ 据点 #" + caravanDestID
					EndIf
				elseif IsActorWorker(a)
					status = 1
					WorkshopObjectScript[] ownedJobs = GetOwnedJobObjects(ws, a)
					jobKind = JobKindOfWorker(a, ownedJobs)
					int k = 0
					while k < ownedJobs.Length
						if jobs != ""
							jobs += "、"
						EndIf
						jobs += RefName(ownedJobs[k])
						k += 1
					endWhile
				elseif IsCompanion(a)
					status = 2
					jobKind = KIND_COMPANION
				EndIf

				; 原版三个开关：能否指挥 / 能否迁走 / 能否跑运输
				String flags = ""
				if WorkshopFramework:WorkshopFunctions.IsCommandable(a)
					flags += "1"
				Else
					flags += "0"
				EndIf
				if WorkshopFramework:WorkshopFunctions.AllowMove(a)
					flags += "1"
				Else
					flags += "0"
				EndIf
				if WorkshopFramework:WorkshopFunctions.AllowCaravan(a)
					flags += "1"
				Else
					flags += "0"
				EndIf

				; 床位：原版就有判断函数（会考虑床的派系归属与占用者）
				String bedFlag = "0"
				WorkshopNPCScript wnp = a as WorkshopNPCScript
				if wnp && WorkshopParent.ActorOwnsBed(ws, wnp)
					bedFlag = "1"
				EndIf

				; 性别（0=男 1=女）放在 W 行末尾：界面按性别抽随机名字
				int sexOfActor = ActorSex(a)

				; 第 8 个字段（jobKind）是职业类别：居民页的标签栏与「职业状态」按它走
				int spareInt = 0
				if HasSpareCapacity(a, ws)
					spareInt = 1
				EndIf
				String wLine = "W|" + ActorName(a) + "|" + status + "|" + jobs + "|" + flags + "|" + bedFlag + "|" + sexOfActor + "|" + jobKind + "|" + ActorSpecialPacked(a) + "|" + spareInt + "\n"
				detail += wLine
			EndIf
			i += 1
		endWhile

		; G 行：**全部工位**（岗位页以岗位为主：每个工位一行，反过来说"这个工位谁来干"）。
		; 格式 G|工位名|类别|占用者名（占用者为空 = 空缺）。以前只有 J 行（空闲工位），
		; 岗位页因此只能看到空位；现在给全量，页面才能"给岗位挑人"。
		; 顺带记下这份工位对象列表：界面发回来的行号要按它解析（同 LastPushedRoster 的道理）。
		ObjectReference[] jobObjs = WorkshopParent.GetResourceObjects(ws)
		LastPushedJobs = new ObjectReference[0]
		int gj = 0
		while gj < jobObjs.Length
			WorkshopObjectScript jobObj = jobObjs[gj] as WorkshopObjectScript
			if jobObj && jobObj.RequiresActor() && !jobObj.IsBed()
				LastPushedJobs.Add(jobObj)
				String workerName = ""
				Actor jobOwner = jobObj.GetActorRefOwner()
				if jobOwner
					workerName = ActorName(jobOwner)
				EndIf
				detail += "G|" + RefName(jobObj) + "|" + JobResourceKind(jobObj) + "|" + workerName + "\n"
			EndIf
			gj += 1
		endWhile

		; 床位统计：床对象总数 / 已分配 / 空床
		ObjectReference[] bedObjs = WorkshopParent.GetBeds(ws)
		int bedsAssigned = 0
		int bi = 0
		while bi < bedObjs.Length
			WorkshopObjectScript bedObj = bedObjs[bi] as WorkshopObjectScript
			if bedObj && bedObj.IsActorAssigned()
				bedsAssigned += 1
			EndIf
			bi += 1
		endWhile
		detail += "B|" + bedObjs.Length + "|" + bedsAssigned + "|" + (bedObjs.Length - bedsAssigned) + "\n"

		Form[] freeJobs = GetFreeJobForms(ws)
		i = 0
		while i < freeJobs.Length
			detail += "J|" + RefName(freeJobs[i] as ObjectReference) + "\n"
			i += 1
		endWhile
		; 暂存这一份：离开这个据点后，界面上还能看到"上次在此据点时的明细"（玩家方案）
		RememberSettlementDetail(ws.GetWorkshopID(), detail)
		Debug.Trace("[SM] 已暂存据点明细：ID " + ws.GetWorkshopID())
	Else
		; **不在任何据点范围内**时也发一条空 H 行，否则界面会一直显示上一个据点的名字
		; （玩家反馈：快速传送走之后，据点页还把庇护山庄标成"当前所在"）。
		detail += "H|" + "\n"
	EndIf
	s += detail

	PrismaUI.Push(DashboardViewName(), "smOnData", s)
EndFunction

; 打开（或复用）面板。第一次调用时创建视图；数据随后推过去。
;
; 关键：如果是从哔哔小子菜单里点进来的，那个菜单还开着并占着输入焦点 ——
; 面板会画出来但鼠标/键盘都被它截走（实测：Esc 关掉的是哔哔小子）。
; 所以先尽力关掉几个可能的原版菜单（F4SE 的 UI.CloseMenu），再显示+聚焦，
; 然后起一个定时器在稍后再确认一次聚焦（菜单关闭需要一点时间）。
Function OpenDashboard(String asSource = "未标注")
	String view = DashboardViewName()
	float now = Utility.GetCurrentRealTime()

	; 全息卡带的重复触发：卡带播放结束后游戏可能把菜单项再跑一遍，
	; 这时面板会被重新打开，玩家看到的就是"面板自己又弹出来"。
	; 真人不可能在 8 秒内重放一次卡带并再点一次菜单项，所以窗口内的第二次
	; 「卡带菜单」触发一律当重复触发忽略 —— 但要提示一下，免得玩家以为是卡了。
	if asSource == "卡带菜单"
		; 差值必须落在 [0, 8)：负数说明这个时间戳来自上一局（进程时钟重置过），
		; 当成重复触发会让卡带在很长一段时间里点不开。
		float sinceTerminal = now - LastTerminalOpenTime
		if LastTerminalOpenTime > 0.0 && sinceTerminal >= 0.0 && sinceTerminal < 8.0
			int gap = (Math.Floor(sinceTerminal)) as int
			Debug.Trace("[SM] 忽略一次全息卡带的重复触发（" + gap + " 秒前刚打开过）")
			Debug.Trace("[SM] OpenDashboard 忽略重复的卡带触发，间隔 " + (now - LastTerminalOpenTime))
			return
		EndIf
		LastTerminalOpenTime = now
	EndIf

	Debug.Trace("[SM] OpenDashboard 来源=" + asSource + " 距上次关闭=" + (now - LastCloseTime) + " 距上次卡带=" + (now - LastTerminalOpenTime))

	; 先把原版菜单关掉，再创建视图 —— 顺序很重要：
	; 若在 CreateView 之后关，会连带关掉 PrismaUI 刚建立的光标菜单（CursorMenu），
	; 结果光标失控、双向通信也失效（踩过）。
	CloseTheseMenus("打开前")

	if !PrismaUI.IsValid(view)
		if !PrismaUI.CreateView(view, "SimpleSettlementManager/index.html")
			Debug.MessageBox("据点管理面板：创建视图失败。\n\n请确认 PrismaUI F4 已正确安装（Data/PrismaUI_F4/views/SimpleSettlementManager/index.html 是否存在）。")
			return
		EndIf
	EndIf

	PrismaUI.Show(view)
	; 第三个参数必须是 false：让 PrismaUI 自己管理光标（并接管 Esc 为"取消聚焦"）。
	; 传 true 会抑制它的 FocusMenu 覆盖层，导致"游戏已有的光标保持激活" ——
	; 表现就是关掉面板后鼠标指针还留在屏幕上（踩过）。
	PrismaUI.Focus(view, true, false)
	OpenDashboardTime = Utility.GetCurrentRealTime()
	DashboardOpen = true
	WritePanelState(1)
	PushDashboardData()

	; 稍后再确认一次（菜单真正关闭 + 视图聚焦完成）
	StartTimer(0.4, 9001)
	; 之后每 0.5 秒检查一次：还在打开状态但已经失去焦点（例如玩家按了 Esc）就关掉面板
	StartTimer(0.5, 9002)
EndFunction

; 已知的、可能和我们抢输入的原版菜单。
;   * 必须包含 TerminalMenu —— 全息卡带播放的终端菜单就是这个引擎菜单名，
;     漏掉它会导致"面板开着时终端菜单也开着"，表现为大指针画出来却冻住（踩过）。
;   * 绝对不能包含 CursorMenu —— 那是 PrismaUI 自己的光标菜单，
;     关掉它会让光标管理和双向通信一起失效（面板显示"事件未到达游戏"就是这么来的）。
;   * 故意不含 PauseMenu：那是玩家自己的菜单，我们不碰它。
String[] Function GameMenuNames()
	String[] names = new String[5]
	names[0] = "TerminalMenu"
	names[1] = "PipboyHolotapeMenu"
	names[2] = "PipboyMenu"
	names[3] = "PipboySubMenu"
	names[4] = "PipboyQuestMenu"
	return names
EndFunction

Function CloseTheseMenus(String asWhy)
	String[] names = GameMenuNames()
	int i = 0
	while i < names.Length
		if UI.IsMenuOpen(names[i])
			bool ok = UI.CloseMenu(names[i])
		EndIf
		i += 1
	endWhile
EndFunction

Function CloseDashboard()
	String view = DashboardViewName()
	PrismaUI.Unfocus(view)
	PrismaUI.Hide(view)
	; 这里**不要** Destroy。PrismaUI 官方文档明确说视图应当保留（不用时 Hide），
	; "destroy and recreate" 反而会破坏框架的光标/焦点交接 ——
	; 之前"按 Esc 能恢复、点关闭不能"的差异就是它造成的（踩过）。
	; 视图的跨读档残留问题由 OnPlayerLoadGame 里的清理负责（那时视图没有焦点，销毁是安全的）。
	DashboardOpen = false
	WritePanelState(0)              ; 面板状态归零 —— 插件据此放开暂停菜单、允许热键重开
	LastCloseTime = Utility.GetCurrentRealTime()

	; 收尾：把可能还开着的原版菜单关掉（含 TerminalMenu）
	; PauseMenu 不在列表里 —— 那是玩家自己的菜单，不该被我们关
	CloseTheseMenus("收尾")

	; 面板关掉时若还在"等按键"状态，把标记清掉，免得热键一直失效
	bHotkeyCapturing = false

	; 关掉面板后短暂静音热键事件：界面侧关闭（面板聚焦时页面自己按热键关）之后，
	; 同一次按键的"松开"事件还会送到这里 —— 不挡的话它会立刻把面板又开回来
	; （表现就是"F10 关不上"）。
EndFunction

; 界面发来的动作。
;
; 重要限制：FO4 的 Papyrus 字符串类型**没有任何方法**（Find/Substring/AsInt 都不存在，
; 实测编译不过，原版一万个脚本也一次没用过）。所以不能解析 payload，改成：
;   * 动作名直接放在事件名里，Papyrus 用"拼接后比较"的小循环取出下标
;   * 需要用到的状态放在运行时属性里（PickedSettler 等）
; 事件名约定：smRefresh / smClose / smFill / smPickSettler<下标> / smPickJob<下标> / smUnassign<下标>
Function HandleDashboardAction(String asEventName, String asPayload = "")
	if asEventName == "smRefresh"
		PushDashboardData()
		return
	EndIf

	; 关闭的三种来源分开处理：
	;   smCloseEsc —— 玩家按 Esc 关的，游戏可能顺带打开暂停菜单，要收拾一下
	;   smCloseHK  —— 玩家按热键关的，要吞掉同一次按键的松开事件（否则关上又开）
	;   smClose    —— 点左下角"关闭"按钮等，无需额外处理
	if asEventName == "smCloseEsc"
		; Esc 只管关面板。暂停菜单由配套插件在原生层压住（没那次 leaked Esc，也就没东西要收拾）。
		CloseDashboard()
		return
	EndIf
		; 改名：事件名 smRename，新名字在 payload 里（界面原样传字符串，这里也原样用）
	if asEventName == "smSummon"
		; 把当前选中的居民拉到你身边（搬运工在路上的时候用）
		if PickedSettler
			DoSummonActor(PickedSettler)
			PushDashboardData()
		EndIf
		return
	EndIf

	if asEventName == "smDismiss"
		; 开除：把居民从本据点彻底移出去（工位/床位/供应线一起解除）。
		; 这一步是**不可轻易撤销**的，所以界面那边有确认对话框。
		if PickedSettler
			DoDismissActor(PickedSettler, GetPlayerSettlement())
		Else
			Debug.Notification("还没选中居民：先点一下他的名字，再开除")
			PushDashboardData()
		EndIf
		return
	EndIf

	if asEventName == "smRename"
		if PickedSettler
			DoRename(PickedSettler, asPayload)
		Else
			Debug.Trace("[SM] 改名时没有选中的居民（界面行号没对上）")
			Debug.Notification("还没选中居民：先点一下他的名字，再改名")
			PushDashboardData()
		EndIf
		return
	EndIf
	if asEventName == "smClose"
		CloseDashboard()
		return
	EndIf
	if asEventName == "smFill"
		MenuAutoFillJobs()
		PushDashboardData()
		return
	EndIf

	if asEventName == "smUnassignAll"
		MenuUnassignAll()
		PushDashboardData()
		return
	EndIf

	; 设置热键：smSetHotkey<DX 扫描码>（0 = 关闭）。
	; 接受整个扫描码范围 —— 界面是"按键捕获"，任何键都可能传过来。
	int hk = 0
	while hk <= 255
		if asEventName == ("smSetHotkey" + hk)
			ApplyHotkey(hk)
			return
		EndIf
		hk += 1
	endWhile

	; 按键捕获的开关（界面进/出"等待按键"状态时告知）
	if asEventName == "smCaptureStart"
		bHotkeyCapturing = true
		return
	EndIf
	if asEventName == "smCaptureEnd"
		bHotkeyCapturing = false
		return
	EndIf

	if asEventName == "smPing"
		; 自检：界面打开时会 ping 一次，我们回一个带 P|pong 的负载，
		; 界面据此判断"页面 → 游戏"这条方向通不通
		PushDashboardData(true)
		return
	EndIf

	WorkshopScript ws = GetPlayerSettlement()
	if !ws
		return
	EndIf

	int idx = 0
	while idx < 64
		if asEventName == ("smDetail" + idx)
			; 界面展开某个据点时要它的"暂存明细"（离开该据点后仍能看上次的数据）。
			; 回推 "CD|<据点ID>" + 明细行；没有暂存就只回 ID，界面据此显示"走过去看"的提示。
			WorkshopScript dTarget = GetOwnedWorkshopByIndex(idx)
			if dTarget
				String cached = CachedSettlementDetail(dTarget.GetWorkshopID())
				Debug.Trace("[SM] 界面取暂存明细：ID " + dTarget.GetWorkshopID())
				PrismaUI.Push(DashboardViewName(), "smOnData", "CD|" + dTarget.GetWorkshopID() + "\n" + cached)
			EndIf
			return
		EndIf
		if asEventName == ("smAssignSettlerToJob" + idx)
			; 居民页：**给人派活** —— 把当前选中的居民派到第 idx 个工位
			; （行号按"刚推送出去的那份工位列表"解析，同名单的道理）
			WorkshopObjectScript ajob = GetPushedJobByIndex(idx)
			if PickedSettler && ajob
				DoAssignJob(PickedSettler, ajob)
			Else
				Debug.Notification("没找到这个工位，面板刷新了一下，请再点一次")
				PushDashboardData()
			EndIf
			return
		EndIf
		if asEventName == ("smAssignCaravan" + idx)
			; 居民页：把选中的居民派去跑运输线，目的地 = 第 idx 个自有据点
			WorkshopScript cdest = GetOwnedWorkshopByIndex(idx)
			if PickedSettler && cdest
				DoAssignCaravan(PickedSettler, cdest)
			EndIf
			return
		EndIf
		if asEventName == ("smPickJobRow" + idx)
			; 岗位页：**给岗位挑人** 第一步 —— 先点工位，把人选留到下一个事件
			PickedJobRow = idx
			PickedKindRow = -1
			return
		EndIf
		if asEventName == ("smPickKindRow" + idx)
			; 岗位页：点的是"类别合并行"（农民 / 守卫：一人可多岗）
			PickedKindRow = idx
			PickedJobRow = -1
			return
		EndIf
		if asEventName == ("smPickWorker" + idx)
			; 岗位页 第二步 —— 再点人。分两种：
			;   PickedKindRow >= 0：类别合并行（农民/守卫，一人可多岗）→ 批量填空位
			;   否则：单个工位（商人/工人/拾荒者，一岗一人）→ 就派那一个
			Actor wActor = GetSettlerByIndex(ws, idx)
			if !wActor
				Debug.Notification("没找到这位居民，面板刷新了一下，请再点一次")
				PushDashboardData()
			ElseIf PickedKindRow >= 0
				int got = AssignWorkerToKind(wActor, ws, PickedKindRow)
				if got > 0
					ws.RecalculateWorkshopResources(false)
					RefreshUnassignedRating(ws)
					Debug.Notification(ActorName(wActor) + " 已派到 " + got + " 个同类工位")
				Else
					Debug.Notification(ActorName(wActor) + " 没能派上 —— 他可能已经到这一类工位的上限了")
				EndIf
				PushDashboardData()
			Else
				WorkshopObjectScript wjob = GetPushedJobByIndex(PickedJobRow)
				if wjob
					DoAssignJob(wActor, wjob)
				Else
					Debug.Notification("没找到这个工位，面板刷新了一下，请再点一次")
					PushDashboardData()
				EndIf
			EndIf
			PickedJobRow = -1
			PickedKindRow = -1
			return
		EndIf
		if asEventName == ("smPickSettler" + idx)
			PickedSettler = GetSettlerByIndex(ws, idx)
			if !PickedSettler
				; 解析不到说明界面那份名单过期了（例如刚打开面板那几秒）——
				; 不静默失败：提示 + 重新推一份名单，让界面和游戏对齐。
				Debug.Trace("[SM] 行号解析不到居民：idx=" + idx)
				Debug.Notification("没找到这位居民，面板刷新了一下，请再点一次")
				PushDashboardData()
			EndIf
			; 不弹成功通知：多选派活会连续触发很多次，界面自己会显示选中状态
			return
		EndIf
		if asEventName == ("smPickJob" + idx)
			if PickedSettler
				WorkshopObjectScript job = GetFreeJobByIndex(ws, idx)
				if job
					DoAssignJob(PickedSettler, job)
					PickedSettler = None
					PushDashboardData()
				EndIf
			EndIf
			return
		EndIf
		if asEventName == ("smUnassign" + idx)
			Actor who = GetSettlerByIndex(ws, idx)
			if who
				DoUnassignActor(who, ws)
				PushDashboardData()
			EndIf
			return
		EndIf
		if asEventName == ("smMigrateTo" + idx)
			WorkshopScript dest = GetOwnedWorkshopByIndex(idx)
			if PickedSettler && dest && dest != ws
				DoMigrateActor(PickedSettler, dest)
				PickedSettler = None
				PushDashboardData()
			EndIf
			return
		EndIf
		idx += 1
	endWhile

	; 三个开关（原版属性：能否指挥 / 能否迁走 / 能否跑运输），作用于当前选中的居民。
	; 事件名：smFlagC/M/V + 0或1
	if PickedSettler
		if asEventName == "smFlagC0"
			Debug.Notification("已关闭「能否指挥」：" + ActorName(PickedSettler))
			WorkshopFramework:WorkshopFunctions.SetCommandable(PickedSettler, false)
		elseif asEventName == "smFlagC1"
			Debug.Notification("已开启「能否指挥」：" + ActorName(PickedSettler))
			WorkshopFramework:WorkshopFunctions.SetCommandable(PickedSettler, true)
		elseif asEventName == "smFlagM0"
			Debug.Notification("已关闭「能否迁走」：" + ActorName(PickedSettler))
			WorkshopFramework:WorkshopFunctions.SetAllowMove(PickedSettler, false)
		elseif asEventName == "smFlagM1"
			Debug.Notification("已开启「能否迁走」：" + ActorName(PickedSettler))
			WorkshopFramework:WorkshopFunctions.SetAllowMove(PickedSettler, true)
		elseif asEventName == "smFlagV0"
			Debug.Notification("已关闭「能否运输」：" + ActorName(PickedSettler))
			; 「能否运输」= 这个人能否被指派去跑供应线。关掉它时，如果他**已经在跑**，
			; 就立刻解除运输身份（玩家说明的语义）—— 用和"解除岗位"同一套清账：
			; 移出搬运工集合（别名上的行走包随之失效）、断线、删婆罗门、清 AV 与链接引用。
			WorkshopFramework:WorkshopFunctions.SetAllowCaravan(PickedSettler, false)
			if PickedSettler as WorkshopNPCScript
				if ClearCaravanDuty(PickedSettler)
					Debug.Notification(ActorName(PickedSettler) + " 已停止跑运输（「能否运输」被关闭）")
				EndIf
			EndIf
		elseif asEventName == "smFlagV1"
			Debug.Notification("已开启「能否运输」：" + ActorName(PickedSettler))
			WorkshopFramework:WorkshopFunctions.SetAllowCaravan(PickedSettler, true)
		Else
			Debug.Trace("[SM] 面板发来未处理的事件: " + asEventName)
			return
		EndIf
		PushDashboardData()
	Else
		Debug.Trace("[SM] 面板发来未处理的事件: " + asEventName)
	EndIf
EndFunction

; 外部事件回调必须写成 Function（F4SE 的 RegisterForExternalEvent 注释：Callback is the function name）。
; 写成 Event 会编译不过 —— Papyrus 不允许声明父类链里没有的事件。
; 写面板状态（插件读它，作为"压暂停菜单"和"热键只开不关"的唯一依据）
Function WritePanelState(int aiOpen)
	if !PanelState
		PanelState = Game.GetFormFromFile(0x00000F9F, "SimpleSettlementManager.esp") as GlobalVariable
	EndIf
	if PanelState
		PanelState.SetValue(aiOpen as float)
	EndIf
EndFunction

; 把热键值写进 ESP 的 GLOB 记录 SM_HotkeyVK（插件每帧读它）。
; 取记录用 Game.GetFormFromFile + 插件名 + 本地 FormID，取到后缓存到属性里 ——
; 这样 CK 侧不需要任何属性填充。
Function WriteHotkeyGlob(int aiCode)
	if !HotkeyGlobal
		HotkeyGlobal = Game.GetFormFromFile(0x00000F9D, "SimpleSettlementManager.esp") as GlobalVariable
		Debug.Trace("[SM] SM_HotkeyVK 记录：" + HotkeyGlobal)
	EndIf
	if HotkeyGlobal
		HotkeyGlobal.SetValue(aiCode as float)
	EndIf
EndFunction

; 配套插件的事件：SMUI_Event
;   "ready"  —— 插件已拿到有效热键并接管按键（此后本脚本不再自己注册/处理热键）
;   "hotkey" —— 玩家按下了热键（原生按下事件，只报一次，不含长按重复）
; 连击去抖：只有"距上次处理不到 0.3 秒、且没有倒退"才算重复投递。
; 差值为负说明时间戳来自上一局（进程时钟已重置）—— 绝不能当重复，否则热键会被永久吃掉。
bool Function IsRepeatEvent(float afNow)
	float diff = afNow - LastHotkeyTime
	return diff >= 0.0 && diff < 0.3
EndFunction

Function OnSMUIEvent(String asEventName, String asPayload)
	Debug.Trace("[SM] OnSMUIEvent " + asEventName + " / " + asPayload)

	if asPayload == "renamed"
		; 插件改完了：读结果（1 成功 / 2 失败）—— 提示用我们自己存的名字
		int renameOK = 2
		if RenameResult
			renameOK = RenameResult.GetValue() as int
		EndIf
		if renameOK == 1
			Debug.Notification("已改名为「" + PendingRenameName + "」")
		ElseIf renameOK == 3
			; 名字写进去了，但 2 秒后游戏显示的还是老名字 —— 被任务/别名的名字固定了
			; （这跟"哪个 mod"无关，所以提示里不点名）
			Debug.Notification("名字没能显示出来（「" + PendingRenameName + "」）：这个名字被任务或别名固定了，游戏里仍是原名字。")
		Else
			; 写入本身就没落到引用上（对象无效 / 插件未加载）
			Debug.Notification("改名没生效（「" + PendingRenameName + "」）：没能写进这个居民的名字，先试试换个名字或重新打开面板。")
		EndIf
		PushDashboardData()
		return
	EndIf

	if asPayload == "ready"
		if !bPluginReady
			bPluginReady = true
		EndIf
		PushDashboardData()
		return
	EndIf

	if asPayload == "close"
		; 插件发现面板已失焦（PrismaUI 的 Esc 处理只取消聚焦、不关闭）—— 由这里真正收起来
		float nowClose = Utility.GetCurrentRealTime()
		if IsRepeatEvent(nowClose)
			return
		EndIf
		LastHotkeyTime = nowClose
		CloseDashboard()
		return
	EndIf
	if asPayload == "esc"
		; 面板可见时插件在原生层接下了 Esc（游戏不会跟着暂停）—— 这里只负责关面板
		float nowEsc = Utility.GetCurrentRealTime()
		if IsRepeatEvent(nowEsc)
			return
		EndIf
		LastHotkeyTime = nowEsc
		CloseDashboard()
		return
	EndIf
	if asPayload == "hotkey"
		; 能收到热键事件就说明插件活着 —— 顺手撤掉老机制的注册（防御 ready 丢失）
		if !bPluginReady
			bPluginReady = true
			Debug.Trace("[SM] 由热键事件确认插件已接管，撤掉老注册")
		EndIf
		; 去抖：0.3 秒内的重复投递只当一次按键。
		; （即使某些情况下同一个事件被投递多份，也不会出现"开一下马上又关上"。）
		float nowHotkey = Utility.GetCurrentRealTime()
		if IsRepeatEvent(nowHotkey)
			Debug.Trace("[SM] 忽略重复的热键事件")
			return
		EndIf
		LastHotkeyTime = nowHotkey
		; 只开不关：面板已经开着时热键不做事，关闭交给 Esc（与 NODE.LITE 的分工一致）
		if !DashboardOpen
			OpenDashboard("热键（插件）")
		EndIf
		return
	EndIf
EndFunction

Function OnPrismaUIEvent(String asEventName, String asPayload)
	if asEventName != ""
		HandleDashboardAction(asEventName, asPayload)
	EndIf
EndFunction

; ======================================================================
; 判定实验：动态文字能不能显示在哔哔小子的卡带菜单里
;
; 原理：文本替换数据是挂在"引用"上的，菜单项文字里写 <Token.SMTest> 就会显示
; 那个引用的名字。哔哔小子播放的终端没有引用，所以社区说法是"不可用" ——
; 但玩家自己也是一个引用，这里就试把它挂在玩家身上。
; 菜单项 ID=7 的文字是「居民：<Token.SMTest>」，所以：
;   重新进入菜单后显示成居民名字 → 可行，M2 的列表 UI 可以直接做在卡带上
;   仍然显示字面的 <Token.SMTest> → 不行，M2 需要世界里的终端（有引用）
; ======================================================================
