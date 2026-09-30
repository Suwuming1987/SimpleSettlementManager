-- SimpleSettlementManager 的配套 F4SE 插件。
--
-- 只做一件 Papyrus 做不到的事：把"面板聚焦期间的原版暂停菜单"压住。
-- 背景（对照 NODE.LITE 的实现）：
--   * PrismaUI 的 C++ API 提供 SuppressVanillaMenuIf("PauseMenu", 判定函数) 与
--     SetViewOwnsEscape(view, true)，但这两样**只有 C++ 侧能调**，Papyrus 那层没有。
--   * 没有它们时，玩家按 Esc 关面板的同一个 Esc 会漏给游戏，游戏就打开暂停菜单
--     （只能靠 Papyrus 事后把菜单关掉，会闪一下）。
--   * 有了它们：面板聚焦期间游戏根本不会打开暂停菜单，Esc 只让面板自己关掉。
--
-- 工具链与 AutoDisarm 项目一致（portable xmake + vendored CommonLibF4），
-- 目标平台固定 windows/x64/msvc，构建命令见 tools/build_plugin.sh。

set_plat("windows")
set_arch("x64")
set_toolchains("msvc")

includes("lib/commonlibf4")

set_project("SimpleSettlementManagerUI")
set_version("0.8.7")
set_license("GPL-3.0")
set_languages("c++23")
set_warnings("allextra")

add_rules("mode.debug", "mode.releasedbg")

target("SimpleSettlementManagerUI")
    add_rules("commonlibf4.plugin", {
        name = "SimpleSettlementManagerUI",
        author = "suwum",
        description = "Keeps the vanilla pause menu out of the way while the SimpleSettlementManager panel is focused",

        -- 0.7.4 = 1.11.137（AE 线的第一个运行时）：同一份 DLL 覆盖整条 AE 线
        -- （1.11.137 - 1.11.240，本机是 0.7.9 / 1.11.240）。
        xse_minimum = "0.7.4"
    })

    add_files("src/**.cpp")
    add_headerfiles("src/**.h")
    add_includedirs("src")
    set_pcxxheader("src/PCH.h")

    -- 日志里有中文，且要按 UTF-8 写进日志文件（否则中文 Windows 上按 GBK 解会乱码）
    set_encodings("utf-8")

    -- dist/ 是生成物：DLL + mod/ 里的文件合成一个可直接放进 MO2 的 mod 文件夹
    after_build(function (target)
        local project = os.projectdir()
        local dest = path.join(project, "dist")
        os.rm(dest)
        os.mkdir(path.join(dest, "F4SE", "Plugins"))
        os.cp(target:targetfile(), path.join(dest, "F4SE", "Plugins"))
        for _, file in ipairs(os.files(path.join(project, "mod", "**"))) do
            local relative = path.relative(file, path.join(project, "mod"))
            local out = path.join(dest, relative)
            os.mkdir(path.directory(out))
            os.cp(file, out)
        end
    end)
