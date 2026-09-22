#!/usr/bin/env bash
# Linux Silent Installer (Ubuntu/Debian) - unattended app setup for a fresh machine.
#
#   ./install.sh                      interactive picker
#   ./install.sh --recommended --yes  unattended
#   ./install.sh --list               show every app key
#
# Installs silently with apt, snap, flatpak, official vendor repos, .deb downloads, npm or
# vendor install scripts - whichever works first for each app.

set -uo pipefail
shopt -s extglob

WSI_VERSION="2.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${WSI_LOG_DIR:-$SCRIPT_DIR/logs}"
DL_DIR="${TMPDIR:-/tmp}/wsi-downloads"
APT_UPDATED=0
REBOOT_REQUIRED=0
RELOGIN_REQUIRED=0
declare -a RESULT_APP=() RESULT_STATUS=() RESULT_DETAIL=() TIPS=()
declare -A INSTALLED_DPKG INSTALLED_SNAP INSTALLED_FLATPAK STATUS_ON STATUS_TEXT
CUR_LABEL=""
SCAN_DONE=0

# options that the picker can change
OPT_NODE="" OPT_PYTHON="" OPT_JDK="" OPT_XAMPP="" OPT_INTELLIJ="" OPT_PYCHARM="" OPT_OFFICE=""
DEF_NODE="lts" DEF_PYTHON="3.13" DEF_JDK="temurin:21" DEF_XAMPP="8.2" DEF_INTELLIJ="ultimate"
DEF_PYCHARM="professional" DEF_OFFICE="libreoffice"

FORCE=0 DRY_RUN=0 ASSUME_YES=0 SHOW_OUTPUT=0 LIST_ONLY=0 WANT_REBOOT=0

# ============================================================================================
# Glyphs, colours
# ============================================================================================
if [[ -t 1 && -z "${WSI_ASCII:-}" ]]; then
    G_ON="●" G_OFF="○" G_PTR="►" G_OK="√" G_BAD="×" G_DOT="·" G_DIA="♦"
    G_H="─" G_V="│" G_TL="┌" G_TR="┐" G_BL="└" G_BR="┘"
    G_UP="↑" G_DN="↓" G_LEFT="←" G_RIGHT="→"
    SPIN=("●○○" "○●○" "○○●" "○●○")
else
    G_ON="*" G_OFF="o" G_PTR=">" G_OK="+" G_BAD="x" G_DOT="-" G_DIA="*"
    G_H="-" G_V="|" G_TL="+" G_TR="+" G_BL="+" G_BR="+"
    G_UP="^" G_DN="v" G_LEFT="<" G_RIGHT="->"
    SPIN=("|" "/" "-" "\\")
