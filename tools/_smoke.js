// 冒烟测试：用桩件把界面脚本跑起来，喂一份假的 Papyrus 数据，
// 检查 S 行字段位移、E 行解析、供应网络并查集、总览/据点页渲染是否合理。
// 用法：node tools/_smoke.js
const fs = require('fs'), vm = require('vm'), path = require('path');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'src/PrismaUI/views/SimpleSettlementManager/index.html'), 'utf8');
const code = html.match(/<script[^>]*>([\s\S]*?)<\/script>/g).pop().replace(/^<script[^>]*>|<\/script>$/g, '');

const nodes = {};
const docListeners = {};          // type -> [handler]，测试里手动触发
function el(id) {
  if (!nodes[id]) nodes[id] = {
    id: id, innerHTML: "", textContent: "", className: "", lang: "",
    style: { setProperty() {} }, setAttribute() {}, getAttribute: () => null, removeAttribute() {},
    querySelector: () => null, querySelectorAll: () => [], childNodes: [],
    appendChild() {}, addEventListener() {}, contains: () => false,
  };
  return nodes[id];
}
const ctx = {
  console,
  window: (function () {
    // emit 的两个参数都要记下来（改名靠第二个参数），记在 window 上方便断言
    const w = { addEventListener() {}, setTimeout: () => 0, innerHeight: 1080, innerWidth: 1920 };
    w.prisma = { emit(name, data) { (w.__emitted = w.__emitted || []).push([name, data]); } };
    return w;
  })(),
  document: {
    getElementById: el, querySelector: () => null, querySelectorAll: () => [],
    documentElement: el("html"), createElement: () => el("tmp"),
    createTreeWalker: () => ({ nextNode: () => null }),
    addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
  },
  NodeFilter: { SHOW_TEXT: 4 },
  localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  setTimeout: () => 0, clearTimeout() {}, JSON, Math, isNaN, parseFloat, parseInt,
};
ctx.globalThis = ctx;
vm.createContext(ctx);
vm.runInContext(code, ctx);

const payload = [
  "P|pong",
  "H|庇护山丘",
  "K|121",
  "S|1|庇护山丘|7|3|12|20|5|10|7|0|0|0|80|1|9|2",
  "S|2|红火箭加油站|2|1|0|0|0|0|2|2|0|0|70|1|1|1",
  "S|3|十松庄|4|0|6|3|0|4|4|0|0|0|75|0|30|5",
  "S|4|塔芬顿船屋|3|3|0|0|0|0|0|3|3|3|50|0|-1|-1",
  "E|1|2",
  "E|3|2",
  "W|司特|0| |111|0|0|0|3-4-5-6-7-2-1",           // 男：无业、无床
  "W|朱恩|0| |001|1|1|0|1-2-3-4-5-6-7",           // 女：无业、有床
  "W|凯特|2| |001|1|1|7|7-6-5-4-3-2-1",           // 女：队友
  "W|派普|1|铃薯|111|1|0|1|2-2-2-2-2-2-2|1",        // 男：农民
  "W|居民甲|1|玉米|111|1|0|1|5-5-5-5-5-5-5|0",      // 农民
  "W|守卫乙|1|机枪塔|111|1|0|3|4-4-4-4-4-4-4|1",    // 守卫
  "W|商贩丙|1|贸易摊位|111|1|0|4|6-6-6-6-6-6-6|0",  // 商人
  "W|搬运丁|3|→ 红火箭加油站|111|1|1|5|1-1-1-1-1-1-1",   // 搬运工
  "G|铃薯|1|派普", "G|玉米|1|居民甲", "G|铃薯|1|", "G|铃薯|1|",
  "G|机枪塔|3|守卫乙", "G|贸易摊位|4|商贩丙", "G|守卫岗哨|3|", "G|拾荒台|2|",
  "B|7|5|2",
  "J|贸易摊位",
].join("\n");

ctx.smOnData(payload);
const st = ctx.state;
console.log("据点：");
st.settlements.forEach(s => console.log("  id=%d %s 人口=%d 食=%d 水=%d 床=%d 缺食=%d 已加载=%s",
  s.id, s.name, s.pop, s.food, s.water, s.beds, s.missFood, s.loaded));
