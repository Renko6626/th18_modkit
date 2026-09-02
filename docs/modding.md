# 怎么写 mod

## 三层入口

thcrap 改游戏有三条互不冲突的通道。先想清楚你要改的东西属于哪一层：

| 层 | 放哪 | 用来干什么 | 需要编译吗 |
|---|---|---|---|
| **1. 资源替换** | `thcrap/repos/<repo>/<patch>/th18/` | 换图、换文本、换弹幕脚本 | 否 |
| **2. 引擎级改动** | `thcrap/repos/<repo>/<patch>/th18.v1.00a.js` | binhack（改机器码）、codecave、声明 breakpoint | 否 |
| **3. 原生 DLL** | `mods/*.dll` | 任意 C/C++ 逻辑，作为 breakpoint 的处理函数 | 是（32 位） |

第 2、3 层是**配对使用**的 —— 这是本项目最容易踩的坑，下面单独讲。

---

## 第 1 层：资源替换

补丁目录下建一个 `th18/` 文件夹，把文件按 `th18.dat` 解包后的名字放进去即可：

```
thcrap/repos/Renko_1055/renko/th18/
├── st01a.msg          对话
├── pl00.anm           自机贴图
├── st05bs.ecl         弹幕脚本
└── ability/
    └── KOZUCHI_max.png    ANM 里的单张贴图也能单独替换
```

ANM 内部贴图的路径名可以从日志里扒 —— 运行时那一长串
`(PNG) Resolving th18/ability/XXX.png... not found` 就是 thcrap 在挨个找你有没有提供替换。

MSG 还支持 `.jdiff` 增量补丁（只改其中几句，不用整份替换）。

