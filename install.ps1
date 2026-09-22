#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Silent Installer (WSI) - unattended app setup for a fresh Windows 10/11 machine.

.DESCRIPTION
    Installs developer tools and everyday apps silently, using winget first and falling back to
    official installers / npm / vendor scripts when winget fails. Node.js, Python, JDK, XAMPP and
    IntelliJ IDEA versions/editions are selectable.

    Run with no arguments for an interactive menu, or pass -Apps / -All / -Config for unattended use.

.EXAMPLE
    .\install.ps1
    Interactive menu.

.EXAMPLE
    .\install.ps1 -Apps chrome,vscode,git,node,python,jdk -Node 22 -Python 3.12,3.13 -Jdk 21,17 -Yes
    Unattended install of the listed apps with specific versions.

.EXAMPLE
    .\install.ps1 -Config .\profiles\full-dev.json -Yes
    Install everything described in a profile file.

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
    # Add the recommended set (the apps pre-ticked in the menu).
    [switch]$Recommended,
    # JSON profile: { "apps": [...], "node": "22", "python": ["3.13"], "jdk": ["21"], "xampp": "8.2", "intellij": "ultimate" }
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
    # Do not ask for confirmation / versions (use defaults for anything not specified).
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

$script:Version        = '1.0.0'
$script:BoundParams    = $PSBoundParameters
$script:ScriptDir      = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:TEMP 'win-silent-installer' }
$script:DownloadDir    = Join-Path $env:TEMP 'wsi-downloads'
$script:RebootRequired = $false
$script:Results        = New-Object System.Collections.Generic.List[object]
if (-not $LogDir) { $LogDir = Join-Path $script:ScriptDir 'logs' }

$Defaults = @{ node = 'lts'; python = @('3.13'); jdk = @('temurin:21'); xampp = '8.2'; intellij = 'ultimate' }

# winget / msiexec exit codes that mean "fine"
$OkCodes     = @(0, 3010, 1641, -1978335189, -1978335135, -1978334967, -1978334966)
$RebootCodes = @(3010, 1641, -1978334967, -1978334966)
$NoApplicableInstaller = -1978335216

# ============================================================================================
# Output / logging
# ============================================================================================
function Write-Log {
    param([string]$Message)
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8 } catch {}
    }
}
function Write-Info  { param([string]$m) Write-Host "      $m" -ForegroundColor DarkGray; Write-Log "INFO  $m" }
function Write-Ok    { param([string]$m) Write-Host "      [OK] $m" -ForegroundColor Green; Write-Log "OK    $m" }
function Write-Warn  { param([string]$m) Write-Host "      [!]  $m" -ForegroundColor Yellow; Write-Log "WARN  $m" }
function Write-Fail  { param([string]$m) Write-Host "      [X]  $m" -ForegroundColor Red; Write-Log "FAIL  $m" }
function Write-Title { param([string]$m) Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan; Write-Log "==== $m" }

# Installer output goes to the log (and the console with -ShowOutput). Spinner/progress-bar noise is dropped.
function Write-NativeOutput {
    param($Lines)
    foreach ($l in @($Lines)) {
        $s = ("$l" -replace '[\x00-\x08\x0B-\x1F]', '').Trim()
        if (-not $s -or $s -notmatch '[A-Za-z]') { continue }
        Write-Log "  | $s"
        if ($ShowOutput) { Write-Host "        $s" -ForegroundColor DarkGray }
    }
}

function Show-Banner {
    Write-Host ""
    Write-Host "  =====================================================" -ForegroundColor Cyan
    Write-Host "     Windows Silent Installer  v$($script:Version)" -ForegroundColor Cyan
    Write-Host "     Fresh Windows 10/11 setup - winget + fallbacks" -ForegroundColor DarkCyan
    Write-Host "  =====================================================" -ForegroundColor Cyan
}

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
    Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host 'Administrator rights are required (the UAC prompt was declined).' -ForegroundColor Red
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
    Write-Info "Downloading $Url"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fsSL --retry 3 -o $dest $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dest)) { return $dest }
    }
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    return $dest
}

function Test-ExitCode {
    param([int]$Code)
    if ($RebootCodes -contains $Code) { $script:RebootRequired = $true }
    return ($OkCodes -contains $Code)
}