fi
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_DIM=$'\e[90m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_WHITE=$'\e[97m'; C_BOLD=$'\e[1m'
    C_BAR=$'\e[46;30m'; C_SEL=$'\e[100m'; C_CHIP=$'\e[47;30m'
else
    C_RESET="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE="" C_BOLD=""
    C_BAR="" C_SEL="" C_CHIP=""
fi

log()      { [[ -n "${LOG_FILE:-}" ]] && printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE"; return 0; }
info()     { printf '       %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; log "INFO  $*"; }
warn()     { printf '       %s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; log "WARN  $*"; }
fail_msg() { printf '  %s%s  %s%s\n' "$C_RED" "$G_BAD" "$*" "$C_RESET"; log "FAIL  $*"; }
step() { # step ok|warn|fail|skip "text" ["detail"]
    local g c
    case $1 in
        ok)   g="$G_OK"  c="$C_GREEN" ;;
        warn) g="!"      c="$C_YELLOW" ;;
        fail) g="$G_BAD" c="$C_RED" ;;
        *)    g="$G_OFF" c="$C_DIM" ;;
    esac
    printf '  %s%s%s  %s%s%s' "$c" "$g" "$C_RESET" "$C_WHITE" "$2" "$C_RESET"
    [[ -n "${3:-}" ]] && printf '  %s%s%s' "$C_DIM" "$3" "$C_RESET"
    printf '\n'
    log "STEP  [$1] $2 ${3:-}"
}
rule() { local w=${1:-72}; printf '  %s' "$C_DIM"; for ((i = 0; i < w; i++)); do printf '%s' "$G_H"; done; printf '%s\n' "$C_RESET"; }
heading() { printf '\n  %s%s%s\n' "$C_CYAN" "$1" "$C_RESET"; rule 72; }
banner() {
    printf '\n  %s%s%s %s%sLINUX SILENT INSTALLER%s  %sv%s%s\n' \
        "$C_CYAN" "$G_DIA" "$C_RESET" "$C_BOLD" "$C_WHITE" "$C_RESET" "$C_DIM" "$WSI_VERSION" "$C_RESET"
    printf '    %sSilent, unattended app setup for a fresh Ubuntu machine%s\n\n' "$C_DIM" "$C_RESET"
}
elapsed_str() { local s=$1; printf '%d:%02d' $((s / 60)) $((s % 60)); }

# ============================================================================================
# Catalog
# ============================================================================================
declare -a KEYS CATS
declare -A A_NAME A_CAT A_DESC A_REC A_METHODS A_CHECK A_SPECIAL A_TIP A_NEEDS A_ORDER ALIASES CAT_SEEN

app() { # app key|name|category|rec|methods|check|special|order|alias|tip|desc
    local key name cat rec methods check special order alias tip desc
    local IFS='|'
    read -r key name cat rec methods check special order alias tip desc <<<"$1"
    KEYS+=("$key")
    A_NAME[$key]="$name"; A_CAT[$key]="$cat"; A_REC[$key]="$rec"; A_METHODS[$key]="$methods"
    A_CHECK[$key]="$check"; A_SPECIAL[$key]="$special"; A_ORDER[$key]="${order:-50}"
    A_TIP[$key]="$tip"; A_DESC[$key]="$desc"
    ALIASES[$key]="$key"
    local a
    for a in ${alias//,/ }; do [[ -n $a ]] && ALIASES[$a]="$key"; done
    unset IFS
    if [[ -z ${CAT_SEEN[$cat]:-} ]]; then CAT_SEEN[$cat]=1; CATS+=("$cat"); fi
}

C_BROWSER="Browsers & Communication"
C_OFFICE="Office"
C_EDITOR="Editors & IDEs"
C_AI="AI Coding CLIs"
C_LANG="Languages & Runtimes"
C_DEV="Dev Tools & Databases"
C_CLI="Command-line Tools"
C_NET="Terminals & Network"
C_UTIL="System Utilities"
C_MEDIA="Media & Downloads"

app "chrome|Google Chrome|$C_BROWSER|1|deb:https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb|dpkg:google-chrome-stable|||google-chrome||Google's web browser, installed from Google's own .deb package."
app "firefox|Mozilla Firefox|$C_BROWSER|0|apt:firefox,snap:firefox|cmd:firefox||||Mozilla's open-source web browser."
app "brave|Brave Browser|$C_BROWSER|0|fn:install_brave|dpkg:brave-browser|||brave||Privacy-focused Chromium browser with a built-in ad blocker."
app "zoom|Zoom|$C_BROWSER|1|deb:https://zoom.us/client/latest/zoom_amd64.deb,snap:zoom-client|dpkg:zoom||||Video meetings and chat."
app "telegram|Telegram Desktop|$C_BROWSER|0|apt:telegram-desktop,snap:telegram-desktop|cmd:telegram-desktop||||Fast, cloud-based messenger."
app "discord|Discord|$C_BROWSER|0|deb:https://discord.com/api/download?platform=linux&format=deb,snap:discord|dpkg:discord||||Voice, video and text chat for communities."
app "slack|Slack|$C_BROWSER|0|snap:slack|snap:slack||||Team messaging and collaboration."

app "office|Office suite|$C_OFFICE|0||cmd:libreoffice|office|60||Open Word/Excel/PowerPoint files. LibreOffice comes from Ubuntu; OnlyOffice and WPS read Microsoft formats more faithfully.|Office suite for documents, spreadsheets and presentations. Microsoft Office itself has no native Linux version; pick LibreOffice, OnlyOffice or WPS Office."

app "vscode|Visual Studio Code|$C_EDITOR|1|fn:install_vscode,snap:code --classic|cmd:code|||code,vs-code||Microsoft's code editor, from Microsoft's own apt repository."
app "intellij|IntelliJ IDEA|$C_EDITOR|1||snap:intellij-idea-ultimate|intellij|50|idea||JetBrains IDE for Java and Kotlin, installed as a snap. Choose Ultimate or Community."
app "pycharm|PyCharm|$C_EDITOR|1||snap:pycharm-professional|pycharm|50|||JetBrains IDE for Python, installed as a snap. Choose Professional or Community."
app "phpstorm|PhpStorm|$C_EDITOR|1|snap:phpstorm --classic|snap:phpstorm|||php-storm||JetBrains IDE for PHP, Laravel and Symfony. Paid, with a 30-day trial."
app "toolbox|JetBrains Toolbox|$C_EDITOR|1|fn:install_toolbox|path:/opt/jetbrains-toolbox/jetbrains-toolbox|||jetbrains-toolbox|Run 'jetbrains-toolbox' once to finish setup.|Installs and updates every JetBrains IDE from one place."
app "sublime|Sublime Text|$C_EDITOR|0|fn:install_sublime,snap:sublime-text --classic|cmd:subl||||Fast, lightweight code editor."

app "claude|Claude Code|$C_AI|1|fn:install_claude,npm:@anthropic-ai/claude-code|cmd:claude||90|claude-code|Run 'claude' to sign in.|Anthropic's agentic coding tool for the terminal, from the official install script."
app "copilot|GitHub Copilot CLI|$C_AI|1|npm:@github/copilot|cmd:copilot||90|copilot-cli|Run 'copilot' and use /login to sign in.|GitHub Copilot as a coding agent in your terminal (npm, needs Node.js)."
app "opencode|OpenCode|$C_AI|1|fn:install_opencode,npm:opencode-ai|cmd:opencode||90|||Open-source AI coding agent for the terminal."
app "gemini|Gemini CLI|$C_AI|0|npm:@google/gemini-cli|cmd:gemini||90|||Google's Gemini coding agent for the terminal (npm, needs Node.js)."
app "codex|OpenAI Codex CLI|$C_AI|0|npm:@openai/codex|cmd:codex||90|||OpenAI's Codex coding agent for the terminal (npm, needs Node.js)."

app "node|Node.js|$C_LANG|1||cmd:node|node|10|nodejs||JavaScript runtime with npm, from NodeSource. Choose an LTS/current line, a major version, or nvm to switch versions later."
app "python|Python|$C_LANG|1||cmd:python3|python|10|py|Run a specific version with 'python3.13'.|Extra Python versions from the deadsnakes PPA, alongside the Python that Ubuntu ships."
app "jdk|Java JDK|$C_LANG|1||cmd:java|jdk|10|java,openjdk||Java Development Kit. Choose the vendor and versions; the default one sets JAVA_HOME."
app "go|Go|$C_LANG|0|apt:golang-go,snap:go --classic|cmd:go|||golang||The Go programming language toolchain."
app "rust|Rust (rustup)|$C_LANG|0|fn:install_rust|cmd:rustc|||rustup|Open a new terminal, or run: source \$HOME/.cargo/env|rustup installs and manages Rust toolchains (cargo, rustc)."

app "git|Git|$C_DEV|1|apt:git|cmd:git||5|||Distributed version control."
app "gh|GitHub CLI|$C_DEV|0|fn:install_gh,snap:gh|cmd:gh|||github-cli||Pull requests, issues and repos from the command line."
app "docker|Docker Engine|$C_DEV|1|fn:install_docker|cmd:docker|||docker-ce,docker-desktop|Log out and back in so your user can run docker without sudo.|Docker Engine, CLI, Buildx and Compose from Docker's official apt repository."
app "xampp|XAMPP|$C_DEV|0||path:/opt/lampp/lampp|xampp|60||Start it with: sudo /opt/lampp/lampp start|Apache, MariaDB, PHP and Perl in /opt/lampp, from the official installer."
app "lamp|Apache + MariaDB + PHP|$C_DEV|0|apt:apache2 mariadb-server php libapache2-mod-php php-mysql|dpkg:apache2|||||The distro LAMP stack, managed by apt and systemd (an alternative to XAMPP)."
app "pgadmin|pgAdmin 4|$C_DEV|1|fn:install_pgadmin|dpkg:pgadmin4-desktop|||pgadmin4||Management and query tool for PostgreSQL."
app "postgres|PostgreSQL server|$C_DEV|0|apt:postgresql postgresql-contrib|dpkg:postgresql|||postgresql||The PostgreSQL database server."
app "dbeaver|DBeaver|$C_DEV|0|snap:dbeaver-ce|snap:dbeaver-ce||||Universal database client for SQL and NoSQL databases."
app "postman|Postman|$C_DEV|0|snap:postman|snap:postman||||Build, test and document HTTP APIs."
app "buildessential|Build tools|$C_DEV|1|apt:build-essential pkg-config|dpkg:build-essential|||gcc,make||Compiler and build tools (gcc, g++, make) that many other tools need."

app "ffmpeg|FFmpeg|$C_CLI|1|apt:ffmpeg|cmd:ffmpeg||||Record, convert and stream audio and video from the command line."
app "openssl|OpenSSL|$C_CLI|1|apt:openssl|cmd:openssl||||OpenSSL command-line tool."
app "adb|Android Platform-Tools|$C_CLI|1|apt:adb fastboot|cmd:adb|||platform-tools||adb and fastboot for Android devices."
app "ytdlp|yt-dlp|$C_CLI|0|apt:yt-dlp,fn:install_ytdlp|cmd:yt-dlp|||yt-dlp||Download video and audio from YouTube and many other sites."
app "pwsh|PowerShell 7|$C_CLI|0|snap:powershell --classic|cmd:pwsh|||powershell||Cross-platform PowerShell."
app "cliutils|CLI essentials|$C_CLI|1|apt:curl wget jq ripgrep fzf htop tree unzip zip ca-certificates|cmd:jq|||jq,ripgrep||curl, wget, jq, ripgrep, fzf, htop, tree, zip/unzip - the usual terminal toolkit."
app "neovim|Neovim|$C_CLI|0|apt:neovim|cmd:nvim|||vim||Modern Vim-based terminal editor."
app "tmux|tmux|$C_CLI|0|apt:tmux|cmd:tmux||||Terminal multiplexer: split panes and keep sessions alive."
app "zsh|Zsh|$C_CLI|0|apt:zsh|cmd:zsh||||Zsh shell (set it as your default with: chsh -s \$(which zsh))."

app "tabby|Tabby (formerly Terminus)|$C_NET|0|fn:install_tabby|dpkg:tabby-terminal|||terminus||Modern terminal with SSH and serial support. Terminus was renamed Tabby."
app "termius|Termius|$C_NET|0|snap:termius-app|snap:termius-app||||SSH client with synced hosts and keys."
app "warp|Cloudflare WARP|$C_NET|0|fn:install_warp|cmd:warp-cli|||cloudflare,1.1.1.1|Connect with: warp-cli registration new && warp-cli connect|Cloudflare's 1.1.1.1 WARP client (command line on Linux)."
app "openssh|OpenSSH server|$C_NET|0|apt:openssh-server|dpkg:openssh-server|||ssh,sshd||Lets you SSH into this machine."
app "netutils|Network tools|$C_NET|0|apt:net-tools iputils-ping dnsutils traceroute nmap|cmd:nmap||||ping, dig, traceroute, nmap and friends."

app "7zip|7-Zip / archives|$C_UTIL|0|apt:p7zip-full p7zip-rar unrar|cmd:7z|||7z,winzip||Create and extract 7z, zip and rar archives."
app "flatpak|Flatpak + Flathub|$C_UTIL|0|fn:install_flatpak|cmd:flatpak||20|||Flatpak with the Flathub store enabled, for apps not in apt."
app "gnometweaks|GNOME Tweaks|$C_UTIL|0|apt:gnome-tweaks gnome-shell-extension-manager|cmd:gnome-tweaks|||tweaks||Extra desktop settings and a GNOME extensions manager."
app "timeshift|Timeshift|$C_UTIL|0|apt:timeshift|cmd:timeshift||||System snapshots and restore points."
app "flameshot|Flameshot|$C_UTIL|0|apt:flameshot|cmd:flameshot|||screenshot||Screenshot tool with annotation."
app "synaptic|GParted + Synaptic|$C_UTIL|0|apt:gparted synaptic|cmd:gparted|||gparted||Partition editor and a graphical package manager."

app "vlc|VLC media player|$C_MEDIA|1|apt:vlc,snap:vlc|cmd:vlc||||Plays almost any audio and video format."
app "qbittorrent|qBittorrent|$C_MEDIA|1|apt:qbittorrent|cmd:qbittorrent|||qbit||Open-source BitTorrent client with no ads."
app "obs|OBS Studio|$C_MEDIA|0|apt:obs-studio,snap:obs-studio|cmd:obs|||obs-studio||Screen recording and live streaming."
app "gimp|GIMP|$C_MEDIA|0|apt:gimp,snap:gimp|cmd:gimp||||Image editor."

# JDK vendors: key -> "apt package template|installer function|display name"
declare -A JDK_VENDORS=(
    [openjdk]="openjdk-%s-jdk||Ubuntu OpenJDK"
    [temurin]="temurin-%s-jdk|repo_temurin|Eclipse Temurin"
    [microsoft]="msopenjdk-%s|repo_microsoft|Microsoft OpenJDK"
    [corretto]="java-%s-amazon-corretto-jdk|repo_corretto|Amazon Corretto"
)
JDK_VENDOR_ORDER=(temurin openjdk microsoft corretto)

declare -A OFFICE_EDITIONS=(
    [libreoffice]="LibreOffice|from Ubuntu, open source"
    [onlyoffice]="OnlyOffice Desktop|best Microsoft format support"
    [wps]="WPS Office|Microsoft-like interface"
)
OFFICE_ORDER=(libreoffice onlyoffice wps)

# ============================================================================================
# Shell / package helpers
# ============================================================================================
need_sudo() {
    if [[ $EUID -eq 0 ]]; then SUDO=""; return 0; fi
    if ! command -v sudo >/dev/null; then fail_msg "sudo is required (or run this script as root)"; exit 1; fi
    SUDO="sudo"
    if ! sudo -n true 2>/dev/null; then
        printf '  %sAdministrator rights are needed to install packages.%s\n' "$C_YELLOW" "$C_RESET"
        sudo -v </dev/tty || { fail_msg "Could not get sudo rights"; exit 1; }
    fi
    # keep the sudo timestamp fresh while long installs run
    ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE=$!
}

run_logged() { # run a command, sending all output to the log
    log "RUN   $*"
    if [[ $SHOW_OUTPUT -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        return ${PIPESTATUS[0]}
    fi
    "$@" >>"$LOG_FILE" 2>&1
}

spin_run() { # spin_run "label" cmd...
    local label="$1"; shift
    if [[ ! -t 1 ]]; then run_logged "$@"; return $?; fi
    log "RUN   $*"
    ( "$@" >>"$LOG_FILE" 2>&1 ) &
    local pid=$! i=0 start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s  %s  %s%s  %s%s%s' "$C_CYAN" "${SPIN[$((i % ${#SPIN[@]}))]}" "$CUR_LABEL" \
            "$label" "$C_RESET" "$C_DIM" "$(elapsed_str $((SECONDS - start)))" "$C_RESET"
        printf '\e[K'
        i=$((i + 1))
        sleep 0.15
    done
    wait "$pid"
    local rc=$?
    printf '\r\e[K'
    log "EXIT  $rc"
    return $rc
}

apt_update_once() {
    [[ $APT_UPDATED -eq 1 ]] && return 0
    spin_run "apt update" $SUDO apt-get update -qq
    APT_UPDATED=1
}

apt_install() {
    apt_update_once
    spin_run "apt install $*" env DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

snap_install() { # snap_install name [flags...]
    if ! command -v snap >/dev/null; then warn "snap is not available"; return 1; fi
    local name="$1"; shift
    spin_run "snap install $name" $SUDO snap install "$name" "$@"
}

flatpak_install() {
    command -v flatpak >/dev/null || install_flatpak || return 1
    spin_run "flatpak install $1" $SUDO flatpak install -y --noninteractive flathub "$1"
}

download() { # download url [filename] -> path on stdout
    mkdir -p "$DL_DIR"
    local url="$1" name="${2:-}"
    [[ -z $name ]] && name="$(basename "${url%%\?*}")"
    local dest="$DL_DIR/$name"
    spin_run "downloading $name" curl -fsSL --retry 3 -o "$dest" "$url" || return 1
    [[ -s $dest ]]
}

deb_install() { # deb_install url
    local name="wsi-$(date +%s).deb"
    download "$1" "$name" || return 1
    apt_update_once
    spin_run "installing $(basename "$1")" env DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$DL_DIR/$name"
}

npm_install() {
    if ! command -v npm >/dev/null; then warn "npm not found - install Node.js first"; return 1; fi
    spin_run "npm -g $1" $SUDO env PATH="$PATH" npm install -g --silent "$1"
}

add_apt_repo() { # add_apt_repo name keyring_url repo_line
    local name="$1" key_url="$2" line="$3"
    $SUDO install -m 0755 -d /etc/apt/keyrings
    spin_run "adding the $name repository" bash -c "curl -fsSL '$key_url' | gpg --dearmor | $SUDO tee /etc/apt/keyrings/$name.gpg >/dev/null" || return 1
    $SUDO chmod a+r "/etc/apt/keyrings/$name.gpg"
    echo "$line" | $SUDO tee "/etc/apt/sources.list.d/$name.list" >/dev/null
    APT_UPDATED=0
    apt_update_once
}

arch_deb() { dpkg --print-architecture; }
ubuntu_codename() { ( . /etc/os-release 2>/dev/null; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}" ); }
os_field() { ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }

# ============================================================================================
# App installer functions
# ============================================================================================
install_vscode() {
    add_apt_repo microsoft-vscode https://packages.microsoft.com/keys/microsoft.asc \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/microsoft-vscode.gpg] https://packages.microsoft.com/repos/code stable main" || return 1
    apt_install code
}

install_brave() {
    add_apt_repo brave-browser https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/brave-browser.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" || return 1
    apt_install brave-browser
}

install_gh() {
    add_apt_repo githubcli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" || return 1
    apt_install gh
}

install_docker() {
    apt_install ca-certificates curl
    add_apt_repo docker https://download.docker.com/linux/ubuntu/gpg \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(ubuntu_codename) stable" || return 1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    $SUDO groupadd -f docker
    $SUDO usermod -aG docker "${SUDO_USER:-$USER}"
    RELOGIN_REQUIRED=1
    return 0
}

install_pgadmin() {
    add_apt_repo pgadmin https://www.pgadmin.org/static/packages_pgadmin_org.pub \
        "deb [signed-by=/etc/apt/keyrings/pgadmin.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(ubuntu_codename) pgadmin4 main" || return 1
    apt_install pgadmin4-desktop
}

install_warp() {
    add_apt_repo cloudflare-warp https://pkg.cloudflareclient.com/pubkey.gpg \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/cloudflare-warp.gpg] https://pkg.cloudflareclient.com/ $(ubuntu_codename) main" || return 1
    apt_install cloudflare-warp
}

install_sublime() {
    add_apt_repo sublimehq https://download.sublimetext.com/sublimehq-pub.gpg \
        "deb https://download.sublimetext.com/ apt/stable/" || return 1
    apt_install sublime-text
}

install_flatpak() {
    apt_install flatpak gnome-software-plugin-flatpak || apt_install flatpak || return 1
    spin_run "adding Flathub" $SUDO flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
}

install_tabby() {
    local url
    url=$(curl -fsSL https://api.github.com/repos/Eugeny/tabby/releases/latest |
        grep -o 'https://[^"]*linux-x64\.deb' | head -1)
    [[ -z $url ]] && { warn "Could not find the latest Tabby .deb"; return 1; }
    deb_install "$url"
}

install_toolbox() {
    local url tmp
    url=$(curl -fsSL 'https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release' |
        grep -o 'https://[^"]*jetbrains-toolbox-[^"]*\.tar\.gz' | head -1)
    [[ -z $url ]] && { warn "Could not find the JetBrains Toolbox download"; return 1; }
    download "$url" jetbrains-toolbox.tar.gz || return 1
    tmp=$(mktemp -d)
    tar -xzf "$DL_DIR/jetbrains-toolbox.tar.gz" -C "$tmp" || return 1
    $SUDO rm -rf /opt/jetbrains-toolbox
    $SUDO mv "$tmp"/jetbrains-toolbox-* /opt/jetbrains-toolbox || return 1
    $SUDO ln -sf /opt/jetbrains-toolbox/jetbrains-toolbox /usr/local/bin/jetbrains-toolbox
    rm -rf "$tmp"
    return 0
}

install_claude() {
    spin_run "claude.ai/install.sh" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' || return 1
    export PATH="$HOME/.local/bin:$PATH"
    command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]
}

install_opencode() {
    spin_run "opencode.ai/install" bash -c 'curl -fsSL https://opencode.ai/install | bash' || return 1
    export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
    command -v opencode >/dev/null || [[ -x "$HOME/.opencode/bin/opencode" ]]
}

install_rust() {
    spin_run "rustup" bash -c "curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path" || return 1
    [[ -x "$HOME/.cargo/bin/rustc" ]] || return 1
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' >>"$HOME/.profile"
    return 0
}

install_ytdlp() {
    $SUDO curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp &&
        $SUDO chmod a+rx /usr/local/bin/yt-dlp
}

# ---- versioned installers ------------------------------------------------------------------
install_node() { # install_node <spec>
    local spec="${1:-lts}"
    case $spec in
        nvm*)
            local ver="${spec#nvm}"; ver="${ver#:}"; ver="${ver:-lts/*}"
            spin_run "nvm" bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash' || return 1
            spin_run "nvm install $ver" bash -c "export NVM_DIR=\"\$HOME/.nvm\"; . \"\$NVM_DIR/nvm.sh\"; nvm install '$ver' && nvm alias default '$ver'" || return 1
            TIPS+=("Node.js: open a new terminal, then switch versions with 'nvm use <version>'.")
            return 0
            ;;
        lts)     local setup="setup_lts.x" ;;
        latest|current) local setup="setup_current.x" ;;
        *)       local setup="setup_${spec%%.*}.x" ;;
    esac
    apt_install ca-certificates curl gnupg
    spin_run "NodeSource $spec" bash -c "curl -fsSL https://deb.nodesource.com/$setup | $SUDO -E bash -" || return 1
    APT_UPDATED=0
    apt_install nodejs
}

install_python() { # install_python <3.x> <primary 0|1>
    local ver="$1" primary="${2:-0}"
    local have=""
    command -v "python$ver" >/dev/null && have=1
    if [[ -z $have ]]; then
        # deadsnakes carries versions Ubuntu does not ship
        if ! apt_install "python$ver" "python$ver-venv"; then
            apt_install software-properties-common || return 1
            spin_run "adding the deadsnakes PPA" $SUDO add-apt-repository -y ppa:deadsnakes/ppa || return 1
            APT_UPDATED=0
            apt_install "python$ver" "python$ver-venv" "python$ver-dev" || return 1
        fi
    fi
    apt_install python3-pip >/dev/null 2>&1
    if [[ $primary -eq 1 ]]; then
        TIPS+=("Python: run this version with 'python$ver' (the system 'python3' is left alone on purpose).")
    fi
    return 0
}

install_jdk() { # install_jdk <vendor> <major> <primary>
    local vendor="$1" major="$2" primary="${3:-0}"
    local spec="${JDK_VENDORS[$vendor]}"
    local pkg_tpl="${spec%%|*}" rest="${spec#*|}"
    local repo_fn="${rest%%|*}"
    local pkg
    # shellcheck disable=SC2059
    pkg=$(printf "$pkg_tpl" "$major")
    if [[ -n $repo_fn ]]; then "$repo_fn" || return 1; fi
    apt_install "$pkg" || return 1
    if [[ $primary -eq 1 ]]; then
        local home
        home=$(find_java_home "$major") || true
        if [[ -n $home ]]; then
            echo "export JAVA_HOME=$home" | $SUDO tee /etc/profile.d/java-home.sh >/dev/null
            $SUDO chmod 0644 /etc/profile.d/java-home.sh
            export JAVA_HOME="$home"
            info "JAVA_HOME=$home (set for new shells in /etc/profile.d/java-home.sh)"
            [[ -x "$home/bin/java" ]] && $SUDO update-alternatives --set java "$home/bin/java" >>"$LOG_FILE" 2>&1
        fi
    fi
    return 0
}

repo_temurin() {
    add_apt_repo adoptium https://packages.adoptium.net/artifactory/api/gpg/key/public \
        "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(ubuntu_codename) main"
}
repo_microsoft() {
    add_apt_repo microsoft-prod https://packages.microsoft.com/keys/microsoft.asc \
        "deb [arch=$(arch_deb) signed-by=/etc/apt/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/$(os_field VERSION_ID)/prod $(ubuntu_codename) main"
}
repo_corretto() {
    add_apt_repo corretto https://apt.corretto.aws/corretto.key \
        "deb [signed-by=/etc/apt/keyrings/corretto.gpg] https://apt.corretto.aws stable main"
}

find_java_home() {
    local major="$1" d
    for d in /usr/lib/jvm/*"$major"*; do
        [[ -x "$d/bin/java" ]] && { echo "$d"; return 0; }
    done
    return 1
}

install_xampp() { # install_xampp <php version>
    local phpver="$1" url ver
    case $phpver in
        8.2) ver="8.2.12-0" ;;
        8.1) ver="8.1.25-0" ;;
        *)   ver="8.2.12-0" ;;
    esac
    url="https://sourceforge.net/projects/xampp/files/XAMPP%20Linux/${ver%-*}/xampp-linux-x64-${ver}-installer.run/download"
    download "$url" "xampp-installer.run" || return 1
    chmod +x "$DL_DIR/xampp-installer.run"
    spin_run "XAMPP installer" $SUDO "$DL_DIR/xampp-installer.run" --mode unattended
}

install_office() { # install_office <edition>
    case $1 in
        libreoffice) apt_install libreoffice ;;
        onlyoffice)
            deb_install "https://download.onlyoffice.com/install/desktop/editors/linux/onlyoffice-desktopeditors_amd64.deb" ||
                snap_install onlyoffice-desktopeditors ;;
        wps) deb_install "https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffice/download/linux/11719/wps-office_11.1.0.11719.XA_amd64.deb" ;;
        *) return 1 ;;
    esac
}

install_ide_snap() { # install_ide_snap <snap name>
    snap_install "$1" --classic
}

# ============================================================================================
# Installed-app scan
# ============================================================================================
scan_installed() {
    CUR_LABEL="Scanning installed apps"
    local tmp
    tmp=$(mktemp)
    if command -v dpkg-query >/dev/null; then
        dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | awk '$4 == "installed" {print $1}' >"$tmp"
        while read -r p; do [[ -n $p ]] && INSTALLED_DPKG[$p]=1; done <"$tmp"
    fi
    if command -v snap >/dev/null; then
        snap list 2>/dev/null | tail -n +2 | awk '{print $1}' >"$tmp"
        while read -r p; do [[ -n $p ]] && INSTALLED_SNAP[$p]=1; done <"$tmp"
    fi
    if command -v flatpak >/dev/null; then
        flatpak list --app --columns=application 2>/dev/null >"$tmp"
        while read -r p; do [[ -n $p ]] && INSTALLED_FLATPAK[$p]=1; done <"$tmp"
    fi
    rm -f "$tmp"
    SCAN_DONE=1
    local key n=0
    for key in "${KEYS[@]}"; do
        if app_installed "$key"; then STATUS_ON[$key]=1; n=$((n + 1)); else STATUS_ON[$key]=0; fi
    done
    CUR_LABEL=""
    step ok "Scanned installed apps" "$n of ${#KEYS[@]} catalog apps already installed"
}

check_spec_met() { # check_spec_met "cmd:x" / "dpkg:x" / "snap:x" / "flatpak:x" / "path:/x"
    local spec="$1"
    [[ -z $spec ]] && return 1
    case ${spec%%:*} in
        cmd)     command -v "${spec#*:}" >/dev/null ;;
        dpkg)    [[ -n ${INSTALLED_DPKG[${spec#*:}]:-} ]] || dpkg -s "${spec#*:}" >/dev/null 2>&1 ;;
        snap)    [[ -n ${INSTALLED_SNAP[${spec#*:}]:-} ]] ;;
        flatpak) [[ -n ${INSTALLED_FLATPAK[${spec#*:}]:-} ]] ;;
        path)    [[ -e ${spec#*:} ]] ;;
        *)       return 1 ;;
    esac
}

app_installed() { # per-app "is it already here" check
    local key="$1"
    case ${A_SPECIAL[$key]} in
        python) python_versions_installed | grep -q . ;;
        jdk)    command -v java >/dev/null ;;
        *)      check_spec_met "${A_CHECK[$key]}" ;;
    esac
}

python_versions_installed() {
    local d
    for d in /usr/bin/python3.[0-9]*; do
        [[ -x $d ]] || continue
        [[ $d == *-config ]] && continue
        basename "$d" | sed 's/^python//'
    done | sort -Vr | uniq
}

jdk_versions_installed() {
    local d
    for d in /usr/lib/jvm/*/bin/java; do
        [[ -x $d ]] || continue
        d=${d%/bin/java}
        basename "$d" | grep -o '[0-9][0-9]*' | head -1
    done | sort -nr | uniq
}

# ============================================================================================
# Plan / install
# ============================================================================================
plan_state() { # plan_state <key> -> "install" | "skip - installed" | "reinstall" | "install X"
    local key="$1"
    if [[ $FORCE -eq 1 ]]; then
        [[ ${STATUS_ON[$key]:-0} -eq 1 ]] && { echo "reinstall"; return; }
        echo "install"; return
    fi
    case ${A_SPECIAL[$key]} in
        python)
            local have new=() v
            have=$(python_versions_installed | tr '\n' ' ')
            for v in ${OPT_PYTHON//,/ }; do [[ " $have " == *" $v "* ]] || new+=("$v"); done
            [[ ${#new[@]} -eq 0 ]] && { echo "skip - installed"; return; }
            echo "install ${new[*]}"; return ;;
        jdk)
            local have new=() spec major
            have=$(jdk_versions_installed | tr '\n' ' ')
            for spec in ${OPT_JDK//,/ }; do
                major="${spec##*:}"
                [[ " $have " == *" $major "* ]] || new+=("$major")
            done
            [[ ${#new[@]} -eq 0 ]] && { echo "skip - installed"; return; }
            echo "install ${new[*]}"; return ;;
        node)
            [[ ${STATUS_ON[$key]:-0} -eq 1 ]] && { echo "skip - installed"; return; }
            echo "install"; return ;;
    esac
    [[ ${STATUS_ON[$key]:-0} -eq 1 ]] && { echo "skip - installed"; return; }
    echo "install"
}

option_summary() { # option_summary <key>
    local key="$1"
    case ${A_SPECIAL[$key]} in
        node)
            case $OPT_NODE in
                lts) echo "LTS" ;;
                latest|current) echo "Latest" ;;
                nvm) echo "nvm + LTS" ;;
                nvm:*) echo "nvm + ${OPT_NODE#nvm:}" ;;
                *) echo "v$OPT_NODE" ;;
            esac ;;
        python) echo "${OPT_PYTHON//,/, }" ;;
        jdk)
            local spec vendor major out="" majors="" one_vendor="" mixed=0
            for spec in ${OPT_JDK//,/ }; do
                if [[ $spec == *:* ]]; then vendor="${spec%%:*}"; major="${spec##*:}"; else vendor="temurin"; major="$spec"; fi
                [[ -z $one_vendor ]] && one_vendor="$vendor"
                [[ $vendor != "$one_vendor" ]] && mixed=1
                majors="${majors:+$majors, }$major"
                out="${out:+$out, }${JDK_VENDORS[$vendor]##*|} $major"
            done
            if [[ $mixed -eq 1 ]]; then echo "$out"; else echo "${JDK_VENDORS[$one_vendor]##*|} $majors"; fi ;;
        xampp) echo "PHP $OPT_XAMPP" ;;
        intellij) echo "${OPT_INTELLIJ^}" ;;
        pycharm) echo "${OPT_PYCHARM^}" ;;
        office) echo "${OFFICE_EDITIONS[$OPT_OFFICE]%%|*}" ;;
        *) echo "" ;;
    esac
}

