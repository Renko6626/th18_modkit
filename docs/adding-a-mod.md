# 加一个新 mod：通用流程

[`modding.md`](modding.md) 讲的是**原理**（三层入口、patch↔dll 的契约）。
这份讲的是**流程**：从零到能在启动器里勾上，每一步该建什么文件、写什么、怎么自查。

---

## 第 0 步：先判断形态

| 形态 | 判据 | 要建的东西 | 现成例子 |
|---|---|---|---|
| **A. 纯 patch** | 改动能用「改机器码 / 换资源」表达完，不需要跑自己的 C 代码 | 补丁目录 | （见下方 A 节；仓库里暂无纯 patch 的现成 mod） |
| **B. 纯 DLL** | 只读诊断、自己开线程/窗口，不需要 hook 游戏的具体指令 | `mods/*.dll` | `th18_probe.dll` |
| **C. patch + DLL** | 要在游戏的某条指令处夺取控制权、或要在运行时往 codecave 里填数据 | 两个都要 | `th18_mouse_control` + `th18_mouse.dll`（BP 耦合）<br>`th18_card_expand` + `th18_card_expand.dll`（生命周期耦合） |

判断口诀：**能不能只用「往这个地址写这几个字节」说清楚**。
能 → A；不能、要跑逻辑 → C；根本不用挂在游戏某条指令上 → B。

形态 C 是**一个 mod 两个勾**（patch 一个、dll 一个），启动器里两个都得勾上。

---

## 通用约定（三种形态都适用）

| 项 | 规定 | 为什么 |
|---|---|---|
| 编码 | **UTF-8 无 BOM** | thcrap 的 json 解析器不吃 BOM，会直接解析失败 |
| 行尾 | LF（`.gitattributes` 会在 checkout 时转 CRLF） | 仓库统一 |
| 缩进 | Tab | 跟 `repos/` 下现有 js 一致 |
| 命名 | patch 用 `th18_<功能>`，DLL 用 `th18_<功能>.dll` | 启动器按 id 字母序排栈，同前缀排一起 |
| 目标版本 | 只做 **TH18 v1.00a 原版**（非 Steam / 非汉化） | 所有硬地址都是按这一版扒的，换版必歪 |

---

## 形态 A：纯 patch（js-based）

以 `th18_card_expand` 的**补丁半边**为参照。（那个 mod 另外还配了个 dll，整体属形态 C —— 见下面「两种耦合方式」；但补丁这一半是标准的纯 patch 写法。）

### A1. 建目录

```
thcrap/repos/Renko_1055/th18_card_expand/
├── patch.js           元数据
├── th18.v1.00a.js     实际改动（binhack / codecave）
└── files.js           文件清单 + CRC32
```

> 目录里**必须**至少有一个叫 `th18*` 的文件或目录，否则启动器会当它「跟本作无关」
> 而不显示（控制台会打 `跳过与 th18 无关的补丁: xxx`）。`th18.v1.00a.js` 就满足这条。

### A2. `patch.js`

```json
{
	"id": "th18_card_expand",
	"version": "0.1.0",
	"title": "(18) 一句话说明。纯 binhack，不需要 dll。",
	"dependencies": [
		"nmlgc/base_tsa"
	],
	"update": false
}
```

- `id` **必须**和目录名一致 —— 启动器和 thcrap 都按目录找、按 id 显示，不一致会错位
- `dependencies` 写 `"nmlgc/base_tsa"`（带仓库前缀）。base_tsa 提供版本识别，
  没有它 thcrap 认不出 `th18.v1.00a.js` 这个文件名该不该加载
- `"update": false` **一定要写** —— 否则 thcrap 可能试图去服务器同步，覆盖掉你的文件
- `title` 前缀 `(18)` 是仓库惯例，跟 thpatch 官方补丁的写法对齐。要配 dll 的补丁在这里写明
  `Needs xxx.dll in mods/.` —— 这是漏勾一边时唯一的线索来源

### A3. `th18.v1.00a.js`

