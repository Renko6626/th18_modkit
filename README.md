# th18_modkit

《东方虹龙洞》(TH18 v1.00a) 的 mod 开发环境。基于 [thcrap](https://github.com/thpatch/thcrap)，
把**补丁栈**和**原生 DLL 插件**两条改法统一到一个带勾选界面的启动器里。

整个目录自包含、可任意搬动，不写注册表、不改系统、不联网。

---

## 三步开跑

**1. clone**

```
git clone <这个仓库> th18_modkit
```

**2. 放游戏文件**

本仓库不含游戏本体。把 TH18 **v1.00a 原版**的 `th18.exe` / `th18.dat` / `thbgm.dat`
（可选 `custom.exe`）复制进 `game/`。版本必须对得上 —— 详见 [`docs/setup.md`](docs/setup.md)。

**3. 双击 `启动TH18mod.bat`**

弹出勾选窗口，选好要加载的补丁和 DLL，点【启动】。

```
┌─ TH18 Mod Loader ───────────────────────────────────────┐
│ 补丁栈  (thcrap patch - breakpoint / binhack / 资源替换) │
│  ☑ th18_mouse_control  -  (18) Mouse control for...     │
│  ☐ renko               -  Renko's TH18 mod workspace    │
│ repos/nmlgc/base_tsa/  始终位于栈底，不可取消            │
│                                                          │
│ 自定义 DLL  (thcrap\bin 插件 - 提供 BP_xxx 处理函数)     │
│  ☑ th18_mouse.dll  -  鼠标操作自机  [BP: mouse_move]    │
│  ☐ th18_probe.dll  -  坐标探针                          │
│                                                          │
│ ┌ 说明 ────────────────────────────────────────────────┐│
│ │ 让鼠标直接驱动自机坐标，F9 开关。需要同时启用…       ││
│ └──────────────────────────────────────────────────────┘│
│ ┌ 检查 ────────────────────────────────────────────────┐│
│ │ patch 与 dll 对得上。                                ││
│ │ 栈 : base_tsa, th18_mouse_control                    ││
│ │ dll: th18_mouse.dll                                  ││
│ └──────────────────────────────────────────────────────┘│
│ ┌启动目标─────────┐              [启动]      [取消]     │
│ │(•)th18 ( )custom│                                     │
│ └─────────────────┘                                     │
└──────────────────────────────────────────────────────────┘
```

命令行参数：

| 写法 | 效果 |
|---|---|
| `启动TH18mod.bat` | 弹窗勾选 |
| `启动TH18mod.bat -NoUi` | 不弹窗，沿用上次选择直接启动 |
| `启动TH18mod.bat custom` | 弹窗，默认选中 `custom.exe`（改分辨率/按键） |

---

## 现成的 mod

| mod | 组成 | 说明 |
|---|---|---|
| **鼠标操作自机** | patch `th18_mouse_control` + dll `th18_mouse.dll` | 鼠标直接驱动自机，F9 开关。**两个都要勾**。 |
| **卡表搬迁 / 扩容** | patch `th18_card_expand` + dll `th18_card_expand.dll` | 把 `zTableCardData` 从 `.rdata` 搬进 codecave，给加卡腾空间。patch 负责改指令，dll 在 `post_init` 阶段填表并自检。**两个都要勾** —— 这对是生命周期耦合，检查栏查不出漏勾。 |
| **坐标探针** | dll `th18_probe.dll` | 只读诊断：轮询自机坐标/定点数/focus/state，写 `game/th18_probe.log`。不需要 patch。 |

---

## 目录

```
th18_modkit/
├── 启动TH18mod.bat            ← 入口
├── tools/modloader.ps1        ← 启动器本体（勾选界面 + 装配 + 拉起游戏）
│
├── mods/                      ← DLL 插件放这
│   ├── th18_card_expand.dll + .json   .json 是可选侧车，给界面提供标题和说明
│   ├── th18_mouse.dll  + .json
│   ├── th18_probe.dll  + .json
│   ├── enabled.default.json       首次运行的默认勾选（进仓库）
│   └── enabled.json               你本机的勾选状态（不进仓库，自动生成）
│
├── thcrap/                    ← thcrap 引擎（Public Domain，随仓库分发）
│   ├── thcrap.exe                 官方配置 GUI，一般用不到
│   ├── bin/                       引擎二进制 + 启动器暂存进来的 mod_*.dll
│   ├── config/
│   │   ├── config.js              全局设置（console=true，自动更新已关）
│   │   ├── games.js               启动器生成，勿手改
│   │   └── renko_th18.js          启动器生成的 run config，勿手改
│   ├── logs/thcrap_log.txt        每次运行的完整日志，排错看这个
│   └── repos/
│       ├── nmlgc/base_tsa/        ZUN 游戏引擎支持（版本识别），别动
│       └── Renko_1055/            本项目的补丁仓库
│           ├── renko/                 空白工作区，你自己的改动放这
│           ├── th18_card_expand/      卡表搬迁 / 扩容的 binhack + codecave 声明
│           └── th18_mouse_control/    鼠标 mod 的断点声明
│
├── game/                      ← 游戏本体（不进仓库，你自己放）
└── docs/
    ├── setup.md               准备游戏文件、版本校验、首次运行
    ├── adding-a-mod.md        加新 mod 的分步流程 + 自查脚本
    ├── modding.md             怎么写 mod：三层入口、patch↔dll 契约
    └── troubleshooting.md     排错
```

---

## 文档

- **[docs/setup.md](docs/setup.md)** — 从零开始，含版本校验和常见坑
- **[docs/modding.md](docs/modding.md)** — 三层改法、patch 与 dll 的契约、怎么加新 mod
- **[docs/adding-a-mod.md](docs/adding-a-mod.md)** — 加一个新 mod 的分步流程：三种形态、每个字段怎么写、完工自查脚本
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — 日志怎么读、症状对照表

---

## 许可与来源

- `thcrap/` 下的引擎二进制来自 [thpatch/thcrap](https://github.com/thpatch/thcrap)（2024-11-06 stable），
  该项目声明为 **Public Domain / Unlicense**，可自由再分发。
- `thcrap/repos/nmlgc/base_tsa/` 是 thcrap 官方的 TSA 游戏支持补丁，同上。
- `mods/` 下的 DLL 和 `Renko_1055/` 下的补丁是本项目内容。
- **游戏本体不在本仓库内，也不要提交进来。**

> **注意**：`mods/` 里目前只有编译好的 DLL，没有源码。协作者暂时无法重新编译它们。
> 如果你要加入 DLL 源码，建议放 `src/<模块名>/` 并在 `docs/modding.md` 里补上构建说明。