# Task list: each entry is "key<TAB>display name<TAB>order<TAB>runner"
declare -a TASK_NAME TASK_RUN TASK_KEY TASK_ORDER

add_task() { TASK_KEY+=("$1"); TASK_NAME+=("$2"); TASK_ORDER+=("$3"); TASK_RUN+=("$4"); }

build_tasks() {
    TASK_KEY=() TASK_NAME=() TASK_ORDER=() TASK_RUN=()
    local key v i vendor major primary
    for key in "${SELECTED[@]}"; do
        case ${A_SPECIAL[$key]} in
            node)
                local nname
                case $OPT_NODE in
                    lts) nname="Node.js LTS" ;;
                    latest|current) nname="Node.js (current)" ;;
                    nvm|nvm:*) local nv="${OPT_NODE#nvm}"; nv="${nv#:}"; nname="nvm + Node.js ${nv:-LTS}" ;;
                    *) nname="Node.js $OPT_NODE" ;;
                esac
                add_task node "$nname" 10 "install_node '$OPT_NODE'" ;;
            python)
                i=0
                for v in ${OPT_PYTHON//,/ }; do
                    primary=$([[ $i -eq 0 ]] && echo 1 || echo 0)
                    add_task python "Python $v$([[ $i -eq 0 ]] && echo ' (default)')" 10 "install_python '$v' $primary"
                    i=$((i + 1))
                done ;;
            jdk)
                i=0
                for v in ${OPT_JDK//,/ }; do
                    if [[ $v == *:* ]]; then vendor="${v%%:*}"; major="${v##*:}"; else vendor="temurin"; major="$v"; fi
                    primary=$([[ $i -eq 0 ]] && echo 1 || echo 0)
                    local vn="${JDK_VENDORS[$vendor]##*|}"
                    add_task jdk "$vn $major$([[ $i -eq 0 ]] && echo ' (JAVA_HOME)')" 10 "install_jdk '$vendor' '$major' $primary"
                    i=$((i + 1))
                done ;;
            xampp)   add_task xampp "XAMPP (PHP $OPT_XAMPP)" 60 "install_xampp '$OPT_XAMPP'" ;;
            office)  add_task office "${OFFICE_EDITIONS[$OPT_OFFICE]%%|*}" 60 "install_office '$OPT_OFFICE'" ;;
            intellij)
                local snapname="intellij-idea-ultimate"
                [[ $OPT_INTELLIJ == community ]] && snapname="intellij-idea-community"
                add_task intellij "IntelliJ IDEA ${OPT_INTELLIJ^}" 50 "install_ide_snap $snapname" ;;
            pycharm)
                local psnap="pycharm-professional"
                [[ $OPT_PYCHARM == community ]] && psnap="pycharm-community"
                add_task pycharm "PyCharm ${OPT_PYCHARM^}" 50 "install_ide_snap $psnap" ;;
            *)
                add_task "$key" "${A_NAME[$key]}" "${A_ORDER[$key]}" "run_methods '$key'" ;;
        esac
    done
}

