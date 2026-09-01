# 准备与首次运行

## 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Windows | thcrap 只有 Windows 版；TH18 本身也是 Win32 程序 |
| PowerShell | 5.1（系统自带）或更高 | 启动器用的是系统自带的 `powershell.exe`，不需要额外安装 |
| VC++ 运行库 | x86 版 | 缺了游戏起不来。`thcrap/bin/vc_redist.x86.exe` 就是安装包，双击装一次即可 |
| .NET Framework | 4.6.1+ | 只有 `thcrap.exe`（官方配置 GUI）需要，本项目的启动器不需要 |

不需要管理员权限，不写注册表，不联网（自动更新已在 `thcrap/config/config.js` 里关掉）。

---

## 放游戏文件

把 TH18 **v1.00a 原版**的文件复制进 `game/`：

```
game/
├── th18.exe      必需
├── th18.dat      必需
├── thbgm.dat     必需
└── custom.exe    可选（设置程序：分辨率、按键）
```

不要再套一层子目录 —— `game/th18/th18.exe` 是错的，`game/th18.exe` 才对。

## 版本必须对得上

thcrap 通过 **exe 的 SHA256** 识别游戏版本，然后才知道该往哪些地址打补丁。认不出版本 =
什么都不会发生。

| 文件 | 大小 | SHA256 |
|---|---|---|
| `th18.exe` | 847,360 | `5aeb74b19939a29a8cf06e4fe7777aaf9139e93478507e039f43318171020e9f` |
| `custom.exe` | 132,096 | `6b287f8826bf703ac82bf97ac65f7343d32dfffacc875a20fd84a1a0bae7a8c1` |

自己核对：

```powershell
Get-FileHash game\th18.exe -Algorithm SHA256
```

启动器每次运行也会自动核对，对不上会警告。

### 哪些版本不行

- **Steam 版** —— 是另一个 exe（1,043,032 字节），哈希不同。thcrap 认得它，但本项目的
  `th18_mouse_control` 补丁里的地址 `0x45b170` 是按非 Steam 版算的，用 Steam 版会打歪。
- **汉化版** —— 通常替换了 `th18.exe` 或塞了 `th18c.exe` + `data/` 目录。哈希对不上。
- **任何改过的 exe** —— 包括自己用别的工具打过补丁的。

如果你手上只有汉化版：汉化补丁一般是覆盖安装在原版上的，去找原版备份，或者重新下一份原版。

---

## 首次运行

1. 双击 `启动TH18mod.bat`
2. 启动器先自检 `game/`，缺文件会直接弹框告诉你缺哪个
3. 自检通过后弹出勾选窗口，默认按 `mods/enabled.default.json` 勾好（鼠标 mod）
4. 点【启动】

第一次跑完之后：

- `mods/enabled.json` —— 记录了你的勾选，下次自动恢复（这个文件不进仓库，各人一份）
- `thcrap/config/games.js` 和 `renko_th18.js` —— 启动器按当前路径生成的，**别手改**，
  每次启动都会被重写
- `thcrap/logs/thcrap_log.txt` —— 完整日志

## 确认真的生效了

打开 `thcrap/logs/thcrap_log.txt`，找这三行：

```
Hashing executable... → th18 v1.00a (original)        ← 认出游戏了
Patches in the stack: base_tsa, th18_mouse_control    ← 补丁进栈了
[Plugin] mod_th18_mouse.dll: initialized and active   ← dll 加载了
```

再看断点：

```
(20/20) mouse_move...
at 0x0045B170... OK
```

四条都在，就是全通了。任何一条缺失或报错，去看
[troubleshooting.md](troubleshooting.md)。

---

## 搬动与备份

整个目录可以随便挪盘符、改路径、打包发人。启动器每次运行会按自己所在位置重新生成
`games.js`，不存在硬编码路径。

唯一注意：路径别放进 OneDrive 之类会做文件锁的同步目录，`thcrap/bin/mod_*.dll` 的
暂存/删除会被干扰。
