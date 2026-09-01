<#
    TH18 modkit - patch + DLL manager

    thcrap 里改游戏有两条正交的通道，这个启动器两条都管：

    1) patch（thcrap 原生）—— repos/<repo>/<patch>/，进 run config 的 patches 栈。
       breakpoints / binhacks / codecaves / 资源替换都在这一层声明。
    2) dll（插件）—— thcrap 无条件加载 thcrap\bin 下所有导出 thcrap_plugin_init 的 dll。
       没有开关，所以只能靠控制 bin\ 里有什么：启动前 del bin\mod_*.dll，
       再把勾选的复制成 bin\mod_<原名>.dll。前缀保证碰不到 thcrap 自带文件。
       清理只能放"下次启动前"——注入完 loader 就退出了，但游戏还在跑、dll 被映射着，删不掉。

    两条通道是耦合的：patch 里声明 breakpoint "foo"，必须有某个已加载的 dll 导出 BP_foo，
    否则断点装上了却没人接，游戏毫无反应且日志里看不出问题。窗口底部会实时交叉检查这一点。
#>
param(
    [ValidateSet('th18', 'custom')][string]$Target,
    [switch]$NoUi
)

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$ModsDir   = Join-Path $Root 'mods'
$GameDir   = Join-Path $Root 'game'
$ThcrapDir = Join-Path $Root 'thcrap'
$BinDir    = Join-Path $ThcrapDir 'bin'
$ReposDir  = Join-Path $ThcrapDir 'repos'
$ConfigDir = Join-Path $ThcrapDir 'config'
$StateFile = Join-Path $ModsDir 'enabled.json'
$DefaultStateFile = Join-Path $ModsDir 'enabled.default.json'
$RunConfig = 'renko_th18.js'
$Prefix    = 'mod_'

# game/ 不进仓库，协作者要自己放。这里核对的是 thcrap 认得的那一版：
# 东方虹龙洞 v1.00a 原版（非 Steam、非汉化版）。哈希取自 base_tsa/versions.js。
$GameRequired = @{
    'th18.exe'   = '5aeb74b19939a29a8cf06e4fe7777aaf9139e93478507e039f43318171020e9f'
    'th18.dat'   = ''   # 只查存在，不查哈希（117MB，每次启动算太慢）
    'thbgm.dat'  = ''
}
$GameOptional = @{
    'custom.exe' = '6b287f8826bf703ac82bf97ac65f7343d32dfffacc875a20fd84a1a0bae7a8c1'
}

# 栈底固定：base_tsa 是所有 ZUN 游戏的引擎支持（版本识别 + 官方 breakpoint），
# 不给勾选，永远第一个。其 breakpoint 由 thcrap_tsa.dll 提供，不参与交叉检查。
$AlwaysOn  = @('base_tsa')

# 本作会读到的游戏 js（补丁根目录级别，不是 th18/ 里面）
$GameJs    = @('global.js', 'th18.js', 'th18.v1.00a.js')

