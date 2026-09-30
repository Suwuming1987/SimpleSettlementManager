#pragma once

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN

#include <RE/Fallout.h>
#include <F4SE/F4SE.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string_view>

// 只做一件事的插件：看住 PrismaUI 的面板焦点，聚焦期间压住原版暂停菜单。
// 详细原因见 xmake.lua 顶部与 PanelWatcher.cpp。