三种条目（`codecaves` / `breakpoints` / `binhacks`）的详细语义见
[`modding.md` 第 2 层](modding.md)。这里只补 codecave 的坑：

```json
{
	"codecaves": {
		"th18_card_table": {
			"size": "0xbc8",
			"access": "RW",
			"title": "搬迁目标：58 行 × 0x34"
		}
	},
	"binhacks": {
		"cardtable_start_407d72": {
			"addr": "0x407d72",
			"code": "b8<codecave:th18_card_table+4>",
			"expected": "b8c4534c00",
			"title": "start | mov eax, K | +0x4"
		}
	}
}
```

codecave 的规则（对应 thcrap 引擎里的各个错误分支）：

| 规则 | 说明 |
|---|---|
| 必须有 `code` 或 `size` | 两个都没有 → `codecave %s without "code" or "size" ignored`，静默不生效 |
| `size` 为 0 → 忽略 | 同上，不报错，只是没了 |
| `access` 取 `R`/`W`/`X` 组合 | 纯数据表用 `RW`；要执行的用 `RX` |
| 不能是 no-access | 引擎直接跳过 |
| write-only 提升成 read-write，execute-write 提升成 execute-read-write | 会打日志，不影响功能 |
| `"export": true` 只能配 execute / execute-read | 用在 `RW` 上会被拒 |
| 名字里不能有 `+` | `Codecave %s contains illegal character +` |
| 引用写法 `<codecave:名字>`，可加偏移 `<codecave:名字+0x10>` | 偏移里的 `+` 是表达式，合法；名字里的不合法 |