console.log("当前据点：%s   边：%s   热键：%d", st.here, JSON.stringify(st.edges), st.hotkeyInGame);

const nets = ctx.supplyNetworks();
console.log("供应网络 %d 个：", nets.length);
nets.forEach(n => console.log("  成员=%s  人数=%d 食物=%d 供水=%d",
  n.members.map(m => m.name).join("+"), n.pop, n.food, n.water));

// 渲染检查：总览应含合计段，据点页选中"红火箭"时应显示明细不可用提示
ctx.go("overview");
const ov = el("page-overview").innerHTML;
console.log("总览含『供应网络合计』：%s  含成员列表：%s",
  ov.indexOf("供应网络合计") >= 0, ov.indexOf("庇护山丘、红火箭加油站、十松庄") >= 0);
console.log("总览不再出现『已在场』：%s", ov.indexOf("已在场") < 0);
console.log("总览含『未接入供应网』并列出孤立据点：%s",
  ov.indexOf("未接入供应网的据点") >= 0 && ov.indexOf("塔芬顿船屋") >= 0);

// 供应网络按层级显示：网络标题（成员名单 + 合计）→ 每个成员一行数值；未接入的据点单列
const netRows = (ov.match(/class="scard in-net"/g) || []).length;
console.log("网络标题含成员名单：%s", ov.indexOf("网络 1：庇护山丘、红火箭加油站、十松庄") >= 0);
console.log("每个据点一行完整明细（3 成员 + 1 未接入 = 4 行）：%s（实际 %d 行）",
  netRows === 4, netRows);
// 详情行里要有完整数值（人口/食物/水/电/防/床/幸福）与缺食之类标记 —— 这正是玩家要求"搬到上面"的那份
const okRow = /庇护山丘[\s\S]{0,240}?人口 7[\s\S]{0,200}?幸福 80/.test(ov);
console.log("明细行含完整数值：%s", okRow);
console.log("缺食/缺水/无床等标记也搬进了明细行：%s",
  /塔芬顿船屋[\s\S]{0,260}?缺食 3/.test(ov));
console.log("不再有重复的下方平铺列表：%s",
  ov.indexOf('class="scard"') < 0);

// 状态圆点看"整个网络补不补得上"：网络总产量 ≥ 网络总需求 → 黄；否则（含未接入、缺床）→ 红
const netRowEls = ov.match(/<div class="scard in-net"[\s\S]*?<\/div>/g) || [];
const rowOf = n => netRowEls.find(x => x.indexOf(n) >= 0) || "";
const rr = rowOf("红火箭加油站"), tf = rowOf("塔芬顿船屋"), sanc = rowOf("庇护山丘");
console.log("网络能补上的短缺 → 黄（圆点与右侧文字都黄）：%s",
  /dot warn/.test(rr) && /flags warn/.test(rr) && /缺食/.test(rr));
console.log("未接入网络（没人能补）→ 红：%s",
  /dot bad/.test(tf) && /flags bad/.test(tf));
console.log("没有短缺 → 绿：%s", /dot ok/.test(sanc));

// 岗位数：在据点里数到过就显示（并可与人口比较标"缺人"）；没去过（-1）不显示、不猜
console.log("明细行显示工位数与需人数：%s", /工位 9/.test(sanc) && /需 2 人/.test(sanc));
// 缺人用"需人数"而不是岗位数：十松庄 30 个岗位只需 5 人，人口 4 → 缺 1（按一人一岗会算成 26）
const shi = rowOf("十松庄");
console.log("缺人按产能折算（30 岗 / 每人 6 = 需 5 人，人口 4 → 缺人 1）：%s",
  /缺人 1/.test(shi) && /需 5 人/.test(shi));
console.log("人口够的不标缺人：%s", !/缺人/.test(sanc) && !/缺人/.test(rr));
console.log("没数过工位的据点不显示（-1）：%s", !/工位/.test(tf) && !/缺人/.test(tf));