run_methods() { # try each method for an app until one works
    local key="$1"
    local methods="${A_METHODS[$key]}" m rc=1 label next
    local IFS=','
    read -ra mlist <<<"$methods"
    unset IFS
    local i
    for i in "${!mlist[@]}"; do
        m="${mlist[$i]}"
        [[ -z $m ]] && continue
        label=$(method_label "$m")
        case ${m%%:*} in
            apt)     apt_install ${m#*:} ;;
            snap)    snap_install ${m#*:} ;;
            flatpak) flatpak_install "${m#*:}" ;;
            deb)     deb_install "${m#*:}" ;;
            npm)     npm_install "${m#*:}" ;;
            fn)      "${m#*:}" ;;
            *)       false ;;
        esac
        rc=$?
        if [[ $rc -eq 0 ]]; then LAST_METHOD="$label"; return 0; fi
        next=""
        [[ $((i + 1)) -lt ${#mlist[@]} ]] && next=" - trying $(method_label "${mlist[$((i + 1))]}")"
        warn "$label failed$next"
    done
    return 1
}

method_label() {
    case ${1%%:*} in
        apt)     echo "apt" ;;
        snap)    echo "snap" ;;
        flatpak) echo "flatpak" ;;
        deb)     echo "direct .deb" ;;
        npm)     echo "npm" ;;
        fn)      case "${1#*:}" in
                     install_vscode) echo "Microsoft apt repo" ;;
                     install_docker) echo "Docker apt repo" ;;
                     install_brave) echo "Brave apt repo" ;;
                     install_gh) echo "GitHub apt repo" ;;
                     install_pgadmin) echo "pgAdmin apt repo" ;;
                     install_warp) echo "Cloudflare apt repo" ;;
                     install_sublime) echo "Sublime apt repo" ;;
                     install_claude) echo "official script" ;;
                     install_opencode) echo "official script" ;;
                     install_rust) echo "rustup" ;;
                     *) echo "official installer" ;;
                 esac ;;
        *) echo "$1" ;;
    esac
}

result_line() { # result_line glyph colour name detail time
    printf '  %s%s%s  %s%-38s%s %s%-30s%s%s%6s%s\n' \
        "$3" "$1" "$C_RESET" "$C_WHITE" "${4:0:38}" "$C_RESET" "$C_DIM" "${5:0:30}" "$C_RESET" "$C_DIM" "${6:-}" "$C_RESET"
}

run_tasks() {
    local total=${#TASK_KEY[@]} i n=0 start rc
    for i in $(order_tasks); do
        n=$((n + 1))
        local key name runner
        key="${TASK_KEY[$i]}"; name="${TASK_NAME[$i]}"; runner="${TASK_RUN[$i]}"
        CUR_LABEL="[$n/$total] $name"
        log "---- $CUR_LABEL"
        start=$SECONDS
        if [[ $FORCE -eq 0 ]] && task_installed "$i"; then
            result_line "$G_OFF" "" "$C_DIM" "$name" "already installed" ""
            RESULT_APP+=("$name"); RESULT_STATUS+=("Skipped"); RESULT_DETAIL+=("already installed")
            continue
        fi
        if [[ $DRY_RUN -eq 1 ]]; then
            result_line "$G_DIA" "" "$C_CYAN" "$name" "would use $(task_method_label "$i")" ""
            RESULT_APP+=("$name"); RESULT_STATUS+=("DryRun"); RESULT_DETAIL+=("$(task_method_label "$i")")
            continue
        fi
        LAST_METHOD=""
        eval "$runner"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            [[ -n ${A_TIP[$key]:-} ]] && TIPS+=("${A_NAME[$key]}: ${A_TIP[$key]}")
            result_line "$G_OK" "" "$C_GREEN" "$name" "installed${LAST_METHOD:+ via $LAST_METHOD}" "$(elapsed_str $((SECONDS - start)))"
            RESULT_APP+=("$name"); RESULT_STATUS+=("Installed"); RESULT_DETAIL+=("${LAST_METHOD:-ok}")
        else
            result_line "$G_BAD" "" "$C_RED" "$name" "failed (see log)" "$(elapsed_str $((SECONDS - start)))"
            RESULT_APP+=("$name"); RESULT_STATUS+=("Failed"); RESULT_DETAIL+=("all install methods failed")
        fi
    done
    CUR_LABEL=""
}

order_tasks() { # print task indexes sorted by order then position
    local i
    for i in "${!TASK_KEY[@]}"; do printf '%s %s\n' "${TASK_ORDER[$i]}" "$i"; done |
        sort -n -k1,1 -k2,2 | awk '{print $2}'
}

task_installed() {
    local i="$1"
    local key="${TASK_KEY[$i]}" name="${TASK_NAME[$i]}"
    case $key in
        python)
            local v="${name#Python }"; v="${v%% *}"
            python_versions_installed | grep -qx "$v" ;;
        jdk)
            local major
            major=$(echo "$name" | grep -o '[0-9][0-9]*' | head -1)
            jdk_versions_installed | grep -qx "$major" ;;
        node)   [[ $OPT_NODE == nvm* ]] && { command -v nvm >/dev/null || [[ -s "$HOME/.nvm/nvm.sh" ]]; return; }
                command -v node >/dev/null ;;
        *)      app_installed "$key" ;;
    esac
}

task_method_label() {
    local i="$1"
    local key="${TASK_KEY[$i]}"
    case $key in
        node)     [[ $OPT_NODE == nvm* ]] && echo "nvm" || echo "NodeSource apt repo" ;;
        python)   echo "apt / deadsnakes" ;;
        jdk)      echo "apt" ;;
        xampp)    echo "official installer" ;;
        office)   echo "apt / direct .deb" ;;
        intellij|pycharm) echo "snap" ;;
        *)        method_label "${A_METHODS[$key]%%,*}" ;;
    esac
}

