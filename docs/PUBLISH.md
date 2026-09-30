# 发布流程（GitHub + 发布页）

给自己用的检查单，按顺序做。

## 0. 一次性：仓库设置

- [ ] GitHub 上新建仓库（公开、名字用 `SimpleSettlementManager`），**不要**勾选初始化
      README / .gitignore / LICENSE（本地已经有了）
- [ ] 推送时会弹出浏览器登录（本机已配 Git Credential Manager）—— 不需要装 gh，也没配 SSH
- [ ] 本地加远端并推：
      `git remote add origin https://github.com/Suwuming1987/SimpleSettlementManager.git && git push -u origin main`
- [ ] 仓库设置：简介一句话（`A holotape settlement/settler manager for Fallout 4`）、
      Topics：`fallout4` `f4se` `papyrus` `prismaui` `settlement`
- [ ] 确认 `vendor/`、`backups/`、`dist/`、`tools/local.conf` 没被推上去（`.gitignore` 已挡，
      但第一次 `git add -A` 后请 `git status --short` 扫一眼）
- [ ] `git submodule` 生效：别人 clone 要用 `--recursive`，README 里已写明

## 1. 每次发布

- [ ] 改版本号：**只改一处** —— `src/PrismaUI/views/SimpleSettlementManager/index.html` 设置页
      `about` 文案里的「版本 x.y.z」（`tools/package.sh` 从这里取，写进包名和包内 README）
- [ ] 顺手把 `tools/meta.ini` 的 `version` / `newestVersion` 一起改（MO2 显示用）
- [ ] 在游戏里过一遍这次的改动（**没验过的改动不要发**）
- [ ] `bash tools/package.sh` → 产出 `dist/release/SimpleSettlementManager-<版本>.zip`
      - 脚本会自己复查 ESL 标志，缺了会直接中止
      - 包里只有可运行文件：esp / .pex / 界面 / 可选插件 DLL / README.md（**无源码**，源码在仓库里）
- [ ] 提交并打 tag：`git add -A && git commit -m "release: 0.8.7" && git tag -a v0.8.7 -m "0.8.7"`
- [ ] `git push && git push --tags`
- [ ] GitHub → Releases → 新建，选 tag `v0.8.7`，把 zip 作为附件上传
- [ ] 发布说明用 `git log --oneline v0.8.6..v0.8.7` 里的条目整理（写玩家看得懂的话，不要 commit 原文）

## 2. GPL 合规（必须做，不是可选项）

插件 DLL 链接了 GPL-3.0 的 CommonLibF4，所以：

- [ ] **每个发二进制的页面都要给出源码地址**（仓库地址写进 Nexus 描述、GitHub Release 说明、
      以及包内 README 里已经写了一句"源码见发布页"）
- [ ] 发布页标注许可 = GPL-3.0
- [ ] 知道这一点：GPL **允许**别人再分发你的包（包括传到别处），只要他们保留许可并给出源码 ——
      所以"禁止转载"是写不了的，别在描述里承诺做不到的事

## 3. 发布页（Nexus 之类）必备内容

- 依赖（缺一不可）：Fallout 4 AE 1.11.137–1.11.240、F4SE 0.7.4+、**PrismaUI F4 2.2.0+**、
  Workshop Framework；明确写"不需要 Sim Settlements 2"
- 安装：MO2/Vortex 直接装 zip；手动解压到 `Fallout 4/Data/`
- 可选项说明：`F4SE/Plugins/SimpleSettlementManagerUI.dll` 只负责压住暂停菜单，删掉不影响功能
- 已知限制（照抄包内 README）：明细只对当前所在据点实时、被别名固定名字的居民改不了显示名、
  改名会写进存档
- 兼容性提醒：会改居民的岗位/床位，和别的"自动分配/床位管理"类 mod 同时用可能互相覆盖 ——
  建议提示玩家二选一或先在存档副本上试

## 4. 发布文案草稿

**中文**

> 据点管理终端 —— 全息卡带式的据点与居民管理。一屏看完所有据点的人口 / 床位 / 食物 / 水 / 电 /
> 防御 / 缺人，供应网络自动分组合计；按职业分类看居民，能改名、召唤、解除岗位、迁居、开除；
> 岗位页可以一键填补空岗（用最少的人）。不需要 Sim Settlements 2。
> 需要 F4SE、PrismaUI F4 2.2.0+、Workshop Framework。

**English**

> Simple Settlement Manager — a holotape-based settlement & settler manager. See every settlement's
> population, beds, food, water, power and defense on one screen with supply networks grouped and
> totalled; browse residents by job, rename/summon/unassign/move/dismiss them; fill vacant jobs with
> the fewest settlers. No Sim Settlements 2 required. Requires F4SE, PrismaUI F4 2.2.0+ and
> Workshop Framework.