**最容易踩的坑：codecave 不会自动执行。**
`"export": true` 只是把这段代码注册成一个可被引用的函数名，**不是**「开机自动调用」。
一段初始化性质的 codecave（比如「把零售数据拷进新表」），必须有人真的去跑它。两条路：
在游戏初始化路径上找一处加 binhack 跳进去（`"code": "e8<codecave:xxx_init>"`），
或者写个 dll 走 `_mod_post_init` 生命周期钩子在 C 里填（见 [C-2](#c-2-生命周期耦合在引擎的某个阶段被自动调用)）。
什么都不做的话，它会被分配、被填零，然后永远不执行，而日志里一切正常。

`expected` 是可选的保险，**强烈建议写**：thcrap 会核对目标地址的原始字节，
对不上就拒绝打这条 binhack，避免在错误的版本上打歪。

### A4. `files.js`

thcrap 更新机制用的清单：文件名 → 内容的 CRC32（十进制）。
**不列自己**，照抄现有格式即可：

```json
{
	"patch.js": 401516817,
	"th18.v1.00a.js": 2379384875
}
```

本项目 `update: false`，所以 CRC 对不上不会导致运行出错；但仓库里几个补丁都写了，
保持一致，且将来真要走更新时不至于被静默重下覆盖。**改完 js 记得重算。**

算 CRC32 的一次性脚本（PowerShell，改掉 `$p` 后整段粘贴）：

```powershell
Add-Type -TypeDefinition @'
public static class Crc32Calc {
  static uint[] t;
  static Crc32Calc(){ t=new uint[256]; for(uint i=0;i<256;i++){ uint c=i;
    for(int k=0;k<8;k++) c=((c&1)!=0)?(0xEDB88320u^(c>>1)):(c>>1); t[i]=c; } }
  public static uint Compute(byte[] b){ uint crc=0xFFFFFFFFu;
    foreach(byte by in b) crc=t[(crc^by)&0xFF]^(crc>>8); return crc^0xFFFFFFFFu; }
}
'@
$p = 'D:\TouhouProject\th18_modkit\thcrap\repos\Renko_1055\th18_card_expand'
foreach ($f in 'patch.js','th18.v1.00a.js') {
    '{0,-20} {1}' -f $f, [Crc32Calc]::Compute([IO.File]::ReadAllBytes("$p\$f"))
}
```

> 别用纯 PowerShell 手写 CRC 循环：`[uint32]0xFFFFFFFF` 里的 `0xFFFFFFFF` 会先被解析成
> `[int]-1`，转 uint32 直接抛异常，然后你会拿到一串看着很像、但全错的数。上面走 C# 是为了绕开这个。

### A5. 在 `repo.js` 里登记

`thcrap/repos/Renko_1055/repo.js`：

```json
{
	"id": "Renko_1055",
	"title": "Renko's local patch repository",
	"patches": {
		"renko": "Renko's TH18 mod workspace",
		"th18_card_expand": "(18) Card table relocation / expansion (needs th18_card_expand.dll)",
		"th18_mouse_control": "(18) Mouse control for the player"
	}
}
```

**这一步跟启动器无关** —— 启动器是扫目录发现补丁的（`repos/` 下递归两层找 `patch.js`），
不看 `repo.js`。登记是给 **thcrap 官方 GUI**（`thcrap.exe` / `thcrap_configure`）看的：
不写这行，官方配置界面里选不到这个补丁。为了两条路都能用，照写。

按 id 字母序插入，值写英文一句话（这个文件其它条目都是 ASCII）。

### A6. 勾上跑

双击 `启动TH18mod.bat` → 补丁栈里勾上 → 【启动】。

想让新 clone 下来默认开着，把 id 加进 `mods/enabled.default.json` 的 `patches`。
`mods/enabled.json` 是本机状态、不进仓库，启动器每次运行时自己重写；
`thcrap/config/renko_th18.js`（run config）同理，是启动器按勾选生成的，**别手改**。

---

## 形态 B：纯 DLL

1. 编译成 **32 位（x86）** DLL，导出 `thcrap_plugin_init()`：返回 `0` = 加载成功，
   返回非 0 → thcrap 立刻 `FreeLibrary` 卸载（日志 `not used for this game`）
2. 丢进 `mods/`
3. 可选：写同名 `.json` 侧车，界面上会显示标题和说明

```json
{
	"title": "判定点可视化",
	"description": "在自机判定点画一个红圈，按 F9 开关。"
}
```

4. 启动器里勾上

> 没有侧车也能跑，界面上就只显示文件名和导出表。

---

## 形态 C：patch + DLL

先按 **A1–A6** 建补丁，再按 **B** 加 DLL。两者怎么接上，有**两种耦合方式** ——
选哪种取决于你要在**什么时候**拿到控制权。

### C-1. breakpoint 耦合：在游戏的某条指令处夺取控制权

```
patch  th18.v1.00a.js  →  "breakpoints": { "mouse_move": { "addr": ..., "cavesize": 6 } }
                                              ↕  名字必须一致
dll    导出表           →  BP_mouse_move
```

- patch 里写 `mouse_move`，DLL 里就必须导出 `BP_mouse_move`
- `name#tag`（如 `spell_id#real`）对应的仍是 `BP_spell_id`，`#` 后面只是区分多个地址
- `codecave:foo` 不是 breakpoint，不需要 `BP_` 函数
- `cavesize` 必须 **≥ 5 且落在整指令边界**，切在指令中间 = 当场崩

**只有一边的后果**：

| 情况 | 日志 | 现象 |
|---|---|---|
| 只有 dll，没有 patch 声明 | 什么都没有 | dll 加载了但 `BP_xxx` 永不触发，**毫无效果** |
| 只有 patch 声明，没有 dll | `ERROR: function 'BP_mouse_move' not found!` | 断点装不上 |
| 两边都有 | `(20/20) mouse_move... at 0x0045B170... OK` | 生效 |

第一种最阴险 —— 日志一切正常，游戏就是没反应。

现成例子：`th18_mouse_control` + `th18_mouse.dll`。

### C-2. 生命周期耦合：在引擎的某个阶段被自动调用

thcrap 扫插件导出表，凡是叫 `<任意前缀>_mod_<阶段>` 的函数，**在对应阶段自动调用**，
patch 里不用声明任何东西。thcrap 引擎自己就这么用（`steam_mod_post_init`、
`motd_mod_post_init`、`strings_mod_init` …）。

| 导出名后缀 | 时机 |
|---|---|
| `_mod_init` | 插件加载、引擎初始化 |
| `_mod_detour` | 装 detour 时 |
| `_mod_post_init` | **binhack / codecave / breakpoint 全部应用完之后** |
| `_mod_repatch` | 补丁文件热重载时 |
| `_mod_exit` | 收尾 |
| `_mod_thread_exit` | 线程退出 |

`post_init` 正是「codecave 已经分配好了，往里填东西」的时机。
现成例子 `th18_card_expand` + `th18_card_expand.dll` 就走这条：

```
patch  th18.v1.00a.js  →  "codecaves": { "th18_card_table": { "size": "0xbc8", "access": "RW" } }
                                              ↕  DLL 用 func_get("codecave:th18_card_table") 要地址
dll    导出表           →  th18_card_expand_mod_post_init
```

DLL 侧从 `thcrap.dll` 里 `GetProcAddress` 取 `func_get` / `log_printf`，
`func_get("codecave:名字")` 返回该 codecave 的实际地址，然后往里写数据。

> **这就是「初始化型 codecave 不会自动执行」（见 A3）的第二种解法。**
> 要么在游戏初始化路径上加一条 binhack 跳进去，要么像这样用 `_mod_post_init` 在 C 里填。
> 后者的额外好处是能顺手做自检：版本对不对、原表签名对不对、binhack 是不是真的全打上了 ——
> 不对就打日志并自行卸载，而不是让人带着半张空表开一局。

### C-3. 两种耦合的检查差异（重要）

| 耦合方式 | 启动器底部的检查栏 | 漏勾一边 |
|---|---|---|
| **breakpoint** | **会查** —— 比对已勾 patch 的 `breakpoints` 键名 ↔ 已勾 dll 的 `BP_*` 导出，对不上标红 | 有提示 |
| **生命周期** | **查不到** —— 这层耦合不经过 `breakpoints` 声明，启动器无从得知 | **一句提示都没有** |

所以走生命周期耦合的 mod，必须自己补三道防线：

1. `patch.js` 的 `title` 里写 `Needs xxx.dll in mods/.`
2. 侧车 `.json` 的 `description` 写明「必须同时启用 xxx 补丁」，并说明它不是 BP 耦合、检查栏看不见
3. **DLL 自己做自检** —— `func_get` 拿不到 codecave 就说明补丁没进栈，打一行 FAIL 到日志；
   版本 / 原始数据签名对不上就自行卸载

---

## 完工自查

粘进 PowerShell 跑一遍，四件事一次查完：json 能不能解析、`files.js` 的 CRC 对不对、
启动器会不会列出它、声明了哪些断点（需要有 DLL 接）。

```powershell
Add-Type -TypeDefinition @'
public static class Crc32Chk {
  static uint[] t;
  static Crc32Chk(){ t=new uint[256]; for(uint i=0;i<256;i++){ uint c=i;
    for(int k=0;k<8;k++) c=((c&1)!=0)?(0xEDB88320u^(c>>1)):(c>>1); t[i]=c; } }
  public static uint Compute(byte[] b){ uint crc=0xFFFFFFFFu;
    foreach(byte by in b) crc=t[(crc^by)&0xFF]^(crc>>8); return crc^0xFFFFFFFFu; }
}
'@
$Repos = 'D:\TouhouProject\th18_modkit\thcrap\repos'

foreach ($pj in Get-ChildItem $Repos -Filter patch.js -File -Recurse -Depth 2) {
    $dir = $pj.Directory
    try { $meta = Get-Content $pj.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { "[X] $($dir.Name)\patch.js 解析失败: $($_.Exception.Message)"; continue }

    $id = if ($meta.id) { [string]$meta.id } else { $dir.Name }
    if ($id -eq 'base_tsa') { continue }

    if ($id -ne $dir.Name)       { "[!] $id : id 与目录名 $($dir.Name) 不一致" }
    if ($meta.update -ne $false) { "[!] $id : 没写 update:false" }
    if (-not (Get-ChildItem $dir.FullName -Filter 'th18*' -EA SilentlyContinue)) {
        "[!] $id : 没有 th18* 文件，启动器不会列出它"
    }

    $fjPath = Join-Path $dir.FullName 'files.js'
    if (Test-Path $fjPath) {
        $fj = Get-Content $fjPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($n in $fj.PSObject.Properties.Name) {
            $t = Join-Path $dir.FullName $n
            if (-not (Test-Path $t)) { "[!] $id : files.js 列了不存在的 $n"; continue }
            $act = [Crc32Chk]::Compute([IO.File]::ReadAllBytes($t))
            if ($act -ne $fj.$n) { "[!] $id : $n CRC 过期 (files.js=$($fj.$n) 实际=$act)" }
        }
    }

    $bps = @()
    foreach ($g in 'global.js','th18.js','th18.v1.00a.js') {
        $f = Join-Path $dir.FullName $g
        if (-not (Test-Path $f)) { continue }
        try { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { "[X] $id\$g 解析失败: $($_.Exception.Message)"; continue }
        if ($j.breakpoints) {
            foreach ($n in $j.breakpoints.PSObject.Properties.Name) {
                if ($n -notlike 'codecave:*') { $bps += ($n -split '#')[0] }
            }
        }
    }
    "[ok] {0,-20} 断点: {1}" -f $id, $(if ($bps.Count) { $bps -join ', ' } else { '(无)' })
}

$repo   = Get-Content "$Repos\Renko_1055\repo.js" -Raw -Encoding UTF8 | ConvertFrom-Json
$listed = $repo.patches.PSObject.Properties.Name
foreach ($d in (Get-ChildItem "$Repos\Renko_1055" -Directory).Name) {
    if ($listed -notcontains $d) { "[!] $d : 没在 repo.js 里登记（官方 GUI 看不到）" }
}
```

`[ok]` 行里列出的断点，必须在 `mods/` 的某个 DLL 导出表里有对应的 `BP_<名字>` ——
这一条启动器窗口底部会自动查，不用手工核。

**但生命周期耦合（`_mod_<阶段>` 导出）这个脚本和启动器都查不出来**（见 [C-3](#c-3-两种耦合的检查差异重要)）。
用了这种耦合的 mod，自己确认 patch 和 dll 是不是都勾上了 —— 或者干脆在 DLL 里做自检。

---

## 常见坑速查

| 症状 | 多半是 |
|---|---|
| 启动器里根本看不到这个补丁 | 目录里没有 `th18*` 文件；或 `patch.js` 有 BOM / json 语法错 |
| thcrap 官方 GUI 里看不到 | `repo.js` 没登记 |
| 补丁勾了但游戏毫无变化 | binhack 的 `expected` 对不上被拒（看日志）；或 codecave 定义了却没人调用 |
| 日志 `function 'BP_xxx' not found` | 声明了断点但 DLL 没导出，或 DLL 没勾 |
| DLL 勾了但没反应 | 没有对应的 patch 声明断点；或 DLL 不是 32 位；或没导出 `thcrap_plugin_init` |
| 改了 DLL 重编译，跑的还是旧的 | 上一局没关，`bin/mod_*.dll` 删不掉。**先关游戏再启动**，启动器会打黄字警告 |
| 两个补丁改同一处，只有一个生效 | 补丁栈靠后的覆盖靠前的，目前按 id 字母序，`base_tsa` 恒在栈底 |
| json 明明没错却解析失败 | 存成了 UTF-8 **带 BOM** |
| 勾了 patch 没勾 dll，游戏能跑但数据全是 0 / 行为不对 | 生命周期耦合（`_mod_*`）启动器不查，没有任何提示。看 dll 日志里的 FAIL 行 |
| dll 日志打 `FAIL: codecave:xxx not found` | 对应的 patch 没进栈（没勾，或 codecave 名字拼错） |

排错的第一手材料永远是 `thcrap/logs/thcrap_log.txt`，读法见
[`troubleshooting.md`](troubleshooting.md)。