function Write-Step([string]$m) { Write-Host "  $m" }
function Write-Warn([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "  [X] $m" -ForegroundColor Red }

# ---------------------------------------------------------------- JSON 输出

# thcrap 的 json 解析器不吃 BOM，也不保证按本地代码页读，所以自己写：
# UTF-8 无 BOM + 非 ASCII 一律转 \uXXXX
function ConvertTo-JsonStringLiteral([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 32 -or $code -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Write-TextNoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- PE 导出表

# 纯 PowerShell 解析导出名，用来找 dll 提供了哪些 BP_xxx
function Get-DllExportNames([string]$path) {
    try {
        $b = [System.IO.File]::ReadAllBytes($path)
        if ($b.Length -lt 0x40) { return @() }
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        if ($pe -le 0 -or ($pe + 24) -ge $b.Length) { return @() }
        $nSec    = [BitConverter]::ToUInt16($b, $pe + 6)
        $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
        $optOff  = $pe + 24
        $magic   = [BitConverter]::ToUInt16($b, $optOff)
        # PE32 的 DataDirectory 在 optional header +96，PE32+ 在 +112
        $ddOff   = if ($magic -eq 0x20B) { $optOff + 112 } else { $optOff + 96 }
        $expRva  = [BitConverter]::ToUInt32($b, $ddOff)
        if ($expRva -eq 0) { return @() }
        $secOff = $optOff + $optSize

        $rvaToFile = {
            param([uint32]$rva)
            for ($i = 0; $i -lt $nSec; $i++) {
                $s   = $secOff + $i * 40
                $va  = [BitConverter]::ToUInt32($b, $s + 12)
                $sz  = [BitConverter]::ToUInt32($b, $s + 16)
                $raw = [BitConverter]::ToUInt32($b, $s + 20)
                if ($rva -ge $va -and $rva -lt ($va + $sz)) { return [int]($rva - $va + $raw) }
            }
            return -1
        }

        $e = & $rvaToFile $expRva
        if ($e -lt 0) { return @() }
        $nNames   = [BitConverter]::ToUInt32($b, $e + 24)
        $namesRva = [BitConverter]::ToUInt32($b, $e + 32)
        $np = & $rvaToFile $namesRva
        if ($np -lt 0) { return @() }

        $out = @()
        for ($i = 0; $i -lt $nNames; $i++) {
            $p = & $rvaToFile ([BitConverter]::ToUInt32($b, $np + $i * 4))
            if ($p -lt 0) { continue }
            $end = $p
            while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
            $out += [System.Text.Encoding]::ASCII.GetString($b, $p, $end - $p)
        }
        $out
    } catch {
        @()
    }
}

# ---------------------------------------------------------------- 发现 patch

$script:SkippedPatches = @()

function Get-PatchList {
    $result = @()
    foreach ($pj in (Get-ChildItem -Path $ReposDir -Filter 'patch.js' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
        $dir = $pj.Directory
        try {
            $meta = Get-Content $pj.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Warn "$($dir.Name)\patch.js 解析失败，已跳过: $($_.Exception.Message)"
            continue
        }
        $id = if ($meta.id) { [string]$meta.id } else { $dir.Name }
        if ($AlwaysOn -contains $id) { continue }

        # 只列跟本作有关的补丁：补丁根目录下有 th18* 的文件或 th18/ 资源目录。
        # 这样 base_tasofro（黄昏边境游戏用）之类不会来占位置。被滤掉的会在控制台列出来。
        if (-not (Get-ChildItem -Path $dir.FullName -Filter 'th18*' -ErrorAction SilentlyContinue)) {
            $script:SkippedPatches += $id
            continue
        }

        # archive 必须是相对 thcrap 根目录的正斜杠路径
        $rel = $dir.FullName.Substring($ThcrapDir.Length).TrimStart('\') -replace '\\', '/'
        if (-not $rel.EndsWith('/')) { $rel += '/' }

        # 这个 patch 声明了哪些 breakpoint（codecave: 开头的不是 BP 函数；name#tag 取 name）
        $bps = @()
        foreach ($g in $GameJs) {
            $f = Join-Path $dir.FullName $g
            if (-not (Test-Path $f)) { continue }
            try {
                $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Write-Warn "$id\$g 解析失败: $($_.Exception.Message)"
                continue
            }
            if ($null -eq $j.breakpoints) { continue }
            foreach ($n in $j.breakpoints.PSObject.Properties.Name) {
                if ($n -like 'codecave:*') { continue }
                $bps += ($n -split '#')[0]
            }
        }

        $result += [pscustomobject]@{
            Id          = $id
            Title       = if ($meta.title) { [string]$meta.title } else { '' }
            Archive     = $rel
            Breakpoints = @($bps | Sort-Object -Unique)
            Display     = if ($meta.title) { "$id   -   $($meta.title)" } else { $id }
            Description = "archive : $rel" +
                          $(if ($meta.title) { "`r`n说明    : $($meta.title)" } else { '' }) +
                          $(if ($meta.dependencies) { "`r`n依赖    : $($meta.dependencies -join ', ')" } else { '' }) +
                          $(if ($bps.Count) { "`r`n声明断点: $(($bps | Sort-Object -Unique) -join ', ')   (需要某个已选 dll 导出 BP_<名字>)" }
                            else { "`r`n声明断点: (无)" })
        }
    }
    $result | Sort-Object Id
}

# ---------------------------------------------------------------- 发现 dll

function Get-ModList {
    $result = @()
    if (-not (Test-Path $ModsDir)) { return $result }
    foreach ($f in (Get-ChildItem -Path $ModsDir -Filter '*.dll' -File | Sort-Object Name)) {
        $stem  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $title = ''
        $desc  = ''
        $side  = Join-Path $ModsDir ($stem + '.json')
        if (Test-Path $side) {
            try {
                $meta  = Get-Content $side -Raw -Encoding UTF8 | ConvertFrom-Json
                $title = [string]$meta.title
                $desc  = [string]$meta.description
            } catch {
                Write-Warn "$($f.Name) 的侧车 json 解析失败，已忽略: $($_.Exception.Message)"
            }
        }

        $exports = Get-DllExportNames $f.FullName
        $isPlugin = $exports -contains 'thcrap_plugin_init'
        $provides = @($exports | Where-Object { $_ -like 'BP_*' } | ForEach-Object { $_.Substring(3) })

        $tag = if ($provides.Count) { "  [BP: $($provides -join ', ')]" } else { '' }
        $result += [pscustomobject]@{
            Name        = $f.Name
            Path        = $f.FullName
            Provides    = $provides
            IsPlugin    = $isPlugin
            Display     = $(if ($title) { "$($f.Name)   -   $title" } else { $f.Name }) + $tag
            Description = $(if ($desc) { $desc } else { "(没有 $stem.json，无说明)" }) +
                          "`r`n导出    : $(if ($exports.Count) { $exports -join ', ' } else { '(无)' })" +
                          $(if (-not $isPlugin) { "`r`n[!] 没有导出 thcrap_plugin_init，thcrap 不会把它当插件加载" } else { '' })
        }
    }
    $result
}

# ---------------------------------------------------------- 交叉检查 patch <-> dll

function Get-Mismatch([object[]]$patches, [object[]]$dlls) {
    $declared = @($patches | ForEach-Object { $_.Breakpoints } | Where-Object { $_ } | Sort-Object -Unique)
    $provided = @($dlls | ForEach-Object { $_.Provides } | Where-Object { $_ } | Sort-Object -Unique)
    $lines = @()
    foreach ($d in $declared) {
        if ($provided -notcontains $d) { $lines += "断点 $d 已声明，但没有已选 dll 导出 BP_$d —— 断点会装上但没人接，游戏无反应" }
    }
    foreach ($p in $provided) {
        if ($declared -notcontains $p) { $lines += "dll 导出了 BP_$p，但没有已选 patch 声明断点 $p —— dll 会加载但永远不触发" }
    }
    foreach ($m in $dlls) {
        if (-not $m.IsPlugin) { $lines += "$($m.Name) 没有导出 thcrap_plugin_init，不会被 thcrap 加载" }
    }
    $lines
}

# ---------------------------------------------------------------- 状态持久化

function Read-State {
    $state = @{ target = 'th18'; patches = @(); dlls = @() }
    # enabled.json 是本机状态，不进仓库；新 clone 下来就用仓库里的默认值开局
    $src = if (Test-Path $StateFile) { $StateFile }
           elseif (Test-Path $DefaultStateFile) { $DefaultStateFile }
           else { $null }
    if ($src) {
        try {
            $j = Get-Content $src -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.target)  { $state.target  = [string]$j.target }
            if ($j.patches) { $state.patches = @($j.patches) }
            if ($j.dlls)    { $state.dlls    = @($j.dlls) }
            elseif ($j.enabled) { $state.dlls = @($j.enabled) }   # 兼容旧格式
        } catch {
            Write-Warn "enabled.json 读取失败，按默认处理: $($_.Exception.Message)"
        }
    }
    $state
}

function Format-JsonArray([string[]]$items, [string]$indent) {
    if (-not $items -or $items.Count -eq 0) { return '[]' }
    $nl = "`r`n"
    $body = ($items | ForEach-Object { "$indent`t`"" + (ConvertTo-JsonStringLiteral $_) + "`"" }) -join ",$nl"
    "[$nl$body$nl$indent]"
}

function Write-State([string]$target, [string[]]$patches, [string[]]$dlls) {
    $nl = "`r`n"
    $t  = ConvertTo-JsonStringLiteral $target
    Write-TextNoBom $StateFile (
        "{$nl" +
        "`t`"target`": `"$t`",$nl" +
        "`t`"patches`": $(Format-JsonArray $patches "`t"),$nl" +
        "`t`"dlls`": $(Format-JsonArray $dlls "`t")$nl" +
        "}$nl")
}

# ------------------------------------------------------------ 生成 run config

# 这个文件每次启动都会被重写，别手改；要改栈就在窗口里勾。
function Write-RunConfig([object[]]$patches) {
    $nl = "`r`n"
    $archives = @('repos/nmlgc/base_tsa/') + @($patches | ForEach-Object { $_.Archive })
    $entries = ($archives | ForEach-Object {
        "`t`t{$nl`t`t`t`"archive`": `"" + (ConvertTo-JsonStringLiteral $_) + "`"$nl`t`t}"
    }) -join ",$nl"
    Write-TextNoBom (Join-Path $ConfigDir $RunConfig) (
        "{$nl" +
        "`t`"console`": true,$nl" +
        "`t`"dat_dump`": false,$nl" +
        "`t`"patched_files_dump`": false,$nl" +
        "`t`"patches`": [$nl$entries$nl`t]$nl" +
        "}$nl")
    $archives
}

function Update-GamesJs {
    $nl     = "`r`n"
    $th18   = ConvertTo-JsonStringLiteral ((Join-Path $GameDir 'th18.exe') -replace '\\', '/')
    $custom = ConvertTo-JsonStringLiteral ((Join-Path $GameDir 'custom.exe') -replace '\\', '/')
    Write-TextNoBom (Join-Path $ConfigDir 'games.js') `
        "{$nl`t`"th18`": `"$th18`",$nl`t`"th18_custom`": `"$custom`"$nl}$nl"
}

# ---------------------------------------------------------------- dll 暂存

# 返回仍被占用（删不掉）的 mod 原始文件名
function Clear-StagedMods {
    $stuck = @()
    foreach ($f in (Get-ChildItem -Path $BinDir -Filter "$Prefix*.dll" -File -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item $f.FullName -Force -ErrorAction Stop
        } catch {
            $stuck += $f.Name.Substring($Prefix.Length)
        }
    }
    $stuck
}

function Copy-StagedMods([object[]]$mods, [string[]]$stuck) {
    $loaded = @()
    foreach ($m in $mods) {
        if ($stuck -contains $m.Name) {
            Write-Warn "$($m.Name) 仍被上一局游戏占用，沿用 bin\ 里的旧版本（重编译的新版本本次不会生效）"
            $loaded += $m.Name
            continue
        }
        try {
            Copy-Item $m.Path (Join-Path $BinDir ($Prefix + $m.Name)) -Force -ErrorAction Stop
            $loaded += $m.Name
        } catch {
            Write-Err "$($m.Name) 复制到 bin\ 失败: $($_.Exception.Message)"
        }
    }
    $loaded
}

# ---------------------------------------------------------------- GUI

function Get-CheckedItems($clb, [int]$overrideIdx, [bool]$overrideVal) {
    $r = @()
    for ($i = 0; $i -lt $clb.Items.Count; $i++) {
        $c = if ($i -eq $overrideIdx) { $overrideVal } else { $clb.GetItemChecked($i) }
        if ($c) { $r += $clb.Items[$i] }
    }
    $r
}

function Show-ModDialog([object[]]$patches, [object[]]$mods, [hashtable]$state) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'TH18 Mod Loader'
    $form.ClientSize = New-Object System.Drawing.Size(560, 606)
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        $l
    }

    $form.Controls.Add((New-Label '补丁栈  (thcrap patch - breakpoint / binhack / 资源替换都在这一层)' 12 8 536 18))

    $clbP = New-Object System.Windows.Forms.CheckedListBox
    $clbP.Location = New-Object System.Drawing.Point(12, 28)
    $clbP.Size = New-Object System.Drawing.Size(536, 128)
    $clbP.CheckOnClick = $true
    $clbP.IntegralHeight = $false
    $clbP.DisplayMember = 'Display'
    foreach ($p in $patches) { [void]$clbP.Items.Add($p, ($state.patches -contains $p.Id)) }
    $form.Controls.Add($clbP)

    $lblBase = New-Label 'repos/nmlgc/base_tsa/  始终位于栈底（版本识别与引擎支持），不可取消' 12 160 536 18
    $lblBase.ForeColor = [System.Drawing.SystemColors]::GrayText
    $form.Controls.Add($lblBase)

    $form.Controls.Add((New-Label '自定义 DLL  (thcrap\bin 插件 - 提供 BP_xxx 断点处理函数)' 12 186 536 18))

    $clbD = New-Object System.Windows.Forms.CheckedListBox
    $clbD.Location = New-Object System.Drawing.Point(12, 206)
    $clbD.Size = New-Object System.Drawing.Size(536, 128)
    $clbD.CheckOnClick = $true
    $clbD.IntegralHeight = $false
    $clbD.DisplayMember = 'Display'
    foreach ($m in $mods) { [void]$clbD.Items.Add($m, ($state.dlls -contains $m.Name)) }
    $form.Controls.Add($clbD)

    $desc = New-Object System.Windows.Forms.TextBox
    $desc.Location = New-Object System.Drawing.Point(12, 342)
    $desc.Size = New-Object System.Drawing.Size(536, 84)
    $desc.Multiline = $true
    $desc.ReadOnly = $true
    $desc.ScrollBars = 'Vertical'
    $desc.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($desc)

    $status = New-Object System.Windows.Forms.TextBox
    $status.Location = New-Object System.Drawing.Point(12, 432)
    $status.Size = New-Object System.Drawing.Size(536, 76)
    $status.Multiline = $true
    $status.ReadOnly = $true
    $status.ScrollBars = 'Vertical'
    $status.BackColor = [System.Drawing.SystemColors]::Control
    $form.Controls.Add($status)

    # 状态栏只认传进来的两个集合，不自己去问控件。
    # （初始状态直接用 enabled.json 算——控件句柄创建时序不可靠，
    #   在 ShowDialog 前后读 GetItemChecked 拿到的结果不一致。）
    $setStatus = {
        param($sp, $sd)
        $sp = @($sp); $sd = @($sd)
        $bad = @(Get-Mismatch $sp $sd)
        if ($bad.Count -gt 0) {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = "[!] " + ($bad -join "`r`n[!] ")
        } else {
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
            $status.Text = "patch 与 dll 对得上。" +
                "`r`n栈 : base_tsa" + $(if ($sp.Count) { ', ' + (($sp | ForEach-Object { $_.Id }) -join ', ') } else { '' }) +
                "`r`ndll: " + $(if ($sd.Count) { ($sd | ForEach-Object { $_.Name }) -join ', ' } else { '(无)' })
        }
    }

    # 勾选变化时才去读控件：这时窗口已经显示，状态可靠；
    # 正在变的那一项用 ItemCheck 给的 NewValue，因为事件是在状态落地之前触发的。
    $refresh = {
        param([int]$pi = -1, [bool]$pv = $false, [int]$di = -1, [bool]$dv = $false)
        & $setStatus (Get-CheckedItems $clbP $pi $pv) (Get-CheckedItems $clbD $di $dv)
    }

    $clbP.Add_SelectedIndexChanged({ if ($clbP.SelectedItem) { $desc.Text = $clbP.SelectedItem.Description } })
    $clbD.Add_SelectedIndexChanged({ if ($clbD.SelectedItem) { $desc.Text = $clbD.SelectedItem.Description } })
    $clbP.Add_ItemCheck({ & $refresh $_.Index ($_.NewValue -eq [System.Windows.Forms.CheckState]::Checked) -1 $false })
    $clbD.Add_ItemCheck({ & $refresh -1 $false $_.Index ($_.NewValue -eq [System.Windows.Forms.CheckState]::Checked) })

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = '启动目标'
    $grp.Location = New-Object System.Drawing.Point(12, 516)
    $grp.Size = New-Object System.Drawing.Size(212, 52)
    $rbGame = New-Object System.Windows.Forms.RadioButton
    $rbGame.Text = 'th18.exe'
    $rbGame.Location = New-Object System.Drawing.Point(12, 20)
    $rbGame.Size = New-Object System.Drawing.Size(88, 22)
    $rbConf = New-Object System.Windows.Forms.RadioButton
    $rbConf.Text = 'custom.exe'
    $rbConf.Location = New-Object System.Drawing.Point(108, 20)
    $rbConf.Size = New-Object System.Drawing.Size(96, 22)
    if ($state.target -eq 'custom') { $rbConf.Checked = $true } else { $rbGame.Checked = $true }
    $grp.Controls.AddRange(@($rbGame, $rbConf))
    $form.Controls.Add($grp)

    $btnGo = New-Object System.Windows.Forms.Button
    $btnGo.Text = '启动'
    $btnGo.Location = New-Object System.Drawing.Point(346, 524)
    $btnGo.Size = New-Object System.Drawing.Size(96, 34)
    $btnGo.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnGo)
    $form.AcceptButton = $btnGo

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(452, 524)
    $btnCancel.Size = New-Object System.Drawing.Size(96, 34)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    if ($clbP.Items.Count -gt 0) { $clbP.SelectedIndex = 0 }
    & $setStatus @($patches | Where-Object { $state.patches -contains $_.Id }) `
                 @($mods    | Where-Object { $state.dlls    -contains $_.Name })

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    @{
        patches = @(Get-CheckedItems $clbP -1 $false)
        dlls    = @(Get-CheckedItems $clbD -1 $false)
        target  = $(if ($rbConf.Checked) { 'custom' } else { 'th18' })
    }
}

# ---------------------------------------------------------------- 游戏文件自检

# 不用 Get-FileHash：它在某些 Windows PowerShell 环境里不可用（模块自动加载被限制时）。
# 直接走 .NET，任何 PS 版本都有。
function Get-Sha256Hex([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs  = [System.IO.File]::OpenRead($path)
    try {
        -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $fs.Dispose(); $sha.Dispose()
    }
}

# 返回 @{ missing = @(...); mismatched = @(...) }
function Test-GameFiles {
    $missing = @()
    $mismatched = @()
    foreach ($set in @($GameRequired, $GameOptional)) {
        $required = [object]::ReferenceEquals($set, $GameRequired)
        foreach ($name in $set.Keys) {
            $f = Join-Path $GameDir $name
            if (-not (Test-Path $f)) {
                if ($required) { $missing += $name }
                continue
            }
            $want = $set[$name]
            if ($want -and (Get-Sha256Hex $f) -ne $want) { $mismatched += $name }
        }
    }
    @{ missing = $missing; mismatched = $mismatched }
}

# ---------------------------------------------------------------- main

Write-Host ''
Write-Host '=== TH18 Mod Loader ===' -ForegroundColor Cyan

foreach ($d in @($ModsDir, $BinDir, $ConfigDir, $GameDir, $ReposDir)) {
    if (-not (Test-Path $d)) { Write-Err "目录不存在: $d"; exit 1 }
}

$gameCheck = Test-GameFiles
if ($gameCheck.missing.Count -gt 0) {
    $msg = "game\ 里缺少这些文件：`r`n`r`n  " + ($gameCheck.missing -join "`r`n  ") +
           "`r`n`r`n本仓库不含游戏本体。请把《东方虹龙洞》v1.00a 原版的文件复制到：`r`n$GameDir" +
           "`r`n`r`n详见 docs/setup.md"
    Write-Err ($gameCheck.missing -join ', ')
    Write-Err "game\ 缺少上述文件，见 docs/setup.md"
    if (-not $NoUi) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'TH18 Mod Loader', 'OK', 'Error')
    }
    exit 1
}
if ($gameCheck.mismatched.Count -gt 0) {
    Write-Warn "这些文件的 SHA256 和 th18 v1.00a 原版对不上: $($gameCheck.mismatched -join ', ')"
    Write-Warn "（Steam 版 / 汉化版 / 改过的 exe 都不行——thcrap 靠哈希认版本，认不出就不会打补丁）"
}

$state = Read-State
if ($Target) { $state.target = $Target }

$stuck = Clear-StagedMods
if ($stuck.Count -gt 0) {
    Write-Warn "上一局游戏可能还开着，以下 mod 无法从 bin\ 撤下: $($stuck -join ', ')"
}

$allPatches = @(Get-PatchList)
$allMods    = @(Get-ModList)
if ($script:SkippedPatches.Count -gt 0) {
    Write-Step "跳过与 th18 无关的补丁: $($script:SkippedPatches -join ', ')"
}

if ($NoUi) {
    $choice = @{
        patches = @($allPatches | Where-Object { $state.patches -contains $_.Id })
        dlls    = @($allMods    | Where-Object { $state.dlls    -contains $_.Name })
        target  = $state.target
    }
    Write-Step '-NoUi: 沿用上次选择'
} else {
    $choice = Show-ModDialog $allPatches $allMods $state
    if ($null -eq $choice) { Write-Step '已取消，未启动。'; exit 0 }
}

foreach ($line in (Get-Mismatch $choice.patches $choice.dlls)) { Write-Warn $line }

$loaded   = Copy-StagedMods $choice.dlls $stuck
$archives = Write-RunConfig $choice.patches
Write-State $choice.target @($choice.patches | ForEach-Object { $_.Id }) $loaded
Update-GamesJs

$exeName = $(if ($choice.target -eq 'custom') { 'custom.exe' } else { 'th18.exe' })
$exePath = Join-Path $GameDir $exeName
if (-not (Test-Path $exePath)) { Write-Err "找不到 $exePath"; exit 1 }

Write-Host ''
Write-Step "run config : thcrap\config\$RunConfig  (每次启动重写)"
Write-Step "patch stack: $($archives -join '  ->  ')"
Write-Step "mod dll    : $(if ($loaded.Count) { $loaded -join ', ' } else { '(无)' })"
Write-Step "target exe : $exeName"
Write-Host ''

# 必须用 Start-Process 而不是 &：thcrap_loader.exe 是 GUI 子系统程序，
# PowerShell 用 & 调它不会等待、也不会设置 $LASTEXITCODE。
# -WorkingDirectory 很重要：run config 里的 archive 是相对 thcrap 根目录的。
$proc = Start-Process -FilePath (Join-Path $BinDir 'thcrap_loader.exe') `
    -ArgumentList @($RunConfig, ('"' + $exePath + '"')) `
    -WorkingDirectory $ThcrapDir -NoNewWindow -Wait -PassThru
$rc = $proc.ExitCode
if ($null -eq $rc) { $rc = 0 }

if ($rc -ne 0) {
    Write-Err "thcrap_loader 退出码 $rc，见 thcrap\logs\thcrap_log.txt"
    exit $rc
}
exit 0
