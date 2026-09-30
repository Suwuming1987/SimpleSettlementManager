# 去掉 Garden of Eden 依赖（改名改由配套插件实现）

目标：`SetDisplayName` 与读显示名都搬进 `SimpleSettlementManagerUI.dll`，GoE 从"必需"变"完全不需要"。

## 为什么现在卡在"通道"上

Papyrus 目前**无法主动调用插件**：
* 这份 CommonLibF4 里 `IVirtualMachine` **没有 `RegisterFunction`**（那是 SKSE 的写法，实测编译期就报错）；
* GLOB 只能传浮点数，传不了字符串；
* 走网页的 JS 回调（`RegisterJSListener`）会**断 PrismaUI 的双向通道**（已实测，禁止再用）。

所以反过来做：**插件主动去读 Papyrus 的属性**。

## 已核实的 API 线索（都在 vendor 的 CommonLibF4 里）

* `RE::GameVM::GetSingleton()->GetVM()` → `IVirtualMachine*`（`BSScriptUtil.h` 里的 helper 就是这么拿的）。
* `vm->GetObjectHandlePolicy().GetHandleForObject(typeID, ptr)` → 取某个对象（任务/表单）的句柄；
  `EmptyHandle()` 判断失败。
* `vm->FindBoundObject(handle, scriptName, false, object, false)` → 拿到该脚本的 `Object`。
* `vm->GetScriptObjectType(BSFixedString("SimpleSettlementManager:ControllerQuest"), typeInfo)` → 脚本类型信息。
* 还需要确认的一步：`Object` 上的属性读写接口名（`GetProperty`/`SetProperty` 之类），
  去 `RE/B/BSScript_Object.h`（或 `Object.h`）里找；找不到就用 `ObjectTypeInfo` + `Property` 结构自己取。

## 实施顺序（每步单独编译 + 实机验证，一步只引入一个新机制）

1. **只读验证**：插件读一个已知的 Papyrus 属性（例如 `HotkeyCode`）并写进日志。
   日志里数值对 → 通道成立。
2. **改名搬迁**：Papyrus 的 `DoRename` 改成"把 待改名居民 + 新名字 存进两个脚本属性 +
   把 GLOB `SM_RenameReq` 的请求号 +1"；插件看到请求号变化 → 读那两个属性 → 写显示名 →
   回读 `GetDisplayFullName()` 确认（回读与"没生效"提示逻辑已有，直接复用）。
   写显示名的原生实现：`ExtraTextDisplayData`（地址库里有 `ExtraTextDisplayData` 与
   `SetDisplayNameFromInstanceData` 两个 ID 可参考）。
3. **读名字搬迁**：`ActorName()` 改为优先用插件提供的 `GetDisplayFullName()`
   （去掉对 `ObjectReference.GetDisplayName()` 那行"F4SE 基础脚本补丁"的依赖）。
4. 验证通过后：删除关于行里的 "改名需要 Garden of Eden"，并从 `vendor/gardenofeden/` 移除依赖
   （`SimpleSettlementManager.ppj` 的 Import 也删掉）。

## 风险与回退

* 第 2 步是**纯数据写入**（不碰 PrismaUI 的视图/焦点/输入），与之前把桥弄断的那些改动无关，风险低。
* 但仍是新机制：**先做第 1 步**，只在日志里验证通道；通道不通就不动第 2 步（GoE 继续用，功能不受影响）。
* 每一步失败都直接回退到上一个能编译能跑的状态；改名前后的行为对比可依靠现有的"回读确认 + 通知"。

## 第 1 步的实现线索（已核实到这一步，下次从这里继续）

**已经拿到确切签名的：**

```cpp
// 同步读属性（不需要回调，最适合第 1 步）
// RE/B/BSScript_Object.h:46
Variable* Object::GetProperty(const BSFixedString& a_name);
// 异步版本（备选，要 IStackCallbackFunctor）
// RE/B/BSScript_IVirtualMachine.h:83-84
virtual bool SetPropertyValue(const BSTSmartPointer<Object>& a_self, const char* a_propName,
                              const Variable& a_newValue, const BSTSmartPointer<IStackCallbackFunctor>& cb) = 0;
virtual bool GetPropertyValue(const BSTSmartPointer<Object>& a_self, const char* a_propName,
                              const BSTSmartPointer<IStackCallbackFunctor>& cb) = 0;
// 句柄：RE/B/BSScriptUtil.h:352-366 有 GetVMTypeID<T>()；用法见同文件 533-600 的 helper
//   auto& policy = vm->GetObjectHandlePolicy();
//   auto handle = policy.GetHandleForObject(GetVMTypeID<RE::TESQuest>(), quest);
//   if (handle != policy.EmptyHandle()) vm->FindBoundObject(handle, "SimpleSettlementManager:ControllerQuest", false, object, false);
```

