#include "PCH.h"

#include "PanelWatcher.h"
#include "PrismaUI_F4_API.h"

#include <spdlog/spdlog.h>

#include <fstream>
#include <string>
#include <cstring>

// ---------------------------------------------------------------------------
// 面板焦点看门狗
//
// 目的：面板（PrismaUI 视图）聚焦期间压住**原版暂停菜单**。
// 为什么需要（对照 NODE.LITE）：NODE.LITE 自带 F4SE 插件，在原生层处理 Esc 与焦点，
// 所以它按 Esc 关面板时游戏不会跟着弹暂停菜单。我们这边相关能力只有 C++ 接口
// （IVPrismaUI6::SuppressVanillaMenu / IVPrismaUI7::SuppressVanillaMenuIf /
//   IVPrismaUI9::SetViewOwnsEscape），所以用这个插件把它们接上。
// 没装这个插件时 Papyrus 侧仍会"事后把菜单关掉"，功能不受影响。
//
// 设计要点：
//   * 视图是 Papyrus 建的，插件按 **HTML 路径**找出来（EnumerateViewsEx），
//     不需要 Papyrus 与原生之间的桥；视图被销毁/重建时按 IsValid 重新找。
//   * 压菜单用 SuppressVanillaMenuIf("PauseMenu", 判定)：判定在游戏"想开菜单"那一刻被调用。
//     条件 = "有 PrismaUI 面板可见" 或 "刚关掉面板的一瞬间"（GRACE）——后者必要，
//     因为 Esc 关面板与游戏处理同一个 Esc 可能错开一两帧。
//     写成"任何面板可见"而不是"只有我们的面板"，是为了不和 NODE.LITE 这类同接口 mod 打架。
//   * SetViewOwnsEscape(view, true)：告诉 PrismaUI 这个视图自己处理 Esc。
// ---------------------------------------------------------------------------

namespace
{
    using namespace PRISMA_UI_API;

    IVPrismaUI10* g_api = nullptr;
    PrismaView    g_view = 0;

    std::atomic<bool> g_panelVisible{ false };
    std::atomic<int64_t> g_graceUntilMs{ 0 };