// 就地展开（原据点页已并入总览）
// 展开/收起靠 expandSettle 切换，测试里不要去改 state.selSettle（那会让"再点一次收起"的条件提前成立）
function expandTo(i) {
  if (!(ctx.state.expanded && ctx.state.selSettle === i)) ctx.expandSettle(i);
}
expandTo(1);                      // 红火箭（非当前据点）
const sp = el("page-overview").innerHTML;
console.log("展开非当前据点：先提示还没有暂存数据：%s  并且向游戏请求了暂存明细：%s  不串当前据点数据：%s",
  sp.indexOf("走过去看一次") >= 0,
  (ctx.window.__emitted || []).some(function (x) { return String(x[0]).indexOf("smDetail") === 0; }),
  sp.indexOf("床位总数") < 0);

// 游戏回推"暂存明细"（CD| 行）后，展开块要显示这份暂存数据 + 明确标注
ctx.smOnData('CD|2\nW|居民甲|1|铃薯|111|1|0|1|4-4-4-4-4-4-4\nW|居民乙|0| |111|0|1|0|5-5-5-5-5-5-5\nB|4|2|2\nJ|铃薯\nJ|玉米');
const spc = el("page-overview").innerHTML;
console.log("暂存明细也带居民概况：%s", /居民（2）/.test(spc) && /农民 1/.test(spc) && /无业 1/.test(spc));
console.log("暂存明细渲染：含标注=%s 含床位段=%s 含空岗=%s 不串实时数据=%s",
  spc.indexOf("上次在该据点") >= 0, spc.indexOf("床位总数") >= 0,
  spc.indexOf("铃薯") >= 0, spc.indexOf("贸易摊位") < 0);

expandTo(0);                      // 庇护山丘（当前据点）
const sp2 = el("page-overview").innerHTML;
console.log("展开当前据点：含居民概况=%s（农民 2 队友 1 无业 3 之类）", /居民（8）/.test(sp2) && /农民 2/.test(sp2));
console.log("展开当前据点：含床位段=%s 含全部工位（有人/空缺都列出）=%s 标出『当前所在』=%s",
  sp2.indexOf("床位总数") >= 0,
  sp2.indexOf("jchip taken") >= 0 && sp2.indexOf("jchip vacant") >= 0 &&
  sp2.indexOf("铃薯") >= 0 && sp2.indexOf("贸易摊位") >= 0,
  sp2.indexOf("（当前所在）") >= 0);
// 工位段落把"有人 / 空缺"的数目写进标题，并且两类都给了颜色类
console.log("工位标题带 已有人/空缺 计数：%s", /工位（\d+：已有人 \d+ \/ 空缺 \d+）/.test(sp2));
// 无业居民的 jobs 是"一个空格"，不能被当成工位名（实测出现过名字为空的幽灵标签）
console.log("工位标签没有空白名字的幽灵条目：%s（有人工位数 = %d）",
  /jchip taken">\s*×/.test(sp2) === false && (sp2.match(/jchip taken/g) || []).length === 4,
  (sp2.match(/jchip taken/g) || []).length);
// 两个按钮已经删掉（岗位页才是操作的地方）
console.log("据点详情不再有那两个批量按钮：%s",
  sp2.indexOf("一键填补空岗") < 0 && sp2.indexOf("解除本据点全部岗位") < 0);
ctx.expandSettle(0);              // 再点一次收起
console.log("再点一次收起：%s", el("page-overview").innerHTML.indexOf("床位总数") < 0);
console.log("导航不再有『据点』页：%s", ctx.state.page !== "settle");

// 性别：W 行末的新字段要解析出来，并显示在居民详情里
const byName = n => ctx.state.settlers.find(s => s.name === n);
console.log("性别解析：%s（%d 位居民；凯特=女、司特=男、朱恩=女）",
  ctx.state.settlers.length === 8 && ctx.state.settlers.every(s => s.sex === 0 || s.sex === 1) &&
  byName("凯特").sex === 1 && byName("司特").sex === 0 && byName("朱恩").sex === 1,
  ctx.state.settlers.length);