**还需要确认的两个名字**（确认后第 1 步的代码就能直接写）：

1. `BSScript::Variable` 的**取值接口**：`RE/B/BSScript_Variable.h:180` 有 `GetType()`；
   同文件里找 `GetSInt` / `GetFloat` / `GetString` / `Unpack<T>` 之类（拿 int 属性用哪个）。
2. `ObjectHandlePolicy` 的**头文件名**：不在 `B/BSScript_ObjectHandlePolicy.h`
   （该文件不存在），去 `ls RE/B | grep -i Handle` 找（可能是 `BSScript_ObjectHandlePolicy` 之外的拼写，
   或定义在 `BSScript_Internal_VirtualMachine.h` 里）。
3. 顺带确认 `GetVMTypeID<RE::TESQuest>()` 对**任务**是否给对 typeID（表单类句柄按 FormType 分；
   若不支持，就用 `FindBoundObject` 的另一种重载或先 `GetScriptObjectType`）。

**第 1 步的验收**：插件日志出现一行形如 `papyrus property HotkeyCode = 121`，
且与游戏里设置页显示的热键一致 → 通道成立，再做第 2 步（写显示名）。

## 进展（第 1 步已通过实机验证）

```
[14:04:43.105] probe OK: papyrus property HotkeyCode = 121
```

⇒ **"插件读 Papyrus 属性"的通道成立**（`Object::GetProperty` + `GetVMTypeID<TESQuest>` + `FindBoundObject`
这套按预期工作）。第 2 步（插件写显示名替掉 GoE）可以放心做。

第 2 步要查的下一个 API：写显示名要碰 `ExtraTextDisplayData`（地址库里有
`ExtraTextDisplayData` 与 `SetDisplayNameFromInstanceData` 两个 ID 可参考）。
去 `RE/E/ExtraTextDisplayData.h` 看怎么创建/更新那个额外数据，以及 `TESObjectREFR` 上
有没有现成的 `SetDisplayName`/`GetDisplayFullName` 可配合回读。

顺带修掉一个日志刷屏：插件原先用 `IsValid(view)` 判断是否要重新认领视图，
而它对 Papyrus 建的视图总返回 false → 每 0.5 秒重复配置一次。
现在只在 `g_view == 0`（读档时会被清 0）或句柄变化时才配置。

### 第 2 步的 API 已核实（照这个写即可）

**写显示名**（等价于 GoE 的 `SetDisplayName`）——`RE/E/ExtraTextDisplayData.h`：

```cpp
auto* extra = ref->extraList.GetByType<RE::ExtraTextDisplayData>();   // 没有就新建并 Add 进 extraList
extra->displayName       = a_name;                                    // BSFixedStringCS，可直接赋值
extra->ownerInstance     = RE::ExtraTextDisplayData::DisplayDataType::kCustomName;  // = -2，表示"自定义名"
extra->customNameLength  = static_cast<std::uint16_t>(strlen(a_name));
```

**回读**（插件侧，去掉对 GetDisplayName 那行脚本补丁的依赖）：`RE/T/TESObjectREFR.h:327`
`const char* TESObjectREFR::GetDisplayFullName()`。

**还差一个名字**（下次先查）：`ExtraList` 上添加新建额外数据的接口名（`Add(BSExtraData*)` 还是 `AddExtra`），
以及它的所有权语义（ExtraList 接管释放，插件不要自己 delete）。

### 第 2 步的接线（Papyrus ↔ 插件）

* 新 GLOB：`SM_RenameReq`（请求号，Papyrus 每次改名 +1）、`SM_RenameResult`（插件写：0 待处理 / 1 成功 / 2 失败）。
* Papyrus `DoRename`：把 `PendingRenameActor` / `PendingRenameName` 存进两个脚本属性 → 请求号 +1 → 结果置 0。
* 插件：请求号变化 → 用**已验证的通道**读那两个属性（`Object::GetProperty` + `get<T>`；
  字符串用 `get<BSFixedString>`）→ 写显示名 → 回读 `GetDisplayFullName()` → 写结果 GLOB →
  发外部事件 `"renamed"`。
* Papyrus 收到 `"renamed"` → 读结果 GLOB → 用自己存的名字发通知（成功/失败提示逻辑复用现有那两条）。
* 完成后：删关于行的 GoE 说明 + 从 `SimpleSettlementManager.ppj` 移除 `vendor/gardenofeden` 的 Import。
