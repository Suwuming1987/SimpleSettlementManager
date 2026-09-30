@echo off
rem Build the SimpleSettlementManagerUI F4SE plugin (run from cmd, not git-bash).
rem Why cmd: a git-bash shell makes xmake inherit MSYS2 and pick the mingw platform.
cd /d "%~dp0.."
tools\xmake\xmake.exe f -p windows -a x64 --toolchain=msvc -y
tools\xmake\xmake.exe build -y
