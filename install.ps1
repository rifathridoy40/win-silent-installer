#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Silent Installer (WSI) - unattended app setup for a fresh Windows 10/11 machine.

.DESCRIPTION
    Opens an interactive, keyboard-driven picker: arrow keys to move, Space to select, Right arrow to
    choose versions (Node.js, Python, JDK, XAMPP, IntelliJ), / to search, Enter to review and install.

    Everything installs silently, using winget first and falling back to official installers, npm, or
    vendor scripts. Pass -Apps / -All / -Recommended / -Config to skip the picker for unattended use.

.EXAMPLE
    .\install.ps1
    Interactive picker.

.EXAMPLE
    .\install.ps1 -Apps chrome,vscode,git,node,python,jdk -Node 22 -Python 3.12,3.13 -Jdk 21,17 -Yes
    Unattended install of the listed apps with specific versions.

.EXAMPLE
    .\install.ps1 -Config full-dev -Yes
    Install a bundled profile (profiles\full-dev.json), a profile path, or a profile URL.

.EXAMPLE
    .\install.ps1 -List
    Show every available app key.
#>
[CmdletBinding()]
param(
    # App keys to install (comma separated). See -List.
    [string[]]$Apps,
    # Install every app in the catalog.
    [switch]$All,
    # Add the recommended set (the apps pre-selected in the picker).
    [switch]$Recommended,
    # Profile: a JSON file path, a name from .\profiles, or an http(s) URL.
    [string]$Config,
    # lts | latest | <major> | <x.y.z> | nvm | nvm:<version>
    [string]$Node,
    # One or more: 3.13 | 3.12.8 ...   (first one becomes the default on PATH)
    [string[]]$Python,
    # One or more: [temurin|microsoft|zulu|corretto|oracle:]<major>   (first one becomes JAVA_HOME)
    [string[]]$Jdk,
    # 8.2 | 8.1
    [string]$Xampp,
    # ultimate | community
    [string]$IntelliJ,
    # Do not ask anything (use defaults for anything not specified).
    [switch]$Yes,
    # Reinstall even if the app is already detected.
    [switch]$Force,
    # Show what would be installed without installing anything.
    [switch]$DryRun,
    # List the catalog and exit.
    [switch]$List,
    # Reboot automatically at the end if an installer requested it.
    [switch]$Reboot,
    # Stream installer output to the console (it always goes to the log).
    [switch]$ShowOutput,
    # Folder for log files (default: .\logs next to the script).
    [string]$LogDir,
    # Internal: set when the script re-launched itself as administrator.
    [switch]$Elevated
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$script:Version        = '2.0.0'
$script:BoundParams    = $PSBoundParameters
$script:ScriptDir      = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:TEMP 'win-silent-installer' }
$script:DownloadDir    = Join-Path $env:TEMP 'wsi-downloads'
$script:RebootRequired = $false
$script:Results        = New-Object System.Collections.Generic.List[object]
$script:Tips           = @()
$script:InstalledNames = @()
$script:InstalledIds   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:ScanDone       = $false
$script:Status         = @{}
$script:CurLabel       = ''
$script:Live           = $true
try { $script:Live = -not [Console]::IsOutputRedirected } catch {}
try { $script:BaseBg = [Console]::BackgroundColor; $script:BaseFg = [Console]::ForegroundColor } catch { $script:BaseBg = 'Black'; $script:BaseFg = 'Gray' }
if ([int]$script:BaseBg -lt 0) { $script:BaseBg = 'Black' }
if (-not $LogDir) { $LogDir = Join-Path $script:ScriptDir 'logs' }

$Defaults = @{ node = 'lts'; python = @('3.13'); jdk = @('temurin:21'); xampp = '8.2'; intellij = 'ultimate' }

# winget / msiexec exit codes that mean "fine"
$OkCodes     = @(0, 3010, 1641, -1978335189, -1978335135, -1978334967, -1978334966)
$RebootCodes = @(3010, 1641, -1978334967, -1978334966)
$NoApplicableInstaller = -1978335216

# ============================================================================================
# Glyphs (all from the WGL4 set so they render in the default console fonts; WSI_ASCII=1 forces ASCII)
# ============================================================================================
$script:UseUnicode = (-not $env:WSI_ASCII) -and $script:Live
function Get-Glyph([int]$Code, [string]$Ascii) { if ($script:UseUnicode) { [string][char]$Code } else { $Ascii } }
$Gl = @{
    On = Get-Glyph 0x25CF '*'; Off = Get-Glyph 0x25CB 'o'; Ptr = Get-Glyph 0x25BA '>'; Dia = Get-Glyph 0x2666 '*'
    Ok = Get-Glyph 0x221A '+'; Bad = Get-Glyph 0x00D7 'x'; Dot = Get-Glyph 0x00B7 '-'; Warn = '!'
    H = Get-Glyph 0x2500 '-'; V = Get-Glyph 0x2502 '|'; TL = Get-Glyph 0x250C '+'; TR = Get-Glyph 0x2510 '+'
    BL = Get-Glyph 0x2514 '+'; BR = Get-Glyph 0x2518 '+'; L = Get-Glyph 0x25C4 '<'; R = Get-Glyph 0x25BA '>'
    Up = Get-Glyph 0x2191 '^'; Dn = Get-Glyph 0x2193 'v'; Right = Get-Glyph 0x2192 '->'; Left = Get-Glyph 0x2190 '<-'
}
$Spinner = if ($script:UseUnicode) {
    @("$($Gl.On)$($Gl.Off)$($Gl.Off)", "$($Gl.Off)$($Gl.On)$($Gl.Off)", "$($Gl.Off)$($Gl.Off)$($Gl.On)", "$($Gl.Off)$($Gl.On)$($Gl.Off)")
} else { @('|  ', '/  ', '-  ', '\  ') }

# ============================================================================================
# Output / logging
# ============================================================================================
function Write-Log {
    param([string]$Message)
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8 } catch {}
    }
}
function Write-Info  { param([string]$m) Write-Host "       $m" -ForegroundColor DarkGray; Write-Log "INFO  $m" }
function Write-Ok    { param([string]$m) Write-Host "       $($Gl.Ok) $m" -ForegroundColor Green; Write-Log "OK    $m" }
function Write-Warn  { param([string]$m) Write-Host "       ! $m" -ForegroundColor Yellow; Write-Log "WARN  $m" }
function Write-Fail  { param([string]$m) Write-Host "  $($Gl.Bad)  $m" -ForegroundColor Red; Write-Log "FAIL  $m" }

function Write-Step {
    param([ValidateSet('ok', 'warn', 'fail', 'skip')][string]$State, [string]$Text, [string]$Detail)
    $g, $c = switch ($State) { 'ok' { $Gl.Ok, 'Green' } 'warn' { '!', 'Yellow' } 'fail' { $Gl.Bad, 'Red' } default { $Gl.Off, 'DarkGray' } }
    Write-Host "  $g  " -ForegroundColor $c -NoNewline
    Write-Host $Text -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host "  $Detail" -ForegroundColor DarkGray } else { Write-Host '' }
    Write-Log "STEP  [$State] $Text $Detail"
}

function Write-Rule {
    param([string]$Label)
    $w = 72
    try { $w = [Math]::Min(96, [Console]::WindowWidth - 4) } catch {}
    if ($Label) {
        Write-Host ''
        Write-Host "  $Label" -ForegroundColor Cyan
    }
    Write-Host ('  ' + ($Gl.H * $w)) -ForegroundColor DarkGray
}

# Installer output goes to the log (and the console with -ShowOutput). Spinner/progress-bar noise is dropped.
function Write-NativeOutput {
    param($Lines)
    foreach ($l in @($Lines)) {
        $s = ("$l" -replace '[\x00-\x08\x0B-\x1F]', '').Trim()
        if (-not $s -or $s -notmatch '[A-Za-z]') { continue }
        Write-Log "  | $s"
        if ($ShowOutput) { Write-Host "         $s" -ForegroundColor DarkGray }
    }
}

function Show-Banner {
    Write-Host ''
    Write-Host "  $($Gl.Dia) " -ForegroundColor Cyan -NoNewline
    Write-Host 'WINDOWS SILENT INSTALLER' -ForegroundColor White -NoNewline
    Write-Host "  v$($script:Version)" -ForegroundColor DarkGray
    Write-Host '    Silent, unattended app setup for a fresh Windows 10/11 PC' -ForegroundColor DarkGray
    Write-Host ''
}

function Format-Elapsed([TimeSpan]$t) { if ($t.TotalHours -ge 1) { $t.ToString('h\:mm\:ss') } else { $t.ToString('m\:ss') } }

# ============================================================================================
# Environment helpers
# ============================================================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    if (-not $PSCommandPath) {
        Write-Host 'Administrator rights are required. Re-run from an elevated PowerShell (Run as administrator).' -ForegroundColor Red
        exit 1
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $script:BoundParams.GetEnumerator()) {
        $v = $kv.Value
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$($kv.Key)" }
        } else {
            $argList += "-$($kv.Key)"
            $argList += ('"{0}"' -f ((@($v) -join ',') -replace '"', ''))
        }
    }
    $argList += '-Elevated'
    Write-Host '  Requesting administrator rights - approve the UAC prompt to continue in a new window.' -ForegroundColor Yellow
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host '  Administrator rights are required (the UAC prompt was declined).' -ForegroundColor Red
        exit 1
    }
    exit 0
}

function Send-EnvChange {
    if (-not ('Wsi.Native' -as [type])) {
        Add-Type -Namespace Wsi -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $r = [UIntPtr]::Zero
    [void][Wsi.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
}

# Reload PATH (and a few tool variables) from the registry so freshly installed tools are usable right away.
function Update-SessionEnv {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra   = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
        "$env:ProgramFiles\WinGet\Links",
        "$env:APPDATA\npm",
        "$env:USERPROFILE\.local\bin"
    )
    $seen = @{}
    $parts = foreach ($p in (@("$machine;$user" -split ';') + $extra)) {
        if ($p -and -not $seen.ContainsKey($p.ToLower())) { $seen[$p.ToLower()] = 1; $p }
    }
    $env:Path = $parts -join ';'
    foreach ($name in 'JAVA_HOME', 'NVM_HOME', 'NVM_SYMLINK') {
        $v = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name, 'User') }
        if ($v) { Set-Item -Path "Env:$name" -Value $v }
    }
}

