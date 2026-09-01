# 排错

## 先看日志

`thcrap/logs/thcrap_log.txt` 是每次运行的完整记录（上一次的会轮转成 `thcrap_log.1.txt`）。
全通的话这四行都在：

```
Hashing executable... → th18 v1.00a (original)        认出游戏
Patches in the stack: base_tsa, th18_mouse_control    补丁进栈
[Plugin] mod_th18_mouse.dll: initialized and active   dll 加载
(20/20) mouse_move...
at 0x0045B170... OK                                   断点装上
```

DLL 自己的输出在 `game/` 下（如 `game/th18_mouse.log`、`game/th18_probe.log`），
跟 thcrap 的日志是两回事 —— **两边都要看**。

---

## 症状对照

### 游戏起不来

| 现象 | 原因 | 处理 |
|---|---|---|
| 启动器弹框说 `game\ 里缺少这些文件` | 游戏文件没放对 | 见 [setup.md](setup.md)，注意别多套一层子目录 |
| 游戏闪退，日志里什么都没有 | 缺 VC++ x86 运行库 | 装 `thcrap/bin/vc_redist.x86.exe` |
| `Failed to start ... 目录名称无效` | `games.js` 路径失效 | 正常情况下启动器每次会重写它；如果你手改过，删掉让它重新生成 |
| 启动器一闪而过 | 正常 | `.bat` 只在出错时 pause。thcrap 自己的控制台会在游戏进程里另开一个 |

### 补丁没生效

| 日志里的话 | 含义 | 处理 |
|---|---|---|
| 没有 `Hashing executable... → th18 v1.00a` | 版本认不出 | exe 哈希对不上，见 [setup.md](setup.md) |
| `Patches in the stack:` 里没有你的补丁 | 没勾上 | 在启动器窗口里勾 |
| 补丁在栈里但资源没换 | 文件名或路径不对 | 搜日志里的 `Resolving th18/...`，看 thcrap 到底在找什么名字 |
| `binhack xxx: ignored` | 补丁自己声明了 `"ignore": true` | 正常，不是错误 |

### DLL 没生效

| 日志里的话 | 含义 | 处理 |
|---|---|---|
| `[Plugin] xxx.dll: not a plugin` | 没导出 `thcrap_plugin_init` | 检查导出表和 `.def`/`__declspec(dllexport)` |
| `[Plugin] xxx.dll: not used for this game` | 导出了，但 `thcrap_plugin_init` 返回了非 0，thcrap 已卸载 | DLL 自己判断"不适用于当前游戏"，看它的日志 |
| 完全没出现这个 dll | 没勾上，或文件不在 `mods/` 根目录 | 勾上；确认扩展名是 `.dll` |
| `initialized and active` 但游戏没反应 | **多半是缺 patch 声明** | 见下 |

### `initialized and active` 却毫无效果 ← 最常见

DLL 加载成功不等于它的 `BP_xxx` 会被调用。breakpoint 必须由**补丁**声明才会真正打进游戏代码。

搜日志里的 `ERROR: function 'BP_` ：

```
(20/20) mouse_move...ERROR: function 'BP_mouse_move' not found!
```

- **有这行** → 补丁勾了但 DLL 没勾（或 DLL 里没这个导出）
- **一行都没有，断点总数也没涨** → DLL 勾了但补丁没勾，断点根本没被声明

启动器窗口底部的检查栏会提前把这两种情况标红，启动前留意。

详细契约见 [modding.md](modding.md#patch--dll-的配对关系重要)。

### 改了 DLL 但行为没变

上一局游戏还开着 —— DLL 被映射着删不掉，启动器只能沿用 `bin/` 里的旧版本。
这时会打黄字：

```
[!] th18_mouse.dll 仍被上一局游戏占用，沿用 bin\ 里的旧版本（重编译的新版本本次不会生效）
```

**先完全关掉上一局，再启动。**

### 断点装上了但游戏崩溃

`cavesize` 切在指令中间了。thcrap 要写 5 字节 JMP，被覆盖的原指令必须是完整的若干条。
重新 dump 目标地址的字节，按指令长度累加到第一个 ≥5 的边界。见
[modding.md](modding.md#第-2-层引擎级改动)。

也建议在 breakpoint 里加 `"expected": "55 8b ec ..."`，让 thcrap 在字节对不上时直接拒绝打。

---

## 恢复到干净状态

启动器生成的东西都可以安全删掉，下次启动会重新生成：

```
thcrap/config/games.js
thcrap/config/renko_th18.js
thcrap/bin/mod_*.dll
thcrap/logs/*
mods/enabled.json          删掉会退回 mods/enabled.default.json
```

如果 `thcrap/bin/mod_*.dll` 删不掉，说明还有游戏进程开着。

**别删** `thcrap/bin/` 下其他任何文件、`thcrap/repos/nmlgc/base_tsa/`、`thcrap/config/config.js`。

---

## 还是不行

带上这些信息开 issue：

1. `thcrap/logs/thcrap_log.txt`（完整）
2. `game/*.log`（相关 DLL 的日志）
3. `Get-FileHash game\th18.exe -Algorithm SHA256` 的输出
4. 启动器控制台的输出（用 `启动TH18mod.bat -NoUi` 跑一次更容易截到）