// 职业分类（kind）：数值对应 Papyrus 的 KIND_*，居民页的标签栏与「职业状态」按它走
console.log("职业分类解析：%s（农民×2 / 守卫 / 商人 / 搬运工 / 队友 / 无业×2）",
  byName("派普").kind === 1 && byName("居民甲").kind === 1 && byName("守卫乙").kind === 3 &&
  byName("商贩丙").kind === 4 && byName("搬运丁").kind === 5 && byName("凯特").kind === 7 &&
  byName("司特").kind === 0 && byName("朱恩").kind === 0);
ctx.state.pickedSettler = -1;
ctx.go("people");
const pplAll = el("page-people").innerHTML;
const pplTabs = ["全部", "无业", "农民", "拾荒者", "守卫", "商人", "运输", "工人", "队友", "无床"];
console.log("居民页含职业标签栏（%d 个标签都在）：%s", pplTabs.length,
  pplTabs.every(x => pplAll.indexOf(">" + x + "<") >= 0));
// 行内只放「名字 + 职业状态」：按钮与岗位文字都归右侧详情（玩家要求，别再加回行里）
const rowHits = pplAll.match(/<div class="row[^>]*>[\s\S]*?<\/div>/g) || [];
const rowHtml = rowHits.join("");
console.log("行内只有名字+职业状态（%d 行都无按钮、无岗位文字）：%s", rowHits.length,
  rowHits.length >= 5 && pplAll.indexOf(">农民<") >= 0 && pplAll.indexOf(">运输<") >= 0 &&
  rowHtml.indexOf("<button") < 0 && rowHtml.indexOf("铃薯") < 0 && rowHtml.indexOf("机枪塔") < 0);
ctx.setFilter("k1");                                  // 只看农民
const pplFarmer = el("page-people").innerHTML;
console.log("按职业筛选（农民）只留农民：%s",
  pplFarmer.indexOf("派普") >= 0 && pplFarmer.indexOf("守卫乙") < 0 && pplFarmer.indexOf("商贩丙") < 0);
ctx.setFilter("k5");                                  // 只看搬运工
console.log("按职业筛选（运输）只留搬运工：%s",
  el("page-people").innerHTML.indexOf("搬运丁") >= 0 && el("page-people").innerHTML.indexOf("派普") < 0);
ctx.setFilter("all");
// 详情面板要显示"具体工作"：挑一个农民（派普，岗位是 铃薯）来验
ctx.state.pickedSettler = ctx.state.settlers.findIndex(s => s.name === "派普");
ctx.go("people");
const ppl = el("page-people").innerHTML;
console.log("居民详情含性别行：%s  含改名控件：%s",
  ppl.indexOf("性别：<b>男</b>") >= 0 || ppl.indexOf("性别：<b>女</b>") >= 0,
  ppl.indexOf("renameInput") >= 0 && ppl.indexOf("确定改名") >= 0);
// S.P.E.C.I.A.L.：W 行第 9 字段（基础值，打包成 "力-感-耐-魅-智-敏-运"）
console.log("SPECIAL 解析：%s（派普 = 2-2-2-2-2-2-2，司特 = 3-4-5-6-7-2-1）",
  byName("派普").special === "2-2-2-2-2-2-2" && byName("司特").special === "3-4-5-6-7-2-1");
console.log("居民详情含 S.P.E.C.I.A.L. 表格（中文全称 + 值）：%s",
  ppl.indexOf("sptable") >= 0 && ppl.indexOf("S.P.E.C.I.A.L.") >= 0 &&
  /力量<\/td><td class="spv">2</.test(ppl) && /智力<\/td><td class="spv">2</.test(ppl) &&
  /幸运<\/td><td class="spv">2</.test(ppl));
// 开除按钮在操作区；开关关掉后对应的操作要变成不可用
console.log("操作区有开除按钮：%s", ppl.indexOf(">开除<") >= 0 || ppl.indexOf(">Dismiss<") >= 0);
ctx.state.pickedSettler = ctx.state.settlers.findIndex(s => s.name === "朱恩");
ctx.go("people");
const pplNoCmd = el("page-people").innerHTML;
console.log("开关关掉后按钮禁用（朱恩 flags=001：召唤/解除岗位/迁走 全禁用）：%s",
  (pplNoCmd.match(/<button class="btn[^"]*"[^>]* disabled>/g) || []).length === 3 &&
  pplNoCmd.indexOf("能否指挥」——") >= 0 && pplNoCmd.indexOf("能否迁走」——") >= 0);
ctx.state.pickedSettler = ctx.state.settlers.findIndex(s => s.name === "派普");
ctx.go("people");
console.log("居民详情含「职业状态」与「具体工作」：%s",
  ppl.indexOf("职业状态") >= 0 && ppl.indexOf("岗位：") >= 0 && ppl.indexOf("铃薯") >= 0);

// 名字库：性别分组要有内容；随机抽名字要落在对应性别的库里
const lib = ctx.NAMES;
console.log("名字库：en 男%d 女%d；zh 男%d 女%d（应无 Rare 池）",
  lib.en.male.length, lib.en.female.length, lib.zh.male.length, lib.zh.female.length);
console.log("名字库分男女严格（无跨性别重名）：%s",
  !lib.zh.male.some(n => lib.zh.female.indexOf(n) >= 0) && !lib.en.male.some(n => lib.en.female.indexOf(n) >= 0));
// 罕见名已经并进主名单（只需要区分男女），这里不再有 Rare 池
const zhPool = new Set(lib.zh.male);
const enPool = new Set(lib.en.male);
let okPool = true;
for (let n = 0; n < 200; n++) {
  ctx.renameRandom.call(null);                     // 男（pickedSettler=0 是司特，sex=0）
  const picked = el("renameInput").value;
  if (!zhPool.has(picked) && !enPool.has(picked)) { okPool = false; break; }
}
console.log("随机名字 200 次都命中男性名字库：%s（例：%s）", okPool, el("renameInput").value);

// 改名草稿要能扛住重绘：点了「确定改名」之后焦点就离开输入框了，这时若正好有一次
// 数据推送回来触发重绘，输入框里的内容不能被冲回原名（玩家反馈"前几秒会自动还原"）。
ctx.state.pickedSettler = 0;
ctx.go("people");
el("renameInput").value = "草稿名字";
ctx.renameDraftChanged();                       // 等价于玩家在输入框里打字
ctx.go("people");                               // 等价于一次推送后的重绘
console.log("推送重绘后改名草稿仍在：%s", el("renameInput").value === "草稿名字");

// 而游戏数据里名字已经变成草稿的名字之后，草稿要丢掉（否则会一直盖着游戏数据）
ctx.smOnData(payload.replace("W|司特|", "W|草稿名字|"));
console.log("改名落地后草稿被清掉：%s", !ctx.state.__renameDraft);

// 面板聚焦时：Esc 与热键都要能关（F4SE 的按键事件在暂停时送不到 Papyrus，只能靠页面）
function press(ev) {
  ctx.window.__emitted = [];
  const e = Object.assign({ preventDefault() {}, stopPropagation() {}, target: null }, ev);
  (docListeners.keydown || []).forEach(fn => fn(e));
  return (ctx.window.__emitted || []).map(x => x[0]);
}
ctx.state.pong = true;
ctx.state.cfg.hotkey = 121;
ctx.state.cfg.hotkeyOff = undefined;
const escSent = press({ key: "Escape", code: "Escape", keyCode: 27 });
console.log("按 Esc → 发 smCloseEsc（游戏侧会收拾暂停菜单）：%s", escSent.indexOf("smCloseEsc") >= 0);
const hkSent = press({ code: "F10", key: "F10", keyCode: 121 });
// 热键现在由 F4SE 插件在原生层处理（插件也就把它吞掉了），页面不该有任何反应
console.log("按 F10 页面不发动作（热键由插件原生层处理）：%s", hkSent.length === 0);
console.log("按 J(VK74) → 什么都不发：%s", press({ code: "KeyJ", key: "j", keyCode: 74 }).length === 0);
console.log("在输入框里按 Esc → 只退输入不关面板：%s",
  press({ key: "Escape", keyCode: 27, target: { tagName: "INPUT", blur() {} } }).length === 0);
ctx.state.pong = false;

// 老配置迁移：localStorage 里有旧键码 68（且没有新标记）时，必须迁到 121 —— 否则会被推回游戏（68 = D）
const vm2 = require('vm');
const store = { sm_cfg: JSON.stringify({ hotkey: 68, lang: "zh" }) };
const ctx2 = {
  console,
  window: (function () {
    const w = { addEventListener() {}, setTimeout: () => 0, innerHeight: 1080, innerWidth: 1920 };
    w.prisma = { emit() {} };
    w.localStorage = {
      getItem: k => (k in store ? store[k] : null),
      setItem: (k, v) => { store[k] = String(v); },
      removeItem: k => { delete store[k]; },
    };
    return w;
  })(),
  document: ctx.document, NodeFilter: { SHOW_TEXT: 4 }, localStorage: null,
  setTimeout: () => 0, clearTimeout() {}, JSON, Math, isNaN, parseFloat, parseInt,
};
ctx2.document.localStorage = ctx2.window.localStorage;
ctx2.localStorage = ctx2.window.localStorage;
ctx2.globalThis = ctx2;
vm2.createContext(ctx2);
vm2.runInContext(code, ctx2);
console.log("老配置 68 + 无标记 → 迁移后热键=%d（应为 121=F10）；标记已写入=%s",
  ctx2.state.cfg.hotkey, ctx2.window.localStorage.getItem("sm_hotkey_ver"));

// 改名要带 payload 发出（桥的 emit(event, data) 第二段是原样字符串）
ctx.window.__emitted = [];
el("renameInput").value = "  测试名字  ";
ctx.renameNow();
const sent = (ctx.window.__emitted || []).filter(x => x[0] === "smRename");
console.log("改名提交：动作数=%d payload=%s（首尾空格应被去掉）",
  sent.length, JSON.stringify(sent[0] ? sent[0][1] : null));
ctx.window.__emitted = [];
el("renameInput").value = "   ";
ctx.renameNow();
console.log("空名字不发动作：%s", (ctx.window.__emitted || []).length === 0);

// 岗位页：**以岗位为主** —— 列出全部工位（含已有人）、按类别分组、点工位给人挑人
ctx.go("jobs");
const jp = el("page-jobs").innerHTML;
console.log("岗位页列出全部工位（含已有人）：%s", jp.indexOf("jchip") < 0 && /工位（8：已有人 4 \/ 空缺 4）/.test(jp));
console.log("岗位页按类别分组并显示占用者/空缺：%s",
  jp.indexOf("农民（") >= 0 && jp.indexOf("派普、居民甲") >= 0 && jp.indexOf("空缺") >= 0);
// 农民/守卫同类工位合并成一条（一人可多岗）；商人/工人保持一岗一行
console.log("农民合并成一条（铃薯 ×3 + 玉米，已有人 2 / 空缺 2）：%s",
  /铃薯 ×3/.test(jp) && jp.indexOf("已有人 2 / 空缺 2") >= 0);
console.log("商人保持一岗一行：%s", jp.indexOf("贸易摊位") >= 0 && jp.indexOf("→ 商贩丙") >= 0);
console.log("守卫也合并（机枪塔 与 守卫岗哨 在同一条）：%s",
  jp.indexOf("机枪塔") >= 0 && jp.indexOf("守卫岗哨") >= 0 && /机枪塔[\s\S]{0,120}守卫岗哨/.test(jp));
console.log("点合并行(农民)出现挑人面板（无业的排前面）：%s",
  (function () { ctx.pickKindRow(1); var h = el("page-jobs").innerHTML;
    var ok = h.indexOf("pickbar") >= 0 && h.indexOf("挑一个人来干这个工位") >= 0;
    ctx.pickKindRow(-1); return ok; })());
console.log("挑人面板只列 无业 + 同类未满（农民行：有派普，无已满的居民甲）：%s",
  (function () { ctx.pickKindRow(1); var h = el("page-jobs").innerHTML;
    var bar = h.slice(h.indexOf("pickbar"));
    var ok = bar.indexOf("派普") >= 0 && bar.indexOf("居民甲") < 0 && bar.indexOf("商贩丙") < 0;
    ctx.pickKindRow(-1); return ok; })());
console.log("点单岗行(贸易摊位)也出现挑人面板：%s",
  (function () { ctx.pickJobRow(5); var h = el("page-jobs").innerHTML;
    var ok = h.indexOf("pickbar") >= 0 && h.indexOf("贸易摊位") >= 0;
    ctx.pickJobRow(-1); return ok; })());
// 居民页：给人派活 / 派运输线的入口，以及两者的选择面板
ctx.state.pickedSettler = ctx.state.settlers.findIndex(s => s.name === "司特");
ctx.go("people");
const pplNow = el("page-people").innerHTML;
// 注：居民详情的按钮在"选中了居民"时才渲染，这里直接查模板（渲染效果由预览页人工确认）
console.log("居民页模板有指派入口：%s",
  html.indexOf("setPickMode") >= 0 && html.indexOf("assignJob") >= 0 && html.indexOf("assignCaravan") >= 0);
var jobPanel = ctx.jobPickerForPicked();
console.log("『指派工作』面板列出空缺工位（不含已有人的派普/商贩丙）：%s",
  jobPanel.indexOf("选一个空缺工位") >= 0 && jobPanel.indexOf("守卫岗哨") >= 0 &&
  jobPanel.indexOf("铃薯") >= 0 && jobPanel.indexOf("派普") < 0);
var carPanel = ctx.caravanPicker();
console.log("『指派运输线』面板列出其它据点（不含当前所在的庇护山丘）：%s",
  carPanel.indexOf("选一个运输线目的地") >= 0 && carPanel.indexOf("红火箭加油站") >= 0 &&
  carPanel.indexOf("十松庄") >= 0 && carPanel.indexOf("庇护山丘") < 0);
// 英文模式下同样的提示应走英文文案（顺带看合计栏的英文标题）
ctx.state.cfg.lang = "en";
ctx.go("overview");              // 先切回总览（这几行前面在居民页，否则看到的是旧渲染）
expandTo(1);
console.log("EN 展开非当前据点的提示：%s", el("page-overview").innerHTML.indexOf("you are currently in") >= 0);

// 据点顺序被打乱（Papyrus 每次推送的顺序不保证一样）时，选中的据点不能跟着变
// —— 玩家反馈过"据点名显示错误，而且每次打开都会变"
ctx.state.cfg.lang = "zh";
ctx.state.selSettleId = 3;                                  // 十松庄
const lines = payload.split("\n");
const sLines = lines.filter(l => l.startsWith("S|"));
const rest = lines.filter(l => !l.startsWith("S|"));
ctx.smOnData(rest.concat(sLines.slice().reverse()).join("\n"));   // S 行倒序重发
console.log("顺序打乱后仍定位十松庄（展开状态按 ID 跟随）：%s（当前下标 %d，共 %d 个据点）",
  ctx.state.settlements[ctx.state.selSettle].name === "十松庄", ctx.state.selSettle, ctx.state.settlements.length);

// 批量操作对话框里的据点名必须是"当前所在"的据点，而不是据点页选中的那个
ctx.askFill();
const dlg = el("confirmTxt").textContent || "";
const dupCount = (dlg.match(/用尽量少的居民填满/g) || []).length;
console.log("填充对话框：用当前据点=%s  未用选中据点=%s  重复句=%d",
  dlg.indexOf("庇护山丘") >= 0, dlg.indexOf("十松庄") < 0, dupCount);
ctx.askUnassignAll();
const dlg2 = el("confirmTxt").textContent || "";
console.log("解除对话框：用当前据点=%s  未用选中据点=%s",
  dlg2.indexOf("庇护山丘") >= 0, dlg2.indexOf("十松庄") < 0);
ctx.state.cfg.lang = "en";
ctx.go("overview");
const ovEn = el("page-overview").innerHTML;
console.log("EN 总览：合计标题=%s  含 Raw 中文合计段=%s",
  ovEn.indexOf("Supply network totals") >= 0,
  /供应网络合计/.test(ovEn));

// 设置页曾经因为一段多余的 return 片段整体语法错误（整个脚本都跑不起来），这里守一道
ctx.state.cfg.lang = "en";
ctx.go("settings");
const se = el("page-settings").innerHTML;
console.log("设置页：含热键行=%s  含改键按钮=%s  含语言行=%s  没出现裸 key=%s",
  se.indexOf("Hotkey") >= 0, se.indexOf("hotkeyCapture") >= 0, se.indexOf("Language") >= 0,
  se.indexOf("hotkeyOff") < 0);
// 热键关掉时那一行要显示"未设置"，而不是裸 key 或空（注意：上面刚切成英文，先切回来）
ctx.state.cfg.lang = "zh";
ctx.state.cfg.hotkey = 0;
ctx.go("settings");
const se2 = el("page-settings").innerHTML;
console.log("热键=0 时显示『未设置』：%s", se2.indexOf("未设置") >= 0 && se2.indexOf("hotkeyOff") < 0);
ctx.state.cfg.hotkey = 121;

// 自定义热键：三种按键事件来源都要能认出来，而且换算成**虚拟键码**（F4SE 的空间）
const cases = [
  [{ code: "KeyF", key: "f", keyCode: 70 }, 0x46, "code=KeyF"],
  [{ key: "F", keyCode: 70 }, 0x46, "只有大写 key"],
  [{ key: "f" }, 0x46, "只有小写 key"],
  [{ keyCode: 70 }, 0x46, "只有 keyCode（本身就是 VK）"],
  [{ code: "F10", key: "F10", keyCode: 121 }, 0x79, "code=F10"],
  [{ key: "F10" }, 0x79, "只有 key=F10"],
  [{ code: "Escape", key: "Escape", keyCode: 27 }, 0x1B, "Esc"],
  [{ key: "7" }, 0x37, "只有 key=7"],
  [{ keyCode: 0x31 }, 0x31, "只有 VK 1"],
  [{ key: " ", keyCode: 32 }, 0x20, "空格"],
  [{ code: "KeyD" }, 0x44, "D（曾经被误当成 F10 的键）"],
  [{ key: "Unidentified", keyCode: 0 }, 0, "认不出来 → 0"],
];
let bad = 0;
cases.forEach(function (c) {
  const got = ctx.keyToCode(c[0]);
  if (got !== c[1]) { bad++; console.log("  ✗ %s：期望 0x%s 实际 0x%s", c[2], c[1].toString(16), (got||0).toString(16)); }
});
console.log("热键兼容键码换算（VK）：%d/%d 通过", cases.length - bad, cases.length);
console.log("默认热键是 VK_F10(121)：%s；显示名 %s",
  ctx.state.cfg.hotkey === 121, ctx.scName(ctx.state.cfg.hotkey));

// 词典检查：两种语言 key 必须一致；模板里写死的 t('key') 必须存在
// （曾经漏了 hotkeyOff，界面上直接显示成裸的 "hotkeyOff"）
const zk = Object.keys(ctx.STR.zh), ek = Object.keys(ctx.STR.en);
const onlyZh = zk.filter(k => ek.indexOf(k) < 0), onlyEn = ek.filter(k => zk.indexOf(k) < 0);
const used = new Set();
for (const m of html.matchAll(/\bt\(\s*['"]([A-Za-z0-9_]+)['"]/g)) {
  if (m[1].endsWith("_")) continue;            // t("title_" + p) 这类动态拼的
  used.add(m[1]);
}
const missing = [...used].filter(k => zk.indexOf(k) < 0);
console.log("词典：zh %d 条 / en %d 条；单边缺失=%s；模板用到的 key 缺定义=%s",
  zk.length, ek.length, JSON.stringify(onlyZh.concat(onlyEn)), JSON.stringify(missing));

// 英文模式下不该再看到中文（除了据点/居民这种游戏里的专有名词）
ctx.state.cfg.lang = "en";
ctx.state.selSettle = 0;
ctx.state.pickedSettler = 0;
const pages = ["overview", "settle", "people", "jobs", "settings"];
for (const p of pages) {
  ctx.go(p);
  const body = el("page-" + p).innerHTML.replace(/<[^>]*>/g, " ");
  const cjk = body.match(/[\u4e00-\u9fff][\u4e00-\u9fff，。：（）……、！？]+/g) || [];
  const uniq = [...new Set(cjk)].filter(s => s.length > 1);
  if (uniq.length) console.log("  %s 页残留中文：%s", p, JSON.stringify(uniq.slice(0, 12)));
}
ctx.state.cfg.lang = "zh";
