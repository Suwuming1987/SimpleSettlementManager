Scriptname SimpleSettlementManager:TerminalMenu extends Terminal
{ 据点管理终端 —— 菜单分派脚本

  挂在终端记录 SM_MainMenu 上（记录窗口的 Papyrus Scripts → Add）。
  用 Terminal 自带的 OnMenuItemRun 事件：**任何菜单项都做同一件事 —— 打开管理面板**。

  为什么不用 Fragment：
    * 全息卡带在哔哔小子里播放时，终端是"表单"而不是世界里的引用
      （事件里的 akTerminalRef 为 None，这是 CK wiki 明确写过的），
      所以 Fragment 那套每项一份生成脚本、每份还要单独填属性的做法没必要；
      全部逻辑集中在这里 + 控制器脚本，CK 侧只需要填一次属性。
    * Pip-Boy 上文本替换不可用，所以所有动态内容都走 PrismaUI 面板。

  注：M1 时期这里按菜单项 ID 分派（iMenuID_Report / Roster / AutoFill / …），
  那些属性以及对应的 MessageBox 报表都已删除 —— 面板是唯一的界面。
}

SimpleSettlementManager:ControllerQuest Property SM_ControllerQuest Auto Const Mandatory
{ 控制器任务（EditorID: SM_ControllerQuest），Auto-Fill All 会自动填 }

Event OnMenuItemRun(int auiMenuItemID, ObjectReference akTerminalRef)
	; 打日志：万一菜单项触发/ID 对不上，Papyrus 日志里能直接看到收到的 ID
	Debug.Trace("[SM] OnMenuItemRun id=" + auiMenuItemID + " terminalRef=" + akTerminalRef)

	if !SM_ControllerQuest
		Debug.Notification("据点管理终端：控制器未就绪（终端记录的 SM_ControllerQuest 属性没填）")
		return
	EndIf

	SM_ControllerQuest.OpenDashboard("卡带菜单")
EndEvent