print_summary() {
    local ok=0 skip=0 dry=0 failed=0 i
    for i in "${!RESULT_STATUS[@]}"; do
        case ${RESULT_STATUS[$i]} in
            Installed) ok=$((ok + 1)) ;;
            Skipped)   skip=$((skip + 1)) ;;
            DryRun)    dry=$((dry + 1)) ;;
            Failed)    failed=$((failed + 1)) ;;
        esac
    done
    rule 72
    printf '  %s%s %d installed%s    %s%s %d skipped%s' "$C_GREEN" "$G_OK" "$ok" "$C_RESET" "$C_DIM" "$G_OFF" "$skip" "$C_RESET"
    [[ $dry -gt 0 ]] && printf '    %s%s %d would install%s' "$C_CYAN" "$G_DIA" "$dry" "$C_RESET"
    local fc="$C_DIM"; [[ $failed -gt 0 ]] && fc="$C_RED"
    printf '    %s%s %d failed%s' "$fc" "$G_BAD" "$failed" "$C_RESET"
    printf '    %stook %s%s\n' "$C_DIM" "$(elapsed_str $((SECONDS - RUN_START)))" "$C_RESET"
    if [[ $failed -gt 0 ]]; then
        printf '\n  %sFailed:%s\n' "$C_RED" "$C_RESET"
        for i in "${!RESULT_STATUS[@]}"; do
            [[ ${RESULT_STATUS[$i]} == Failed ]] && printf '   %s%s %s%s  %s%s%s\n' \
                "$C_RED" "$G_BAD" "${RESULT_APP[$i]}" "$C_RESET" "$C_DIM" "${RESULT_DETAIL[$i]}" "$C_RESET"
        done
    fi
    if [[ ${#TIPS[@]} -gt 0 ]]; then
        printf '\n  %sNext steps:%s\n' "$C_CYAN" "$C_RESET"
        local t
        for t in "${TIPS[@]}"; do printf '   %s %s\n' "$G_RIGHT_SAFE" "$t"; done
    fi
    printf '\n  %sLog     %s%s\n' "$C_DIM" "$C_RESET" "$LOG_FILE"
    printf '  %sReplay  %s%s --config %s --yes\n' "$C_DIM" "$C_RESET" "$SCRIPT_DIR/install.sh" "$LOG_DIR/last-selection.json"
    [[ $ok -gt 0 ]] && printf '  %sOpen a new terminal so PATH changes take effect.%s\n' "$C_YELLOW" "$C_RESET"
    if [[ $RELOGIN_REQUIRED -eq 1 ]]; then
        printf '  %sLog out and back in for group changes (docker) to apply.%s\n' "$C_YELLOW" "$C_RESET"
    fi
    return $((failed > 0))
}

# ============================================================================================
# Interactive picker
# ============================================================================================
FRAME="" PLAIN=""
frame_reset() { FRAME="" PLAIN=""; }
fput() { FRAME+="$1"; PLAIN+="$2"; }                       # coloured text, plain text
fline() { FRAME+=$'\e[K\n'; PLAIN+=$'\n'; }                 # end of line
fshow() {
    printf '\e[H%s' "$FRAME"
    printf '\e[J'
    if [[ -n ${WSI_TEST_DUMP:-} ]]; then printf '%s\n%s\n' "$PLAIN" "========================================" >>"$WSI_TEST_DUMP"; fi
}

pad() { # pad <width> <text>  (truncates and pads to a visible width)
    local w="$1" t="$2"
    ((${#t} > w)) && t="${t:0:w}"
    printf '%-*s' "$w" "$t"
}
repeat() { local n="$1" c="$2" out="" i; for ((i = 0; i < n; i++)); do out+="$c"; done; printf '%s' "$out"; }

term_size() {
    COLS=${WSI_COLS:-$(tput cols 2>/dev/null || echo 100)}
    ROWS=${WSI_ROWS:-$(tput lines 2>/dev/null || echo 30)}
}

KEY=""
read_key() {
    if [[ -n ${TEST_KEYS:-} ]]; then
        if [[ $TEST_IDX -ge ${#TEST_KEY_ARR[@]} ]]; then KEY="QUIT"; return; fi
        local t="${TEST_KEY_ARR[$TEST_IDX]}"
        TEST_IDX=$((TEST_IDX + 1))
        case $t in
            DUMP) fshow; read_key; return ;;
            UP|DOWN|LEFT|RIGHT|ENTER|SPACE|ESC|TAB|BACKSPACE|PGUP|PGDN|HOME|END|QUIT) KEY="$t" ;;
            *) KEY="CHAR:$t" ;;
        esac
        LAST_KEY="$KEY"
        return
    fi
    local k rest
    IFS= read -rsn1 k </dev/tty || { KEY=QUIT; return; }
    case $k in
        $'\e')
            IFS= read -rsn2 -t 0.1 rest </dev/tty
            case $rest in
                '[A') KEY=UP ;; '[B') KEY=DOWN ;; '[C') KEY=RIGHT ;; '[D') KEY=LEFT ;;
                '[H'|'OH') KEY=HOME ;; '[F'|'OF') KEY=END ;;
                '[5') IFS= read -rsn1 -t 0.1 _ </dev/tty; KEY=PGUP ;;
                '[6') IFS= read -rsn1 -t 0.1 _ </dev/tty; KEY=PGDN ;;
                '') KEY=ESC ;;
                *) KEY=OTHER ;;
            esac ;;
        '') KEY=ENTER ;;
        ' ') KEY=SPACE ;;
        $'\t') KEY=TAB ;;
        $'\x7f'|$'\b') KEY=BACKSPACE ;;
        *) KEY="CHAR:$k" ;;
    esac
    LAST_KEY="$KEY"
}

declare -A SEL
declare -a ROW_KIND ROW_KEY ROW_CAT
CURSOR=0 SCROLL=0 FILTER="" SEARCH_MODE=0 MSG=""

build_rows() {
    ROW_KIND=() ROW_KEY=() ROW_CAT=()
    local cat key hay
    for cat in "${CATS[@]}"; do
        local any=0
        for key in "${KEYS[@]}"; do
            [[ ${A_CAT[$key]} == "$cat" ]] || continue
            if [[ -n $FILTER ]]; then
                hay="${A_NAME[$key]} $key ${A_CAT[$key]} ${A_DESC[$key]}"
                [[ ${hay,,} == *"${FILTER,,}"* ]] || continue
            fi
            if [[ $any -eq 0 ]]; then
                ROW_KIND+=("cat"); ROW_KEY+=(""); ROW_CAT+=("$cat"); any=1
            fi
            ROW_KIND+=("app"); ROW_KEY+=("$key"); ROW_CAT+=("$cat")
        done
    done
}

next_app_row() { # next_app_row <from> <dir>
    local i=$(($1 + $2))
    while ((i >= 0 && i < ${#ROW_KIND[@]})); do
        [[ ${ROW_KIND[$i]} == app ]] && { echo "$i"; return; }
        i=$((i + $2))
    done
    echo "$1"
}

selected_count() { local k n=0; for k in "${KEYS[@]}"; do [[ ${SEL[$k]} -eq 1 ]] && n=$((n + 1)); done; echo "$n"; }

draw_panel_lines() { # fills PANEL[] with plain-ish lines for the details box
    local key="$1" w="$2"
    local iw=$((w - 4))
    PANEL=()
    [[ -z $key ]] && return
    local name="${A_NAME[$key]}"
    PANEL+=("$G_TL$G_H $name $(repeat $((iw - ${#name} - 1)) "$G_H")$G_TR")
    local line
    while IFS= read -r line; do PANEL+=("$G_V $(pad $iw "$line") $G_V"); done < <(fold -s -w "$iw" <<<"${A_DESC[$key]}")
    PANEL+=("$G_V $(pad $iw "") $G_V")
    PANEL+=("$G_V $(pad $iw "Source     $(task_source_text "$key")") $G_V")
    if [[ ${STATUS_ON[$key]:-0} -eq 1 ]]; then
        PANEL+=("$G_V $(pad $iw "Status     installed") $G_V")
    else
        PANEL+=("$G_V $(pad $iw "Status     not installed") $G_V")
    fi
    if [[ ${SEL[$key]} -eq 1 ]]; then
        PANEL+=("$G_V $(pad $iw "Selected   yes") $G_V")
    else
        PANEL+=("$G_V $(pad $iw "Selected   no  (Space to select)") $G_V")
    fi
    if [[ -n ${A_SPECIAL[$key]} ]]; then
        PANEL+=("$G_V $(pad $iw "Version    $(option_summary "$key")") $G_V")
        PANEL+=("$G_V $(pad $iw "           press $G_RIGHT to change") $G_V")
    fi
    if [[ -n ${A_TIP[$key]} ]]; then
        PANEL+=("$G_V $(pad $iw "") $G_V")
        while IFS= read -r line; do PANEL+=("$G_V $(pad $iw "$line") $G_V"); done < <(fold -s -w "$iw" <<<"After install: ${A_TIP[$key]}")
    fi
    PANEL+=("$G_BL$(repeat $((w - 2)) "$G_H")$G_BR")
}

task_source_text() {
    local key="$1"
    case ${A_SPECIAL[$key]} in
        node)   echo "NodeSource apt repo / nvm" ;;
        python) echo "apt + deadsnakes PPA" ;;
        jdk)    echo "apt (vendor repository)" ;;
        xampp)  echo "apachefriends.org installer" ;;
        office) echo "apt / vendor .deb" ;;
        intellij|pycharm) echo "snap (classic)" ;;
        *)      method_label "${A_METHODS[$key]%%,*}" ;;
    esac
}

chip() { fput "$C_CHIP $1 $C_RESET$C_DIM $2   $C_RESET" " $1  $2   "; }

