#include "PCH.h"

#include "PanelWatcher.h"

#include <spdlog/spdlog.h>

F4SE_PLUGIN_LOAD(const F4SE::LoadInterface* a_f4se)
{
    F4SE::Init(a_f4se, { .logLevel = REX::ELogLevel::Info, .logName = "SimpleSettlementManagerUI" });

    REX::INFO("SimpleSettlementManagerUI {} loading", F4SE::GetPluginVersion().string());

    PanelWatcher::Install();

    return true;
}