# ============================================================================================
# winget
# ============================================================================================
function Get-WingetVersion {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    try {
        $v = & winget --version 2>$null | Select-Object -First 1
        if ("$v" -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    } catch {}
    return $null
}

function Initialize-Winget {
    Update-SessionEnv
    $v = Get-WingetVersion
    if ($v -and $v -ge [version]'1.6') {
        Write-Ok "winget $v"
    } else {
        if ($v) { Write-Warn "winget $v is too old - updating App Installer..." } else { Write-Warn 'winget not found - installing App Installer...' }
        try {
            Write-Info 'Installing Microsoft.WinGet.Client module and repairing winget'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            Repair-WinGetPackageManager -AllUsers -Latest -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Warn "Module method failed ($($_.Exception.Message)); trying direct MSIX install"
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
            Write-Fail 'winget is unavailable - only apps with direct-download fallbacks can be installed'
            return $false
        }
        Write-Ok "winget $v"
    }
    Write-Info 'Updating winget sources'
    Write-NativeOutput (& winget source update --disable-interactivity 2>&1)
    return $true
}

function Test-WingetInstalled {
    param([string]$Id)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    $null = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Winget {
    param([string]$Id, [string]$Version, [string]$Scope)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warn 'winget not available'; return $false }
    $wg = @('install', '--id', $Id, '--exact', '--silent', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Version) { $wg += @('--version', $Version) }
    if ($Scope)   { $wg += @('--scope', $Scope) }
    Write-Log "winget $($wg -join ' ')"
    $out  = & winget @wg 2>&1
    $code = $LASTEXITCODE
    Write-NativeOutput $out
    if ($code -eq $NoApplicableInstaller -and $Scope) {
        Write-Info "No $Scope-scope installer, retrying with default scope"
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

function Invoke-Method {
    param($m)
    switch ($m.Type) {
        'winget' { return (Invoke-Winget -Id $m.Id -Version $m.Version -Scope $m.Scope) }
        'msi' {
            $f = Get-Download $m.Url $m.File
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$f`" /qn /norestart $($m.Args)" -Wait -PassThru
            return (Test-ExitCode $p.ExitCode)
        }
        'exe' {
            $f = Get-Download $m.Url $m.File
            $p = Start-Process -FilePath $f -ArgumentList $m.Args -Wait -PassThru
            return (Test-ExitCode $p.ExitCode)
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
            $out = & npm.cmd install -g $m.Package 2>&1
            $code = $LASTEXITCODE
            Write-NativeOutput $out
            return ($code -eq 0)
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
    Write-NativeOutput (& wsl.exe --install --no-distribution 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-NativeOutput (& dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>&1)
        Write-NativeOutput (& dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>&1)
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
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'irm https://claude.ai/install.ps1 | iex' 2>&1
    Write-NativeOutput $out
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
    Write-Info "nvm install $v"
    Write-NativeOutput (& nvm install $v 2>&1)
    Write-NativeOutput (& nvm use $v 2>&1)
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
    Write-Info "Default python -> $dir"
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
          [int]$Order = 50, [string]$Note, [string]$Needs, [string]$Tip, [string[]]$Alias)
    @{ Key = $Key; Name = $Name; Cat = $Cat; Winget = $Winget; Rec = $Rec.IsPresent; Fallback = $Fallback
       CheckCmd = $CheckCmd; CheckPath = $CheckPath; Special = $Special; Pre = $Pre; Post = $Post
       Order = $Order; Note = $Note; Needs = $Needs; Tip = $Tip; Alias = $Alias }
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
    App chrome     'Google Chrome'            $cBrowser Google.Chrome -Rec -Fallback @(@{ Type = 'msi'; Url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; File = 'chrome.msi' })
    App firefox    'Mozilla Firefox'          $cBrowser Mozilla.Firefox
    App brave      'Brave Browser'            $cBrowser Brave.Brave
    App zoom       'Zoom Workplace'           $cBrowser Zoom.Zoom -Rec -Fallback @(@{ Type = 'msi'; Url = 'https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64'; File = 'zoom.msi' })
    App telegram   'Telegram Desktop'         $cBrowser Telegram.TelegramDesktop
    App discord    'Discord'                  $cBrowser Discord.Discord
    App slack      'Slack'                    $cBrowser SlackTechnologies.Slack

    App vscode     'Visual Studio Code'       $cEditor Microsoft.VisualStudioCode -Rec -CheckCmd code -Alias code, 'vs-code' -Fallback @(@{ Type = 'exe'; Url = 'https://update.code.visualstudio.com/latest/win32-x64/stable'; File = 'VSCodeSetup.exe'; Args = '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath' })
    App intellij   'IntelliJ IDEA'            $cEditor -Special intellij -Rec -Note '(edition asked later)' -Alias idea
    App toolbox    'JetBrains Toolbox'        $cEditor JetBrains.Toolbox -Rec -Alias 'jetbrains-toolbox'
    App notepadpp  'Notepad++'                $cEditor 'Notepad++.Notepad++' -Alias 'notepad++'
    App cursor     'Cursor'                   $cEditor Anysphere.Cursor

    App claude     'Claude Code CLI'          $cAi Anthropic.ClaudeCode -Rec -CheckCmd claude -Order 90 -Post $ClaudePost -Tip "Run 'claude' in a new terminal to sign in." -Alias 'claude-code' -Fallback @(@{ Type = 'script'; Label = 'claude.ai/install.ps1'; Script = $ClaudeScript }, @{ Type = 'npm'; Package = '@anthropic-ai/claude-code' })
    App copilot    'GitHub Copilot CLI'       $cAi GitHub.Copilot -Rec -CheckCmd copilot -Order 90 -Tip "Run 'copilot' and use /login to sign in." -Alias 'copilot-cli' -Fallback @(@{ Type = 'npm'; Package = '@github/copilot' })
    App opencode   'OpenCode CLI'             $cAi SST.opencode -Rec -CheckCmd opencode -Order 90 -Fallback @(@{ Type = 'npm'; Package = 'opencode-ai' })
    App gemini     'Gemini CLI'               $cAi -CheckCmd gemini -Order 90 -Needs node -Note '(npm, needs Node)' -Fallback @(@{ Type = 'npm'; Package = '@google/gemini-cli' })
    App codex      'OpenAI Codex CLI'         $cAi -CheckCmd codex -Order 90 -Needs node -Note '(npm, needs Node)' -Fallback @(@{ Type = 'npm'; Package = '@openai/codex' })

    App node       'Node.js'                  $cLang -Special node -Rec -Order 10 -Note '(version asked later)' -Alias nodejs
    App python     'Python'                   $cLang -Special python -Rec -Order 10 -Note '(version asked later)' -Alias py
    App jdk        'Java JDK'                 $cLang -Special jdk -Rec -Order 10 -Note '(vendor/version asked later)' -Alias java, openjdk
    App go         'Go'                       $cLang GoLang.Go -Alias golang
    App rust       'Rust (rustup)'            $cLang Rustlang.Rustup -Alias rustup

    App git        'Git'                      $cDev Git.Git -Rec -CheckCmd git -Order 5
    App gh         'GitHub CLI'               $cDev GitHub.cli -CheckCmd gh -Alias 'github-cli'
    App docker     'Docker Desktop'           $cDev Docker.DockerDesktop -Rec -Pre $DockerPre -Post $DockerPost -Tip 'Reboot, then start Docker Desktop once to finish WSL 2 setup.' -Fallback @(@{ Type = 'exe'; Url = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'; File = 'DockerDesktopInstaller.exe'; Args = 'install --quiet --accept-license' })
    App xampp      'XAMPP'                    $cDev -Special xampp -Rec -Note '(PHP version asked later)'
    App pgadmin    'pgAdmin 4'                $cDev PostgreSQL.pgAdmin -Rec -Alias pgadmin4
    App dbeaver    'DBeaver Community'        $cDev DBeaver.DBeaver.Community
    App postman    'Postman'                  $cDev Postman.Postman

    App ffmpeg     'FFmpeg'                   $cCli Gyan.FFmpeg -Rec -CheckCmd ffmpeg
    App openssl    'OpenSSL'                  $cCli ShiningLight.OpenSSL.Light -Rec -Post $OpenSslPost
    App adb        'Android Platform-Tools (adb)' $cCli Google.PlatformTools -Rec -CheckCmd adb -Alias 'platform-tools' -Fallback @(@{ Type = 'zip'; Url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'; File = 'platform-tools.zip'; Dest = 'C:\Android'; PathAdd = 'C:\Android\platform-tools' })
    App ytdlp      'yt-dlp'                   $cCli yt-dlp.yt-dlp -CheckCmd yt-dlp -Alias 'yt-dlp'
    App pwsh       'PowerShell 7'             $cCli Microsoft.PowerShell -Alias powershell

    App tabby      'Tabby (formerly Terminus)' $cNet Eugeny.Tabby -Rec -Alias terminus
    App termius    'Termius SSH client'       $cNet Termius.Termius
    App wterminal  'Windows Terminal'         $cNet Microsoft.WindowsTerminal -Alias 'windows-terminal'
    App warp       'Cloudflare 1.1.1.1 / WARP' $cNet Cloudflare.Warp -Rec -Alias cloudflare, '1.1.1.1' -Fallback @(@{ Type = 'msi'; Url = 'https://1111-releases.cloudflareclient.com/win/latest'; File = 'Cloudflare_WARP.msi' })

    App powertoys  'Microsoft PowerToys'      $cUtil Microsoft.PowerToys -Rec
    App 7zip       '7-Zip'                    $cUtil 7zip.7zip -Alias 7z
    App winzip     'WinZip'                   $cUtil Corel.WinZip -Note '(trial, paid license)'
    App wzcline    'WinZip Command Line add-on' $cUtil Corel.WinZip.CommandLineSupportAddOn -Note '(needs WinZip)' -Alias 'winzip-cli', wzzip
    App everything 'Everything (file search)' $cUtil voidtools.Everything
    App sharex     'ShareX'                   $cUtil ShareX.ShareX

    App vlc        'VLC media player'         $cMedia VideoLAN.VLC -Rec
    App qbittorrent 'qBittorrent'             $cMedia qBittorrent.qBittorrent -Rec -Alias qbit
    App obs        'OBS Studio'               $cMedia OBSProject.OBSStudio
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

$Patterns = @{
    node     = '^(?i)(lts|latest|current|nvm(:\S+)?|v?\d+(\.\d+){0,2})$'
    python   = '^3\.\d+(\.\d+)?(\s*,\s*3\.\d+(\.\d+)?)*$'
    jdk      = '^(?i)((temurin|microsoft|zulu|corretto|oracle):)?\d+(\s*,\s*((temurin|microsoft|zulu|corretto|oracle):)?\d+)*$'
    xampp    = '^8\.[12]$'
    intellij = '^(?i)(ultimate|community)$'
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
        return New-Task -Key node -Name 'Node.js (LTS)' -Methods @(@{ Type = 'winget'; Id = 'OpenJS.NodeJS.LTS' }) -CheckCmd node -Order 10
    }
    if ($s -eq 'latest' -or $s -eq 'current') {
        return New-Task -Key node -Name 'Node.js (latest)' -Methods @(@{ Type = 'winget'; Id = 'OpenJS.NodeJS' }) -CheckCmd node -Order 10
    }
    if ($s -match '^nvm(:(.+))?$') {
        $v = if ($Matches[2]) { $Matches[2] } else { 'lts' }
        return New-Task -Key node -Name "NVM for Windows + Node.js $v" -Methods @(@{ Type = 'winget'; Id = 'CoreyButler.NVMforWindows' }) `
            -CheckCmd nvm -Post $NvmPost -Data @{ Version = $v } -Order 10 -Tip "Switch Node versions with: nvm install <ver>; nvm use <ver>"
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
    New-Task -Key python -Name $label -Methods @(@{ Type = 'winget'; Id = $id; Version = $exact; Scope = 'machine' }) `
        -WingetCheck $id -Post $PythonPost -Data @{ Minor = $minor; Primary = $Primary } -Order 10
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
    $label  = if ($Primary) { "JDK $major ($vendor, JAVA_HOME)" } else { "JDK $major ($vendor)" }
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

function Invoke-Task {
    param($t, [int]$N, [int]$Total)
    Write-Host ""
    Write-Host ("  [{0}/{1}] {2}" -f $N, $Total, $t.Name) -ForegroundColor White
    Write-Log "---- $($t.Name)"
    if ($t.ErrorText) { Write-Fail $t.ErrorText; Add-Result $t.Name 'Failed' $t.ErrorText; return }

    Update-SessionEnv
    if (-not $Force -and (Test-TaskInstalled $t)) {
        Write-Info 'Already installed - skipping (use -Force to reinstall)'
        if (-not $DryRun -and $t.Post) { try { & $t.Post $t } catch { Write-Warn "Post-install step: $($_.Exception.Message)" } }
        Add-Result $t.Name 'Skipped' 'already installed'
        return
    }
    if ($DryRun) {
        foreach ($m in $t.Methods) { Write-Info ("would try: " + (Get-MethodLabel $m)) }
        Add-Result $t.Name 'DryRun' (Get-MethodLabel $t.Methods[0])
        return
    }

    if ($t.Pre) { try { & $t.Pre $t } catch { Write-Warn "Pre-install step: $($_.Exception.Message)" } }

    $via = $null
    foreach ($m in $t.Methods) {
        $label = Get-MethodLabel $m
        Write-Info "Installing via $label ..."
        try {
            if (Invoke-Method $m) { $via = $label; break }
        } catch {
            Write-Warn $_.Exception.Message
        }
        Write-Warn "Failed via $label"
    }
    if (-not $via) { Write-Fail "$($t.Name) could not be installed (see log)"; Add-Result $t.Name 'Failed' 'all methods failed'; return }

    Update-SessionEnv
    if ($t.Post) { try { & $t.Post $t } catch { Write-Warn "Post-install step: $($_.Exception.Message)" } }
    Write-Ok "$($t.Name) installed"
    Add-Result $t.Name 'Installed' $via
    if ($t.Tip) { $script:Tips += "$($t.Name): $($t.Tip)" }
}

# ============================================================================================
# Selection UI
# ============================================================================================
function Split-List {
    param($Value)
    return @(@($Value) | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
}

function Get-Categories {
    $cats = @()
    foreach ($a in $Catalog) { if ($cats -notcontains $a.Cat) { $cats += $a.Cat } }
    return $cats
}

function Show-Catalog {
    foreach ($c in Get-Categories) {
        Write-Host ""
        Write-Host "  $c" -ForegroundColor Cyan
        foreach ($a in ($Catalog | Where-Object { $_.Cat -eq $c })) {
            $src = if ($a.Special) { 'version selectable' } elseif ($a.Winget) { $a.Winget } else { ($a.Fallback | ForEach-Object { Get-MethodLabel $_ }) -join ', ' }
            $rec = if ($a.Rec) { '*' } else { ' ' }
            Write-Host ("   {0} {1,-12} {2,-32} {3}" -f $rec, $a.Key, $a.Name, $src)
        }
    }
    Write-Host ""
    Write-Host '  * = recommended (pre-selected in the menu, installed with -Recommended)' -ForegroundColor DarkGray
}

function Show-Menu {
    param([hashtable]$Sel)
    $cats = Get-Categories
    while ($true) {
        Clear-Host
        Show-Banner
        $n = 0
        $map = @{}
        foreach ($c in $cats) {
            Write-Host ""
            Write-Host "  $c" -ForegroundColor Cyan
            foreach ($a in ($Catalog | Where-Object { $_.Cat -eq $c })) {
                $n++
                $map[$n] = $a.Key
                $on = [bool]$Sel[$a.Key]
                $mark  = if ($on) { '[x]' } else { '[ ]' }
                $color = if ($on) { 'Green' } else { 'Gray' }
                Write-Host ("   {0} {1,3}. {2,-30} {3}" -f $mark, $n, $a.Name, $a.Note) -ForegroundColor $color
            }
        }
        $count = @($Sel.Keys | Where-Object { $Sel[$_] }).Count
        Write-Host ""
        Write-Host "  $count selected.  Toggle: 1 4 7-9  |  a = all  n = none  r = recommended  |  Enter = continue  q = quit" -ForegroundColor Yellow
        $in = Read-Host '  >'
        if ([string]::IsNullOrWhiteSpace($in) -or $in.Trim() -eq 'c') { break }
        foreach ($tok in ($in.Trim().ToLower() -split '[\s,]+' | Where-Object { $_ })) {
            if ($tok -match '^(\d+)-(\d+)$') {
                $from = [int]$Matches[1]; $to = [int]$Matches[2]
                for ($i = $from; $i -le $to; $i++) { if ($map.ContainsKey($i)) { $Sel[$map[$i]] = -not $Sel[$map[$i]] } }
            } elseif ($tok -match '^\d+$') {
                $i = [int]$tok
                if ($map.ContainsKey($i)) { $Sel[$map[$i]] = -not $Sel[$map[$i]] }
            } elseif ($tok -eq 'a') { foreach ($a in $Catalog) { $Sel[$a.Key] = $true } }
            elseif ($tok -eq 'n') { foreach ($a in $Catalog) { $Sel[$a.Key] = $false } }
            elseif ($tok -eq 'r') { foreach ($a in $Catalog) { $Sel[$a.Key] = [bool]$a.Rec } }
            elseif ($tok -eq 'q') { exit 0 }
        }
    }
    return @($Catalog | Where-Object { $Sel[$_.Key] } | ForEach-Object { $_.Key })
}

function Read-Option {
    param([string]$Title, [string]$Hint, [string]$Default, [string]$Pattern)
    while ($true) {
        Write-Host ""
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "  $Hint" -ForegroundColor DarkGray
        $r = Read-Host "  Value [$Default]"
        if ([string]::IsNullOrWhiteSpace($r)) { $r = $Default }
        $r = $r.Trim()
        if ($r -match $Pattern) { return $r }
        Write-Host "  Invalid value '$r'" -ForegroundColor Red
    }
}

# ============================================================================================
# Main
# ============================================================================================
Show-Banner

if ($List) { Show-Catalog; return }

if (-not $DryRun -and -not (Test-Admin)) { Restart-Elevated }

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$script:LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Tips = @()
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
Write-Log "WSI $($script:Version) on $($os.Caption) $($os.Version) build $($os.BuildNumber), PS $($PSVersionTable.PSVersion)"

# ---- gather selection: defaults < config < command line < interactive prompts
$opt = @{ node = $null; python = @(); jdk = @(); xampp = $null; intellij = $null }
$keys = @()
if ($Config) {
    # a path, a profile name from .\profiles (e.g. "full-dev"), or an http(s) URL
    if ($Config -match '^https?://') {
        try { $cfg = Invoke-RestMethod -Uri $Config -UseBasicParsing -ErrorAction Stop }
        catch { Write-Fail "Could not download config $Config : $($_.Exception.Message)"; exit 1 }
    } else {
        $named = Join-Path $script:ScriptDir "profiles\$Config.json"
        if (-not (Test-Path $Config) -and (Test-Path $named)) { $Config = $named }
        if (-not (Test-Path $Config)) { Write-Fail "Config not found: $Config"; exit 1 }
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

$interactive = ($keys.Count -eq 0)
if ($interactive -and $Yes) { Write-Fail 'Nothing selected. Use -Apps, -All, -Recommended or -Config with -Yes.'; exit 1 }

if ($interactive) {
    $sel = @{}
    foreach ($a in $Catalog) { $sel[$a.Key] = [bool]$a.Rec }
    $keys = Show-Menu $sel
} else {
    $resolved = @()
    foreach ($k in $keys) {
        $kk = $AliasMap[$k.ToLower()]
        if ($kk) { $resolved += $kk } else { Write-Warn "Unknown app '$k' (see -List) - ignored" }
    }
    # keep catalog order, drop duplicates
    $keys = @($Catalog | Where-Object { $resolved -contains $_.Key } | ForEach-Object { $_.Key })
}
if ($keys.Count -eq 0) { Write-Host 'Nothing selected - exiting.'; exit 0 }

# npm-only tools need Node.js
$needsNode = @($keys | Where-Object { $CatalogByKey[$_].Needs -eq 'node' })
if ($needsNode.Count -and $keys -notcontains 'node' -and -not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Warn "$($needsNode -join ', ') need Node.js - adding Node.js to the selection"
    $keys = @($Catalog | Where-Object { $keys -contains $_.Key -or $_.Key -eq 'node' } | ForEach-Object { $_.Key })
}

# ---- versions
$ask = -not $Yes
if ($keys -contains 'node' -and -not $opt.node) {
    $opt.node = if ($ask) { Read-Option 'Node.js version' 'lts | latest | 22 | 20 | 20.18.0 | nvm | nvm:22   (nvm = NVM for Windows, lets you switch later)' $Defaults.node $Patterns.node } else { $Defaults.node }
}
if ($keys -contains 'python' -and -not $opt.python.Count) {
    $opt.python = if ($ask) { Split-List (Read-Option 'Python version(s)' '3.14 | 3.13 | 3.12 | 3.11 | 3.10 | exact like 3.12.8 - comma separate for several; the first becomes the default' ($Defaults.python -join ',') $Patterns.python) } else { $Defaults.python }
}
if ($keys -contains 'jdk' -and -not $opt.jdk.Count) {
    $opt.jdk = if ($ask) { Split-List (Read-Option 'JDK version(s)' "[vendor:]major e.g. 21 | 17,21 | microsoft:21  - vendors: $($JdkVendors.Keys -join ', ') (default temurin); first = JAVA_HOME" ($Defaults.jdk -join ',') $Patterns.jdk) } else { $Defaults.jdk }
}
if ($keys -contains 'xampp' -and -not $opt.xampp) {
    $opt.xampp = if ($ask) { Read-Option 'XAMPP PHP version' '8.2 | 8.1' $Defaults.xampp $Patterns.xampp } else { $Defaults.xampp }
}
if ($keys -contains 'intellij' -and -not $opt.intellij) {
    $opt.intellij = if ($ask) { Read-Option 'IntelliJ IDEA edition' 'ultimate (unified, free tier available) | community' $Defaults.intellij $Patterns.intellij } else { $Defaults.intellij }
}
foreach ($f in 'node', 'xampp', 'intellij') {
    if ($opt[$f] -and "$($opt[$f])" -notmatch $Patterns[$f]) { Write-Fail "Invalid $f value '$($opt[$f])'"; exit 1 }
}

# ---- save selection so it can be replayed unattended
$profileObj = [ordered]@{ apps = $keys }
foreach ($f in 'node', 'python', 'jdk', 'xampp', 'intellij') { if ($keys -contains $f) { $profileObj[$f] = $opt[$f] } }
$lastProfile = Join-Path $LogDir 'last-selection.json'
try { $profileObj | ConvertTo-Json | Set-Content -Path $lastProfile -Encoding UTF8 } catch {}

# ---- winget + plan
Write-Title 'Checking winget'
$null = Initialize-Winget
$tasks = Get-Tasks $keys $opt

Write-Title ("Install plan ({0} items){1}" -f $tasks.Count, $(if ($DryRun) { ' - DRY RUN' } else { '' }))
foreach ($t in $tasks) {
    $how = if ($t.ErrorText) { "ERROR: $($t.ErrorText)" } elseif ($t.Methods.Count) { Get-MethodLabel $t.Methods[0] } else { '' }
    Write-Host ("   - {0,-38} {1}" -f $t.Name, $how)
}
if (-not $Yes -and -not $DryRun) {
    Write-Host ""
    $ans = Read-Host '  Proceed? [Y/n]'
    if ($ans -and $ans.Trim() -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 0 }
}

# ---- install
Write-Title 'Installing'
$sw = [Diagnostics.Stopwatch]::StartNew()
$i = 0
foreach ($t in $tasks) { $i++; Invoke-Task $t $i $tasks.Count }
$sw.Stop()

# ---- summary
Write-Title ("Summary ({0:mm\:ss})" -f $sw.Elapsed)
foreach ($r in $script:Results) {
    $color = switch ($r.Status) { 'Installed' { 'Green' } 'Skipped' { 'DarkGray' } 'DryRun' { 'Cyan' } default { 'Red' } }
    Write-Host ("   {0,-10} {1,-38} {2}" -f $r.Status, $r.App, $r.Detail) -ForegroundColor $color
}
$failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })
Write-Host ""
Write-Host ("   Installed: {0}   Skipped: {1}   Failed: {2}" -f
    @($script:Results | Where-Object { $_.Status -eq 'Installed' }).Count,
    @($script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count,
    $failed.Count)
if ($script:Tips.Count) {
    Write-Host ""
    Write-Host '   Next steps:' -ForegroundColor Cyan
    foreach ($tip in $script:Tips) { Write-Host "    - $tip" }
}
Write-Host ""
Write-Host "   Log:       $script:LogFile" -ForegroundColor DarkGray
Write-Host "   Replay:    .\install.ps1 -Config `"$lastProfile`" -Yes" -ForegroundColor DarkGray
Write-Host '   Open a NEW terminal so PATH changes take effect.' -ForegroundColor Yellow

if ($script:RebootRequired -and -not $DryRun) {
    Write-Host ""
    Write-Host '   A reboot is required to finish some installs (e.g. WSL 2 / Docker).' -ForegroundColor Yellow
    if ($Reboot) {
        Write-Host '   Rebooting in 15 seconds...' -ForegroundColor Yellow
        shutdown.exe /r /t 15 /c "Windows Silent Installer: finishing setup"
    } elseif (-not $Yes) {
        $ans = Read-Host '   Reboot now? [y/N]'
        if ($ans -match '^(y|yes)$') { Restart-Computer -Force }
    }
}

if ($Elevated) { Write-Host ""; Read-Host '  Press Enter to close' | Out-Null }
exit $(if ($failed.Count) { 1 } else { 0 })
