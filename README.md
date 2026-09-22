# Windows Silent Installer

Sets up a fresh Windows 10/11 machine from a single script. You pick apps in a full-screen, keyboard-driven
picker, or pass them on the command line. Everything installs silently (no installer windows, no clicking Next).

- **Interactive picker:** arrow keys, search, a details panel for each app, "installed" badges, version dialogs, and
  a review screen before anything is installed.
- Uses **winget** first. If winget is missing or too old (common on a fresh Windows 10), the script installs it.
- **Falls back** to the official installer, npm, or a vendor script when winget fails for an app.
- **Selectable versions** for Node.js, Python, the JDK (vendor too), XAMPP (PHP version) and IntelliJ IDEA (edition).
- **Skips** apps that are already installed. Use `-Force` to reinstall them.
- Fixes up the environment where installers don't: `JAVA_HOME`, the default Python on PATH, OpenSSL on PATH,
  WSL 2 for Docker, and adding you to the `docker-users` group.
- Writes a log for every run and saves your selection so you can replay it unattended.
- Runs on the built-in Windows PowerShell 5.1, so nothing needs to be installed first.

## Install with one command

Open **PowerShell** (Win+X, then Terminal or PowerShell. It doesn't need to be run as administrator) and paste:

```powershell
irm https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/get.ps1 | iex
```

Approve the UAC prompt, then pick your apps in the picker (see [Using the picker](#using-the-picker)).

To install without the picker, pass options to the same script:

```powershell
# the recommended set, no questions
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/get.ps1))) -Recommended -Yes

# a bundled profile, or your own profile hosted anywhere
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/get.ps1))) -Config full-dev -Yes
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/get.ps1))) -Config https://gist.githubusercontent.com/.../my-pc.json -Yes
```

From **cmd.exe** or the Run dialog (Win+R):

```bat
powershell -ExecutionPolicy Bypass -c "[Net.ServicePointManager]::SecurityProtocol=3072; irm https://raw.githubusercontent.com/rifathridoy40/win-silent-installer/main/get.ps1 | iex"
```

> On some fresh Windows 10 installs, the short command fails with *"Could not create SSL/TLS secure channel"*.
> Windows PowerShell 5.1 there doesn't use TLS 1.2 by default. Use the cmd.exe line above instead, which turns
> TLS 1.2 on first. It works from PowerShell too.

`get.ps1` downloads this repo to `%LOCALAPPDATA%\win-silent-installer\app` and runs `install.ps1` from there.
Logs and your saved selection are kept in `%LOCALAPPDATA%\win-silent-installer\logs`. To use a fork, set
`$env:WSI_REPO = 'you/your-fork'` (and optionally `$env:WSI_BRANCH`) before running.

## Run from a local copy

1. Clone the repo or copy this folder to the PC (for example, from a USB stick).
2. Double-click **`install.cmd`**, or run `.\install.cmd` from a terminal.

## Using the picker

```
  ♦ WINDOWS SILENT INSTALLER  v2.0.0                                  24 selected  ·  47 apps
  Choose the apps to install on this PC, then press Enter to review.
  ──────────────────────────────────────────────────────────────────────────────────────────
  LANGUAGES & RUNTIMES  3/5                          ┌─ Node.js ──────────────────────────┐
 ► ●  Node.js  LTS  ►                   √ v22.18.0   │ JavaScript runtime with npm. ...   │
   ●  Python  3.13  ►                                │ Source    winget  OpenJS.NodeJS    │
   ●  Java JDK  Eclipse Temurin 21  ►                │ Status    installed (v22.18.0)     │
   ○  Go                                             │ Version   LTS                      │
   ○  Rust (rustup)                                  │           press → to change        │
```

| Key | Action |
|---|---|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | Move |
| `Tab` / `Shift+Tab` | Jump to the next / previous category |
| `Space` | Select or unselect the app |
| `→` | Choose versions: Node.js, Python, Java JDK (and vendor), XAMPP (PHP), IntelliJ IDEA (edition) |
| `/` | Search by name, category or description. `Enter` keeps the filter, `Esc` clears it. |
| `A` / `N` / `R` | Select all apps in the list / clear the selection / restore the recommended set |
| `C` | Select or unselect the whole category |
| `Enter` | Open the review screen. There, `Enter` installs, `F` switches reinstalling on or off, and `Esc` goes back. |
| `Esc` / `Q` | Quit without installing |

In the version dialogs, `Space` selects a version, `D` makes it the default (the Python on PATH, or `JAVA_HOME`),
`←` `→` changes the JDK vendor, and `Enter` applies. Nothing is installed until you confirm on the review screen.

The picker uses symbols from the standard Windows console fonts. If they look wrong in your terminal, run
`$env:WSI_ASCII = 1` first to switch to plain ASCII.

## Unattended usage

```powershell
# Recommended set with default versions, no questions
.\install.cmd -Recommended -Yes

# Pick apps and versions
.\install.cmd -Apps chrome,vscode,git,node,python,jdk,docker -Node 22 -Python 3.12,3.13 -Jdk 21,17 -Yes

# From a profile file
.\install.cmd -Config profiles\full-dev.json -Yes

# See what would happen without installing anything
.\install.cmd -Recommended -DryRun

# List every app key
.\install.cmd -List
```

After each run, the selection is saved to `logs\last-selection.json`. To repeat the same setup on another PC, run
`.\install.cmd -Config logs\last-selection.json -Yes`.

## Options

| Option | Description |
|---|---|
| `-Apps a,b,c` | App keys to install (see `-List`). Aliases work too: `terminus`, `java`, `nodejs`, `1.1.1.1`, `platform-tools` ... |
| `-All` / `-Recommended` | The whole catalog / the pre-ticked set |
| `-Config` | A profile: a file path, a bundled profile name (`full-dev`, `minimal`), or an `https://` URL. Command-line options override its values. |
| `-Node` | `lts` (default), `latest`, a major like `22`, an exact version like `20.18.0`, `nvm`, or `nvm:22` |
| `-Python` | One or more versions: `3.13` (default), `3.12,3.13`, or an exact version like `3.12.8`. The **first** one goes on PATH. |
| `-Jdk` | One or more `[vendor:]major` values: `21` (default), `17,21`, `microsoft:21`. Vendors: `temurin` (default), `microsoft`, `zulu`, `corretto`, `oracle`. The **first** one becomes `JAVA_HOME`. |
| `-Xampp` | `8.2` (default) or `8.1` |
| `-IntelliJ` | `ultimate` (default; the unified IDE with a free tier) or `community` |
| `-Yes` | Skip all questions and use the defaults |
| `-Force` | Reinstall apps that are already installed |
| `-DryRun` | Show the plan only (does not need admin rights) |
| `-Reboot` | Reboot automatically at the end if an installer asked for it |
| `-ShowOutput` | Show installer output in the console (it always goes to the log) |
| `-LogDir path` | Where to write logs (default `.\logs`) |

## Catalog

Apps marked with ★ are recommended (ticked by default).

| Category | Apps |
|---|---|
| Browsers & communication | Chrome ★, Firefox, Brave, Zoom ★, Telegram, Discord, Slack |
| Editors & IDEs | VS Code ★, IntelliJ IDEA ★, JetBrains Toolbox ★, Notepad++, Cursor |
| AI coding CLIs | Claude Code ★, GitHub Copilot CLI ★, OpenCode ★, Gemini CLI, Codex CLI |
| Languages & runtimes | Node.js ★, Python ★, JDK ★, Go, Rust |
| Dev tools & databases | Git ★, GitHub CLI, Docker Desktop ★, XAMPP ★, pgAdmin 4 ★, DBeaver, Postman |
| Command-line tools | FFmpeg ★, OpenSSL ★, ADB platform-tools ★, yt-dlp, PowerShell 7 |
| Terminals & network | Tabby (formerly Terminus) ★, Termius, Windows Terminal, Cloudflare 1.1.1.1/WARP ★ |
| System utilities | PowerToys ★, 7-Zip, WinZip, WinZip Command Line add-on, Everything, ShareX |
| Media | VLC ★, qBittorrent ★, OBS Studio |

**Adding an app:** add one `App` line to the catalog in `install.ps1`. For example:

```powershell
App keepass 'KeePassXC' $cUtil KeePassXCTeam.KeePassXC
```

To find an app's winget ID, run `winget search <name>`.

## Notes

- **Terminus:** Terminus was renamed **Tabby**, so the `tabby` key (alias `terminus`) installs it. If you meant the
  Termius SSH client, select `termius` instead.
- **Docker:** on a PC without WSL, the script turns on WSL 2 first. Reboot afterward, then start Docker Desktop once.
- **Node versions:** Node.js is a single install. To keep several versions side by side, use `-Node nvm:22`, which
  installs NVM for Windows. After that, switch with `nvm install 20` and `nvm use 20`.
- **PATH:** open a new terminal after the run so the updated PATH, `JAVA_HOME` and other variables take effect.
- **Exit code:** the script exits with `0` if everything succeeded and `1` if any app failed. Check
  `logs\install-*.log` for installer output.