draw_picker() {
    term_size
    local w=$((COLS - 1)) h=$ROWS
    local show_panel=0 lw=$w
    if ((w >= 100)); then show_panel=1; lw=$(( w * 55 / 100 )); ((lw > 70)) && lw=70; fi
    local pw=$((w - lw - 2))
    local list_h=$((h - 6))
    ((list_h < 3)) && list_h=3
    LIST_H=$list_h

    # keep the cursor visible
    ((CURSOR < SCROLL)) && SCROLL=$CURSOR
    if ((CURSOR > 0)) && [[ ${ROW_KIND[$((CURSOR - 1))]:-} == cat ]] && ((CURSOR - 1 < SCROLL)); then SCROLL=$((CURSOR - 1)); fi
    ((CURSOR >= SCROLL + list_h)) && SCROLL=$((CURSOR - list_h + 1))
    local maxscroll=$((${#ROW_KIND[@]} - list_h))
    ((maxscroll < 0)) && maxscroll=0
    ((SCROLL > maxscroll)) && SCROLL=$maxscroll
    ((SCROLL < 0)) && SCROLL=0

    frame_reset
    # title bar
    local left="  $G_DIA LINUX SILENT INSTALLER  v$WSI_VERSION"
    local right="$(selected_count) selected  $G_DOT  ${#KEYS[@]} apps  "
    local gap=$((w - ${#left} - ${#right}))
    ((gap < 1)) && gap=1
    fput "$C_BAR$left$(repeat $gap ' ')$right$C_RESET" "$left$(repeat $gap ' ')$right"; fline

    # second line
    if [[ $SEARCH_MODE -eq 1 ]]; then
        fput "  ${C_DIM}Search: $C_RESET$C_YELLOW$FILTER$C_RESET${C_YELLOW}_$C_RESET" "  Search: ${FILTER}_"
    elif [[ -n $FILTER ]]; then
        fput "  ${C_DIM}Filter: $C_RESET$C_YELLOW$FILTER$C_RESET$C_DIM   (Esc clears)$C_RESET" "  Filter: $FILTER   (Esc clears)"
    else
        fput "  ${C_DIM}Choose the apps to install, then press ${C_RESET}Enter${C_DIM} to review.$C_RESET" "  Choose the apps to install, then press Enter to review."
    fi
    fline
    fput "$C_DIM$(repeat $w "$G_H")$C_RESET" "$(repeat $w "$G_H")"; fline

    local curkey=""
    [[ ${ROW_KIND[$CURSOR]:-} == app ]] && curkey="${ROW_KEY[$CURSOR]}"
    PANEL=()
    [[ $show_panel -eq 1 ]] && draw_panel_lines "$curkey" "$pw"

    local i ri
    for ((i = 0; i < list_h; i++)); do
        ri=$((SCROLL + i))
        if ((ri < ${#ROW_KIND[@]})); then
            if [[ ${ROW_KIND[$ri]} == cat ]]; then
                local cat="${ROW_CAT[$ri]}" n=0 tot=0 k
                for k in "${KEYS[@]}"; do
                    [[ ${A_CAT[$k]} == "$cat" ]] || continue
                    tot=$((tot + 1)); [[ ${SEL[$k]} -eq 1 ]] && n=$((n + 1))
                done
                local ctext="  ${cat^^}"
                local cnt=""
                [[ $n -gt 0 ]] && cnt="  $n/$tot"
                fput "$C_CYAN$(pad $((lw - ${#cnt})) "$ctext")$C_RESET$C_DIM$cnt$C_RESET" "$(pad $((lw - ${#cnt})) "$ctext")$cnt"
            else
                local key="${ROW_KEY[$ri]}" iscur=0
                ((ri == CURSOR)) && iscur=1
                local bg=""; [[ $iscur -eq 1 ]] && bg="$C_SEL"
                local mark="$G_OFF" mc="$C_DIM"
                [[ ${SEL[$key]} -eq 1 ]] && { mark="$G_ON"; mc="$C_GREEN"; }
                local ptr="   "; [[ $iscur -eq 1 ]] && ptr=" $G_PTR "
                local badge=""
                [[ ${STATUS_ON[$key]:-0} -eq 1 ]] && badge="$G_OK installed"
                local opt=""
                [[ -n ${A_SPECIAL[$key]} ]] && opt="  $(option_summary "$key")  $G_RIGHT"
                local nm="${A_NAME[$key]}"
                local room=$((lw - 6 - ${#badge} - ${#opt} - 2))
                ((${#nm} > room)) && nm="${nm:0:room}"
                local body="$ptr$mark  $nm$opt"
                local padn=$((lw - ${#body} - ${#badge} - 1))
                ((padn < 0)) && padn=0
                local plainline="$body$(repeat $padn ' ')$badge "
                fput "$bg$C_CYAN$ptr$mc$mark$C_RESET$bg$C_WHITE  $nm$C_RESET$bg$C_CYAN$opt$C_RESET$bg$(repeat $padn ' ')$C_GREEN$badge$C_RESET$bg $C_RESET" "$plainline"
            fi
        else
            fput "$(repeat $lw ' ')" "$(repeat $lw ' ')"
        fi
        if [[ $show_panel -eq 1 ]]; then
            local pl="${PANEL[$i]:-}"
            fput "  $C_DIM$pl$C_RESET" "  $pl"
        fi
        fline
    done

    local above=$SCROLL below=$((${#ROW_KIND[@]} - SCROLL - list_h))
    ((below < 0)) && below=0
    local slabel=""
    ((above > 0)) && slabel="$G_UP $above more"
    ((below > 0)) && slabel="$slabel   $G_DN $below more"
    [[ -n $slabel ]] && slabel=" $slabel "
    fput "$C_DIM$G_H$G_H$slabel$(repeat $((w - 2 - ${#slabel})) "$G_H")$C_RESET" "$G_H$G_H$slabel"; fline

    if [[ -n $MSG ]]; then
        fput "  $C_YELLOW$MSG$C_RESET" "  $MSG"; MSG=""
    elif [[ -n $curkey && $show_panel -eq 0 ]]; then
        fput "  $C_DIM${A_DESC[$curkey]:0:$((w - 4))}$C_RESET" "  ${A_DESC[$curkey]:0:$((w - 4))}"
    else
        fput "  ${C_DIM}Tip: press $G_RIGHT on Node.js, Python, Java JDK, XAMPP, IntelliJ, PyCharm or Office to choose versions.$C_RESET" "  Tip"
    fi
    fline

    fput " " " "
    if [[ $SEARCH_MODE -eq 1 ]]; then
        chip "type" "filter"; chip "$G_UP$G_DN" "move"; chip "Space" "select"; chip "Enter" "done"; chip "Esc" "clear"
    else
        chip "$G_UP$G_DN" "move"; chip "Space" "select"; chip "$G_RIGHT" "versions"; chip "/" "search"
        chip "A" "all"; chip "N" "none"; chip "R" "recommended"; chip "C" "category"; chip "Enter" "review"; chip "Esc" "quit"
    fi
    fshow
}

# ---- version dialogs -----------------------------------------------------------------------
dialog_choose() { # dialog_choose <title> <hint> <current> <items...>  items: value|label|hint -> DIALOG_RESULT
    local title="$1" hint="$2" current="$3"; shift 3
    local items=("$@") cur=0 i
    for i in "${!items[@]}"; do [[ ${items[$i]%%|*} == "$current" ]] && cur=$i; done
    while true; do
        term_size
        local bw=62 iw=58
        ((bw > COLS - 4)) && { bw=$((COLS - 4)); iw=$((bw - 4)); }
        local lines=()
        lines+=("$G_TL$G_H $title $(repeat $((iw - ${#title} - 1)) "$G_H")$G_TR")
        lines+=("$G_V $(pad $iw "$hint") $G_V")
        lines+=("$G_V $(pad $iw "") $G_V")
        for i in "${!items[@]}"; do
            local v="${items[$i]%%|*}" rest="${items[$i]#*|}"
            local lab="${rest%%|*}" h="${rest#*|}"
            [[ $h == "$lab" ]] && h=""
            local m="$G_OFF"; [[ $v == "$current" ]] && m="$G_ON"
            local p="  "; ((i == cur)) && p="$G_PTR "
            lines+=("$G_V $(pad $iw "$p$m  $lab${h:+  $h}") $G_V")
        done
        lines+=("$G_V $(pad $iw "") $G_V")
        lines+=("$G_V $(pad $iw " Enter choose   Esc cancel") $G_V")
        lines+=("$G_BL$(repeat $((bw - 2)) "$G_H")$G_BR")
        draw_dialog "${lines[@]}"
        read_key
        case $KEY in
            UP) cur=$(((cur - 1 + ${#items[@]}) % ${#items[@]})) ;;
            DOWN) cur=$(((cur + 1) % ${#items[@]})) ;;
            SPACE) current="${items[$cur]%%|*}" ;;
            ENTER) DIALOG_RESULT="${items[$cur]%%|*}"; return 0 ;;
            ESC|QUIT) return 1 ;;
        esac
    done
}

dialog_multi() { # dialog_multi <title> <hint> <current csv> <items...> -> DIALOG_RESULT (default first)
    local title="$1" hint="$2" current="$3"; shift 3
    local items=("$@") cur=0 i
    local -a chosen
    IFS=',' read -ra chosen <<<"$current"
    local default="${chosen[0]:-}"
    local err=""
    while true; do
        term_size
        local bw=62 iw=58
        ((bw > COLS - 4)) && { bw=$((COLS - 4)); iw=$((bw - 4)); }
        local lines=()
        lines+=("$G_TL$G_H $title $(repeat $((iw - ${#title} - 1)) "$G_H")$G_TR")
        lines+=("$G_V $(pad $iw "$hint") $G_V")
        lines+=("$G_V $(pad $iw "") $G_V")
        if [[ -n ${DIALOG_VENDOR:-} ]]; then
            lines+=("$G_V $(pad $iw "Vendor    $G_LEFT ${JDK_VENDORS[$DIALOG_VENDOR]##*|} $G_RIGHT   $G_LEFT $G_RIGHT to change") $G_V")
            lines+=("$G_V $(pad $iw "") $G_V")
        fi
        for i in "${!items[@]}"; do
            local v="${items[$i]%%|*}" rest="${items[$i]#*|}"
            local lab="${rest%%|*}" h="${rest#*|}"
            [[ $h == "$lab" ]] && h=""
            local m="$G_OFF"
            [[ " ${chosen[*]} " == *" $v "* ]] && m="$G_ON"
            local p="  "; ((i == cur)) && p="$G_PTR "
            local d=""
            [[ $v == "$default" && $m == "$G_ON" ]] && d="  default"
            lines+=("$G_V $(pad $iw "$p$m  $lab$d${h:+  $h}") $G_V")
        done
        lines+=("$G_V $(pad $iw "$err") $G_V")
        lines+=("$G_V $(pad $iw " Space toggle   D default   Enter apply   Esc cancel") $G_V")
        lines+=("$G_BL$(repeat $((bw - 2)) "$G_H")$G_BR")
        draw_dialog "${lines[@]}"
        err=""
        local v="${items[$cur]%%|*}"
        read_key
        case $KEY in
            UP) cur=$(((cur - 1 + ${#items[@]}) % ${#items[@]})) ;;
            DOWN) cur=$(((cur + 1) % ${#items[@]})) ;;
            LEFT|RIGHT)
                if [[ -n ${DIALOG_VENDOR:-} ]]; then
                    local n=${#JDK_VENDOR_ORDER[@]} idx=0 j
                    for j in "${!JDK_VENDOR_ORDER[@]}"; do [[ ${JDK_VENDOR_ORDER[$j]} == "$DIALOG_VENDOR" ]] && idx=$j; done
                    if [[ $KEY == LEFT ]]; then idx=$(((idx - 1 + n) % n)); else idx=$(((idx + 1) % n)); fi
                    DIALOG_VENDOR="${JDK_VENDOR_ORDER[$idx]}"
                fi ;;
            SPACE)
                if [[ " ${chosen[*]} " == *" $v "* ]]; then
                    local -a keep=()
                    for i in "${chosen[@]}"; do [[ $i == "$v" ]] || keep+=("$i"); done
                    chosen=("${keep[@]}")
                    [[ $default == "$v" ]] && default="${chosen[0]:-}"
                else
                    chosen+=("$v")
                    [[ -z $default ]] && default="$v"
                fi ;;
            CHAR:d|CHAR:D)
                [[ " ${chosen[*]} " == *" $v "* ]] || chosen+=("$v")
                default="$v" ;;
            ENTER)
                if [[ ${#chosen[@]} -eq 0 ]]; then err="Select at least one version (or Esc to cancel)"; continue; fi
                local out="$default"
                for i in "${items[@]}"; do
                    local vv="${i%%|*}"
                    [[ $vv == "$default" ]] && continue
                    [[ " ${chosen[*]} " == *" $vv "* ]] && out="$out,$vv"
                done
                DIALOG_RESULT="$out"; return 0 ;;
            ESC|QUIT) return 1 ;;
        esac
    done
}

LAST_KEY=""

draw_dialog() {
    term_size
    local lines=("$@") bw=${#1} n=${#lines[@]}
    local bx=$(((COLS - 62) / 2)) by=$(((ROWS - n) / 2))
    ((bx < 1)) && bx=1
    ((by < 1)) && by=1
    local i
    for i in "${!lines[@]}"; do
        printf '\e[%d;%dH%s%s%s' $((by + i + 1)) $((bx + 1)) "$C_CYAN" "${lines[$i]}" "$C_RESET"
    done
    if [[ -n ${WSI_TEST_DUMP:-} ]]; then
        printf '%s\n%s\n' "$(printf '%s\n' "${lines[@]}")" "========================================" >>"$WSI_TEST_DUMP"
    fi
}

open_options() { # open_options <key>
    local key="$1"
    DIALOG_RESULT=""
    case ${A_SPECIAL[$key]} in
        node)
            dialog_choose "Node.js version" "Pick one version." "$OPT_NODE" \
                "lts|LTS|recommended" "latest|Latest (current)|newest features" \
                "24|Node 24|" "22|Node 22|" "20|Node 20|" "nvm|nvm|switch versions anytime" && OPT_NODE="$DIALOG_RESULT" ;;
        python)
            dialog_multi "Python versions" "Select one or more. The first is the default." "$OPT_PYTHON" \
                "3.14|Python 3.14|" "3.13|Python 3.13|" "3.12|Python 3.12|" "3.11|Python 3.11|" "3.10|Python 3.10|" && OPT_PYTHON="$DIALOG_RESULT" ;;
        jdk)
            local first="${OPT_JDK%%,*}"
            DIALOG_VENDOR="${first%%:*}"
            [[ $DIALOG_VENDOR == "$first" ]] && DIALOG_VENDOR="temurin"
            local majors="" sp
            for sp in ${OPT_JDK//,/ }; do majors="${majors:+$majors,}${sp##*:}"; done
            if dialog_multi "Java JDK" "Select one or more. The first sets JAVA_HOME." "$majors" \
                "25|JDK 25|LTS, newest" "21|JDK 21|LTS" "17|JDK 17|LTS" "11|JDK 11|LTS, older" "8|JDK 8|legacy"; then
                local out="" m
                for m in ${DIALOG_RESULT//,/ }; do out="${out:+$out,}$DIALOG_VENDOR:$m"; done
                OPT_JDK="$out"
            fi
            DIALOG_VENDOR="" ;;
        xampp)
            dialog_choose "XAMPP" "Pick the PHP version." "$OPT_XAMPP" "8.2|PHP 8.2|recommended" "8.1|PHP 8.1|" && OPT_XAMPP="$DIALOG_RESULT" ;;
        intellij)
            dialog_choose "IntelliJ IDEA" "Pick the edition." "$OPT_INTELLIJ" \
                "ultimate|Ultimate|paid, 30-day trial" "community|Community|free" && OPT_INTELLIJ="$DIALOG_RESULT" ;;
        pycharm)
            dialog_choose "PyCharm" "Pick the edition." "$OPT_PYCHARM" \
                "professional|Professional|paid, 30-day trial" "community|Community|free" && OPT_PYCHARM="$DIALOG_RESULT" ;;
        office)
            dialog_choose "Office suite" "Microsoft Office has no Linux version; these open the same files." "$OPT_OFFICE" \
                "libreoffice|LibreOffice|from Ubuntu, open source" \
                "onlyoffice|OnlyOffice Desktop|best Microsoft format support" \
                "wps|WPS Office|Microsoft-like interface" && OPT_OFFICE="$DIALOG_RESULT" ;;
        *) MSG="${A_NAME[$key]} has no version options - press Space to select it."; return ;;
    esac
    SEL[$key]=1
    MSG="$G_OK ${A_NAME[$key]}: $(option_summary "$key")"
}

review_screen() { # returns 0 = install, 1 = back
    local scroll=0
    while true; do
        term_size
        local w=$((COLS - 1)) h=$ROWS list_h=$((ROWS - 6))
        ((list_h < 3)) && list_h=3
        local lines=() plains=()
        local ninstall=0 nskip=0 cat key
        for cat in "${CATS[@]}"; do
            local any=0
            for key in "${KEYS[@]}"; do
                [[ ${A_CAT[$key]} == "$cat" && ${SEL[$key]} -eq 1 ]] || continue
                if [[ $any -eq 0 ]]; then lines+=("CAT|$cat"); any=1; fi
                local st
                st=$(plan_state "$key")
                [[ $st == skip* ]] && nskip=$((nskip + 1)) || ninstall=$((ninstall + 1))
                lines+=("APP|$key|$st")
            done
            [[ $any -eq 1 ]] && lines+=("GAP|")
        done
        local maxscroll=$((${#lines[@]} - list_h))
        ((maxscroll < 0)) && maxscroll=0
        ((scroll > maxscroll)) && scroll=$maxscroll
        ((scroll < 0)) && scroll=0

        frame_reset
        local title="  $G_DIA REVIEW  v$WSI_VERSION"
        [[ $DRY_RUN -eq 1 ]] && title="  $G_DIA DRY RUN  v$WSI_VERSION"
        local right="$ninstall to install  $G_DOT  $nskip already installed  "
        local gap=$((w - ${#title} - ${#right}))
        ((gap < 1)) && gap=1
        fput "$C_BAR$title$(repeat $gap ' ')$right$C_RESET" "$title$(repeat $gap ' ')$right"; fline
        if [[ $DRY_RUN -eq 1 ]]; then
            fput "  ${C_YELLOW}Dry run: nothing will be installed.$C_RESET" "  Dry run: nothing will be installed."
        else
            fput "  ${C_DIM}Everything below installs silently. Nothing happens until you press Enter.$C_RESET" "  Everything below installs silently."
        fi
        fline
        fput "$C_DIM$(repeat $w "$G_H")$C_RESET" "$(repeat $w "$G_H")"; fline
        local i ri
        for ((i = 0; i < list_h; i++)); do
            ri=$((scroll + i))
            if ((ri < ${#lines[@]})); then
                local e="${lines[$ri]}"
                case ${e%%|*} in
                    CAT) fput "  $C_CYAN${e#*|}$C_RESET" "  ${e#*|}" ;;
                    APP)
                        local rest="${e#*|}"
                        local k="${rest%%|*}" st="${rest#*|}"
                        local sc="$C_GREEN"; [[ $st == skip* ]] && sc="$C_DIM"
                        local opt=""
                        [[ -n ${A_SPECIAL[$k]} ]] && opt="$(option_summary "$k")"
                        fput "   $sc$G_ON$C_RESET  $C_WHITE$(pad 28 "${A_NAME[$k]}")$C_RESET $C_CYAN$(pad 26 "$opt")$C_RESET$sc$st$C_RESET" \
                             "   $G_ON  $(pad 28 "${A_NAME[$k]}") $(pad 26 "$opt")$st" ;;
                    *) fput "" "" ;;
                esac
            fi
            fline
        done
        fput "$C_DIM$(repeat $w "$G_H")$C_RESET" "$(repeat $w "$G_H")"; fline
        local fs="off"; [[ $FORCE -eq 1 ]] && fs="ON"
        fput "  ${C_DIM}Reinstall apps that are already installed: $C_RESET$fs" "  Reinstall: $fs"; fline
        fput " " " "
        chip "Enter" "install now"; chip "Esc" "back to list"; chip "F" "toggle reinstall"; chip "$G_UP$G_DN" "scroll"
        fshow
        read_key
        case $KEY in
            ENTER) return 0 ;;
            ESC|LEFT|BACKSPACE|QUIT) return 1 ;;
            CHAR:f|CHAR:F) FORCE=$((1 - FORCE)) ;;
            UP) scroll=$((scroll - 1)) ;;
            DOWN) scroll=$((scroll + 1)) ;;
            PGUP) scroll=$((scroll - list_h)) ;;
            PGDN) scroll=$((scroll + list_h)) ;;
        esac
    done
}

picker() {
    local key
    for key in "${KEYS[@]}"; do SEL[$key]=${A_REC[$key]}; done
    CURSOR=0 SCROLL=0 FILTER="" SEARCH_MODE=0
    build_rows
    CURSOR=$(next_app_row -1 1)
    [[ -t 1 ]] && { printf '\e[?1049h\e[?25l'; stty -echo 2>/dev/null; }
    trap 'picker_cleanup' EXIT INT TERM
    while true; do
        build_rows
        if ((CURSOR >= ${#ROW_KIND[@]})) || [[ ${ROW_KIND[$CURSOR]:-} != app ]]; then CURSOR=$(next_app_row -1 1); fi
        draw_picker
        local k
        read_key
        k="$KEY"
        local curkey=""
        [[ ${ROW_KIND[$CURSOR]:-} == app ]] && curkey="${ROW_KEY[$CURSOR]}"
        case $k in
            UP) CURSOR=$(next_app_row "$CURSOR" -1) ;;
            DOWN) CURSOR=$(next_app_row "$CURSOR" 1) ;;
            PGUP) local n=0; while ((n < LIST_H - 1)); do CURSOR=$(next_app_row "$CURSOR" -1); n=$((n + 1)); done ;;
            PGDN) local n=0; while ((n < LIST_H - 1)); do CURSOR=$(next_app_row "$CURSOR" 1); n=$((n + 1)); done ;;
            HOME) CURSOR=$(next_app_row -1 1) ;;
            END) CURSOR=$(next_app_row ${#ROW_KIND[@]} -1) ;;
            TAB)
                local i=$((CURSOR + 1))
                while ((i < ${#ROW_KIND[@]})) && [[ ${ROW_KIND[$i]} != cat ]]; do i=$((i + 1)); done
                ((i >= ${#ROW_KIND[@]})) && i=-1
                CURSOR=$(next_app_row "$i" 1) ;;
            SPACE) [[ -n $curkey ]] && SEL[$curkey]=$((1 - SEL[$curkey])) ;;
            RIGHT) [[ -n $curkey ]] && open_options "$curkey" ;;
            ENTER)
                if [[ $SEARCH_MODE -eq 1 ]]; then SEARCH_MODE=0; continue; fi
                if [[ $(selected_count) -eq 0 ]]; then MSG="Nothing selected yet - press Space on an app first."; continue; fi
                if review_screen; then
                    SELECTED=()
                    for key in "${KEYS[@]}"; do [[ ${SEL[$key]} -eq 1 ]] && SELECTED+=("$key"); done
                    picker_cleanup
                    return 0
                fi ;;
            ESC)
                if [[ $SEARCH_MODE -eq 1 ]]; then SEARCH_MODE=0; FILTER=""; continue; fi
                [[ -n $FILTER ]] && { FILTER=""; continue; }
                picker_cleanup; return 1 ;;
            QUIT) picker_cleanup; return 1 ;;
            BACKSPACE) [[ $SEARCH_MODE -eq 1 && -n $FILTER ]] && FILTER="${FILTER%?}" ;;
            CHAR:*)
                local c="${k#CHAR:}"
                if [[ $SEARCH_MODE -eq 1 ]]; then
                    FILTER+="$c"
                    continue
                fi
                case $c in
                    /) SEARCH_MODE=1 ;;
                    q|Q) picker_cleanup; return 1 ;;
                    a|A) local r; for r in "${!ROW_KIND[@]}"; do [[ ${ROW_KIND[$r]} == app ]] && SEL[${ROW_KEY[$r]}]=1; done; MSG="Selected every app in the list." ;;
                    n|N) local r; for r in "${!ROW_KIND[@]}"; do [[ ${ROW_KIND[$r]} == app ]] && SEL[${ROW_KEY[$r]}]=0; done; MSG="Cleared the selection." ;;
                    r|R) for key in "${KEYS[@]}"; do SEL[$key]=${A_REC[$key]}; done; MSG="Restored the recommended selection." ;;
                    c|C)
                        [[ -z $curkey ]] && continue
                        local cat="${A_CAT[$curkey]}" allon=1 k2
                        for k2 in "${KEYS[@]}"; do
                            [[ ${A_CAT[$k2]} == "$cat" ]] || continue
                            [[ ${SEL[$k2]} -eq 1 ]] || allon=0
                        done
                        for k2 in "${KEYS[@]}"; do
                            [[ ${A_CAT[$k2]} == "$cat" ]] || continue
                            SEL[$k2]=$((1 - allon))
                        done ;;
                    v|V) [[ -n $curkey ]] && open_options "$curkey" ;;
                esac ;;
        esac
    done
}

picker_cleanup() {
    trap - EXIT INT TERM
    [[ -t 1 ]] && { stty echo 2>/dev/null; printf '\e[?25h\e[?1049l'; }
}

# ============================================================================================
# CLI
# ============================================================================================
show_list() {
    local cat key
    for cat in "${CATS[@]}"; do
        printf '\n  %s%s%s\n' "$C_CYAN" "${cat^^}" "$C_RESET"
        for key in "${KEYS[@]}"; do
            [[ ${A_CAT[$key]} == "$cat" ]] || continue
            local rec=" "
            [[ ${A_REC[$key]} -eq 1 ]] && rec="$G_ON"
            local src
            if [[ -n ${A_SPECIAL[$key]} ]]; then src="version selectable"; else src="$(method_label "${A_METHODS[$key]%%,*}")"; fi
            printf '   %s%s%s %s%-14s%s %-30s %s%s%s\n' "$C_GREEN" "$rec" "$C_RESET" "$C_WHITE" "$key" "$C_RESET" "${A_NAME[$key]}" "$C_DIM" "$src" "$C_RESET"
        done
    done
    printf '\n  %s%s = recommended (pre-selected in the picker, installed with --recommended)%s\n' "$C_DIM" "$G_ON" "$C_RESET"
}

usage() {
    cat <<EOF
Linux Silent Installer $WSI_VERSION

  ./install.sh                         interactive picker
  ./install.sh --recommended --yes     install the recommended set, no questions
  ./install.sh --apps chrome,git,node --node 22 --yes
  ./install.sh --config profiles/full-dev.json --yes
  ./install.sh --list

Options
  --apps a,b,c        apps to install (see --list)
  --all               every app in the catalog
  --recommended       the pre-selected set
  --config FILE|NAME  profile file, a name from profiles/, or an https URL
  --node SPEC         lts (default) | latest | 24 | 22 | 20 | nvm | nvm:22
  --python LIST       3.13 (default) | 3.12,3.13 ...   first one is the default
  --jdk LIST          [vendor:]major, e.g. 21 | 17,21 | microsoft:21
                      vendors: ${JDK_VENDOR_ORDER[*]}
  --xampp VER         8.2 (default) | 8.1
  --intellij ED       ultimate (default) | community
  --pycharm ED        professional (default) | community
  --office ED         libreoffice (default) | onlyoffice | wps
  --yes               no questions
  --force             reinstall apps that are already installed
  --dry-run           show the plan, install nothing (no sudo needed)
  --reboot            reboot at the end if an installer asked for it
  --show-output       show installer output (it always goes to the log)
  --log-dir DIR       where to write logs (default: ./logs)
  --list              list every app
  -h, --help          this help
EOF
}

parse_profile() { # very small JSON reader for our own profile format
    local file="$1" body
    if [[ $file == https://* ]]; then body=$(curl -fsSL "$file") || { fail_msg "Could not download $file"; exit 1; }
    else
        [[ -f $file ]] || file="$SCRIPT_DIR/profiles/$file.json"
        [[ -f $file ]] || { fail_msg "Config not found: $1"; exit 1; }
        body=$(cat "$file")
    fi
    local apps
    apps=$(tr -d '\n' <<<"$body" | grep -o '"apps"[[:space:]]*:[[:space:]]*\[[^]]*\]' | grep -o '"[^"]*"' | tail -n +2 | tr -d '"' | tr '\n' ',')
    [[ -n $apps ]] && APPS_ARG="${apps%,}"
    local f v
    for f in node xampp intellij pycharm office; do
        v=$(tr -d '\n' <<<"$body" | grep -o "\"$f\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | grep -o '"[^"]*"$' | tr -d '"')
        [[ -n $v ]] && case $f in
            node) OPT_NODE="$v" ;; xampp) OPT_XAMPP="$v" ;; intellij) OPT_INTELLIJ="$v" ;;
            pycharm) OPT_PYCHARM="$v" ;; office) OPT_OFFICE="$v" ;;
        esac
    done
    for f in python jdk; do
        v=$(tr -d '\n' <<<"$body" | grep -o "\"$f\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | grep -o '"[^"]*"' | tail -n +2 | tr -d '"' | tr '\n' ',')
        v="${v%,}"
        [[ -n $v ]] && case $f in python) OPT_PYTHON="$v" ;; jdk) OPT_JDK="$v" ;; esac
    done
}

save_profile() {
    local out="$LOG_DIR/last-selection.json" key first=1
    {
        printf '{\n    "apps": ['
        for key in "${SELECTED[@]}"; do
            [[ $first -eq 1 ]] && first=0 || printf ','
            printf '"%s"' "$key"
        done
        printf '],\n'
        printf '    "node": "%s",\n    "python": ["%s"],\n    "jdk": ["%s"],\n' "$OPT_NODE" "${OPT_PYTHON//,/\",\"}" "${OPT_JDK//,/\",\"}"
        printf '    "xampp": "%s",\n    "intellij": "%s",\n    "pycharm": "%s",\n    "office": "%s"\n}\n' \
            "$OPT_XAMPP" "$OPT_INTELLIJ" "$OPT_PYCHARM" "$OPT_OFFICE"
    } >"$out" 2>/dev/null
}

APPS_ARG="" WANT_ALL=0 WANT_REC=0 CONFIG_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --apps) APPS_ARG="${APPS_ARG:+$APPS_ARG,}$2"; shift 2 ;;
        --all) WANT_ALL=1; shift ;;
        --recommended) WANT_REC=1; shift ;;
        --config) CONFIG_ARG="$2"; shift 2 ;;
        --node) OPT_NODE="$2"; shift 2 ;;
        --python) OPT_PYTHON="$2"; shift 2 ;;
        --jdk) OPT_JDK="$2"; shift 2 ;;
        --xampp) OPT_XAMPP="$2"; shift 2 ;;
        --intellij) OPT_INTELLIJ="$2"; shift 2 ;;
        --pycharm) OPT_PYCHARM="$2"; shift 2 ;;
        --office) OPT_OFFICE="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --reboot) WANT_REBOOT=1; shift ;;
        --show-output) SHOW_OUTPUT=1; shift ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1"; usage; exit 1 ;;
    esac
