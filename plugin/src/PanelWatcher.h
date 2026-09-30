#pragma once

namespace PanelWatcher
{
    // 安装：注册每帧任务（内部限频）与 F4SE 消息监听，用来盯着 PrismaUI 的面板焦点。
    // 找不到 PrismaUI 时会安静地什么都不做 —— 那样就退回 Papyrus 侧的事后清理，功能不受影响。
    void Install();
}
