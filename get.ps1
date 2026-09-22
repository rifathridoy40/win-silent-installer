# Windows Silent Installer - web bootstrapper.
#
#   irm https://raw.githubusercontent.com/OWNER/win-silent-installer/main/get.ps1 | iex
#
# With arguments:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/win-silent-installer/main/get.ps1))) -Apps chrome,git,node -Yes
#
# Downloads the repository to %LOCALAPPDATA%\win-silent-installer and runs install.ps1 from there.
# It runs as a real file (not through iex), so self-elevation works and 'exit' can't close this window.
# Set $env:WSI_REPO / $env:WSI_BRANCH to install from a fork or another branch
# ($env:WSI_ZIP_URL to use any zip of this repo instead).

& {
    $repo   = if ($env:WSI_REPO)   { $env:WSI_REPO }   else { 'OWNER/win-silent-installer' }
    $branch = if ($env:WSI_BRANCH) { $env:WSI_BRANCH } else { 'main' }
    $home_  = Join-Path $env:LOCALAPPDATA 'win-silent-installer'
    $app    = Join-Path $home_ 'app'
    $zip    = Join-Path $env:TEMP 'win-silent-installer.zip'
    $zipUrl = if ($env:WSI_ZIP_URL) { $env:WSI_ZIP_URL } else { "https://github.com/$repo/archive/refs/heads/$branch.zip" }

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    # Windows PowerShell 5.1 on Windows 10 may not enable TLS 1.2 by default; GitHub requires it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Host "Downloading $repo ($branch)..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
        $tmp = Join-Path $env:TEMP ('wsi-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if (Test-Path $app) { Remove-Item -Path $app -Recurse -Force }
        New-Item -ItemType Directory -Path $home_ -Force | Out-Null
        Move-Item -Path $src.FullName -Destination $app
        Remove-Item -Path $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Re-quote the caller's arguments for a child process: arrays become "a,b,c", switches pass as-is.
    $passArgs = @(foreach ($a in $args) {
        if ($a -is [array]) { '"{0}"' -f ($a -join ',') }
        elseif ("$a" -match '^-\w+:?$') { "$a" }
        else { '"{0}"' -f $a }
    })
    if (-not ($passArgs -match '^-LogDir')) { $passArgs += @('-LogDir', ('"{0}"' -f (Join-Path $home_ 'logs'))) }

    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'install.ps1') @passArgs
} @args