done

G_RIGHT_SAFE="$G_RIGHT"

banner
if [[ $LIST_ONLY -eq 1 ]]; then show_list; exit 0; fi

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG_FILE"
RUN_START=$SECONDS

# ---- preflight
OS_PRETTY="$(os_field PRETTY_NAME)"; OS_ID="$(os_field ID)"; OS_LIKE="$(os_field ID_LIKE)"
step ok "${OS_PRETTY:-Linux}" "$(uname -r)  $G_DOT  bash ${BASH_VERSION%%(*}"
if [[ $OS_ID != ubuntu && $OS_LIKE != *debian* ]]; then
    step warn "This script targets Ubuntu/Debian" "apt-based commands may not work here"
fi
if [[ $DRY_RUN -eq 1 ]]; then
    SUDO="sudo"
    step skip "Dry run" "nothing will be installed, no sudo needed"
else
    need_sudo
    step ok "Administrator rights" "sudo ready"
fi
command -v curl >/dev/null || { [[ $DRY_RUN -eq 0 ]] && apt_install curl; }
scan_installed

# ---- selection
[[ -n $CONFIG_ARG ]] && parse_profile "$CONFIG_ARG"
OPT_NODE="${OPT_NODE:-$DEF_NODE}"
OPT_PYTHON="${OPT_PYTHON:-$DEF_PYTHON}"
OPT_JDK="${OPT_JDK:-$DEF_JDK}"
OPT_XAMPP="${OPT_XAMPP:-$DEF_XAMPP}"
OPT_INTELLIJ="${OPT_INTELLIJ:-$DEF_INTELLIJ}"
OPT_PYCHARM="${OPT_PYCHARM:-$DEF_PYCHARM}"
OPT_OFFICE="${OPT_OFFICE:-$DEF_OFFICE}"