    bool SuppressPredicate()
    {
        if (std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch())
                .count() < g_graceUntilMs.load())
        {
            return true;
        }
        return g_panelVisible.load();
    }

    constexpr int64_t kGraceMs = 250;
    constexpr auto kReinstallEvery = std::chrono::milliseconds(1500);

    // 视图还没建出来时多久找一次（面板是玩家点卡带/按热键才创建的）
    constexpr auto kResolveInterval = std::chrono::milliseconds(500);

    std::chrono::steady_clock::time_point g_lastTick{};
    std::chrono::steady_clock::time_point g_lastInstall{};
    std::chrono::steady_clock::time_point g_lastResolve{};
    bool g_suppressionReady = false;
    std::chrono::steady_clock::time_point g_lastAnnounce{};

    // ---- 给 Papyrus 发外部事件 ----
    // 这就是 PrismaUI 给页面送 PrismaUI_Event 用的那套：取出该事件名的所有
    // RegisterForExternalEvent 注册，逐个派发。VM 指针从 PapyrusInterface::Register
    // 的回调里拿到（那份接口只用来取 VM，我们不需要注册任何原生函数）。
    RE::BSScript::IVirtualMachine* g_vm = nullptr;

    struct EventPayload
    {
        const char* name;
        const char* arg;
        int         delivered;   // 这次派发实际成功投递了几份（0 = 没人注册，事件丢了）
    };

    void F4SEAPI OnRegistrant(std::uint64_t a_handle, const char* a_scriptName, const char* a_callbackName, void* a_data)
    {
        auto* payload = static_cast<EventPayload*>(a_data);
        if (!payload || !g_vm)
            return;

        // Papyrus 侧回调签名：Function(String asEventName, String asPayload)
        const bool ok = g_vm->DispatchMethodCall(
            a_handle,
            RE::BSFixedString(a_scriptName),
            RE::BSFixedString(a_callbackName),
            nullptr,
            RE::BSFixedString(payload->name),
            RE::BSFixedString(payload->arg));
        if (ok)
            payload->delivered += 1;
        else
            REX::WARN("event '{}' -> DispatchMethodCall FAILED (handle {}, script '{}', cb '{}')",
                      payload->name, a_handle, a_scriptName ? a_scriptName : "?", a_callbackName ? a_callbackName : "?");
    }

    void NotifyPapyrus(const char* a_name, const char* a_arg)
    {
        const auto papyrus = F4SE::GetPapyrusInterface();
        if (!papyrus || !g_vm)
            return;

        EventPayload payload{ a_name, a_arg, 0 };
        papyrus->GetExternalEventRegistrations(a_name, &payload, &OnRegistrant);
        // 0 = 当前没有任何脚本注册这个事件（Papyrus 那边注册掉了）—— 这是"按了没反应"的典型原因，
        // 之前这条信息只存在于 Papyrus 日志里（而 Papyrus 日志默认是关的），排错全靠猜。
        if (payload.delivered == 0)
            REX::WARN("event '{}' ('{}') had NO registrants -> Papyrus never got it", a_name, a_arg);
    }

    bool PapyrusRegister(RE::BSScript::IVirtualMachine* a_vm)
    {
        g_vm = a_vm;
        return true;
    }

    // ---- 热键：从 ESP 里的 GLOB 记录读值（Papyrus 写，插件读）----
    // 为什么用 GLOB：Papyrus 通知插件的正路（vm->RegisterFunction）在这份 CommonLibF4 里没有，
    // 而 GLOB 是 FO4 里插件与 Papyrus 共享设置的常规做法 —— 界面改键 → Papyrus 写 → 插件读。
    constexpr std::uint32_t kVkEscape = 0x1B;             // 虚拟键码 Esc
    constexpr std::uint32_t kHotkeyGlobID = 0x00000F9D;
    constexpr std::uint32_t kPanelStateGlobID = 0x00000F9F;   // tools/add_glob.py 建的
    constexpr const char*    kHotkeyGlobPlugin = "SimpleSettlementManager.esp";

    RE::TESGlobal* g_hotkeyGlobal = nullptr;
    RE::TESGlobal* g_panelStateGlobal = nullptr;
    bool           g_panelOpen = false;   // 唯一状态来源：Papyrus 写在 SM_PanelOpen 里
    int            g_lastGlobVk = -1;
    std::uint32_t  g_hotkeyCode = 0;
    bool           g_hotkeyReady = false;
    bool           g_keySpaceChecked = false;
    bool           g_vkSpace = true;
    bool           g_handlerRegistered = false;
    bool           g_announced = false;
    PrismaView     g_configuredView = 0;   // 已经配置过（role + 接管 Esc）的视图句柄

    // ---- 热键值的本地缓存（消除"读档后约 10 秒热键空窗"）----
    // 唯一的写入者是 Papyrus 的读档回调，而引擎把它排在很后面（mod 多时几秒到十几秒），
    // 这段时间 GLOB 里是上一局的旧值。插件把上次的值存在 DLL 旁边的小文件里，
    // 启动即读 → 热键当场可用；GLOB 只在你改键时才变（那次会同步写文件）。
    std::string HotkeyCachePath()
    {
        char buf[MAX_PATH]{};
        const auto mod = GetModuleHandleW(L"SimpleSettlementManagerUI.dll");
        const auto n = GetModuleFileNameA(mod, buf, MAX_PATH);
        std::string path(buf, n > 0 ? static_cast<std::size_t>(n) : 0);
        // 反斜杠和正斜杠都要找：`"\/"` 在 C++ 里只是**正斜杠**（`\/` 被当成 `/`），
        // 而 Windows 路径用的是反斜杠 —— 曾经因此截取失败，缓存文件名里带上了整个 DLL 路径
        // （...\SimpleSettlementManagerUI.dllSimpleSettlementManagerUI.hotkey）。读写用的是同一个路径，
        // 所以功能一直正常，只是名字离谱。
        const auto slash = path.find_last_of("\\/");
        if (slash != std::string::npos)
            path.resize(slash + 1);
        return path + "SimpleSettlementManagerUI.hotkey";
    }

    void WriteHotkeyCache(int a_vk)
    {
        std::ofstream out(HotkeyCachePath(), std::ios::trunc);
        if (out)
            out << a_vk;
    }

    int ReadHotkeyCache()
    {
        std::ifstream in(HotkeyCachePath());
        int vk = -1;
        if (in)
            in >> vk;
        return (in && !in.fail()) ? vk : -1;
    }

    // ---- GoE 迁移 第 1 步：验证"插件能读 Papyrus 属性" ----
    // 读控制器任务上的 HotkeyCode 并写日志。数值与设置页显示的热键一致 → 通道成立，
    // 就可以把改名（写显示名）从 Garden of Eden 搬到插件里（见 docs/GOE-REMOVAL.md）。
    void ProbePapyrusProperty()
    {
        static bool done = false;
        if (done || !g_vm)
            return;

        auto* handler = RE::TESDataHandler::GetSingleton();
        auto* quest = handler ? handler->LookupForm<RE::TESQuest>(0x00000F9A, "SimpleSettlementManager.esp") : nullptr;
        if (!quest)
            return;                       // 数据还没加载好，下一 tick 再试

        const auto& policy = g_vm->GetObjectHandlePolicy();
        const auto  handle = policy.GetHandleForObject(RE::BSScript::GetVMTypeID<RE::TESQuest>(), quest);
        if (handle == policy.EmptyHandle())
        {
            done = true;
            REX::WARN("probe: no handle for controller quest (GetVMTypeID<TESQuest> likely wrong)");
            return;
        }

        RE::BSTSmartPointer<RE::BSScript::Object> object;
        if (!g_vm->FindBoundObject(handle, "SimpleSettlementManager:ControllerQuest", false, object, false) || !object)
        {
            done = true;
            REX::WARN("probe: quest script object is not bound");
            return;
        }

        auto* var = object->GetProperty(RE::BSFixedString("HotkeyCode"));
        if (!var)
        {
            done = true;
            REX::WARN("probe: property HotkeyCode not found");
            return;
        }
        if (var->is<std::int32_t>())
            REX::INFO("probe OK: papyrus property HotkeyCode = {}", RE::BSScript::get<std::int32_t>(*var));
        else
            REX::WARN("probe: HotkeyCode has an unexpected type");
        done = true;
    }

    // ---- GoE 迁移 第 2 步：改名由插件执行 ----
    // 流程：Papyrus 把"改谁的 FormID / 改成什么名字"存进两个脚本属性，并把 SM_RenameReq 请求号 +1；
    // 插件看到请求号变化 → 用已验证的属性通道取到这两个值 → 写显示名（ExtraTextDisplayData）
    // → 回读 GetDisplayFullName() 确认 → 写 SM_RenameResult（1 成功 / 2 失败）→ 通知 Papyrus。
    constexpr std::uint32_t kRenameReqGlobID = 0x00000FA0;
    constexpr std::uint32_t kRenameResultGlobID = 0x00000FA1;
    RE::TESGlobal* g_renameReqGlobal = nullptr;
    RE::TESGlobal* g_renameResultGlobal = nullptr;
    int            g_lastRenameReq = -1;

    // 改名的**延迟复核**状态（说明见 ApplyPendingRename）：写完之后名字不一定当场就变，
    // 所以 2 秒后再读一次 —— 那时还不对，才能断定是"被别的名字来源压住了"。
    constexpr int kRenameVerifyTicks = 8;   // 8 × 250ms = 2s
    std::uint32_t g_renameVerifyFormID = 0;
    std::string   g_renameVerifyWanted;
    std::string   g_renameVerifyBefore;   // 改之前的显示名（判定"有没有变"用）
    int           g_renameVerifyTicks = 0;

    // 读控制器任务上的一个属性（通道在第 1 步已验证）
    RE::BSScript::Variable* ReadControllerProperty(const char* a_name)
    {
        if (!g_vm)
            return nullptr;
        auto* handler = RE::TESDataHandler::GetSingleton();
        auto* quest = handler ? handler->LookupForm<RE::TESQuest>(0x00000F9A, "SimpleSettlementManager.esp") : nullptr;
        if (!quest)
            return nullptr;
        const auto& policy = g_vm->GetObjectHandlePolicy();
        const auto  handle = policy.GetHandleForObject(RE::BSScript::GetVMTypeID<RE::TESQuest>(), quest);
        if (handle == policy.EmptyHandle())
            return nullptr;
        RE::BSTSmartPointer<RE::BSScript::Object> object;
        if (!g_vm->FindBoundObject(handle, "SimpleSettlementManager:ControllerQuest", false, object, false) || !object)
            return nullptr;
        return object->GetProperty(RE::BSFixedString(a_name));
    }

    // 给引用写自定义显示名。
    // **走引擎自己的入口 ExtraDataList::SetOverrideName**，不再手工往附加数据链表里插条目：
    //   * `BaseExtraList::AddExtra` 里有 `assert(!HasType(type))`，而 `RemoveExtra(type)`
    //     只有在链表里**找得到**同类型条目时才会清掉类型标志位 —— 一旦出现"标志位说存在、
    //     链表里其实没有"（引擎自己的名称刷新就会造成这种状态），按类型既删不掉、再 AddExtra
    //     就当场弹断言。玩家实测：第一次改名成功，第二次改名必崩。
    //   * `ExtraTextDisplayData` 是 novtable 且没有默认构造，`new` 出来的对象里
    //     displayNameText / ownerQuest / textPairs 全是野指针（旧代码就这么干的）。
    // 返回值只表示"我们已经把改名请求交给引擎了"，**是否真的显示出来由调用方回读判定**。
    bool SetReferenceDisplayName(RE::TESObjectREFR* a_ref, const std::string& a_name)
    {
        if (!a_ref || a_name.empty() || !a_ref->extraList)
            return false;

        a_ref->extraList->SetOverrideName(a_name.c_str());

        // 兜底一：链里已有显示名条目 → **就地改字段**（不碰链表结构、不碰标志位，永远安全）
        bool haveEntry = false;
        if (auto* extra = a_ref->extraList->GetByType<RE::ExtraTextDisplayData>())
        {
            extra->displayName = a_name.c_str();
            extra->displayNameText = nullptr;
            extra->ownerQuest = nullptr;
            extra->textPairs = nullptr;
            extra->ownerInstance = RE::ExtraTextDisplayData::DisplayDataType::kCustomName;
            extra->customNameLength = static_cast<std::uint16_t>(a_name.size());
            haveEntry = true;
        }

        // 兜底二：链里没有、且**类型标志位是干净的**（说明链表状态自洽）时才新建一份。
        // 只在这种状态下 AddExtra 才不会踩上面的断言；标志位是脏的（有标志无条目）时
        // 就到此为止 —— 引擎那条路已经试过了，剩下的交给回读判定 + 日志。
        if (!haveEntry && !a_ref->extraList->HasType(RE::ExtraTextDisplayData::TYPE))
        {
            auto* extra = new RE::ExtraTextDisplayData();
            extra->displayName = a_name.c_str();
            extra->displayNameText = nullptr;
            extra->ownerQuest = nullptr;
            extra->textPairs = nullptr;
            extra->ownerInstance = RE::ExtraTextDisplayData::DisplayDataType::kCustomName;
            extra->customNameLength = static_cast<std::uint16_t>(a_name.size());
            a_ref->extraList->AddExtra(extra);   // 列表接管所有权，别自己 delete
        }
        return true;
    }

    void ApplyPendingRename(int a_req)
    {
        bool ok = false;
        std::string wanted;
        std::string before;
        REX::INFO("rename request {}: applying", a_req);

        auto* formIDVar = ReadControllerProperty("PendingRenameFormID");
        auto* nameVar = ReadControllerProperty("PendingRenameName");
        if (formIDVar && nameVar && formIDVar->is<std::int32_t>() && nameVar->is<RE::BSFixedString>())
        {
            const auto formID = static_cast<std::uint32_t>(RE::BSScript::get<std::int32_t>(*formIDVar));
            wanted = RE::BSScript::get<RE::BSFixedString>(*nameVar).c_str();
            if (auto* ref = RE::TESForm::GetFormByID<RE::TESObjectREFR>(formID))
            {
                // 判定标准是"显示名有没有变"，所以先把改之前的样子记下来
                const char* prev = ref->GetDisplayFullName();
                before = prev ? prev : "";

                ok = SetReferenceDisplayName(ref, wanted);
                if (ok)
                {
                    // 当场回读**只记日志、不判成败**：这个名字不一定立刻刷新，以前拿它当判据 →
                    // 会出现"其实改成功了却提示没生效"的假警报（玩家反馈：What's Your Name
                    // 早就卸载了，照样报它）。真正的判定放到 2 秒后，见 VerifyRename()。
                    const char* now = ref->GetDisplayFullName();
                    REX::INFO("rename: wrote '{}'; right after the write the game shows '{}'", wanted, now ? now : "?");
                    g_renameVerifyFormID = formID;
                    g_renameVerifyWanted = wanted;
                    g_renameVerifyBefore = before;
                    g_renameVerifyTicks  = kRenameVerifyTicks;
                }
            }
            else
            {
                REX::WARN("rename: form {:08X} not found", formID);
            }
        }
        else
        {
            REX::WARN("rename: pending properties unreadable");
        }

        if (!g_renameResultGlobal)
        {
            if (auto* handler = RE::TESDataHandler::GetSingleton())
                g_renameResultGlobal = handler->LookupForm<RE::TESGlobal>(kRenameResultGlobID, kHotkeyGlobPlugin);
        }
        if (!ok)
        {
            // 写入就失败（对象无效 / 属性读不到）：立刻给结论
            if (g_renameResultGlobal)
                g_renameResultGlobal->value = 2.0f;
            NotifyPapyrus("SMUI_Event", "renamed");
            return;
        }
        // 写成功时**不在这里通知**：显示名要过一会儿才刷新，现在报"已改名"有可能被
        // 2 秒后的复核推翻（弹两条自相矛盾的通知）。面板上已经有"已提交改名"的即时反馈了，
        // 这里就等 VerifyRename() 给出唯一的权威结论。
    }

    // 改名的延迟复核：写完 2 秒后再读显示名，还是老名字才算"显示不出来"。
    // 这一档的成因是**名字被优先级更高的来源固定**（任务别名等），跟"写入失败"是两回事，
    // 提示语因此不能写死某个 mod（以前写死了 What's Your Name，玩家卸载后还在报它）。
    // 结果码：1 = 写入成功且游戏显示的就是新名字；3 = 写入成功但游戏显示不出来。
    void VerifyRename()
    {
        if (g_renameVerifyTicks <= 0)
            return;
        if (--g_renameVerifyTicks > 0)
            return;

        auto* ref = RE::TESForm::GetFormByID<RE::TESObjectREFR>(g_renameVerifyFormID);
        const char* now = ref ? ref->GetDisplayFullName() : nullptr;
        // 判定标准是「显示名**变了没有**」，而不是「是否逐字等于我们写的那个字符串」。
        // 严格相等会把"改成功了但名字被别的东西装饰/加了前后缀"误判成失败 ——
        // 上一版就是这么误报了「哈莫尼」的（玩家实测：第一次改名给了一条"被别名固定"的错结论）。
        // 只有"改前改后一模一样"才说明这次改名没落到显示上。
        const bool  changed = now && !g_renameVerifyBefore.empty() && g_renameVerifyBefore != now;
        const bool  sameAsAsked = now && g_renameVerifyWanted == now;
        // 引用已经不在（读档 / 换场景）时判不了 —— 但改名请求本身已经交出去了，按成功报，
        // 别让玩家改完名什么提示都没有。
        const bool  ok = changed || sameAsAsked || !ref;
        REX::INFO("rename: {}s later: before '{}', asked '{}', the game shows '{}' -> {}",
            kRenameVerifyTicks / 4, g_renameVerifyBefore, g_renameVerifyWanted,
            now ? now : "(no reference)",
            ok ? "ok" : "the shown name did not change (fixed by a quest alias?)");
        g_renameVerifyWanted.clear();
        g_renameVerifyBefore.clear();

        if (g_renameResultGlobal)
            g_renameResultGlobal->value = ok ? 1.0f : 3.0f;
        NotifyPapyrus("SMUI_Event", "renamed");
    }

    void EnsureKeySpace()
    {
        if (g_keySpaceChecked)
            return;
        g_keySpaceChecked = true;

        std::uint32_t forward = 0;
        if (const auto* map = RE::ControlMap::GetSingleton())
        {
            forward = map->GetMappedKey("Forward", RE::INPUT_DEVICE::kKeyboard);
        }

        // 0x57 = 'W'（虚拟键码）→ 界面捕获的键码与游戏按键表是同一套；否则按扫描码换算
        g_vkSpace = (forward == 0x57);
        REX::INFO("key space check: Forward mapped to 0x{:X} -> hotkey treated as {}",
            forward, g_vkSpace ? "virtual key code" : "scan code");
    }

    void ApplyHotkeyVk(int a_vk)
    {
        EnsureKeySpace();

        if (a_vk <= 0)
        {
            g_hotkeyReady = false;
            REX::INFO("hotkey disabled (GLOB value {})", a_vk);
            return;
        }

        if (g_vkSpace)
        {
            g_hotkeyCode = static_cast<std::uint32_t>(a_vk);
        }
        else
        {
            const auto sc = MapVirtualKeyW(static_cast<UINT>(a_vk), MAPVK_VK_TO_VSC);
            g_hotkeyCode = sc ? sc : static_cast<std::uint32_t>(a_vk);
        }
        g_hotkeyReady = true;
        REX::INFO("hotkey set: VK 0x{:X} -> game key code 0x{:X}", a_vk, g_hotkeyCode);
    }

    // ---- 原生按键处理：热键按下 → 通知 Papyrus 开关面板 ----
    // 这一层替掉了原先 Papyrus 侧的一整套补丁：
    //   * 只有真实按键（不会再读到"假的按下"事件）；
    //   * QJustPressed 天然区分按下/重复，不需要去抖；
    //   * 游戏暂停时照样收得到（面板聚焦时也能用热键关）；
    //   * 不需要注册/反注册，没有残留；
    //   * ShouldHandleEvent 只对热键返回 true → 抢下这次按键，
    //     即使热键设成 E 这类游戏用键，也不会同时触发游戏动作。
    class HotkeyUser : public RE::BSInputEventUser
    {
    public:
        bool ShouldHandleEvent(const RE::InputEvent* a_event) override
        {
            if (!g_hotkeyReady || !a_event)
                return false;
            const auto* button = a_event->As<RE::ButtonEvent>();
            if (!button || button->device.get() != RE::INPUT_DEVICE::kKeyboard)
                return false;
            const auto code = static_cast<std::uint32_t>(button->QIDCode());
            if (code == g_hotkeyCode)
                return true;
            // Esc：**只在我们的面板可见时**接管（面板关着时 Esc 是玩家自己的暂停键，绝不碰）。
            // 对照 NODE.LITE：它的 Esc 也是原生层接的，所以按一次就关、不等轮询、也不会漏给游戏。
            return (code == kVkEscape) && g_panelVisible.load();
        }

        void OnButtonEvent(const RE::ButtonEvent* a_event) override
        {
            if (!g_hotkeyReady || !a_event)
                return;
            if (a_event->device.get() != RE::INPUT_DEVICE::kKeyboard)
                return;
            if (static_cast<std::uint32_t>(a_event->QIDCode()) != g_hotkeyCode)
                return;
            if (!a_event->QJustPressed())
                return;

            // Esc（面板可见时）：交给 Papyrus 关面板。原生层吃掉这次按键，游戏不会跟着暂停。
            if (static_cast<std::uint32_t>(a_event->QIDCode()) == kVkEscape)
            {
                REX::INFO("escape pressed while panel visible -> close");
                NotifyPapyrus("SMUI_Event", "esc");
                return;
            }

            // **只开不关**（对齐 NODE.LITE 的分工）：面板已经开着时热键什么都不做，
            // 关闭一律交给 Esc（页面 → Papyrus）。这样就没有"热键把自己关掉/开了又关"
            // 这一类时序问题（玩家反馈过"打开马上关上""关掉又自己打开"）。
            REX::INFO("hotkey pressed (code 0x{:X}, panel visible={})", g_hotkeyCode, g_panelVisible.load());
            NotifyPapyrus("SMUI_Event", "ready");   // 补发：Papyrus 可能没收到最早那次
            if (!g_panelVisible.load())
                NotifyPapyrus("SMUI_Event", "hotkey");
            else
                REX::INFO("panel already visible; hotkey does nothing (Esc closes)");
        }
    };

    HotkeyUser g_hotkeyUser;

    void EnsureHandlerRegistered()
    {
        if (g_handlerRegistered)
            return;
        auto* controls = RE::MenuControls::GetSingleton();
        if (!controls)
            return;
        controls->RegisterHandler(&g_hotkeyUser);
        g_handlerRegistered = true;
        REX::INFO("native input handler registered (hotkey)");
    }

    bool ViewBelongsToUs(const char* a_htmlPath, const char* a_owner)
    {
        const std::string_view html = a_htmlPath ? a_htmlPath : "";
        const std::string_view owner = a_owner ? a_owner : "";
        return html.find("SimpleSettlementManager") != std::string_view::npos ||
               owner.find("SimpleSettlementManager") != std::string_view::npos;
    }

    void ResolveView()
    {
        g_view = 0;
        g_api->EnumerateViewsEx(
            [](PrismaView a_view, const char* a_htmlPath, const char* a_owner, void*) {
                if (g_view == 0 && a_view != 0 && ViewBelongsToUs(a_htmlPath, a_owner))
                {
                    g_view = a_view;
                    REX::INFO("found panel view {} (path='{}', owner='{}')",
                        a_view,
                        a_htmlPath ? a_htmlPath : "?",
                        a_owner ? a_owner : "?");
                }
            },
            nullptr);

        // 只在"这个句柄还没配置过"时才配置。为什么必须要这道判断：
        // EnumerateViewsEx 的回调是异步的，g_view 要到下一次 tick 才真正保存下来，
        // 因此 Tick 里 g_view == 0 的判断每轮都成立 → 每 0.5 秒重设一次"视图接管 Esc"，
        // 反复扰动 PrismaUI 的焦点状态，导致 Esc 有时被吃掉（玩家反馈：要按两三次）。
        if (g_view == 0 || g_view == g_configuredView)
            return;
        g_configuredView = g_view;
        g_api->SetViewRole(g_view, ViewRole::kPanel);
        g_api->SetViewOwnsEscape(g_view, true);   // 让页面能收到 Esc（别再加 RegisterJSListener，那个会断桥）
        REX::INFO("view configured: owns escape + panel role (handle {})", g_view);
    }

    void Tick()
    {
        const auto now = std::chrono::steady_clock::now();
        if (now - g_lastTick < std::chrono::milliseconds(250))
            return;
        g_lastTick = now;

        // 原生按键处理器（不等 PrismaUI，热键与它无关）
        EnsureHandlerRegistered();

        // 每 0.25 秒读一次共享变量：Papyrus 改键后到这里生效
        // GoE 迁移 第 1 步：只读验证（已完成，留作自检）
        ProbePapyrusProperty();

        // GoE 迁移 第 2 步：改名执行端
        if (!g_renameReqGlobal)
        {
            if (auto* handler = RE::TESDataHandler::GetSingleton())
                g_renameReqGlobal = handler->LookupForm<RE::TESGlobal>(kRenameReqGlobID, kHotkeyGlobPlugin);
        }
        if (g_renameReqGlobal)
        {
            // 先把结果 GLOB 的指针也拿到 —— 它原本只在 ApplyPendingRename 里惰性查找，
            // 若在它之前就用（下面要用它的值判断"是否待处理"），第一次改名时它还是空指针，
            // 于是被当成"结果非 0"而跳过 → 改名整个失效（踩过）。
            if (!g_renameResultGlobal)
            {
                if (auto* handler = RE::TESDataHandler::GetSingleton())
                    g_renameResultGlobal = handler->LookupForm<RE::TESGlobal>(kRenameResultGlobID, kHotkeyGlobPlugin);
            }
            const int req = static_cast<int>(g_renameReqGlobal->value);
            if (req != g_lastRenameReq)
            {
                g_lastRenameReq = req;
                // **只有"待处理"才执行**：Papyrus 在发请求前会把 SM_RenameResult 写成 0，
                // 执行完再写 1/2。所以结果 != 0 就说明这是一条**上一局遗留的请求号**
                // （读档时计数器从存档里读回来，必然与我们启动时的初值不同）。
                // 以前用 `g_lastRenameReq >= 0 || req > 0` 判断，读档时恒成立 →
                // 每次读档都把上一次的改名重做一遍，玩家会看到"已改名为XX"的通知（玩家反馈）。
                int result = g_renameResultGlobal ? static_cast<int>(g_renameResultGlobal->value) : 0;
                if (result == 0)
                    ApplyPendingRename(req);
                else
                    REX::INFO("rename request {} seen at startup/load with result {} -> not re-applied", req, result);
            }
        }

        // 改名的延迟复核（2 秒后才发现"名字被别名压住"的情况）
        VerifyRename();

        // 先用本地缓存把热键装上（读档后立刻可用，不等 Papyrus 的读档回调）
        {
            static bool cacheLoaded = false;
            if (!cacheLoaded)
            {
                cacheLoaded = true;
                const int cached = ReadHotkeyCache();
                if (cached >= 0)
                {
                    ApplyHotkeyVk(cached);
                    g_lastGlobVk = cached;      // 与 GLOB 相等时不会重复应用
                    REX::INFO("hotkey restored from local cache: VK 0x{:X}", cached);
                }
            }
        }

        if (!g_hotkeyGlobal)
        {
            if (auto* handler = RE::TESDataHandler::GetSingleton())
                g_hotkeyGlobal = handler->LookupForm<RE::TESGlobal>(kHotkeyGlobID, kHotkeyGlobPlugin);
        }
        if (g_hotkeyGlobal)
        {
            const int vk = static_cast<int>(g_hotkeyGlobal->value);
            if (vk != g_lastGlobVk)
            {
                g_lastGlobVk = vk;
                ApplyHotkeyVk(vk);
                WriteHotkeyCache(vk);       // 记住这次的值，下次启动立刻可用
                // 第一次拿到有效热键时告诉 Papyrus"插件已接管热键"，
                // 它收到后就把自己那套 F4SE 注册与补丁停掉（避免两边同时处理）。
                if (g_hotkeyReady && !g_announced)
                {
                    g_announced = true;
                    NotifyPapyrus("SMUI_Event", "ready");
                    REX::INFO("announced 'ready' to papyrus (native hotkey active)");
                }
            }
        }

        if (!g_api)
            return;

        // 视图会被销毁重建（读档后我们就是销毁它再重建的），所以随时核对
        // 只在"还没有视图"时认领。不能用 IsValid 当条件：它对 Papyrus 建的视图总返回 false，
        // 会每 0.5 秒重复认领并重复配置一次（日志里成片的 view configured 就是这么来的）。
        // 视图被销毁（读档）时 OnMessage(kPostLoadGame) 会把 g_view 清 0，靠它判断就够。
        if (g_view == 0)
        {
            if (now - g_lastResolve >= kResolveInterval)
            {
                g_lastResolve = now;
                ResolveView();
            }
        }

        // 面板状态从 GLOB 读（Papyrus 开/关时写）——**不再猜**。
        // 之前用 IsHidden / IsAnyPanelVisible / HasFocus 三个信号判断，日志里错了一半：
        // 面板还画着但已失焦时三个都给 false，于是暂停菜单不压、热键判断也跟着错。
        if (!g_panelStateGlobal)
        {
            if (auto* handler = RE::TESDataHandler::GetSingleton())
                g_panelStateGlobal = handler->LookupForm<RE::TESGlobal>(kPanelStateGlobID, kHotkeyGlobPlugin);
        }
        if (g_panelStateGlobal)
            g_panelOpen = (static_cast<int>(g_panelStateGlobal->value) != 0);

        // 注：这里原先有一个状态自愈兜底（用 IsValid / IsHidden / HasFocus 判断面板是否可见），
        // 但那三个信号对 Papyrus 创建的视图都不可靠（IsValid 恒为 false），
        // 结果是面板打开约 0.4 秒后被误判成已关并自动关闭（玩家反馈的一秒内自动退出）。
        // 已删除；Esc 的关闭现在由页面正常路径负责（SetViewOwnsEscape 生效后页面能收到 Esc）。
        const bool ourFocus = g_panelOpen;
        const bool ourVisible = g_panelOpen;
        const bool anyPanel = g_panelOpen;

        if (ourFocus)
        {
            g_graceUntilMs.store(std::chrono::duration_cast<std::chrono::milliseconds>(
                                     std::chrono::steady_clock::now().time_since_epoch())
                                     .count() +
                                 kGraceMs);
        }
        g_panelVisible.store(anyPanel || ourFocus || ourVisible);

        // 第一次用，或正在用的时候定期重装判定函数（防止被后加载的 mod 顶掉）
        if ((ourFocus || ourVisible) && (!g_suppressionReady || now - g_lastInstall > kReinstallEvery))
        {
            g_api->SuppressVanillaMenuIf("PauseMenu", &SuppressPredicate);
            if (!g_suppressionReady)
            {
                g_suppressionReady = true;
                REX::INFO("pause-menu suppression installed (panel focus)");
            }
            g_lastInstall = now;
        }
    }

    void OnMessage(F4SE::MessagingInterface::Message* a_msg)
    {
        if (!a_msg)
            return;

        switch (a_msg->type)
        {
        case F4SE::MessagingInterface::kPostLoadGame:
        case F4SE::MessagingInterface::kNewGame:
            g_view = 0;
            g_panelVisible.store(false);
            g_graceUntilMs.store(0);
            REX::INFO("game loaded, panel view will be re-resolved");
            break;
        default:
            break;
        }
    }
}

namespace PanelWatcher
{
    void Install()
    {
        // 先拿 VM 指针（给 Papyrus 发外部事件要用）
        if (const auto papyrus = F4SE::GetPapyrusInterface())
        {
            if (!papyrus->Register(&PapyrusRegister))
                spdlog::error("failed to obtain papyrus VM");
        }

        auto* api = RequestPluginAPI<IVPrismaUI10>();
        if (!api)
        {
            REX::WARN("PrismaUI API not available; pause-menu suppression disabled");
            return;
        }

        g_api = api;
        REX::INFO("PrismaUI API acquired (interface V10)");

        const auto tasks = F4SE::GetTaskInterface();
        if (!tasks)
        {
            // 别用 REX::ERROR —— Windows 的 wingdi.h 把 ERROR 定义成 0，
            // PrismaUI 的头文件会拉进 Windows.h，REX::ERROR 会展开成 REX::0。
            spdlog::error("no task interface; panel watcher will not run");
            return;
        }
        tasks->AddTaskPermanent([]() { Tick(); });

        if (const auto messaging = F4SE::GetMessagingInterface())
            messaging->RegisterListener(&OnMessage);
    }
}