解包/打包用 [thtk](https://github.com/thpatch/thtk)（`thdat` / `thanm` / `thecl` / `thmsg` / `thstd`）。

---

## 第 2 层：引擎级改动

**版本 js 放补丁根目录**，不是放 `th18/` 里面：

```
thcrap/repos/Renko_1055/renko/
├── patch.js
├── th18.v1.00a.js     ← 这里
└── th18/              ← 不是这里
```

三种条目：

```json
{
	"codecaves": {
		"my_cave": { "access": "re", "code": "8b4424 04 c3" }
	},
	"breakpoints": {
		"mouse_move": {
			"addr": "0x45b170",
			"expected": "55 8b ec 83 e4 f0",
			"cavesize": 6
		}
	},
	"binhacks": {
		"nop_something": { "addr": "Rx12c76", "code": "909090" }
	}
}
```

地址两种写法都行：绝对 VA（`0x45b170`）或 `Rx` + 相对 imagebase 的偏移（`Rx5b170`）。
TH18 的 imagebase 是 `0x400000` 且没开 DYNAMICBASE，两者等价。

**`cavesize` 必须 ≥ 5 且落在整指令边界上。** thcrap 要在那里写一条 5 字节的 JMP，
被覆盖的原指令会被搬到 cave 里执行。切在指令中间 = 游戏当场崩。

怎么定 cavesize：dump 目标地址的字节，按指令长度往后累加到第一个 ≥5 的边界。以
`0x45b170` 为例：

```
55              push ebp                 → 边界 1
8B EC           mov  ebp, esp            → 边界 3
83 E4 F0        and  esp, 0FFFFFFF0h     → 边界 6   ← 取这个
F3 0F 10 1D …   movss xmm3, [4B9174]     → 边界 14
```

`expected` 是可选的保险：thcrap 会核对目标地址的原始字节，对不上就拒绝打，
避免在错误的版本上打歪。**强烈建议写。**

---

## 第 3 层：原生 DLL

### 契约

thcrap 启动时遍历 `thcrap/bin` 下**所有** `.dll`，凡是导出 `thcrap_plugin_init()` 的就加载：

- 返回 `0` → 加载成功，日志 `initialized and active`
- 返回非 `0` → thcrap 立刻 `FreeLibrary` 卸载，日志 `not used for this game`

DLL 必须是 **32 位（x86）**。

除了 `thcrap_plugin_init`，DLL 的导出表还有两种会被引擎认出来：

| 导出名 | 什么时候被调用 |
|---|---|
| `BP_<名字>` | patch 里声明了同名 breakpoint，游戏执行到那个地址时 |
| `<前缀>_mod_<阶段>` | 引擎跑到对应生命周期阶段时，**自动调用，patch 里不用声明** |

生命周期阶段有 `init` / `detour` / `post_init` / `repatch` / `exit` / `thread_exit`；
thcrap 引擎自己就这么用（`steam_mod_post_init`、`motd_mod_post_init`、`strings_mod_init` …）。
其中 `post_init` 在 binhack / codecave / breakpoint 全部应用完之后跑。
**但对插件它实际上不会被调用**：thcrap 的 `plugin_init` 用 `std::unordered_map::merge` 把插件的
钩子并进全局表，而 thcrap.dll 自己（`steam_mod_post_init` / `motd_mod_post_init`）先占了
`post_init` 这个 key，后来者被静默丢弃，日志无一字（2024-11-06 与 master 同）。
`th18_card_expand.dll` 第一版就栽在这，现改为断点 `ce_gate`。
**要「全部 patch 应用完之后」的时点，用断点。**

**注意这两种耦合的可检查性不一样**：`BP_` 那种启动器底部会自动交叉检查，
`_mod_<阶段>` 那种启动器看不见，漏勾一边不会有任何提示。详见
[`adding-a-mod.md` C-3](adding-a-mod.md)。

### patch ↔ dll 的配对关系（重要）

**声明在 patch 里，实现在 dll 里。**

```
patch  th18.v1.00a.js  →  "breakpoints": { "mouse_move": { "addr": ... } }
                                              ↕  名字必须一致
dll    导出表           →  BP_mouse_move
```

两边缺一不可：

| 情况 | thcrap 日志 | 现象 |
|---|---|---|
| 只有 dll，没有 patch 声明 | 什么都没有 | dll 加载了，但 `BP_xxx` 永远不被调用，**毫无效果** |
| 只有 patch 声明，没有 dll | `mouse_move...ERROR: function 'BP_mouse_move' not found!` | 断点装不上 |
| 两边都有 | `(20/20) mouse_move... at 0x0045B170... OK` | 生效 |

第一种情况最阴险 —— 日志里一切正常，游戏就是没反应。

**启动器窗口底部的检查栏会实时比对这两边**：它读已勾选 patch 的 `breakpoints` 键名，
读已勾选 dll 的 `BP_*` 导出表，两边对不上就标红。加新 mod 时留意这一栏。

### 命名注意

- patch 里的 `name#tag`（如 `spell_id#real`）对应的仍是 `BP_spell_id`，`#` 后面只是区分多个地址
- `codecave:foo` 不是 breakpoint，不需要 `BP_` 函数

---

## 加一个新 mod

三种形态，按需求挑一条：

| 形态 | 要建的东西 | 例子 |
|---|---|---|
| **纯 patch** —— 改动能用「往这个地址写这几个字节」说完 | 补丁目录（`patch.js` + `th18.v1.00a.js` + `files.js`） | （暂无） |
| **纯 DLL** —— 只读诊断、不挂在游戏某条指令上 | `mods/xxx.dll`（+ 可选同名 `.json` 侧车） | `th18_probe.dll` |
| **patch + DLL** —— 要夺取控制权跑逻辑，或运行时往 codecave 里填数据 | 两个都要，靠 `断点名` ↔ `BP_断点名`，或靠 `_mod_<阶段>` 生命周期钩子对上 | `th18_mouse_control` + `th18_mouse.dll`<br>`th18_card_expand` + `th18_card_expand.dll` |

**完整的分步流程、每个字段写什么、`files.js` 的 CRC32 怎么算、`repo.js` 怎么登记、
完工自查脚本、常见坑速查表 —— 见 [`adding-a-mod.md`](adding-a-mod.md)。**

三条铁律，先记住：

- `patch.js` 里 **`"update": false` 一定要写** —— 否则 thcrap 可能去服务器同步，覆盖掉你的文件
- 补丁目录里**必须**有至少一个 `th18*` 的文件或目录，否则启动器当它「跟本作无关」而隐藏
  （控制台会打 `跳过与 th18 无关的补丁: xxx`）
- 所有 json 存成 **UTF-8 无 BOM** —— thcrap 的解析器不吃 BOM

---

## 启动器是怎么装配的

DLL 那一层 thcrap 原生**没有开关** —— `bin/` 下所有插件无条件加载。所以启动器靠控制
`bin/` 里有什么来实现选择性加载：

1. 启动前 `del thcrap/bin/mod_*.dll` —— 撤下上次注入的
2. 把勾选的复制成 `thcrap/bin/mod_<原名>.dll`
3. 按勾选的 patch 生成 `thcrap/config/renko_th18.js`（`base_tsa` 永远在栈底）
4. `thcrap_loader.exe renko_th18.js <exe>`

**为什么用 `mod_` 前缀**：清理就是删 `mod_*.dll`，而 thcrap 自带的 dll 没有一个以 `mod_`
开头，物理上不可能误删官方文件。代价是日志里显示成 `mod_th18_mouse.dll`。

**为什么清理放在"下次启动前"而不是"本次启动后"**：`thcrap_loader` 注入完就退出了，
但游戏还在跑、dll 被映射着，Windows 不允许删除。

**所以：改完 DLL 重新编译后，务必先关掉上一局再启动**，否则跑的还是旧版本。
撤不下来时启动器会打黄字警告（`仍被占用 / 沿用旧版本`），不会假装成功。

补丁栈顺序 = 优先级，靠后的覆盖靠前的。目前按 patch id 字母序排，`base_tsa` 恒在最前。