declare -a SELECTED=()
if [[ $WANT_ALL -eq 1 ]]; then
    SELECTED=("${KEYS[@]}")
elif [[ -n $APPS_ARG || $WANT_REC -eq 1 ]]; then
    declare -A want=()
    if [[ $WANT_REC -eq 1 ]]; then
        for key in "${KEYS[@]}"; do [[ ${A_REC[$key]} -eq 1 ]] && want[$key]=1; done
    fi
    for a in ${APPS_ARG//,/ }; do
        a="${a,,}"
        if [[ -n ${ALIASES[$a]:-} ]]; then want[${ALIASES[$a]}]=1
        else step warn "Unknown app '$a'" "ignored - see --list"; fi
    done
    for key in "${KEYS[@]}"; do [[ -n ${want[$key]:-} ]] && SELECTED+=("$key"); done
else
    if [[ $ASSUME_YES -eq 1 ]]; then fail_msg "Nothing selected. Use --apps, --all, --recommended or --config with --yes."; exit 1; fi
    if [[ ! -t 0 || ! -t 1 ]] && [[ -z ${WSI_TEST_KEYS:-} ]]; then
        fail_msg "The interactive picker needs a terminal. Use --apps, --recommended or --config (see --list)."
        exit 1
    fi
    if [[ -n ${WSI_TEST_KEYS:-} ]]; then
        TEST_KEYS=1
        read -ra TEST_KEY_ARR <<<"$WSI_TEST_KEYS"
        TEST_IDX=0
    fi
    picker || { printf '  %sCancelled - nothing was installed.%s\n\n' "$C_DIM" "$C_RESET"; exit 0; }
    banner
fi

[[ ${#SELECTED[@]} -eq 0 ]] && { printf '  Nothing selected - exiting.\n'; exit 0; }

# npm-based tools need Node.js
need_node=0
for key in "${SELECTED[@]}"; do
    [[ ${A_METHODS[$key]} == *"npm:"* && ${A_METHODS[$key]} != *"fn:"* ]] && need_node=1
done
if [[ $need_node -eq 1 ]] && ! command -v node >/dev/null; then
    if [[ " ${SELECTED[*]} " != *" node "* ]]; then
        step warn "Adding Node.js" "needed by the npm-based CLIs"
        SELECTED=(node "${SELECTED[@]}")
    fi
fi

save_profile

# ---- plan
if [[ ! -t 0 || -n $APPS_ARG || $WANT_ALL -eq 1 || $WANT_REC -eq 1 || -n $CONFIG_ARG ]]; then
    heading "Plan: ${#SELECTED[@]} apps$([[ $DRY_RUN -eq 1 ]] && echo ' (dry run)')"
    for key in "${SELECTED[@]}"; do
        st=$(plan_state "$key")
        sc="$C_GREEN"; [[ $st == skip* ]] && sc="$C_DIM"
        printf '  %s%s%s  %s%-30s%s%s%-26s%s%s%s%s\n' "$sc" "$G_ON" "$C_RESET" "$C_WHITE" "${A_NAME[$key]}" "$C_RESET" \
            "$C_CYAN" "$(option_summary "$key")" "$C_RESET" "$sc" "$st" "$C_RESET"
    done
    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        printf '\n  Install now? [Y/n] '
        read -r ans </dev/tty
        case ${ans,,} in n|no) printf '  %sCancelled.%s\n' "$C_DIM" "$C_RESET"; exit 0 ;; esac
    fi
fi

build_tasks
heading "$([[ $DRY_RUN -eq 1 ]] && echo 'Dry run:' || echo 'Installing') ${#TASK_KEY[@]} items"
run_tasks
print_summary
rc=$?

if [[ $REBOOT_REQUIRED -eq 1 && $DRY_RUN -eq 0 ]]; then
    printf '\n  %sA reboot is recommended to finish setup.%s\n' "$C_YELLOW" "$C_RESET"
    if [[ $WANT_REBOOT -eq 1 ]]; then $SUDO shutdown -r +1 "Linux Silent Installer: finishing setup"; fi
fi
[[ -n ${SUDO_KEEPALIVE:-} ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null
exit $rc