# Add a folder to the persistent PATH, keeping REG_EXPAND_SZ entries like %SystemRoot% intact.
function Add-ToPath {
    param([string]$Dir, [ValidateSet('Machine', 'User')][string]$Scope = 'Machine', [switch]$Prepend)
    if (-not $Dir -or -not (Test-Path $Dir)) { return }
    $key = if ($Scope -eq 'Machine') {
        [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    } else {
        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    }
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $norm    = $Dir.TrimEnd('\')
        $parts   = @($current -split ';' | Where-Object { $_ })
        $exists  = @($parts | Where-Object { $_.TrimEnd('\') -ieq $norm }).Count -gt 0
        if ($exists -and -not $Prepend) { return }
        $parts = @($parts | Where-Object { $_.TrimEnd('\') -ine $norm })
        $new   = if ($Prepend) { @($Dir) + $parts } else { $parts + @($Dir) }
        $key.SetValue('Path', ($new -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Write-Info "PATH ($Scope) += $Dir"
    } finally { $key.Close() }
    Send-EnvChange
    Update-SessionEnv
}

function Set-MachineEnv {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "Env:$Name" -Value $Value
    Send-EnvChange
    Write-Info "$Name = $Value"
}

function Get-Download {
    param([string]$Url, [string]$FileName)
    if (-not (Test-Path $script:DownloadDir)) { New-Item -ItemType Directory -Path $script:DownloadDir -Force | Out-Null }
    if (-not $FileName) { $FileName = ([uri]$Url).Segments[-1] }
    $dest = Join-Path $script:DownloadDir $FileName
    Write-Log "Downloading $Url"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $code = Invoke-Process 'curl.exe' "-fsSL --retry 3 -o `"$dest`" `"$Url`"" 'downloading'
        if ($code -eq 0 -and (Test-Path $dest)) { return $dest }
    }
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    return $dest
}

function Test-ExitCode {
    param([int]$Code)
    if ($RebootCodes -contains $Code) { $script:RebootRequired = $true }
    return ($OkCodes -contains $Code)
}

# Run a process with a live spinner line; its output goes to the log. Returns the exit code.
function Invoke-Process {
    param([string]$File, [string]$Arguments, [string]$Label)
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    Write-Log "RUN   $File $Arguments"
    $sp = @{ FilePath = $File; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $out; RedirectStandardError = $err }
    if ($Arguments) { $sp.ArgumentList = $Arguments }
    $p = Start-Process @sp
    $null = $p.Handle   # keeps ExitCode readable after exit
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $i = 0
    while (-not $p.HasExited) {
        if ($script:Live) {
            $text = "  {0}  {1}  {2}" -f $Spinner[$i % $Spinner.Count], $script:CurLabel, $Label
            $time = Format-Elapsed $sw.Elapsed
            try {
                $w = [Console]::WindowWidth - 1
                $room = $w - $time.Length - 2
                if ($text.Length -gt $room) { $text = $text.Substring(0, [Math]::Max(0, $room)) }
                [Console]::ForegroundColor = 'Cyan'
                [Console]::Write("`r" + $text.PadRight($room) + '  ')
                [Console]::ForegroundColor = 'DarkGray'
                [Console]::Write($time)
                [Console]::ResetColor()
            } catch {}
            $i++
        }
        Start-Sleep -Milliseconds 120
    }
    $p.WaitForExit()
    if ($script:Live) { try { [Console]::Write("`r" + (' ' * ([Console]::WindowWidth - 1)) + "`r") } catch {} }
    $script:LastOutput = @(Get-Content $out -Encoding UTF8 -ErrorAction SilentlyContinue)
    Write-NativeOutput ($script:LastOutput + @(Get-Content $err -Encoding UTF8 -ErrorAction SilentlyContinue))
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    Write-Log "EXIT  $($p.ExitCode)"
    return $p.ExitCode
}

# ============================================================================================
# winget
# ============================================================================================
function Get-WingetPath {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Get-WingetVersion {
    if (-not (Get-WingetPath)) { return $null }
    try {
        $v = & winget --version 2>$null | Select-Object -First 1
        if ("$v" -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    } catch {}
    return $null
}

function Initialize-Winget {
    Update-SessionEnv
    $v = Get-WingetVersion
    if ($v -and $v -ge [version]'1.6') { Write-Step ok "winget $v"; return $true }

    if ($v) { Write-Step warn "winget $v is too old" 'updating App Installer...' } else { Write-Step warn 'winget not found' 'installing App Installer...' }
    try {
        Write-Info 'Installing the Microsoft.WinGet.Client module and repairing winget'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Latest -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warn "Module method failed ($($_.Exception.Message)); trying a direct MSIX install"
        $pkgs = @(
            @{ Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; File = 'VCLibs.appx' },
            @{ Url = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'; File = 'UIXaml.appx' },
            @{ Url = 'https://aka.ms/getwinget'; File = 'AppInstaller.msixbundle' }
        )
        foreach ($p in $pkgs) {
            try { Add-AppxPackage -Path (Get-Download $p.Url $p.File) -ErrorAction Stop }
            catch { Write-Warn "$($p.File): $($_.Exception.Message)" }
        }
    }
    Update-SessionEnv
    $v = Get-WingetVersion
    if (-not $v) {
        Write-Step fail 'winget is unavailable' 'only apps with direct-download fallbacks can be installed'
        return $false
    }
    Write-Step ok "winget $v" 'installed'
    return $true
}

# One 'winget list' gives (almost) every installed package - much faster than a 'winget list --id' per app.
# Bulk listing sometimes correlates an app to an msstore/ARP entry instead of its winget id, so names are
# matched too; anything still not found is re-checked precisely with 'winget list --id' before installing.
function Update-InstalledScan {
    $script:InstalledIds.Clear()
    $script:InstalledNames = @()
    $wg = Get-WingetPath
    if ($wg) {
        $script:CurLabel = 'Scanning installed apps'
        $null = Invoke-Process $wg 'list --accept-source-agreements --disable-interactivity' ''
        $script:CurLabel = ''
        $lines = @($script:LastOutput)
        $hi = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version') { $hi = $i; break } }
        if ($hi -ge 0) {
            $hdr = $lines[$hi] -replace '^[^N]*', ''
            $off = $lines[$hi].Length - $hdr.Length
            $idStart = $hdr.IndexOf(' Id ') + 1 + $off
            $verStart = $hdr.IndexOf(' Version ') + 1 + $off
            foreach ($l in $lines[($hi + 1)..($lines.Count - 1)]) {
                if ($l -match '^-+$' -or $l.Length -le $idStart) { continue }
                $id = $l.Substring($idStart, [Math]::Min($verStart, $l.Length) - $idStart).Trim().TrimEnd([char]0x2026)
                if ($id) { [void]$script:InstalledIds.Add($id) }
                $script:InstalledNames += (($l.Substring(0, $idStart)).ToLower() -replace '[^a-z0-9]', '')
            }
            $script:ScanDone = $true
        }
    }
    foreach ($a in $Catalog) { $script:Status[$a.Key] = Get-AppStatus $a }
    $n = @($Catalog | Where-Object { $script:Status[$_.Key].On }).Count
    if ($script:ScanDone) { Write-Step ok 'Scanned installed apps' "$n of $($Catalog.Count) catalog apps already installed" }
    else { Write-Step warn 'Could not scan installed apps' 'installed apps are detected one by one instead' }
}

# Fuzzy match: the last part of the winget id (e.g. "PowerToys", "qBittorrent") appears in an installed app's name.
function Test-NameInstalled {
    param([string]$WingetId)
    if (-not $WingetId) { return $false }
    $token = (($WingetId -split '\.')[-1]).ToLower() -replace '[^a-z0-9]', ''
    if ($token.Length -lt 5) { return $false }
    foreach ($n in $script:InstalledNames) { if ($n.Contains($token)) { return $true } }
    return $false
}

function Test-WingetInstalled {
    param([string]$Id)
    if ($script:InstalledIds.Contains($Id) -or (Test-NameInstalled $Id)) { return $true }
    if (-not (Get-WingetPath)) { return $false }
    $null = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Winget {
    param([string]$Id, [string]$Version, [string]$Scope)
    $wgPath = Get-WingetPath
    if (-not $wgPath) { Write-Warn 'winget not available'; return $false }
    $wg = "install --id $Id --exact --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity"
    if ($Version) { $wg += " --version $Version" }
    if ($Scope)   { $wg += " --scope $Scope" }
    $code = Invoke-Process $wgPath $wg "winget $Id"
    if ($code -eq $NoApplicableInstaller -and $Scope) {
        Write-Info "No $Scope-scope installer, retrying with the default scope"
        return Invoke-Winget -Id $Id -Version $Version
    }
    if (Test-ExitCode $code) { return $true }
    Write-Warn ("winget exit code {0} (0x{1:X8})" -f $code, $code)
    return $false
}

# Highest winget version of the first package id that has a version matching the prefix (e.g. "22" or "20.18").
function Resolve-WingetVersion {
    param([string[]]$Ids, [string]$Prefix)
    foreach ($id in $Ids) {
        $out  = & winget show --id $id --exact --versions --source winget --accept-source-agreements --disable-interactivity 2>$null
        $vers = @($out | ForEach-Object { "$_".Trim() } |
                  Where-Object { $_ -match '^\d+(\.\d+)+$' -and ($_ -eq $Prefix -or $_.StartsWith("$Prefix.")) })
        if ($vers.Count) {
            $best = $vers | Sort-Object { try { [version]$_ } catch { [version]'0.0' } } -Descending | Select-Object -First 1
            return @{ Id = $id; Version = $best }
        }
    }
    return $null
}

# ============================================================================================
# Install methods
# ============================================================================================
function Get-MethodLabel {
    param($m)
    switch ($m.Type) {
        'winget' { if ($m.Version) { "winget $($m.Id) @ $($m.Version)" } else { "winget $($m.Id)" } }
        'npm'    { "npm -g $($m.Package)" }
        'script' { "script: $($m.Label)" }
        default  { "$($m.Type): $($m.Url)" }
    }
}

function Get-MethodShort {
    param($m)
    switch ($m.Type) { 'winget' { 'winget' } 'npm' { 'npm' } 'script' { 'official script' } default { "direct $($m.Type)" } }
}

function Invoke-Method {
    param($m)
    switch ($m.Type) {
        'winget' { return (Invoke-Winget -Id $m.Id -Version $m.Version -Scope $m.Scope) }
        'msi' {
            $f = Get-Download $m.Url $m.File
            return (Test-ExitCode (Invoke-Process 'msiexec.exe' "/i `"$f`" /qn /norestart $($m.Args)" 'running MSI installer'))
        }
        'exe' {
            $f = Get-Download $m.Url $m.File
            return (Test-ExitCode (Invoke-Process $f $m.Args 'running installer'))
        }
        'zip' {
            $f = Get-Download $m.Url $m.File
            Expand-Archive -Path $f -DestinationPath $m.Dest -Force -ErrorAction Stop
            foreach ($d in @($m.PathAdd)) { Add-ToPath $d }
            return $true
        }
        'npm' {
            Update-SessionEnv
            if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { Write-Warn 'npm not found - install Node.js first'; return $false }
            return ((Invoke-Process 'cmd.exe' "/c npm install -g $($m.Package)" "npm -g $($m.Package)") -eq 0)
        }
        'script' { return [bool](& $m.Script) }
    }
    return $false
}

# ============================================================================================
# Pre/Post hooks (scriptblocks receive the task object)
# ============================================================================================
$DockerPre = {
    param($t)
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    Write-Info 'Enabling WSL 2 (required by Docker Desktop)'
    $code = Invoke-Process 'wsl.exe' '--install --no-distribution' 'enabling WSL 2'
    if ($code -ne 0) {
        $null = Invoke-Process 'dism.exe' '/online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart' 'enabling WSL'
        $null = Invoke-Process 'dism.exe' '/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart' 'enabling Virtual Machine Platform'
    }
    $script:RebootRequired = $true
}

$DockerPost = {
    param($t)
    try {
        Add-LocalGroupMember -Group 'docker-users' -Member "$env:USERDOMAIN\$env:USERNAME" -ErrorAction Stop
        Write-Info "Added $env:USERNAME to docker-users"
    } catch {}
}

$OpenSslPost = {
    param($t)
    foreach ($d in @("$env:ProgramFiles\OpenSSL-Win64\bin", "$env:ProgramFiles\OpenSSL\bin")) {
        if (Test-Path $d) { Add-ToPath $d; break }
    }
}

$ClaudeScript = {
    $null = Invoke-Process 'powershell.exe' '-NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"' 'claude.ai/install.ps1'
    Update-SessionEnv
    return ([bool](Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path "$env:USERPROFILE\.local\bin\claude.exe"))
}

$ClaudePost = { param($t) Add-ToPath "$env:USERPROFILE\.local\bin" -Scope User }

$NvmPost = {
    param($t)
    Update-SessionEnv
    if (-not (Get-Command nvm -ErrorAction SilentlyContinue)) {
        Write-Warn "nvm is not on PATH yet - open a new terminal and run: nvm install $($t.Data.Version)"
        return
    }
    $v = $t.Data.Version
    $null = Invoke-Process 'cmd.exe' "/c nvm install $v" "nvm install $v"
    $null = Invoke-Process 'cmd.exe' "/c nvm use $v" "nvm use $v"
    Update-SessionEnv
}

$NodeCheck = {
    param($t)
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $false }
    $have = "$(& node --version)".Trim().TrimStart('v')
    $want = $t.Data.Want
    return ($have -eq $want -or $have.StartsWith("$want."))
}

function Find-PythonHome {
    param([string]$Minor)
    $tag = $Minor -replace '\.', ''
    foreach ($d in @("$env:ProgramFiles\Python$tag", "$env:LOCALAPPDATA\Programs\Python\Python$tag")) {
        if (Test-Path (Join-Path $d 'python.exe')) { return $d }
    }
    return $null
}

$PythonPost = {
    param($t)
    if (-not $t.Data.Primary) { return }
    $dir = Find-PythonHome $t.Data.Minor
    if (-not $dir) { Write-Warn "Python $($t.Data.Minor) folder not found - PATH not changed"; return }
    $scope = if ($dir.StartsWith($env:ProgramFiles)) { 'Machine' } else { 'User' }
    Add-ToPath (Join-Path $dir 'Scripts') -Scope $scope -Prepend
    Add-ToPath $dir -Scope $scope -Prepend
}

function Find-JdkHome {
    param([string]$Major)
    $roots = @("$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Zulu",
               "$env:ProgramFiles\Amazon Corretto", "$env:ProgramFiles\Java")
    $dirs = foreach ($r in $roots) {
        if (Test-Path $r) {
            Get-ChildItem -Path $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') }
        }
    }
    $match = $dirs | Where-Object {
        # first number in the folder name is the major ("jdk-21.0.4", "zulu-21", "jdk8u422"); "jdk1.8.0_x" means 8
        $nums = @([regex]::Matches($_.Name, '\d+') | ForEach-Object { $_.Value })
        if (-not $nums.Count) { return $false }
        $first = $nums[0]
        if ($first -eq '1' -and $nums.Count -gt 1) { $first = $nums[1] }
        $first -eq $Major
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($match) { return $match.FullName }
    return $null
}

$JdkPost = {
    param($t)
    if (-not $t.Data.Primary) { return }
    $jh = Find-JdkHome $t.Data.Major
    if (-not $jh) { Write-Warn "JDK $($t.Data.Major) folder not found - JAVA_HOME not set"; return }
    Set-MachineEnv 'JAVA_HOME' $jh
    Add-ToPath (Join-Path $jh 'bin') -Prepend
}

# ============================================================================================
# Catalog
# ============================================================================================
function App {
    param([string]$Key, [string]$Name, [string]$Cat, [string]$Winget, [switch]$Rec, [object[]]$Fallback,
          [string]$CheckCmd, [string]$CheckPath, [string]$Special, [scriptblock]$Pre, [scriptblock]$Post,
          [int]$Order = 50, [string]$Desc, [string]$Needs, [string]$Tip, [string[]]$Alias)
    @{ Key = $Key; Name = $Name; Cat = $Cat; Winget = $Winget; Rec = $Rec.IsPresent; Fallback = $Fallback
       CheckCmd = $CheckCmd; CheckPath = $CheckPath; Special = $Special; Pre = $Pre; Post = $Post
       Order = $Order; Desc = $Desc; Needs = $Needs; Tip = $Tip; Alias = $Alias }
}

$cBrowser = 'Browsers & Communication'
$cEditor  = 'Editors & IDEs'
$cAi      = 'AI Coding CLIs'
$cLang    = 'Languages & Runtimes'
$cDev     = 'Dev Tools & Databases'
$cCli     = 'Command-line Tools'
$cNet     = 'Terminals & Network'
$cUtil    = 'System Utilities'
$cMedia   = 'Media & Downloads'

$Catalog = @(
    App chrome     'Google Chrome'              $cBrowser Google.Chrome -Rec -Desc "Google's web browser. Falls back to the enterprise MSI if winget fails." -Fallback @(@{ Type = 'msi'; Url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; File = 'chrome.msi' })
    App firefox    'Mozilla Firefox'            $cBrowser Mozilla.Firefox -Desc "Mozilla's open-source web browser."
    App brave      'Brave Browser'              $cBrowser Brave.Brave -Desc 'Privacy-focused Chromium browser with a built-in ad blocker.'
    App zoom       'Zoom Workplace'             $cBrowser Zoom.Zoom -Rec -Desc 'Video meetings, chat and phone.' -Fallback @(@{ Type = 'msi'; Url = 'https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64'; File = 'zoom.msi' })
    App telegram   'Telegram Desktop'           $cBrowser Telegram.TelegramDesktop -Desc 'Fast, cloud-based messenger.'
    App discord    'Discord'                    $cBrowser Discord.Discord -Desc 'Voice, video and text chat for communities.'
    App slack      'Slack'                      $cBrowser SlackTechnologies.Slack -Desc 'Team messaging and collaboration.'

    App vscode     'Visual Studio Code'         $cEditor Microsoft.VisualStudioCode -Rec -CheckCmd code -Alias code, 'vs-code' -Desc "Microsoft's code editor. Adds 'code' to PATH and Explorer 'Open with Code' entries." -Fallback @(@{ Type = 'exe'; Url = 'https://update.code.visualstudio.com/latest/win32-x64/stable'; File = 'VSCodeSetup.exe'; Args = '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath' })
    App intellij   'IntelliJ IDEA'              $cEditor -Special intellij -Rec -Alias idea -Desc 'JetBrains IDE for Java and Kotlin. Ultimate is the unified IDE with a free tier; Community is the classic free edition.'
    App pycharm    'PyCharm'                    $cEditor JetBrains.PyCharm -Rec -Alias 'pycharm-community', 'pycharm-professional' -Desc 'JetBrains IDE for Python. The unified edition is free for core features, with Pro features on a subscription.'
    App phpstorm   'PhpStorm'                   $cEditor JetBrains.PhpStorm -Rec -Alias php-storm -Desc 'JetBrains IDE for PHP, Laravel, Symfony and WordPress. Paid, with a 30-day free trial.'
    App toolbox    'JetBrains Toolbox'          $cEditor JetBrains.Toolbox -Rec -Alias 'jetbrains-toolbox' -Desc 'Install, update and manage every JetBrains IDE from one place.'
    App notepadpp  'Notepad++'                  $cEditor 'Notepad++.Notepad++' -Alias 'notepad++' -Desc 'Lightweight source-code and text editor.'
    App cursor     'Cursor'                     $cEditor Anysphere.Cursor -Desc 'AI-first code editor built on VS Code.'

    App claude     'Claude Code'                $cAi Anthropic.ClaudeCode -Rec -CheckCmd claude -Order 90 -Post $ClaudePost -Alias 'claude-code' -Desc "Anthropic's agentic coding tool for the terminal. Tries winget, then the official installer, then npm." -Tip "Run 'claude' in a new terminal to sign in." -Fallback @(@{ Type = 'script'; Label = 'claude.ai/install.ps1'; Script = $ClaudeScript }, @{ Type = 'npm'; Package = '@anthropic-ai/claude-code' })
    App copilot    'GitHub Copilot CLI'         $cAi GitHub.Copilot -Rec -CheckCmd copilot -Order 90 -Alias 'copilot-cli' -Desc 'GitHub Copilot as a coding agent in your terminal. Falls back to npm.' -Tip "Run 'copilot' and use /login to sign in." -Fallback @(@{ Type = 'npm'; Package = '@github/copilot' })
    App opencode   'OpenCode'                   $cAi SST.opencode -Rec -CheckCmd opencode -Order 90 -Desc 'Open-source AI coding agent for the terminal. Falls back to npm.' -Fallback @(@{ Type = 'npm'; Package = 'opencode-ai' })
    App gemini     'Gemini CLI'                 $cAi -CheckCmd gemini -Order 90 -Needs node -Desc "Google's Gemini coding agent for the terminal. Installed with npm, so Node.js is added automatically." -Fallback @(@{ Type = 'npm'; Package = '@google/gemini-cli' })
    App codex      'OpenAI Codex CLI'           $cAi -CheckCmd codex -Order 90 -Needs node -Desc "OpenAI's Codex coding agent for the terminal. Installed with npm, so Node.js is added automatically." -Fallback @(@{ Type = 'npm'; Package = '@openai/codex' })

    App node       'Node.js'                    $cLang -Special node -Rec -Order 10 -Alias nodejs -Desc 'JavaScript runtime with npm. Choose LTS, latest, a specific version, or NVM for Windows to switch versions later.'
    App python     'Python'                     $cLang -Special python -Rec -Order 10 -Alias py -Desc 'Python with pip and the py launcher. Install several versions side by side; the default one goes on PATH.'
    App jdk        'Java JDK'                   $cLang -Special jdk -Rec -Order 10 -Alias java, openjdk -Desc 'Java Development Kit. Choose the vendor and one or more versions; the default becomes JAVA_HOME.'
    App go         'Go'                         $cLang GoLang.Go -Alias golang -Desc 'The Go programming language toolchain.'
    App rust       'Rust (rustup)'              $cLang Rustlang.Rustup -Alias rustup -Desc 'rustup installs and manages Rust toolchains (cargo, rustc).'

    App git        'Git'                        $cDev Git.Git -Rec -CheckCmd git -Order 5 -Desc 'Distributed version control, including Git Bash and Git Credential Manager.'
    App gh         'GitHub CLI'                 $cDev GitHub.cli -CheckCmd gh -Alias 'github-cli' -Desc 'Pull requests, issues and repos from the command line.'
    App docker     'Docker Desktop'             $cDev Docker.DockerDesktop -Rec -Pre $DockerPre -Post $DockerPost -Desc 'Build and run containers. Enables WSL 2 first if needed and adds you to docker-users.' -Tip 'Reboot, then start Docker Desktop once to finish WSL 2 setup.' -Fallback @(@{ Type = 'exe'; Url = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'; File = 'DockerDesktopInstaller.exe'; Args = 'install --quiet --accept-license' })
    App xampp      'XAMPP'                      $cDev -Special xampp -Rec -Desc 'Apache, MariaDB, PHP and Perl in C:\xampp. Choose the PHP version.'
    App pgadmin    'pgAdmin 4'                  $cDev PostgreSQL.pgAdmin -Rec -Alias pgadmin4 -Desc 'Management and query tool for PostgreSQL.'
    App dbeaver    'DBeaver Community'          $cDev DBeaver.DBeaver.Community -Desc 'Universal database client for SQL and NoSQL databases.'
    App postman    'Postman'                    $cDev Postman.Postman -Desc 'Build, test and document HTTP APIs.'

    App ffmpeg     'FFmpeg'                     $cCli Gyan.FFmpeg -Rec -CheckCmd ffmpeg -Desc 'Record, convert and stream audio and video from the command line.'
    App openssl    'OpenSSL'                    $cCli ShiningLight.OpenSSL.Light -Rec -Post $OpenSslPost -Desc 'OpenSSL command-line tool; its bin folder is added to PATH.'
    App adb        'Android Platform-Tools'     $cCli Google.PlatformTools -Rec -CheckCmd adb -Alias 'platform-tools' -Desc 'adb and fastboot for Android devices. Falls back to the zip from Google.' -Fallback @(@{ Type = 'zip'; Url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'; File = 'platform-tools.zip'; Dest = 'C:\Android'; PathAdd = 'C:\Android\platform-tools' })
    App ytdlp      'yt-dlp'                     $cCli yt-dlp.yt-dlp -CheckCmd yt-dlp -Alias 'yt-dlp' -Desc 'Download video and audio from YouTube and many other sites.'
    App pwsh       'PowerShell 7'               $cCli Microsoft.PowerShell -Alias powershell -Desc 'Modern cross-platform PowerShell; runs side by side with Windows PowerShell 5.1.'

    App tabby      'Tabby (formerly Terminus)'  $cNet Eugeny.Tabby -Rec -Alias terminus -Desc 'Modern terminal with SSH and serial support. Terminus was renamed Tabby.'
    App termius    'Termius'                    $cNet Termius.Termius -Desc 'SSH client with synced hosts, keys and snippets.'
    App wterminal  'Windows Terminal'           $cNet Microsoft.WindowsTerminal -Alias 'windows-terminal' -Desc "Microsoft's tabbed terminal (built into Windows 11)."
    App warp       'Cloudflare 1.1.1.1 WARP'    $cNet Cloudflare.Warp -Rec -Alias cloudflare, '1.1.1.1' -Desc "Cloudflare's 1.1.1.1 DNS resolver and WARP VPN client." -Fallback @(@{ Type = 'msi'; Url = 'https://1111-releases.cloudflareclient.com/win/latest'; File = 'Cloudflare_WARP.msi' })

    App powertoys  'Microsoft PowerToys'        $cUtil Microsoft.PowerToys -Rec -Desc 'Power-user utilities: FancyZones, PowerRename, Command Palette, Color Picker and more.'
    App 7zip       '7-Zip'                      $cUtil 7zip.7zip -Alias 7z -Desc 'Free file archiver with a high compression ratio.'
    App winzip     'WinZip'                     $cUtil Corel.WinZip -Desc 'File compression utility. Paid app with a free trial.'
    App wzcline    'WinZip Command Line'        $cUtil Corel.WinZip.CommandLineSupportAddOn -Alias 'winzip-cli', wzzip -Desc 'wzzip and wzunzip commands for scripts. Requires WinZip.'
    App everything 'Everything'                 $cUtil voidtools.Everything -Desc 'Instant file-name search across all your drives.'
    App sharex     'ShareX'                     $cUtil ShareX.ShareX -Desc 'Screenshots, screen recording and file sharing.'

    App vlc        'VLC media player'           $cMedia VideoLAN.VLC -Rec -Desc 'Plays almost any audio and video format.'
    App qbittorrent 'qBittorrent'               $cMedia qBittorrent.qBittorrent -Rec -Alias qbit -Desc 'Open-source BitTorrent client with no ads.'
    App obs        'OBS Studio'                 $cMedia OBSProject.OBSStudio -Desc 'Screen recording and live streaming.'
)

$CatalogByKey = @{}
$AliasMap = @{}
foreach ($a in $Catalog) {
    $CatalogByKey[$a.Key] = $a
    $AliasMap[$a.Key] = $a.Key
    foreach ($al in @($a.Alias)) { if ($al) { $AliasMap[$al.ToLower()] = $a.Key } }
}

$JdkVendors = [ordered]@{
    temurin   = 'EclipseAdoptium.Temurin.{0}.JDK'
    microsoft = 'Microsoft.OpenJDK.{0}'
    zulu      = 'Azul.Zulu.{0}.JDK'
    corretto  = 'Amazon.Corretto.{0}.JDK'
    oracle    = 'Oracle.JDK.{0}'
}
$JdkHints = @{ '25' = 'LTS, newest'; '21' = 'LTS'; '17' = 'LTS'; '11' = 'LTS, older'; '8' = 'legacy' }
$JdkVendorNames = @{ temurin = 'Eclipse Temurin'; microsoft = 'Microsoft OpenJDK'; zulu = 'Azul Zulu'; corretto = 'Amazon Corretto'; oracle = 'Oracle JDK' }

$Patterns = @{
    node     = '^(?i)(lts|latest|current|nvm(:\S+)?|v?\d+(\.\d+){0,2})$'
    python   = '^3\.\d+(\.\d+)?$'
    jdk      = '^(?i)((temurin|microsoft|zulu|corretto|oracle):)?\d+$'
    xampp    = '^8\.[12]$'
    intellij = '^(?i)(ultimate|community)$'
}

# ============================================================================================
# Installed status
# ============================================================================================
function Get-AppStatus {
    param($a)
    $s = @{ On = $false; Text = 'installed'; Versions = @() }
    $ids = $script:InstalledIds
    switch ($a.Special) {
        'node' {
            if (Get-Command node -ErrorAction SilentlyContinue) {
                $v = "$(& node --version 2>$null)".Trim()
                $s.On = $true; $s.Text = $v; $s.Versions = @($v.TrimStart('v'))
            }
            $s.Nvm = [bool](Get-Command nvm -ErrorAction SilentlyContinue)
        }
        'python' {
            $v = @(foreach ($id in $ids) { if ($id -match '^Python\.Python\.(3\.\d+)$' -or $id -match 'PythonSoftwareFoundation\.Python\.(3\.\d+)') { $Matches[1] } })
            # winget can't always match a Python install to its package, so also look at the install folders
            $v += @(foreach ($m in 8..16) { if (Find-PythonHome "3.$m") { "3.$m" } })
            $v = @($v | Select-Object -Unique | Sort-Object { [version]$_ } -Descending)
            if ($v.Count) { $s.On = $true; $s.Versions = $v; $s.Text = $v -join ', ' }
        }
        'jdk' {
            $v = @(foreach ($id in $ids) {
                foreach ($vendor in $JdkVendors.Keys) {
                    $rx = '^' + ([regex]::Escape($JdkVendors[$vendor]) -replace '\\\{0}', '(\d+)') + '$'
                    if ($id -match $rx) { "${vendor}:$($Matches[1])" }
                }
            })
            if ($v.Count) { $s.On = $true; $s.Versions = $v; $s.Text = 'JDK ' + (($v | ForEach-Object { ($_ -split ':')[1] }) -join ', ') }
        }
        'xampp' {
            $v = @(foreach ($id in $ids) { if ($id -match '^ApacheFriends\.Xampp\.(8\.\d)$') { $Matches[1] } })
            if ($v.Count -or (Test-Path 'C:\xampp\xampp-control.exe')) { $s.On = $true; $s.Versions = $v }
        }
        'intellij' {
            $v = @(foreach ($e in 'Ultimate', 'Community') { if ($ids.Contains("JetBrains.IntelliJIDEA.$e") -or @($script:InstalledNames | Where-Object { $_ -like "intellijidea$($e.ToLower())*" }).Count) { $e.ToLower() } })
            if ($v.Count) { $s.On = $true; $s.Versions = $v; $s.Text = ($v -join ', ') }
        }
        default {
            if (($a.Winget -and ($ids.Contains($a.Winget) -or (Test-NameInstalled $a.Winget))) -or
                ($a.CheckPath -and (Test-Path $a.CheckPath)) -or
                ($a.CheckCmd -and (Get-Command $a.CheckCmd -ErrorAction SilentlyContinue))) { $s.On = $true }
        }
    }
    return $s
}

function Get-OptionSummary {
    param($Opt, $a)
    switch ($a.Special) {
        'node' {
            $n = "$($Opt.node)".ToLower()
            if ($n -eq 'lts') { return 'LTS' }
            if ($n -eq 'latest' -or $n -eq 'current') { return 'Latest' }
            if ($n -match '^nvm(:(.+))?$') { if ($Matches[2]) { return "NVM + $($Matches[2])" } else { return 'NVM + LTS' } }
            return "v$($n.TrimStart('v'))"
        }
        'python' { return (@($Opt.python) -join ', ') }
        'jdk' {
            $specs = @($Opt.jdk | ForEach-Object { Split-JdkSpec $_ })
            $vendors = @($specs | ForEach-Object { $_.Vendor } | Select-Object -Unique)
            $majors = ($specs | ForEach-Object { $_.Major }) -join ', '
            if ($vendors.Count -eq 1) { return "$($JdkVendorNames[$vendors[0]]) $majors" }
            return (($specs | ForEach-Object { "$($_.Vendor) $($_.Major)" }) -join ', ')
        }
        'xampp' { return "PHP $($Opt.xampp)" }
        'intellij' { return (Get-Culture).TextInfo.ToTitleCase("$($Opt.intellij)".ToLower()) }
    }
    return ''
}

function Split-JdkSpec {
    param([string]$Spec)
    $s = "$Spec".Trim().ToLower()
    if ($s -match '^(?:(\w+):)?(\d+)$') {
        $v = if ($Matches[1]) { $Matches[1] } else { 'temurin' }
        return @{ Vendor = $v; Major = $Matches[2] }
    }
    return @{ Vendor = 'temurin'; Major = $s }
}

# What will happen to an app when installed now: install / skip / reinstall / partial.
function Get-PlanState {
    param($a, $Opt, [bool]$ForceAll)
    $st = $script:Status[$a.Key]
    if (-not $st) { $st = @{ On = $false; Versions = @() } }
    if ($ForceAll) { if ($st.On) { return @('reinstall', 'Yellow') } else { return @('install', 'Green') } }
    switch ($a.Special) {
        'node' {
            $n = "$($Opt.node)".ToLower()
            $have = $st.On
            if ($n -match '^nvm') { $have = $st.Nvm }
            elseif ($n -match '^v?(\d+(\.\d+){0,2})$') { $want = $Matches[1]; $have = $st.On -and (@($st.Versions | Where-Object { $_ -eq $want -or $_.StartsWith("$want.") }).Count -gt 0) }
            if ($have) { return @('skip - installed', 'DarkGray') } else { return @('install', 'Green') }
        }
        'python' {
            $new = @($Opt.python | Where-Object { $st.Versions -notcontains ((($_ -split '\.')[0..1]) -join '.') })
            if (-not $new.Count) { return @('skip - installed', 'DarkGray') }
            if ($new.Count -lt @($Opt.python).Count) { return @("install $($new -join ', ')", 'Green') }
            return @('install', 'Green')
        }
        'jdk' {
            $new = @($Opt.jdk | ForEach-Object { $j = Split-JdkSpec $_; "$($j.Vendor):$($j.Major)" } | Where-Object { $st.Versions -notcontains $_ })
            if (-not $new.Count) { return @('skip - installed', 'DarkGray') }
            if ($new.Count -lt @($Opt.jdk).Count) { return @("install $((($new | ForEach-Object { ($_ -split ':')[1] }) -join ', '))", 'Green') }
            return @('install', 'Green')
        }
        'intellij' {
            if ($st.Versions -contains "$($Opt.intellij)".ToLower()) { return @('skip - installed', 'DarkGray') }
            return @('install', 'Green')
        }
    }
    if ($st.On) { return @('skip - installed', 'DarkGray') }
    return @('install', 'Green')
}

# ============================================================================================
# Tasks
# ============================================================================================
$script:Seq = 0
function New-Task {
    param([string]$Key, [string]$Name, [object[]]$Methods = @(), [string]$CheckCmd, [string]$CheckPath,
          [string]$WingetCheck, [scriptblock]$CheckScript, [scriptblock]$Pre, [scriptblock]$Post,
          [int]$Order = 50, [hashtable]$Data = @{}, [string]$ErrorText, [string]$Tip)
    $script:Seq++
    [pscustomobject]@{
        Key = $Key; Name = $Name; Methods = $Methods; CheckCmd = $CheckCmd; CheckPath = $CheckPath
        WingetCheck = $WingetCheck; CheckScript = $CheckScript; Pre = $Pre; Post = $Post
        Order = $Order; Seq = $script:Seq; Data = $Data; ErrorText = $ErrorText; Tip = $Tip
    }
}

function Get-NodeTask {
    param([string]$Spec)
    $s = "$Spec".Trim().ToLower()
    if (-not $s -or $s -eq 'lts') {
        return New-Task -Key node -Name 'Node.js LTS' -Methods @(@{ Type = 'winget'; Id = 'OpenJS.NodeJS.LTS' }) -CheckCmd node -Order 10
    }
    if ($s -eq 'latest' -or $s -eq 'current') {
        return New-Task -Key node -Name 'Node.js (latest)' -Methods @(@{ Type = 'winget'; Id = 'OpenJS.NodeJS' }) -CheckCmd node -Order 10
    }
    if ($s -match '^nvm(:(.+))?$') {
        $v = if ($Matches[2]) { $Matches[2] } else { 'lts' }
        return New-Task -Key node -Name "NVM for Windows + Node.js $v" -Methods @(@{ Type = 'winget'; Id = 'CoreyButler.NVMforWindows' }) `
            -CheckCmd nvm -Post $NvmPost -Data @{ Version = $v } -Order 10 -Tip 'Switch Node versions with: nvm install <ver>; nvm use <ver>'
    }
    if ($s -match '^v?(\d+(\.\d+){0,2})$') {
        $want  = $Matches[1]
        $major = ($want -split '\.')[0]
        $r = Resolve-WingetVersion @("OpenJS.NodeJS.$major", 'OpenJS.NodeJS.LTS', 'OpenJS.NodeJS') $want
        if (-not $r) { return New-Task -Key node -Name "Node.js $want" -Order 10 -ErrorText "No winget package matches Node.js $want" }
        return New-Task -Key node -Name "Node.js $($r.Version)" -Methods @(@{ Type = 'winget'; Id = $r.Id; Version = $r.Version }) `
            -CheckScript $NodeCheck -Data @{ Want = $want } -Order 10
    }
    return New-Task -Key node -Name "Node.js $Spec" -Order 10 -ErrorText "Invalid Node.js version '$Spec'"
}

function Get-PythonTask {
    param([string]$Spec, [bool]$Primary)
    $s = "$Spec".Trim()
    if ($s -notmatch '^3\.(\d+)(\.\d+)?$') { return New-Task -Key python -Name "Python $s" -Order 10 -ErrorText "Invalid Python version '$s'" }
    $minor = "3.$($Matches[1])"
    $exact = if ($Matches[2]) { $s } else { $null }
    $id    = "Python.Python.$minor"
    $label = if ($Primary) { "Python $s (default)" } else { "Python $s" }
    # a matching minor version from python.org, winget or the Microsoft Store counts as installed
    $have = (-not $exact) -and $script:Status.python -and (@($script:Status.python.Versions) -contains $minor)
    New-Task -Key python -Name $label -Methods @(@{ Type = 'winget'; Id = $id; Version = $exact; Scope = 'machine' }) `
        -WingetCheck $id -CheckScript $(if ($have) { { param($t) $true } } else { $null }) -Post $PythonPost -Data @{ Minor = $minor; Primary = $Primary } -Order 10
}

function Get-JdkTask {
    param([string]$Spec, [bool]$Primary)
    $s = "$Spec".Trim().ToLower()
    if ($s -notmatch '^(?:(\w+):)?(\d+)$' -or ($Matches[1] -and -not $JdkVendors.Contains($Matches[1]))) {
        return New-Task -Key jdk -Name "JDK $Spec" -Order 10 -ErrorText "Invalid JDK spec '$Spec' (use e.g. 21 or microsoft:21)"
    }
    $vendor = if ($Matches[1]) { $Matches[1] } else { 'temurin' }
    $major  = $Matches[2]
    $id     = $JdkVendors[$vendor] -f $major
    $label  = if ($Primary) { "$($JdkVendorNames[$vendor]) $major (JAVA_HOME)" } else { "$($JdkVendorNames[$vendor]) $major" }
    New-Task -Key jdk -Name $label -Methods @(@{ Type = 'winget'; Id = $id }) -WingetCheck $id -Post $JdkPost `
        -Data @{ Major = $major; Primary = $Primary } -Order 10
}

function Get-Tasks {
    param([string[]]$Keys, [hashtable]$Opt)
    $tasks = New-Object System.Collections.Generic.List[object]
    foreach ($k in $Keys) {
        $a = $CatalogByKey[$k]
        switch ($a.Special) {
            'node' { $tasks.Add((Get-NodeTask $Opt.node)) }
            'python' {
                $i = 0
                foreach ($v in $Opt.python) { $tasks.Add((Get-PythonTask $v ($i -eq 0))); $i++ }
            }
            'jdk' {
                $i = 0
                foreach ($v in $Opt.jdk) { $tasks.Add((Get-JdkTask $v ($i -eq 0))); $i++ }
            }
            'xampp' {
                $id = "ApacheFriends.Xampp.$($Opt.xampp)"
                $tasks.Add((New-Task -Key xampp -Name "XAMPP (PHP $($Opt.xampp))" -Methods @(@{ Type = 'winget'; Id = $id }) `
                    -CheckPath 'C:\xampp\xampp-control.exe' -WingetCheck $id -Tip 'XAMPP is in C:\xampp - start it from xampp-control.exe.'))
            }
            'intellij' {
                $ed = (Get-Culture).TextInfo.ToTitleCase("$($Opt.intellij)".ToLower())
                $id = "JetBrains.IntelliJIDEA.$ed"
                $tasks.Add((New-Task -Key intellij -Name "IntelliJ IDEA $ed" -Methods @(@{ Type = 'winget'; Id = $id }) -WingetCheck $id))
            }
            default {
                $methods = @()
                if ($a.Winget)   { $methods += @{ Type = 'winget'; Id = $a.Winget } }
                if ($a.Fallback) { $methods += $a.Fallback }
                $tasks.Add((New-Task -Key $a.Key -Name $a.Name -Methods $methods -CheckCmd $a.CheckCmd -CheckPath $a.CheckPath `
                    -WingetCheck $a.Winget -Pre $a.Pre -Post $a.Post -Order $a.Order -Tip $a.Tip))
            }
        }
    }
    return @($tasks | Sort-Object Order, Seq)
}

function Test-TaskInstalled {
    param($t)
    if ($t.CheckScript) { return [bool](& $t.CheckScript $t) }
    if ($t.CheckPath -and (Test-Path $t.CheckPath)) { return $true }
    if ($t.CheckCmd -and (Get-Command $t.CheckCmd -ErrorAction SilentlyContinue)) { return $true }
    if ($t.WingetCheck) { return (Test-WingetInstalled $t.WingetCheck) }
    return $false
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Results.Add([pscustomobject]@{ App = $Name; Status = $Status; Detail = $Detail })
    Write-Log "RESULT $Name : $Status $Detail"
}

function Write-ResultLine {
    param([string]$Glyph, [string]$Color, [string]$Name, [string]$Detail, [string]$Time)
    $w = 100
    try { $w = [Console]::WindowWidth - 1 } catch {}
    $nameW = [Math]::Min(40, [Math]::Max(20, $w - 40))
    if ($Name.Length -gt $nameW) { $Name = $Name.Substring(0, $nameW - 1) + '.' }
    Write-Host "  $Glyph  " -ForegroundColor $Color -NoNewline
    Write-Host $Name.PadRight($nameW) -ForegroundColor White -NoNewline
    Write-Host ("  {0,-24}" -f $Detail) -ForegroundColor DarkGray -NoNewline
    Write-Host ("{0,6}" -f $Time) -ForegroundColor DarkGray
}

function Invoke-Task {
    param($t, [int]$N, [int]$Total)
    Write-Log "---- [$N/$Total] $($t.Name)"
    $script:CurLabel = "[$N/$Total] $($t.Name)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($t.ErrorText) {
        Write-ResultLine $Gl.Bad Red $t.Name 'error' ''
        Write-Info $t.ErrorText
        Add-Result $t.Name 'Failed' $t.ErrorText
        return
    }

    Update-SessionEnv
    if (-not $Force -and (Test-TaskInstalled $t)) {
        if (-not $DryRun -and $t.Post) { try { & $t.Post $t } catch { Write-Warn "Post-install step: $($_.Exception.Message)" } }
        Write-ResultLine $Gl.Off DarkGray $t.Name 'already installed' ''
        Add-Result $t.Name 'Skipped' 'already installed'
        return
    }
    if ($DryRun) {
        Write-ResultLine $Gl.Dia Cyan $t.Name ("would use " + (Get-MethodShort $t.Methods[0])) ''
        foreach ($m in $t.Methods) { Write-Log ("would try: " + (Get-MethodLabel $m)) }
        Add-Result $t.Name 'DryRun' (Get-MethodLabel $t.Methods[0])
        return
    }

    if ($t.Pre) { try { & $t.Pre $t } catch { Write-Warn "Pre-install step: $($_.Exception.Message)" } }

    $via = $null
    for ($mi = 0; $mi -lt $t.Methods.Count; $mi++) {
        $m = $t.Methods[$mi]
        try {
            if (Invoke-Method $m) { $via = Get-MethodShort $m; break }
        } catch {
            Write-Log "method error: $($_.Exception.Message)"
        }
        $next = if ($mi + 1 -lt $t.Methods.Count) { " - trying $(Get-MethodShort $t.Methods[$mi + 1])" } else { '' }
        Write-Warn "$(Get-MethodShort $m) failed$next"
    }
    if (-not $via) {
        Write-ResultLine $Gl.Bad Red $t.Name 'failed (see log)' (Format-Elapsed $sw.Elapsed)
        Add-Result $t.Name 'Failed' 'all install methods failed'
        return
    }

    Update-SessionEnv
    if ($t.Post) { try { & $t.Post $t } catch { Write-Warn "Post-install step: $($_.Exception.Message)" } }
    Write-ResultLine $Gl.Ok Green $t.Name "installed via $via" (Format-Elapsed $sw.Elapsed)
    Add-Result $t.Name 'Installed' $via
    if ($t.Tip) { $script:Tips += "$($t.Name): $($t.Tip)" }
}

# ============================================================================================
# Interactive picker (full-screen TUI)
# ============================================================================================
function Add-Seg {
    param($List, [string]$Text, $Fg = 'Gray', $Bg = $null)
    if ($null -eq $Bg) { $Bg = $script:BaseBg }
    [void]$List.Add(@($Text, $Fg, $Bg))
}
function New-Segs { return , (New-Object System.Collections.ArrayList) }
function Get-SegsLength { param($Segs) $n = 0; foreach ($s in $Segs) { $n += ([string]$s[0]).Length }; return $n }

# Draw one line of segments at (X, Y) clipped/padded to Width.
function Write-Segs {
    param([int]$X, [int]$Y, [int]$Width, $Segs, $PadBg = $null)
    if ($Width -le 0 -or $Y -ge [Console]::WindowHeight) { return }
    [Console]::SetCursorPosition($X, [Console]::WindowTop + $Y)
    $used = 0
    foreach ($s in $Segs) {
        if ($used -ge $Width) { break }
        $t = [string]$s[0]
        if ($used + $t.Length -gt $Width) { $t = $t.Substring(0, $Width - $used) }
        if (-not $t.Length) { continue }
        [Console]::ForegroundColor = $s[1]
        [Console]::BackgroundColor = $s[2]
        [Console]::Write($t)
        $used += $t.Length
    }
    if ($used -lt $Width) {
        if ($null -eq $PadBg) { $PadBg = $script:BaseBg }
        [Console]::BackgroundColor = $PadBg
        [Console]::Write(' ' * ($Width - $used))
    }
}

function Add-Chip {
    param($List, [string]$Key, [string]$Label)
    Add-Seg $List " $Key " Black Gray
    Add-Seg $List " $Label   " DarkGray
}

function Split-Wrap {
    param([string]$Text, [int]$Width)
    $lines = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($w in ($Text -split '\s+')) {
        if (-not $w) { continue }
        if (-not $cur.Length) { $cur = $w }
        elseif ($cur.Length + 1 + $w.Length -le $Width) { $cur += " $w" }
        else { [void]$lines.Add($cur); $cur = $w }
        while ($cur.Length -gt $Width) { [void]$lines.Add($cur.Substring(0, $Width)); $cur = $cur.Substring($Width) }
    }
    if ($cur.Length) { [void]$lines.Add($cur) }
    return , $lines
}

# Keys come from the console, or from WSI_TEST_KEYS (space separated ConsoleKey names / single chars / DUMP) for tests.
function Read-Key {
    if ($script:TestKeys) {
        if ($script:TestKeys.Count -eq 0) { Save-ScreenDump; throw 'WSI_TEST_END' }
        $tok = $script:TestKeys.Dequeue()
        Write-Log "TESTKEY $tok"
        if ($tok -eq 'DUMP') { Save-ScreenDump; return Read-Key }
        if ($tok.Length -eq 1) {
            $ck = if ($tok -eq '/') { [ConsoleKey]::Oem2 } else { [ConsoleKey]::NoName }
            if ($tok -match '^[a-zA-Z]$') { $ck = [ConsoleKey]$tok.ToUpper() }
            return New-Object ConsoleKeyInfo([char]$tok, $ck, $false, $false, $false)
        }
        $ck = [ConsoleKey]$tok
        $ch = switch ($tok) { 'Spacebar' { [char]' ' } 'Enter' { [char]13 } 'Escape' { [char]27 } 'Backspace' { [char]8 } default { [char]0 } }
        return New-Object ConsoleKeyInfo($ch, $ck, $false, $false, $false)
    }
    return [Console]::ReadKey($true)
}

function Save-ScreenDump {
    if (-not $env:WSI_TEST_DUMP) { return }
    $raw = $Host.UI.RawUI
    $top = [Console]::WindowTop
    $rect = New-Object System.Management.Automation.Host.Rectangle 0, $top, ($raw.BufferSize.Width - 1), ($top + [Console]::WindowHeight - 1)
    $buf = $raw.GetBufferContents($rect)
    $sb = New-Object System.Text.StringBuilder
    for ($y = 0; $y -le $buf.GetUpperBound(0); $y++) {
        $line = New-Object System.Text.StringBuilder
        for ($x = 0; $x -le $buf.GetUpperBound(1); $x++) { $cell = $buf[$y, $x]; [void]$line.Append($cell.Character) }
        [void]$sb.AppendLine($line.ToString().TrimEnd())
    }
    [void]$sb.AppendLine('=' * 40)
    [IO.File]::AppendAllText($env:WSI_TEST_DUMP, $sb.ToString(), [Text.Encoding]::UTF8)
}

function Get-Categories {
    $cats = @()
    foreach ($a in $Catalog) { if ($cats -notcontains $a.Cat) { $cats += $a.Cat } }
    return $cats
}

function Test-AppFilter {
    param($a, [string]$Filter)
    if (-not $Filter) { return $true }
    $hay = "$($a.Name) $($a.Key) $($a.Cat) $($a.Desc) $(@($a.Alias) -join ' ') $($a.Winget)"
    return ($hay -like "*$Filter*")
}

function Get-PickerRows {
    param([string]$Filter)
    $rows = New-Object System.Collections.ArrayList
    foreach ($c in Get-Categories) {
        $apps = @($Catalog | Where-Object { $_.Cat -eq $c -and (Test-AppFilter $_ $Filter) })
        if (-not $apps.Count) { continue }
        [void]$rows.Add(@{ Type = 'cat'; Cat = $c; Apps = $apps })
        foreach ($a in $apps) { [void]$rows.Add(@{ Type = 'app'; App = $a }) }
    }
    return , $rows
}

function Get-NextAppRow {
    param($Rows, [int]$From, [int]$Dir)
    $i = $From + $Dir
    while ($i -ge 0 -and $i -lt $Rows.Count) {
        if ($Rows[$i].Type -eq 'app') { return $i }
        $i += $Dir
    }
    return $From
}

function Get-RowSegs {
    param($S, $Row, [bool]$IsCur, [int]$W)
    $l = New-Segs
    if ($Row.Type -eq 'cat') {
        $n = @($Row.Apps | Where-Object { $S.Sel[$_.Key] }).Count
        Add-Seg $l "  $($Row.Cat.ToUpper())" Cyan
        $cnt = if ($n) { "  $n/$($Row.Apps.Count)" } else { '' }
        Add-Seg $l $cnt DarkGray
        return , $l
    }
    $a  = $Row.App
    $on = [bool]$S.Sel[$a.Key]
    $st = $script:Status[$a.Key]
    $bg = if ($IsCur) { 'DarkGray' } else { $script:BaseBg }
    Add-Seg $l $(if ($IsCur) { " $($Gl.Ptr) " } else { '   ' }) Cyan $bg
    if ($on) { Add-Seg $l $Gl.On Green $bg } else { Add-Seg $l $Gl.Off $(if ($IsCur) { 'Gray' } else { 'DarkGray' }) $bg }
    Add-Seg $l '  ' Gray $bg

    $badge = if ($st -and $st.On) { "$($Gl.Ok) $($st.Text)" } else { '' }
    if ($badge.Length -gt 22) { $badge = $badge.Substring(0, 21) + '.' }
    $opt = if ($a.Special) { Get-OptionSummary $S.Opt $a } else { '' }
    $used = 6
    $room = $W - $used - $badge.Length - 2
    $name = $a.Name
    if ($name.Length -gt $room) { $name = $name.Substring(0, [Math]::Max(0, $room)) }
    Add-Seg $l $name $(if ($IsCur -or $on) { 'White' } else { 'Gray' }) $bg
    $used += $name.Length
    if ($opt) {
        $optText = "  $opt  $($Gl.R)"
        if ($used + $optText.Length -le $W - $badge.Length - 2) {
            Add-Seg $l $optText $(if ($on) { 'Cyan' } else { 'DarkCyan' }) $bg
            $used += $optText.Length
        }
    }
    $pad = $W - $used - $badge.Length - 1
    if ($pad -gt 0) { Add-Seg $l (' ' * $pad) Gray $bg }
    if ($badge) { Add-Seg $l $badge $(if ($IsCur) { 'Green' } else { 'DarkGreen' }) $bg }
    Add-Seg $l ' ' Gray $bg
    return , $l
}

function Add-BoxLine {
    param($Out, [int]$W, $Inner, $Border = 'DarkGray', $InnerBg = $null)
    $l = New-Segs
    Add-Seg $l "$($Gl.V) " $Border
    $room = $W - 4
    $used = 0
    foreach ($s in $Inner) {
        $t = [string]$s[0]
        if ($used + $t.Length -gt $room) { $t = $t.Substring(0, [Math]::Max(0, $room - $used)) }
        if ($t.Length) { [void]$l.Add(@($t, $s[1], $s[2])); $used += $t.Length }
    }
    $pad = $room - $used
    if ($pad -gt 0) { Add-Seg $l (' ' * $pad) Gray $InnerBg }
    Add-Seg $l " $($Gl.V)" $Border
    [void]$Out.Add($l)
}

function Add-BoxEdge {
    param($Out, [int]$W, [string]$Title, [bool]$Top, $Border = 'DarkGray', $TitleFg = 'White')
    $l = New-Segs
    if ($Top) {
        Add-Seg $l "$($Gl.TL)$($Gl.H)" $Border
        if ($Title) { Add-Seg $l " $Title " $TitleFg }
        $rest = $W - 3 - $(if ($Title) { $Title.Length + 2 } else { 0 })
        Add-Seg $l ($Gl.H * [Math]::Max(0, $rest)) $Border
        Add-Seg $l $Gl.TR $Border
    } else {
        Add-Seg $l ($Gl.BL + ($Gl.H * [Math]::Max(0, $W - 2)) + $Gl.BR) $Border
    }
    [void]$Out.Add($l)
}

function Get-SourceText {
    param($a, $Opt)
    switch ($a.Special) {
        'node' { return 'winget  OpenJS.NodeJS' }
        'python' { return 'winget  Python.Python.3.x' }
        'jdk' { $first = @($Opt.jdk)[0]; $v = (Split-JdkSpec $first).Vendor; return 'winget  ' + ($JdkVendors[$v] -f 'N') }
        'xampp' { return "winget  ApacheFriends.Xampp.$($Opt.xampp)" }
        'intellij' { return 'winget  JetBrains.IntelliJIDEA' }
    }
    if ($a.Winget) { return "winget  $($a.Winget)" }
    return (Get-MethodLabel @($a.Fallback)[0])
}

function Get-PanelLines {
    param($S, $a, [int]$W, [int]$H)
    $out = New-Object System.Collections.ArrayList
    if (-not $a -or $W -lt 24) { return , $out }
    $iw = $W - 4
    $st = $script:Status[$a.Key]
    $on = [bool]$S.Sel[$a.Key]

    Add-BoxEdge $out $W $a.Name $true 'DarkGray' 'White'
    foreach ($ln in (Split-Wrap $a.Desc $iw)) { $x = New-Segs; Add-Seg $x $ln Gray; Add-BoxLine $out $W $x }
    Add-BoxLine $out $W (New-Segs)
    $kv = {
        param($k, $v, $fg)
        $x = New-Segs
        Add-Seg $x ($k.PadRight(10)) DarkGray
        $vv = [string]$v
        if ($vv.Length -gt $iw - 10) { $vv = $vv.Substring(0, $iw - 11) + '.' }
        Add-Seg $x $vv $fg
        Add-BoxLine $out $W $x
    }
    & $kv 'Source' (Get-SourceText $a $S.Opt) 'Gray'
    $fb = @($a.Fallback | Where-Object { $_ } | ForEach-Object { Get-MethodShort $_ })
    if ($a.Winget -and $fb.Count) { & $kv 'Fallback' ($fb -join ', ') 'Gray' }
    if ($st -and $st.On) { & $kv 'Status' "installed ($($st.Text))" 'Green' } else { & $kv 'Status' 'not installed' 'DarkGray' }
    if ($on) { & $kv 'Selected' 'yes' 'Green' } else { & $kv 'Selected' 'no  (Space to select)' 'DarkGray' }
    if ($a.Special) {
        $label = if ($a.Special -eq 'intellij') { 'Edition' } else { 'Version' }
        & $kv $label (Get-OptionSummary $S.Opt $a) 'Cyan'
        $x = New-Segs; Add-Seg $x (' ' * 10); Add-Seg $x "press $($Gl.Right) to change" Yellow; Add-BoxLine $out $W $x
    }
    if ($a.Tip) {
        Add-BoxLine $out $W (New-Segs)
        foreach ($ln in (Split-Wrap "After install: $($a.Tip)" $iw)) { $x = New-Segs; Add-Seg $x $ln DarkGray; Add-BoxLine $out $W $x }
    }
    Add-BoxEdge $out $W '' $false

    # queue box with everything selected so far
    $names = @($Catalog | Where-Object { $S.Sel[$_.Key] } | ForEach-Object { $_.Name })
    $room = $H - $out.Count - 3
    if ($room -ge 1) {
        [void]$out.Add((New-Segs))
        Add-BoxEdge $out $W "Selected ($($names.Count))" $true 'DarkGray' 'Cyan'
        if (-not $names.Count) {
            $x = New-Segs; Add-Seg $x 'Nothing yet - press Space on an app' DarkGray; Add-BoxLine $out $W $x
        } else {
            $wrapped = Split-Wrap ($names -join ', ') $iw
            $max = [Math]::Max(1, $room - 1)
            for ($i = 0; $i -lt [Math]::Min($wrapped.Count, $max); $i++) {
                $t = $wrapped[$i]
                if ($i -eq $max - 1 -and $wrapped.Count -gt $max) { $t = $t.Substring(0, [Math]::Min($t.Length, $iw - 4)) + ' ...' }
                $x = New-Segs; Add-Seg $x $t Gray; Add-BoxLine $out $W $x
            }
        }
        Add-BoxEdge $out $W '' $false
    }
    return , $out
}

function Write-TitleBar {
    param([string]$Title, [string]$Right)
    $W = [Console]::WindowWidth - 1
    $l = New-Segs
    Add-Seg $l "  $($Gl.Dia) " White DarkCyan
    Add-Seg $l $Title White DarkCyan
    Add-Seg $l "  v$($script:Version)" Black DarkCyan
    $pad = $W - (Get-SegsLength $l) - $Right.Length - 2
    if ($pad -gt 0) { Add-Seg $l (' ' * $pad) White DarkCyan }
    Add-Seg $l "$Right  " White DarkCyan
    Write-Segs 0 0 $W $l DarkCyan
}

function Write-RuleAt {
    param([int]$Y, [string]$Label)
    $W = [Console]::WindowWidth - 1
    $l = New-Segs
    if ($Label) {
        Add-Seg $l ($Gl.H * 2) DarkGray
        Add-Seg $l " $Label " DarkGray
    }
    Add-Seg $l ($Gl.H * [Math]::Max(0, $W - (Get-SegsLength $l))) DarkGray
    Write-Segs 0 $Y $W $l
}

function Draw-Picker {
    param($S, $Rows)
    $W = [Console]::WindowWidth - 1
    $H = [Console]::WindowHeight
    $showPanel = $W -ge 100
    $LW = if ($showPanel) { [Math]::Min(70, [Math]::Max(54, [int]($W * 0.55))) } else { $W }
    $PX = $LW + 2
    $PW = $W - $PX
    $listTop = 3
    $listH = [Math]::Max(3, $H - 6)

    # keep the cursor (and its category header) in view
    if ($S.Cursor -ge 0) {
        if ($S.Cursor -lt $S.Scroll) { $S.Scroll = $S.Cursor }
        if ($S.Cursor -gt 0 -and $Rows[$S.Cursor - 1].Type -eq 'cat' -and $S.Cursor - 1 -lt $S.Scroll) { $S.Scroll = $S.Cursor - 1 }
        if ($S.Cursor -ge $S.Scroll + $listH) { $S.Scroll = $S.Cursor - $listH + 1 }
    }
    $S.Scroll = [Math]::Max(0, [Math]::Min($S.Scroll, $Rows.Count - $listH))
    $S.ListH = $listH

    $selCount = @($Catalog | Where-Object { $S.Sel[$_.Key] }).Count
    Write-TitleBar 'WINDOWS SILENT INSTALLER' "$selCount selected  $($Gl.Dot)  $($Catalog.Count) apps"

    $l = New-Segs
    if ($S.Search) {
        Add-Seg $l '  Search: ' DarkGray
        Add-Seg $l $S.Filter Yellow
        Add-Seg $l '_' Yellow
        Add-Seg $l "      $($Rows | Where-Object { $_.Type -eq 'app' } | Measure-Object | Select-Object -ExpandProperty Count) matches" DarkGray
    } elseif ($S.Filter) {
        Add-Seg $l '  Filter: ' DarkGray
        Add-Seg $l $S.Filter Yellow
        Add-Seg $l '   (Esc clears)' DarkGray
    } else {
        Add-Seg $l '  Choose the apps to install on this PC, then press ' DarkGray
        Add-Seg $l 'Enter' White
        Add-Seg $l ' to review.' DarkGray
    }
    Write-Segs 0 1 $W $l

    $curApp = if ($S.Cursor -ge 0) { $Rows[$S.Cursor].App } else { $null }
    $panel = if ($showPanel) { Get-PanelLines $S $curApp $PW $listH } else { @() }
    for ($i = 0; $i -lt $listH; $i++) {
        $ri = $S.Scroll + $i
        if ($ri -lt $Rows.Count) { $segs = Get-RowSegs $S $Rows[$ri] ($ri -eq $S.Cursor) $LW }
        elseif ($i -eq 0 -and $Rows.Count -eq 0) { $segs = New-Segs; Add-Seg $segs "  No apps match '$($S.Filter)'" DarkGray }
        else { $segs = New-Segs }
        Write-Segs 0 ($listTop + $i) $LW $segs
        if ($showPanel) {
            Write-Segs $LW ($listTop + $i) 2 (New-Segs)
            if ($i -lt $panel.Count) { Write-Segs $PX ($listTop + $i) $PW $panel[$i] } else { Write-Segs $PX ($listTop + $i) $PW (New-Segs) }
        }
    }

    $above = $S.Scroll
    $below = [Math]::Max(0, $Rows.Count - $S.Scroll - $listH)
    $scrollLabel = @()
    if ($above) { $scrollLabel += "$($Gl.Up) $above more" }
    if ($below) { $scrollLabel += "$($Gl.Dn) $below more" }
    Write-RuleAt 2 ''
    Write-RuleAt ($H - 3) ($scrollLabel -join '   ')

    $l = New-Segs
    if ($S.Msg) { Add-Seg $l "  $($S.Msg)" Yellow; $S.Msg = '' }
    elseif (-not $showPanel -and $curApp) { Add-Seg $l "  $($curApp.Desc)" DarkGray }
    else { Add-Seg $l "  Tip: press $($Gl.Right) on Node.js, Python, Java JDK, XAMPP or IntelliJ IDEA to pick versions." DarkGray }
    Write-Segs 0 ($H - 2) $W $l

    $l = New-Segs
    Add-Seg $l ' ' Gray
    if ($S.Search) {
        Add-Chip $l 'type' 'filter'; Add-Chip $l "$($Gl.Up)$($Gl.Dn)" 'move'; Add-Chip $l 'Space' 'select'
        Add-Chip $l 'Enter' 'done'; Add-Chip $l 'Esc' 'clear'
    } else {
        Add-Chip $l "$($Gl.Up)$($Gl.Dn)" 'move'; Add-Chip $l 'Space' 'select'; Add-Chip $l $Gl.Right 'versions'
        Add-Chip $l '/' 'search'; Add-Chip $l 'A' 'all'; Add-Chip $l 'N' 'none'; Add-Chip $l 'R' 'recommended'
        Add-Chip $l 'C' 'category'; Add-Chip $l 'Enter' 'review'; Add-Chip $l 'Esc' 'quit'
    }
    Write-Segs 0 ($H - 1) $W $l
}

# Version/edition chooser for Node.js, Python, JDK, XAMPP and IntelliJ. Returns $true when applied.
function Show-OptionsDialog {
    param($S, $a)
    $spec = switch ($a.Special) {
        'node' {
            @{ Title = 'Node.js version'; Mode = 'radio'; Hint = 'Pick one version.'; Value = "$($S.Opt.node)".ToLower()
               Items = @(
                    @{ V = 'lts'; L = 'LTS'; H = 'recommended' },
                    @{ V = 'latest'; L = 'Latest (Current)'; H = 'newest features' },
                    @{ V = '24'; L = 'Node 24'; H = '' },
                    @{ V = '22'; L = 'Node 22'; H = '' },
                    @{ V = '20'; L = 'Node 20'; H = '' },
                    @{ V = 'nvm'; L = 'NVM for Windows'; H = '+ LTS, switch versions anytime' },
                    @{ V = '__custom'; L = 'Other version...'; H = 'e.g. 20.18.0 or nvm:22' }) }
        }
        'python' {
            @{ Title = 'Python versions'; Mode = 'check'; Hint = 'Select one or more. The default goes on PATH.'; Values = @($S.Opt.python)
               Items = @(foreach ($v in '3.14', '3.13', '3.12', '3.11', '3.10') { @{ V = $v; L = "Python $v"; H = '' } }) }
        }
        'jdk' {
            $specs = @($S.Opt.jdk | ForEach-Object { Split-JdkSpec $_ })
            @{ Title = 'Java JDK'; Mode = 'check'; Hint = 'Select one or more. The default becomes JAVA_HOME.'
               Values = @($specs | ForEach-Object { $_.Major }); Vendor = $specs[0].Vendor
               Items = @(foreach ($v in '25', '21', '17', '11', '8') { @{ V = $v; L = "JDK $v"; H = $JdkHints[$v] } }) }
        }
        'xampp' {
            @{ Title = 'XAMPP'; Mode = 'radio'; Hint = 'Pick the PHP version.'; Value = "$($S.Opt.xampp)"
               Items = @(@{ V = '8.2'; L = 'PHP 8.2'; H = 'recommended' }, @{ V = '8.1'; L = 'PHP 8.1'; H = '' }) }
        }
        'intellij' {
            @{ Title = 'IntelliJ IDEA'; Mode = 'radio'; Hint = 'Pick the edition.'; Value = "$($S.Opt.intellij)".ToLower()
               Items = @(@{ V = 'ultimate'; L = 'Ultimate'; H = 'unified IDE, free tier available' }, @{ V = 'community'; L = 'Community'; H = 'classic free edition' }) }
        }
    }
    if (-not $spec) { return $false }

    $items = New-Object System.Collections.ArrayList
    foreach ($it in $spec.Items) { [void]$items.Add(@{ V = $it.V; L = $it.L; H = $it.H }) }
    $custom = $null
    if ($spec.Mode -eq 'radio') {
        $value = $spec.Value
        if (-not @($items | Where-Object { $_.V -eq $value }).Count) {
            $custom = $value
            $ci = @($items | Where-Object { $_.V -eq '__custom' })[0]
            if ($ci) { $ci.L = "Other: $value" }
        }
        $cur = 0
        for ($i = 0; $i -lt $items.Count; $i++) { if ($items[$i].V -eq $value -or ($custom -and $items[$i].V -eq '__custom')) { $cur = $i } }
    } else {
        $vals = New-Object System.Collections.ArrayList
        foreach ($v in $spec.Values) { if ($v) { [void]$vals.Add("$v") } }
        foreach ($v in $vals) { if (-not @($items | Where-Object { $_.V -eq $v }).Count) { [void]$items.Add(@{ V = $v; L = $(if ($a.Special -eq 'jdk') { "JDK $v" } else { "Python $v" }); H = 'custom' }) } }
        $default = if ($vals.Count) { $vals[0] } else { $null }
        $cur = 0
        $vendors = @($JdkVendors.Keys)
        $vendor = $spec.Vendor
    }
    $err = ''
    $inputMode = $false
    $inputText = ''

    while ($true) {
        $W = [Console]::WindowWidth - 1
        $H = [Console]::WindowHeight
        $bw = [Math]::Min(64, $W - 4)
        $iw = $bw - 4
        $lines = New-Object System.Collections.ArrayList
        Add-BoxEdge $lines $bw $spec.Title $true 'Cyan' 'White'
        $x = New-Segs; Add-Seg $x $spec.Hint DarkGray; Add-BoxLine $lines $bw $x 'Cyan'
        Add-BoxLine $lines $bw (New-Segs) 'Cyan'
        if ($a.Special -eq 'jdk') {
            $x = New-Segs
            Add-Seg $x 'Vendor    ' DarkGray
            Add-Seg $x "$($Gl.L) " Yellow
            Add-Seg $x $JdkVendorNames[$vendor] Cyan
            Add-Seg $x " $($Gl.R)" Yellow
            Add-Seg $x "   $($Gl.Left) $($Gl.Right) to change" DarkGray
            Add-BoxLine $lines $bw $x 'Cyan'
            Add-BoxLine $lines $bw (New-Segs) 'Cyan'
        }
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $isCur = ($i -eq $cur)
            $bg = if ($isCur) { 'DarkGray' } else { $script:BaseBg }
            $on = if ($spec.Mode -eq 'radio') { ($it.V -eq $value) -or ($custom -and $it.V -eq '__custom' -and $value -eq $custom) } else { $vals -contains $it.V }
            $x = New-Segs
            Add-Seg $x $(if ($isCur) { "$($Gl.Ptr) " } else { '  ' }) Cyan $bg
            Add-Seg $x $(if ($on) { $Gl.On } else { $Gl.Off }) $(if ($on) { 'Green' } else { 'DarkGray' }) $bg
            Add-Seg $x "  $($it.L)" $(if ($isCur -or $on) { 'White' } else { 'Gray' }) $bg
            if ($spec.Mode -eq 'check' -and $on -and $it.V -eq $default) { Add-Seg $x '  default' Yellow $bg }
            if ($it.H) { Add-Seg $x "  $($it.H)" DarkGray $bg }
            Add-BoxLine $lines $bw $x 'Cyan' $bg
        }
        Add-BoxLine $lines $bw (New-Segs) 'Cyan'
        $x = New-Segs
        if ($inputMode) { Add-Seg $x 'Version: ' DarkGray; Add-Seg $x $inputText Yellow; Add-Seg $x '_' Yellow }
        elseif ($err) { Add-Seg $x $err Red }
        Add-BoxLine $lines $bw $x 'Cyan'
        $x = New-Segs
        if ($inputMode) { Add-Chip $x 'Enter' 'ok'; Add-Chip $x 'Esc' 'back' }
        elseif ($spec.Mode -eq 'radio') { Add-Chip $x 'Enter' 'choose'; Add-Chip $x 'Esc' 'cancel' }
        else { Add-Chip $x 'Space' 'toggle'; Add-Chip $x 'D' 'default'; Add-Chip $x 'Enter' 'apply'; Add-Chip $x 'Esc' 'cancel' }
        Add-BoxLine $lines $bw $x 'Cyan'
        Add-BoxEdge $lines $bw '' $false 'Cyan'

        $bx = [int][Math]::Max(0, ($W - $bw) / 2)
        $by = [int][Math]::Max(1, ($H - $lines.Count) / 2)
        for ($i = 0; $i -lt $lines.Count; $i++) { Write-Segs $bx ($by + $i) $bw $lines[$i] }

        $k = Read-Key
        if ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return $false }
        if ($inputMode) {
            if ($k.Key -eq [ConsoleKey]::Enter) {
                $t = $inputText.Trim()
                if ($t -match $Patterns.node) {
                    $custom = $t.ToLower(); $value = $custom
                    $items[$cur].L = "Other: $custom"
                    $inputMode = $false; $err = ''
                    break
                } else { $err = "'$t' is not a valid Node.js version"; $inputMode = $false }
            } elseif ($k.Key -eq [ConsoleKey]::Escape) { $inputMode = $false }
            elseif ($k.Key -eq [ConsoleKey]::Backspace) { if ($inputText.Length) { $inputText = $inputText.Substring(0, $inputText.Length - 1) } }
            elseif ($k.KeyChar -match '[\w\.:]') { if ($inputText.Length -lt 20) { $inputText += $k.KeyChar } }
            continue
        }
        $err = ''
        $it = $items[$cur]
        if ($k.Key -eq [ConsoleKey]::UpArrow) { $cur = ($cur - 1 + $items.Count) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $cur = ($cur + 1) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::Escape) { return $false }
        elseif ($a.Special -eq 'jdk' -and ($k.Key -eq [ConsoleKey]::LeftArrow -or $k.Key -eq [ConsoleKey]::RightArrow)) {
            $vi = [array]::IndexOf($vendors, $vendor)
            $vi = if ($k.Key -eq [ConsoleKey]::RightArrow) { ($vi + 1) % $vendors.Count } else { ($vi - 1 + $vendors.Count) % $vendors.Count }
            $vendor = $vendors[$vi]
        }
        elseif ($spec.Mode -eq 'radio' -and ($k.Key -eq [ConsoleKey]::Spacebar -or $k.Key -eq [ConsoleKey]::Enter)) {
            if ($it.V -eq '__custom') {
                if ($k.Key -eq [ConsoleKey]::Enter -and $custom -and $value -eq $custom) { break }
                $inputMode = $true; $inputText = $(if ($custom) { $custom } else { '' })
                continue
            }
            $value = $it.V
            if ($k.Key -eq [ConsoleKey]::Enter) { break }
        }
        elseif ($spec.Mode -eq 'check' -and $k.Key -eq [ConsoleKey]::Spacebar) {
            if ($vals -contains $it.V) {
                [void]$vals.Remove($it.V)
                if ($default -eq $it.V) { $default = @($items | Where-Object { $vals -contains $_.V } | ForEach-Object { $_.V })[0] }
            } else {
                [void]$vals.Add($it.V)
                if (-not $default) { $default = $it.V }
            }
        }
        elseif ($spec.Mode -eq 'check' -and $k.KeyChar -eq 'd') {
            if ($vals -notcontains $it.V) { [void]$vals.Add($it.V) }
            $default = $it.V
        }
        elseif ($spec.Mode -eq 'check' -and $k.Key -eq [ConsoleKey]::Enter) {
            if (-not $vals.Count) { $err = 'Select at least one version (or Esc to cancel)'; continue }
            break
        }
    }

    switch ($a.Special) {
        'node' { $S.Opt.node = $value }
        'xampp' { $S.Opt.xampp = $value }
        'intellij' { $S.Opt.intellij = $value }
        'python' {
            $ordered = @($default) + @($items | Where-Object { $vals -contains $_.V -and $_.V -ne $default } | ForEach-Object { $_.V })
            $S.Opt.python = $ordered
        }
        'jdk' {
            $ordered = @($default) + @($items | Where-Object { $vals -contains $_.V -and $_.V -ne $default } | ForEach-Object { $_.V })
            $S.Opt.jdk = @($ordered | ForEach-Object { "${vendor}:$_" })
        }
    }
    $S.Sel[$a.Key] = $true
    $S.Msg = "$($Gl.Ok) $($a.Name): $(Get-OptionSummary $S.Opt $a)"
    return $true
}

# Review screen. Returns 'install' or 'back'.
function Show-Review {
    param($S)
    $scroll = 0
    [Console]::BackgroundColor = $script:BaseBg
    Clear-Host
    while ($true) {
        $W = [Console]::WindowWidth - 1
        $H = [Console]::WindowHeight
        $listH = [Math]::Max(3, $H - 6)
        $rows = New-Object System.Collections.ArrayList
        $nInstall = 0; $nSkip = 0
        foreach ($c in Get-Categories) {
            $apps = @($Catalog | Where-Object { $_.Cat -eq $c -and $S.Sel[$_.Key] })
            if (-not $apps.Count) { continue }
            $x = New-Segs; Add-Seg $x "  $($c.ToUpper())" Cyan; [void]$rows.Add($x)
            foreach ($a in $apps) {
                $state = Get-PlanState $a $S.Opt $S.Force
                if ($state[0] -like 'skip*') { $nSkip++ } else { $nInstall++ }
                $x = New-Segs
                Add-Seg $x "   $($Gl.On)  " $(if ($state[0] -like 'skip*') { 'DarkGray' } else { 'Green' })
                $nameW = [Math]::Min(30, [Math]::Max(16, $W - 50))
                $n = $a.Name; if ($n.Length -gt $nameW) { $n = $n.Substring(0, $nameW) }
                Add-Seg $x $n.PadRight($nameW) White
                $o = if ($a.Special) { Get-OptionSummary $S.Opt $a } else { '' }
                $optW = [Math]::Max(0, $W - $nameW - 26)
                if ($o.Length -gt $optW) { $o = $o.Substring(0, $optW) }
                Add-Seg $x ('  ' + $o.PadRight($optW)) Cyan
                Add-Seg $x $state[0] $state[1]
                [void]$rows.Add($x)
            }
            [void]$rows.Add((New-Segs))
        }
        $scroll = [Math]::Max(0, [Math]::Min($scroll, $rows.Count - $listH))

        $mode = if ($DryRun) { 'DRY RUN' } else { 'REVIEW' }
        Write-TitleBar $mode "$nInstall to install  $($Gl.Dot)  $nSkip already installed"
        $l = New-Segs
        if ($DryRun) { Add-Seg $l '  Dry run: nothing will be installed. Press Enter to see what would happen.' Yellow }
        else { Add-Seg $l '  Everything below installs silently. Nothing happens until you press Enter.' DarkGray }
        Write-Segs 0 1 $W $l
        Write-RuleAt 2 ''
        for ($i = 0; $i -lt $listH; $i++) {
            $ri = $scroll + $i
            if ($ri -lt $rows.Count) { Write-Segs 0 (3 + $i) $W $rows[$ri] } else { Write-Segs 0 (3 + $i) $W (New-Segs) }
        }
        $more = if ($rows.Count -gt $scroll + $listH) { "$($Gl.Dn) $($rows.Count - $scroll - $listH) more" } else { '' }
        Write-RuleAt ($H - 3) $more
        $l = New-Segs
        Add-Seg $l '  Reinstall apps that are already installed: ' DarkGray
        if ($S.Force) { Add-Seg $l 'ON' Yellow } else { Add-Seg $l 'off' DarkGray }
        Add-Seg $l '      Logs: ' DarkGray
        Add-Seg $l $LogDir DarkGray
        Write-Segs 0 ($H - 2) $W $l
        $l = New-Segs
        Add-Seg $l ' ' Gray
        Add-Chip $l 'Enter' $(if ($DryRun) { 'run dry run' } else { 'install now' })
        Add-Chip $l 'Esc' 'back to list'
        Add-Chip $l 'F' 'toggle reinstall'
        Add-Chip $l "$($Gl.Up)$($Gl.Dn)" 'scroll'
        Write-Segs 0 ($H - 1) $W $l

        $k = Read-Key
        if ($k.Key -eq [ConsoleKey]::Enter) { return 'install' }
        if ($k.Key -eq [ConsoleKey]::Escape -or $k.Key -eq [ConsoleKey]::Backspace -or $k.Key -eq [ConsoleKey]::LeftArrow) { return 'back' }
        if ($k.Key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return 'back' }
        if ($k.KeyChar -eq 'f') { $S.Force = -not $S.Force }
        elseif ($k.Key -eq [ConsoleKey]::UpArrow) { $scroll-- }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $scroll++ }
        elseif ($k.Key -eq [ConsoleKey]::PageUp) { $scroll -= $listH }
        elseif ($k.Key -eq [ConsoleKey]::PageDown) { $scroll += $listH }
    }
}

# Main picker loop. Returns @{ Keys; Opt; Force } or $null when the user quits.
function Show-Picker {
    param([hashtable]$Opt, [hashtable]$Sel)
    $S = @{ Sel = $Sel; Opt = $Opt; Cursor = -1; Scroll = 0; Filter = ''; Search = $false; Msg = ''; CurKey = $null; Force = [bool]$Force; ListH = 10 }
    $oldCtrlC = [Console]::TreatControlCAsInput
    $size = ''
    try {
        [Console]::TreatControlCAsInput = $true
        [Console]::CursorVisible = $false
        while ($true) {
            $sz = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
            if ($sz -ne $size) { [Console]::BackgroundColor = $script:BaseBg; Clear-Host; $size = $sz }
            $rows = Get-PickerRows $S.Filter
            $idx = -1
            if ($S.CurKey) { for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Type -eq 'app' -and $rows[$i].App.Key -eq $S.CurKey) { $idx = $i; break } } }
            if ($idx -lt 0 -and $rows.Count) { $idx = Get-NextAppRow $rows -1 1; if ($rows[$idx].Type -ne 'app') { $idx = -1 } }
            $S.Cursor = $idx
            if ($idx -ge 0) { $S.CurKey = $rows[$idx].App.Key }

            Draw-Picker $S $rows
            $k = Read-Key
            $key = $k.Key
            $ch = $k.KeyChar
            if ($key -eq [ConsoleKey]::C -and ($k.Modifiers -band [ConsoleModifiers]::Control)) { return $null }
            $app = if ($idx -ge 0) { $rows[$idx].App } else { $null }

            # navigation works in both modes
            $moved = $true
            if ($key -eq [ConsoleKey]::UpArrow) { $S.Cursor = Get-NextAppRow $rows $idx -1 }
            elseif ($key -eq [ConsoleKey]::DownArrow) { $S.Cursor = Get-NextAppRow $rows $idx 1 }
            elseif ($key -eq [ConsoleKey]::PageUp) { $c = $idx; for ($i = 0; $i -lt $S.ListH - 1; $i++) { $c = Get-NextAppRow $rows $c -1 }; $S.Cursor = $c }
            elseif ($key -eq [ConsoleKey]::PageDown) { $c = $idx; for ($i = 0; $i -lt $S.ListH - 1; $i++) { $c = Get-NextAppRow $rows $c 1 }; $S.Cursor = $c }
            elseif ($key -eq [ConsoleKey]::Home) { $S.Cursor = Get-NextAppRow $rows -1 1 }
            elseif ($key -eq [ConsoleKey]::End) { $S.Cursor = Get-NextAppRow $rows $rows.Count -1 }
            elseif ($key -eq [ConsoleKey]::Tab) {
                # jump to the first app of the next (Shift+Tab: previous) category
                $cats = @(for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Type -eq 'cat') { $i } })
                if ($cats.Count) {
                    $ci = -1
                    for ($j = 0; $j -lt $cats.Count; $j++) { if ($cats[$j] -lt $idx) { $ci = $j } }
                    $dir = if ($k.Modifiers -band [ConsoleModifiers]::Shift) { -1 } else { 1 }
                    $ni = ($ci + $dir + $cats.Count) % $cats.Count
                    $S.Cursor = Get-NextAppRow $rows $cats[$ni] 1
                }
            }
            elseif ($key -eq [ConsoleKey]::Spacebar -and $app) { $S.Sel[$app.Key] = -not $S.Sel[$app.Key] }
            elseif (($key -eq [ConsoleKey]::RightArrow) -and $app) {
                if ($app.Special) { [void](Show-OptionsDialog $S $app); $size = '' }
                else { $S.Msg = "$($app.Name) has no version options - press Space to select it." }
            }
            else { $moved = $false }
            if ($moved) {
                if ($S.Cursor -ge 0 -and $S.Cursor -lt $rows.Count) { $S.CurKey = $rows[$S.Cursor].App.Key }
                continue
            }

            if ($S.Search) {
                if ($key -eq [ConsoleKey]::Enter) { $S.Search = $false }
                elseif ($key -eq [ConsoleKey]::Escape) { $S.Search = $false; $S.Filter = '' }
                elseif ($key -eq [ConsoleKey]::Backspace) { if ($S.Filter.Length) { $S.Filter = $S.Filter.Substring(0, $S.Filter.Length - 1) } }
                elseif ($ch -match '[\w\.\+\- &/]' -and [int]$ch -ge 32) { if ($S.Filter.Length -lt 30) { $S.Filter += $ch; $S.CurKey = $null } }
                continue
            }

            if ($ch -eq '/') { $S.Search = $true }
            elseif ($key -eq [ConsoleKey]::Escape -or $ch -eq 'q') {
                if ($S.Filter) { $S.Filter = '' } else { return $null }
            }
            elseif ($ch -eq 'a') { foreach ($r in $rows) { if ($r.Type -eq 'app') { $S.Sel[$r.App.Key] = $true } }; $S.Msg = 'Selected every app in the list.' }
            elseif ($ch -eq 'n') { foreach ($r in $rows) { if ($r.Type -eq 'app') { $S.Sel[$r.App.Key] = $false } }; $S.Msg = 'Cleared the selection.' }
            elseif ($ch -eq 'r') { foreach ($a in $Catalog) { $S.Sel[$a.Key] = [bool]$a.Rec }; $S.Msg = 'Restored the recommended selection.' }
            elseif ($ch -eq 'c' -and $app) {
                $catApps = @($Catalog | Where-Object { $_.Cat -eq $app.Cat -and (Test-AppFilter $_ $S.Filter) })
                $allOn = @($catApps | Where-Object { -not $S.Sel[$_.Key] }).Count -eq 0
                foreach ($a in $catApps) { $S.Sel[$a.Key] = -not $allOn }
            }
            elseif ($ch -eq 'v' -and $app -and $app.Special) { [void](Show-OptionsDialog $S $app); $size = '' }
            elseif ($key -eq [ConsoleKey]::Enter) {
                if (-not @($Catalog | Where-Object { $S.Sel[$_.Key] }).Count) { $S.Msg = 'Nothing selected yet - press Space on an app first.'; continue }
                $r = Show-Review $S
                $size = ''
                if ($r -eq 'install') {
                    return @{ Keys = @($Catalog | Where-Object { $S.Sel[$_.Key] } | ForEach-Object { $_.Key }); Opt = $S.Opt; Force = $S.Force }
                }
            }
        }
    } finally {
        [Console]::TreatControlCAsInput = $oldCtrlC
        [Console]::ResetColor()
        [Console]::CursorVisible = $true
        Clear-Host
    }
}

function Show-Catalog {
    foreach ($c in Get-Categories) {
        Write-Host ''
        Write-Host "  $($c.ToUpper())" -ForegroundColor Cyan
        foreach ($a in ($Catalog | Where-Object { $_.Cat -eq $c })) {
            $src = if ($a.Special) { 'version selectable' } elseif ($a.Winget) { $a.Winget } else { ($a.Fallback | ForEach-Object { Get-MethodLabel $_ }) -join ', ' }
            $rec = if ($a.Rec) { $Gl.On } else { ' ' }
            Write-Host "   $rec " -ForegroundColor Green -NoNewline
            Write-Host ("{0,-12}" -f $a.Key) -ForegroundColor White -NoNewline
            Write-Host (" {0,-28}" -f $a.Name) -NoNewline
            Write-Host " $src" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host "  $($Gl.On) = recommended (pre-selected in the picker, installed with -Recommended)" -ForegroundColor DarkGray
}

function Split-List {
    param($Value)
    return @(@($Value) | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
}

# ============================================================================================
# Main
# ============================================================================================
if ($env:WSI_TEST_KEYS) {
    $script:TestKeys = New-Object System.Collections.Generic.Queue[string]
    foreach ($t in ($env:WSI_TEST_KEYS -split '\s+' | Where-Object { $_ })) { $script:TestKeys.Enqueue($t) }
}

Show-Banner

if ($List) { Show-Catalog; return }

$isAdmin = Test-Admin
if (-not $DryRun -and -not $isAdmin) { Restart-Elevated }

# .NET writes console text in the OEM code page, which mangles the UI glyphs; switch to UTF-8 while running.
$script:OrigOutEnc = $null
if ($script:UseUnicode) {
    try { $script:OrigOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
}
function Exit-Wsi {
    param([int]$Code)
    if ($script:OrigOutEnc) { try { [Console]::OutputEncoding = $script:OrigOutEnc } catch {} }
    exit $Code
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$script:LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ---- preflight
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$dv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
Write-Log "WSI $($script:Version) on $($os.Caption) $dv build $($os.BuildNumber), PS $($PSVersionTable.PSVersion)"
Write-Step ok (("$($os.Caption)" -replace '^Microsoft ', '') + $(if ($dv) { " $dv" } else { '' })) "build $($os.BuildNumber)  $($Gl.Dot)  PowerShell $($PSVersionTable.PSVersion.ToString(2))"
if ($isAdmin) { Write-Step ok 'Running as administrator' } else { Write-Step skip 'Not running as administrator' 'fine for a dry run' }
$null = Initialize-Winget
Update-InstalledScan

# ---- gather selection: defaults < config < command line < picker
$opt = @{ node = $null; python = @(); jdk = @(); xampp = $null; intellij = $null }
$keys = @()
if ($Config) {
    # a path, a profile name from .\profiles (e.g. "full-dev"), or an http(s) URL
    if ($Config -match '^https?://') {
        try { $cfg = Invoke-RestMethod -Uri $Config -UseBasicParsing -ErrorAction Stop }
        catch { Write-Fail "Could not download config $Config : $($_.Exception.Message)"; Exit-Wsi 1 }
    } else {
        $named = Join-Path $script:ScriptDir "profiles\$Config.json"
        if (-not (Test-Path $Config) -and (Test-Path $named)) { $Config = $named }
        if (-not (Test-Path $Config)) { Write-Fail "Config not found: $Config"; Exit-Wsi 1 }
        $cfg = Get-Content -Raw -Path $Config | ConvertFrom-Json
    }
    if ($cfg.apps)     { $keys += Split-List $cfg.apps }
    if ($cfg.node)     { $opt.node = "$($cfg.node)" }
    if ($cfg.python)   { $opt.python = Split-List $cfg.python }
    if ($cfg.jdk)      { $opt.jdk = Split-List $cfg.jdk }
    if ($cfg.xampp)    { $opt.xampp = "$($cfg.xampp)" }
    if ($cfg.intellij) { $opt.intellij = "$($cfg.intellij)" }
}
if ($Apps)        { $keys += Split-List $Apps }
if ($Recommended) { $keys += @($Catalog | Where-Object { $_.Rec } | ForEach-Object { $_.Key }) }
if ($All)         { $keys = @($Catalog | ForEach-Object { $_.Key }) }
if ($Node)        { $opt.node = $Node }
if ($Python)      { $opt.python = Split-List $Python }
if ($Jdk)         { $opt.jdk = Split-List $Jdk }
if ($Xampp)       { $opt.xampp = $Xampp }
if ($IntelliJ)    { $opt.intellij = $IntelliJ }
if (-not $opt.node)         { $opt.node = $Defaults.node }
if (-not $opt.python.Count) { $opt.python = $Defaults.python }
if (-not $opt.jdk.Count)    { $opt.jdk = $Defaults.jdk }
if (-not $opt.xampp)        { $opt.xampp = $Defaults.xampp }
if (-not $opt.intellij)     { $opt.intellij = $Defaults.intellij }
foreach ($f in 'node', 'xampp', 'intellij') {
    if ("$($opt[$f])" -notmatch $Patterns[$f]) { Write-Fail "Invalid $f value '$($opt[$f])'"; Exit-Wsi 1 }
}
foreach ($f in 'python', 'jdk') {
    foreach ($v in $opt[$f]) { if ("$v" -notmatch $Patterns[$f]) { Write-Fail "Invalid $f value '$v'"; Exit-Wsi 1 } }
}

$interactive = ($keys.Count -eq 0)
if ($interactive -and $Yes) { Write-Fail 'Nothing selected. Use -Apps, -All, -Recommended or -Config with -Yes.'; Exit-Wsi 1 }

if ($interactive) {
    $canTui = $true
    try { if (-not $script:TestKeys -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) { $canTui = $false } } catch { $canTui = $false }
    if (-not $canTui) { Write-Fail 'The interactive picker needs a console window. Use -Apps, -Recommended or -Config instead (see -List).'; Exit-Wsi 1 }
    if (-not $script:TestKeys) { Write-Host ''; Write-Host '  Opening the app picker...' -ForegroundColor DarkGray; Start-Sleep -Milliseconds 600 }
    $sel = @{}
    foreach ($a in $Catalog) { $sel[$a.Key] = [bool]$a.Rec }
    try { $pick = Show-Picker $opt $sel }
    catch { if ("$_" -eq 'WSI_TEST_END') { Exit-Wsi 0 }; throw }
    if (-not $pick) { Show-Banner; Write-Host '  Cancelled - nothing was installed.' -ForegroundColor DarkGray; Write-Host ''; Exit-Wsi 0 }
    $keys = $pick.Keys
    $opt = $pick.Opt
    $Force = [switch]$pick.Force
    Show-Banner
} else {
    $resolved = @()
    foreach ($k in $keys) {
        $kk = $AliasMap[$k.ToLower()]
        if ($kk) { $resolved += $kk } else { Write-Step warn "Unknown app '$k'" 'ignored - see -List' }
    }
    # keep catalog order, drop duplicates
    $keys = @($Catalog | Where-Object { $resolved -contains $_.Key } | ForEach-Object { $_.Key })
}
if ($keys.Count -eq 0) { Write-Host '  Nothing selected - exiting.'; Exit-Wsi 0 }

# npm-only tools need Node.js
$needsNode = @($keys | Where-Object { $CatalogByKey[$_].Needs -eq 'node' })
if ($needsNode.Count -and $keys -notcontains 'node' -and -not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Step warn 'Adding Node.js' "needed by $($needsNode -join ', ')"
    $keys = @($Catalog | Where-Object { $keys -contains $_.Key -or $_.Key -eq 'node' } | ForEach-Object { $_.Key })
}

# ---- save selection so it can be replayed unattended
$profileObj = [ordered]@{ apps = $keys }
foreach ($f in 'node', 'python', 'jdk', 'xampp', 'intellij') { if ($keys -contains $f) { $profileObj[$f] = $opt[$f] } }
$lastProfile = Join-Path $LogDir 'last-selection.json'
try { $profileObj | ConvertTo-Json | Set-Content -Path $lastProfile -Encoding UTF8 } catch {}

# ---- plan (non-interactive runs confirm here; the picker already had a review screen)
if (-not $interactive) {
    Write-Rule ("Plan: {0} apps{1}" -f $keys.Count, $(if ($DryRun) { ' (dry run)' } else { '' }))
    foreach ($k in $keys) {
        $a = $CatalogByKey[$k]
        $state = Get-PlanState $a $opt ([bool]$Force)
        $o = if ($a.Special) { Get-OptionSummary $opt $a } else { '' }
        Write-Host "  $($Gl.On)  " -ForegroundColor $(if ($state[0] -like 'skip*') { 'DarkGray' } else { 'Green' }) -NoNewline
        Write-Host $a.Name.PadRight(30) -ForegroundColor White -NoNewline
        Write-Host $o.PadRight(26) -ForegroundColor Cyan -NoNewline
        Write-Host $state[0] -ForegroundColor $state[1]
    }
    if (-not $Yes -and -not $DryRun) {
        Write-Host ''
        $ans = Read-Host '  Install now? [Y/n]'
        if ($ans -and $ans.Trim() -notmatch '^(y|yes)$') { Write-Host '  Cancelled - nothing was installed.' -ForegroundColor DarkGray; Exit-Wsi 0 }
    }
}

# ---- install
$tasks = Get-Tasks $keys $opt
Write-Rule ("{0} {1} item{2}" -f $(if ($DryRun) { 'Dry run:' } else { 'Installing' }), $tasks.Count, $(if ($tasks.Count -ne 1) { 's' } else { '' }))
$sw = [Diagnostics.Stopwatch]::StartNew()
$i = 0
foreach ($t in $tasks) { $i++; Invoke-Task $t $i $tasks.Count }
$sw.Stop()
$script:CurLabel = ''

# ---- summary
$nOk   = @($script:Results | Where-Object { $_.Status -eq 'Installed' }).Count
$nSkip = @($script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count
$nDry  = @($script:Results | Where-Object { $_.Status -eq 'DryRun' }).Count
$failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })
Write-Rule ''
Write-Host '  ' -NoNewline
Write-Host "$($Gl.Ok) $nOk installed" -ForegroundColor Green -NoNewline
Write-Host "    $($Gl.Off) $nSkip skipped" -ForegroundColor DarkGray -NoNewline
if ($nDry) { Write-Host "    $($Gl.Dia) $nDry would install" -ForegroundColor Cyan -NoNewline }
Write-Host "    $($Gl.Bad) $($failed.Count) failed" -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'DarkGray' }) -NoNewline
Write-Host "    took $(Format-Elapsed $sw.Elapsed)" -ForegroundColor DarkGray
if ($failed.Count) {
    Write-Host ''
    Write-Host '  Failed:' -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "   $($Gl.Bad) $($f.App)" -ForegroundColor Red -NoNewline; Write-Host "  $($f.Detail)" -ForegroundColor DarkGray }
}
if ($script:Tips.Count) {
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Cyan
    foreach ($tip in $script:Tips) { Write-Host "   $($Gl.Right) $tip" -ForegroundColor Gray }
}
Write-Host ''
Write-Host '  Log     ' -ForegroundColor DarkGray -NoNewline; Write-Host $script:LogFile -ForegroundColor Gray
Write-Host '  Replay  ' -ForegroundColor DarkGray -NoNewline; Write-Host ".\install.ps1 -Config `"$lastProfile`" -Yes" -ForegroundColor Gray
if ($nOk) { Write-Host '  Open a new terminal so PATH changes take effect.' -ForegroundColor Yellow }

if ($script:RebootRequired -and -not $DryRun) {
    Write-Host ''
    Write-Host '  A reboot is required to finish some installs (for example WSL 2 / Docker).' -ForegroundColor Yellow
    if ($Reboot) {
        Write-Host '  Rebooting in 15 seconds...' -ForegroundColor Yellow
        shutdown.exe /r /t 15 /c "Windows Silent Installer: finishing setup"
    } elseif (-not $Yes) {
        $ans = Read-Host '  Reboot now? [y/N]'
        if ($ans -match '^(y|yes)$') { Restart-Computer -Force }
    }
}

if ($script:TestKeys) { Save-ScreenDump }
if ($Elevated) { Write-Host ''; Read-Host '  Press Enter to close' | Out-Null }
Exit-Wsi $(if ($failed.Count) { 1 } else { 0 })
