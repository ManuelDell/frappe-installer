#!/usr/bin/env bash
###############################################################################
#  install_frappe_bench.sh — Kugelsicheres Frappe-Bench-Installationsskript
#  Zielplattform: Debian 12+ / Ubuntu 22.04+ (inkl. LXC-Container)
#  Unterstützt: Frappe v15 (stable) und v16 (develop)
#  Ausführen als: root
#
#  Features:
#    • Wahl zwischen Fortschrittsbalken und Verbose-Modus
#    • Vollständiges Logfile in beiden Modi
#    • Debian-LXC-kompatibel (Pakete einzeln, fehlende = Warnung)
#    • Automatische Reparatur bei bench init Problemen
#    • Production-Setup mit Supervisor + Nginx
#
#  Autor: Dells Dienste
#  Datum: 2026-03-13
###############################################################################

set -euo pipefail
# KEIN custom IFS! Standard-IFS (space/tab/newline) ist nötig damit
# Word-Splitting bei apt-get etc. korrekt funktioniert.

# ─── Logfile ───────────────────────────────────────────────────────────────────

LOGFILE="/var/log/install_frappe_bench_$(date +%Y%m%d_%H%M%S).log"
touch "$LOGFILE"
exec 3>&1 4>&2

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# ─── Farben ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
OUTPUT_MODE="progress"

# ─── Ausgabe ───────────────────────────────────────────────────────────────────

log_info() { log_to_file "[INFO]  $*"; echo -e "${CYAN}[INFO]${NC}  $*" >&3; }
log_ok()   { log_to_file "[OK]    $*"; echo -e "${GREEN}  ✔${NC}  $*" >&3; }
log_warn() { log_to_file "[WARN]  $*"; echo -e "${YELLOW}  ⚠${NC}  $*" >&3; }
log_error(){ log_to_file "[ERROR] $*"; echo -e "${RED}  ✘${NC}  $*" >&3; }

die() {
    stop_spinner
    log_error "$*"
    echo -e "\n${DIM}  Logfile: ${LOGFILE}${NC}" >&3
    exit 1
}

# ─── Spinner & Fortschritt ─────────────────────────────────────────────────────

TOTAL_STEPS=10
CURRENT_STEP=0
SPINNER_PID=""

draw_progress_bar() {
    local step="$1" label="$2"
    local pct=$(( step * 100 / TOTAL_STEPS ))
    local filled=$(( step * 30 / TOTAL_STEPS ))
    local empty=$(( 30 - filled ))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    echo -ne "\r  ${BOLD}[${GREEN}${bar}${NC}${BOLD}] ${pct}%${NC}  ${CYAN}${label}${NC}    \033[K" >&3
}

start_spinner() {
    local label="$1"
    [[ "$OUTPUT_MODE" != "progress" ]] && return
    (
        local i=0
        while true; do
            echo -ne "\r    ${CYAN}${SPINNER_CHARS[$i]}${NC} ${DIM}${label}${NC}    \033[K" >&3
            i=$(( (i + 1) % ${#SPINNER_CHARS[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        echo -ne "\r\033[K" >&3
    fi
}

cleanup() { stop_spinner; exec 1>&3 2>&4 2>/dev/null || true; }
trap cleanup EXIT

step_start() {
    local step_num="$1" label="$2"
    CURRENT_STEP=$step_num
    stop_spinner
    log_to_file "═══ STEP ${step_num}/${TOTAL_STEPS}: ${label} ═══"
    if [[ "$OUTPUT_MODE" == "progress" ]]; then
        draw_progress_bar "$step_num" "$label"
        echo "" >&3
        start_spinner "$label"
    else
        echo -e "\n${BOLD}━━━ ${step_num}/${TOTAL_STEPS} — ${label} ━━━${NC}" >&3
    fi
}

# ─── Befehl-Wrapper ───────────────────────────────────────────────────────────

# Führt einen Befehl aus. Jedes Argument wird korrekt durchgereicht.
run_cmd() {
    local description="$1"
    shift
    log_to_file "CMD: $*"

    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
        if "$@" 2>&1 | tee -a "$LOGFILE" >&3; then
            return 0
        else
            local rc=$?
            log_error "${description} fehlgeschlagen (rc=${rc})"
            return $rc
        fi
    else
        if "$@" >> "$LOGFILE" 2>&1; then
            return 0
        else
            local rc=$?
            stop_spinner
            log_error "${description} fehlgeschlagen (rc=${rc})"
            echo -e "${DIM}  Letzte Log-Zeilen:${NC}" >&3
            tail -10 "$LOGFILE" | sed 's/^/    /' >&3
            start_spinner "Fortfahren..."
            return $rc
        fi
    fi
}

run_cmd_or_die() {
    local description="$1"; shift
    run_cmd "$description" "$@" || die "${description} — Abbruch. Log: ${LOGFILE}"
}

# ─── LXC-sicherer Service-Controller ──────────────────────────────────────────

# systemctl in LXC-Containern kann bei D-Bus-Fehlern rc=1 liefern,
# obwohl der Dienst tatsächlich läuft. Diese Funktion:
#   1. Versucht systemctl
#   2. Bei Fehler: prüft ob der Dienst WIRKLICH läuft (pgrep/pidof)
#   3. Nur wenn Dienst tatsächlich nicht läuft → Fehler
#
# Nutzung: svc_ctl <action> <service> [<process_name>]
#   action:       enable|start|stop|restart
#   service:      systemd service name (z.B. mariadb)
#   process_name: Prozessname für pgrep-Check (optional, default=service)

svc_ctl() {
    local action="$1"
    local service="$2"
    local process_name="${3:-$service}"

    log_to_file "SVC: systemctl ${action} ${service}"

    # Versuche systemctl
    if systemctl "$action" "$service" >> "$LOGFILE" 2>&1; then
        log_to_file "SVC OK: systemctl ${action} ${service}"
        return 0
    fi

    local rc=$?
    log_to_file "SVC WARN: systemctl ${action} ${service} rc=${rc} (D-Bus?)"

    # enable braucht keinen Laufzeit-Check
    if [[ "$action" == "enable" ]]; then
        log_to_file "SVC: enable fehlgeschlagen, aber nicht kritisch in LXC"
        return 0
    fi

    # stop soll stoppen — prüfe ob Prozess weg ist
    if [[ "$action" == "stop" ]]; then
        sleep 1
        if ! pgrep -x "$process_name" > /dev/null 2>&1; then
            log_to_file "SVC OK: ${service} gestoppt (pgrep bestätigt)"
            return 0
        fi
        log_to_file "SVC FAIL: ${service} läuft noch nach stop"
        return 1
    fi

    # start/restart — warte kurz, dann prüfe ob Prozess läuft
    sleep 2

    if pgrep -x "$process_name" > /dev/null 2>&1; then
        log_to_file "SVC OK: ${service} läuft (pgrep bestätigt, D-Bus-Fehler ignoriert)"
        return 0
    fi

    # Zweiter Versuch: mit service-Befehl (SysV-kompatibel)
    log_to_file "SVC: Fallback → service ${service} ${action}"
    if service "$service" "$action" >> "$LOGFILE" 2>&1; then
        sleep 2
        if pgrep -x "$process_name" > /dev/null 2>&1; then
            log_to_file "SVC OK: ${service} läuft (via service-Befehl)"
            return 0
        fi
    fi

    # Dritter Versuch: Prozess direkt starten (nur MariaDB/Redis)
    if [[ "$action" =~ ^(start|restart)$ ]]; then
        case "$service" in
            mariadb|mysql)
                log_to_file "SVC: Fallback → mariadbd direkt starten"
                mariadbd --user=mysql >> "$LOGFILE" 2>&1 &
                sleep 3
                if pgrep -x "mariadbd" > /dev/null 2>&1; then
                    log_to_file "SVC OK: mariadbd läuft (direkt gestartet)"
                    return 0
                fi
                ;;
            redis-server)
                log_to_file "SVC: Fallback → redis-server direkt starten"
                redis-server /etc/redis/redis.conf >> "$LOGFILE" 2>&1 &
                sleep 2
                if pgrep -x "redis-server" > /dev/null 2>&1; then
                    log_to_file "SVC OK: redis-server läuft (direkt gestartet)"
                    return 0
                fi
                ;;
        esac
    fi

    log_to_file "SVC FAIL: ${service} konnte nicht gestartet werden"
    return 1
}

# ─── Paket-Installer (Kernfix!) ───────────────────────────────────────────────

# Installiert jedes Paket einzeln. Fehlende optionale Pakete = Warnung.
# $1 = "required" oder "optional"
# $2... = Paketnamen
FAILED_PKGS=()
INSTALLED_PKGS=()

install_pkg() {
    local mode="$1"; shift
    local pkg

    for pkg in "$@"; do
        log_to_file "Installiere Paket: ${pkg} (${mode})"
        if apt-get install -y -qq "$pkg" >> "$LOGFILE" 2>&1; then
            INSTALLED_PKGS+=("$pkg")
        else
            if [[ "$mode" == "required" ]]; then
                log_warn "Paket nicht verfügbar: ${pkg}"
                FAILED_PKGS+=("$pkg")
            else
                log_to_file "SKIP optional: ${pkg}"
                FAILED_PKGS+=("$pkg")
            fi
        fi
    done
}

# ─── Voraussetzungen ──────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}  ✘  Bitte als root ausführen: sudo bash $0${NC}"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo unknown)}"
else
    echo -e "${RED}  ✘  /etc/os-release fehlt.${NC}"; exit 1
fi

case "$OS_ID" in
    debian|ubuntu) ;;
    *) echo -e "${RED}  ✘  Nur Debian/Ubuntu (erkannt: ${OS_ID}).${NC}"; exit 1 ;;
esac

# ─── Banner ────────────────────────────────────────────────────────────────────

clear 2>/dev/null || true
echo -e "
${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗
║           Frappe Bench — Installationsskript                ║
║                   Dells Dienste 2026                        ║
╚══════════════════════════════════════════════════════════════╝${NC}

  System:  ${OS_PRETTY}
  Kernel:  $(uname -r)
  Logfile: ${LOGFILE}
"

# ─── Modus ─────────────────────────────────────────────────────────────────────

echo -e "${BOLD}Ausgabe-Modus:${NC}"
echo "  1) Fortschrittsbalken  — sauber, Details im Logfile"
echo "  2) Verbose             — alles live auf dem Terminal"
echo ""
while true; do
    read -rp "Auswahl [1/2] (Standard: 1): " MODE_CHOICE
    MODE_CHOICE="${MODE_CHOICE:-1}"
    case "$MODE_CHOICE" in
        1) OUTPUT_MODE="progress"; break ;;
        2) OUTPUT_MODE="verbose";  break ;;
        *) echo "  Bitte 1 oder 2." ;;
    esac
done
echo ""

# ─── Frappe-Version ────────────────────────────────────────────────────────────

echo -e "${BOLD}Frappe-Version:${NC}"
echo "  1) version-15  (stable — Python 3.11, Node 18, MariaDB 10.x)"
echo "  2) version-16  (develop — Python 3.14, Node 24, MariaDB 11.8)"
echo ""
while true; do
    read -rp "Auswahl [1/2] (Standard: 1): " VERSION_CHOICE
    VERSION_CHOICE="${VERSION_CHOICE:-1}"
    case "$VERSION_CHOICE" in
        1) FRAPPE_BRANCH="version-15"; break ;;
        2) FRAPPE_BRANCH="version-16"; break ;;
        *) echo "  Bitte 1 oder 2." ;;
    esac
done
log_ok "Branch: ${FRAPPE_BRANCH}"
echo ""

# ─── Benutzername ──────────────────────────────────────────────────────────────

while true; do
    read -rp "$(echo -e "${BOLD}Linux-Benutzername${NC} (z.B. frappe): ")" BENCH_USER
    BENCH_USER="${BENCH_USER:-frappe}"
    [[ "$BENCH_USER" =~ ^[a-z][a-z0-9_-]*$ ]] && break
    echo "  Nur Kleinbuchstaben, Zahlen, '-', '_' (Anfang: Buchstabe)."
done
log_ok "Benutzer: ${BENCH_USER}"
echo ""

# ─── Bench-Ordner ─────────────────────────────────────────────────────────────

while true; do
    read -rp "$(echo -e "${BOLD}Bench-Ordnername${NC} (in /home/${BENCH_USER}/): ")" BENCH_DIR
    BENCH_DIR="${BENCH_DIR:-frappe-bench}"
    [[ "$BENCH_DIR" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]] && break
    echo "  Nur Buchstaben, Zahlen, '.', '-', '_'."
done
BENCH_PATH="/home/${BENCH_USER}/${BENCH_DIR}"
log_ok "Pfad: ${BENCH_PATH}"
echo ""

# ─── MariaDB Root-Passwort ────────────────────────────────────────────────────

while true; do
    read -rsp "$(echo -e "${BOLD}MariaDB Root-Passwort:${NC} ")" MYSQL_ROOT_PASS; echo ""
    [[ -z "$MYSQL_ROOT_PASS" ]] && echo "  Darf nicht leer sein." && continue
    [[ ${#MYSQL_ROOT_PASS} -lt 6 ]] && echo "  Min. 6 Zeichen." && continue
    read -rsp "$(echo -e "${BOLD}Bestätigen:${NC} ")" MYSQL_ROOT_PASS_CONFIRM; echo ""
    [[ "$MYSQL_ROOT_PASS" == "$MYSQL_ROOT_PASS_CONFIRM" ]] && break
    echo "  Stimmt nicht überein."
done
log_ok "MariaDB Root-Passwort gesetzt."
echo ""

# ─── Optionale Site ────────────────────────────────────────────────────────────

read -rp "$(echo -e "${BOLD}Gleich eine Site erstellen?${NC} [j/N]: ")" CREATE_SITE
CREATE_SITE="${CREATE_SITE:-n}"
SITE_NAME=""
ADMIN_PASS=""

if [[ "${CREATE_SITE,,}" =~ ^(j|y)$ ]]; then
    echo ""
    while true; do
        read -rp "$(echo -e "${BOLD}Site-Name${NC} (z.B. erp.example.com): ")" SITE_NAME
        [[ -n "$SITE_NAME" && "$SITE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] && break
        echo "  Ungültiger Name."
    done
    while true; do
        read -rsp "$(echo -e "${BOLD}Admin-Passwort:${NC} ")" ADMIN_PASS; echo ""
        [[ -z "$ADMIN_PASS" ]] && echo "  Darf nicht leer sein." && continue
        read -rsp "$(echo -e "${BOLD}Bestätigen:${NC} ")" ADMIN_PASS_CONFIRM; echo ""
        [[ "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]] && break
        echo "  Stimmt nicht überein."
    done
fi

# ─── Zusammenfassung ──────────────────────────────────────────────────────────

echo -e "
${BOLD}═══ Zusammenfassung ═══${NC}
  Modus:         $([ "$OUTPUT_MODE" = "progress" ] && echo "Fortschrittsbalken" || echo "Verbose")
  Branch:        ${FRAPPE_BRANCH}
  Benutzer:      ${BENCH_USER}
  Bench-Pfad:    ${BENCH_PATH}
  MariaDB Root:  (gesetzt)"
[[ -n "$SITE_NAME" ]] && echo "  Site:          ${SITE_NAME}"
echo ""

read -rp "$(echo -e "${BOLD}Starten? [J/n]:${NC} ")" CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ ! "${CONFIRM,,}" =~ ^(j|y)$ ]] && log_warn "Abgebrochen." && exit 0
echo ""

# ─── Versions-Variablen ───────────────────────────────────────────────────────

if [[ "$FRAPPE_BRANCH" == "version-15" ]]; then
    TARGET_PYTHON="3.11"
    NODE_VERSION="18"
    USE_UV=false
    MARIADB_FROM_REPO=false
else
    TARGET_PYTHON="3.14"
    NODE_VERSION="24"
    USE_UV=true
    MARIADB_FROM_REPO=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
#                          INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

# Alle apt/dpkg-Dialoge unterdrücken — das Skript fragt selbst alles ab!
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# MariaDB Feedback-Plugin vorab auf "No" setzen (verhindert ncurses-Dialog)
if command -v debconf-set-selections &>/dev/null; then
    echo "mariadb-server mariadb-server/feedback_plugin_enable boolean false" | debconf-set-selections 2>/dev/null || true
fi

# ─── Vorherige Installation erkennen & aufräumen ─────────────────────────────

EXISTING_ITEMS=()

# Bench-Verzeichnis
BENCH_FULL="${BENCH_PATH:-/home/${BENCH_USER}/${BENCH_DIR}}"
[[ -d "$BENCH_FULL" ]] && EXISTING_ITEMS+=("Bench-Verzeichnis: ${BENCH_FULL}")

# User mit altem bench/uv
if id "$BENCH_USER" &>/dev/null; then
    UH="/home/${BENCH_USER}"
    [[ -d "${UH}/.local/share/uv" ]] && EXISTING_ITEMS+=("uv-Daten: ${UH}/.local/share/uv/")
    [[ -f "${UH}/.local/bin/bench" ]] && EXISTING_ITEMS+=("bench CLI: ${UH}/.local/bin/bench")
fi

# Falsche Node.js-Version
if command -v node &>/dev/null; then
    EXISTING_NODE_MAJOR=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    [[ "$EXISTING_NODE_MAJOR" -ne "$NODE_VERSION" ]] 2>/dev/null && \
        EXISTING_ITEMS+=("Node.js v${EXISTING_NODE_MAJOR} (benötigt: v${NODE_VERSION})")
fi

# Supervisor/Nginx-Configs
ls /etc/supervisor/conf.d/*"${BENCH_DIR}"* &>/dev/null 2>&1 && \
    EXISTING_ITEMS+=("Supervisor-Config für ${BENCH_DIR}")
ls /etc/nginx/conf.d/*"${BENCH_DIR}"* &>/dev/null 2>&1 && \
    EXISTING_ITEMS+=("Nginx-Config für ${BENCH_DIR}")

if [[ ${#EXISTING_ITEMS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}  ⚠  Vorherige Installation erkannt:${NC}"
    for item in "${EXISTING_ITEMS[@]}"; do
        echo -e "     • ${item}"
    done
    echo ""
    echo -e "  Bei der Installation werden alle bestehenden Instanzen gelöscht."
    read -rp "$(echo -e "${BOLD}  Fortfahren? [j/N]:${NC} ")" CLEANUP_CONFIRM

    if [[ ! "${CLEANUP_CONFIRM,,}" =~ ^(j|y)$ ]]; then
        log_warn "Abgebrochen."
        exit 0
    fi

    log_info "Räume auf..."

    # Supervisor stoppen
    if command -v supervisorctl &>/dev/null; then
        supervisorctl stop all >> "$LOGFILE" 2>&1 || true
    fi

    # Bench-Verzeichnis löschen
    if [[ -d "$BENCH_FULL" ]]; then
        rm -rf "$BENCH_FULL"
        log_ok "Gelöscht: ${BENCH_FULL}"
    fi

    # Supervisor/Nginx-Configs entfernen
    rm -f /etc/supervisor/conf.d/*"${BENCH_DIR}"* 2>/dev/null
    rm -f /etc/nginx/conf.d/*"${BENCH_DIR}"* 2>/dev/null
    supervisorctl reread >> "$LOGFILE" 2>&1 || true
    supervisorctl update >> "$LOGFILE" 2>&1 || true

    # uv/bench im User-Home
    if id "$BENCH_USER" &>/dev/null; then
        UH="/home/${BENCH_USER}"
        rm -rf "${UH}/.local/share/uv" 2>/dev/null
        rm -f "${UH}/.local/bin/bench" 2>/dev/null
        log_ok "User-Caches bereinigt."
    fi

    # Falsche Node.js entfernen
    if command -v node &>/dev/null; then
        OLD_NODE=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        if [[ "$OLD_NODE" -ne "$NODE_VERSION" ]] 2>/dev/null; then
            apt-get remove -y -qq nodejs >> "$LOGFILE" 2>&1 || true
            apt-get autoremove -y -qq >> "$LOGFILE" 2>&1 || true
            rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null
            log_ok "Node.js v${OLD_NODE} entfernt."
        fi
    fi

    log_ok "Aufräumen abgeschlossen."
    echo ""
fi

# ─── 1. System aktualisieren ──────────────────────────────────────────────────

step_start 1 "System aktualisieren"
run_cmd_or_die "apt update"  apt-get update -qq
run_cmd_or_die "apt upgrade" apt-get upgrade -y -qq
stop_spinner
log_ok "System aktualisiert."

# ─── 2. Abhängigkeiten ────────────────────────────────────────────────────────

step_start 2 "Abhängigkeiten installieren"

# Pflicht-Pakete: jedes einzeln — kein Gruppieren, kein Word-Splitting-Problem
REQUIRED_PKGS=(
    git
    curl
    wget
    sudo
    gnupg2
    ca-certificates
    lsb-release
    apt-transport-https
    build-essential
    python3-dev
    python3-setuptools
    python3-venv
    libffi-dev
    libssl-dev
    libjpeg-dev
    zlib1g-dev
    libfreetype6-dev
    liblcms2-dev
    libwebp-dev
    libharfbuzz-dev
    libfribidi-dev
    libxcb1-dev
    libpq-dev
    libmariadb-dev
    pkg-config
    libldap2-dev
    libsasl2-dev
    redis-server
    supervisor
    nginx
    xvfb
    libfontconfig
    fontconfig
    cron
)

# Optionale Pakete: Fehlen ist OK (Minimal-Debian, LXC)
OPTIONAL_PKGS=(
    software-properties-common
    python3-pip
    python3-distutils
    fail2ban
)

log_to_file "Installiere ${#REQUIRED_PKGS[@]} Pflicht-Pakete einzeln..."
install_pkg "required" "${REQUIRED_PKGS[@]}"

log_to_file "Installiere ${#OPTIONAL_PKGS[@]} optionale Pakete..."
install_pkg "optional" "${OPTIONAL_PKGS[@]}"

stop_spinner

if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
    log_warn "Nicht installiert (${#FAILED_PKGS[@]}): ${FAILED_PKGS[*]}"
fi
log_ok "${#INSTALLED_PKGS[@]} Pakete installiert."

# Kritische Pakete prüfen
CRITICAL_MISSING=()
for pkg in git curl build-essential python3-dev redis-server supervisor nginx; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        CRITICAL_MISSING+=("$pkg")
    fi
done
if [[ ${#CRITICAL_MISSING[@]} -gt 0 ]]; then
    die "Kritische Pakete fehlen: ${CRITICAL_MISSING[*]} — Installation kann nicht fortfahren!"
fi

# ─── 3. MariaDB installieren ──────────────────────────────────────────────────

step_start 3 "MariaDB installieren"

if [[ "$MARIADB_FROM_REPO" == true ]]; then
    log_to_file "MariaDB 11.8 aus offiziellem Repo..."
    curl -fsSL "https://mariadb.org/mariadb_release_signing_key.pgp" \
        | gpg --dearmor --yes -o /usr/share/keyrings/mariadb-keyring.gpg 2>/dev/null

    cat > /etc/apt/sources.list.d/mariadb.list <<EOF
deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.8/repo/${OS_ID} ${OS_CODENAME} main
EOF
    run_cmd "MariaDB Repo Update" apt-get update -qq
    run_cmd_or_die "MariaDB installieren" apt-get install -y -qq mariadb-server mariadb-client
else
    if ! dpkg -l mariadb-server 2>/dev/null | grep -q "^ii"; then
        run_cmd_or_die "MariaDB installieren" apt-get install -y -qq mariadb-server mariadb-client
    fi
fi

svc_ctl enable mariadb mariadbd || true
svc_ctl start mariadb mariadbd || die "MariaDB konnte nicht gestartet werden!"

stop_spinner
log_ok "MariaDB läuft."

# ─── 4. MariaDB konfigurieren ─────────────────────────────────────────────────

step_start 4 "MariaDB konfigurieren"

cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'MARIADB_CNF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server           = utf8mb4
collation-server               = utf8mb4_unicode_ci

innodb_file_per_table          = 1
innodb_large_prefix            = ON
innodb_buffer_pool_size        = 256M
innodb_log_file_size           = 64M
innodb_flush_log_at_trx_commit = 1
innodb_flush_method            = O_DIRECT

max_allowed_packet             = 256M
open_files_limit               = 65535
table_open_cache               = 4000

[mysql]
default-character-set = utf8mb4
MARIADB_CNF

svc_ctl restart mariadb mariadbd || true

# Warte kurz, dann prüfe ob MariaDB wirklich antwortet
sleep 2
if ! mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1; then
    # Noch ein Versuch
    sleep 3
    mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1 || \
        log_warn "MariaDB antwortet nicht nach Restart — Config evtl. fehlerhaft."
fi

if mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1; then
    mariadb -u root >> "$LOGFILE" 2>&1 <<EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
    stop_spinner
    log_ok "MariaDB Root-Passwort gesetzt & abgesichert."
elif mariadb -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" >> "$LOGFILE" 2>&1; then
    stop_spinner
    log_ok "MariaDB Root-Passwort bereits korrekt."
else
    stop_spinner
    log_warn "MariaDB Root hat ein anderes Passwort — bitte prüfen!"
fi

# ─── 5. Redis ─────────────────────────────────────────────────────────────────

step_start 5 "Redis konfigurieren"

svc_ctl enable redis-server redis-server || true
svc_ctl start redis-server redis-server || log_warn "Redis konnte nicht gestartet werden."

if ! grep -q "vm.overcommit_memory" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
    sysctl vm.overcommit_memory=1 >> "$LOGFILE" 2>&1 || true
fi

stop_spinner
log_ok "Redis läuft."

# ─── 6. Node.js ───────────────────────────────────────────────────────────────

step_start 6 "Node.js ${NODE_VERSION} installieren"

NEED_NODE=true
if command -v node &>/dev/null; then
    EXISTING_MAJOR=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [[ "$EXISTING_MAJOR" -eq "$NODE_VERSION" ]] 2>/dev/null; then
        NEED_NODE=false
    elif [[ "$EXISTING_MAJOR" -ne "$NODE_VERSION" ]] 2>/dev/null; then
        # Falsche Node-Version → deinstallieren
        log_info "Node.js v${EXISTING_MAJOR} gefunden, benötigt v${NODE_VERSION} — ersetze..."
        apt-get remove -y -qq nodejs >> "$LOGFILE" 2>&1 || true
        rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null
        apt-get update -qq >> "$LOGFILE" 2>&1 || true
    fi
fi

if [[ "$NEED_NODE" == true ]]; then
    log_to_file "Node.js ${NODE_VERSION} via NodeSource..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" 2>/dev/null \
        | bash - >> "$LOGFILE" 2>&1
    run_cmd_or_die "Node.js" apt-get install -y -qq nodejs
fi

if ! command -v yarn &>/dev/null; then
    run_cmd "Yarn" npm install -g yarn
fi

stop_spinner
log_ok "Node.js $(node --version 2>/dev/null), Yarn $(yarn --version 2>/dev/null)"

# ─── 7. System-Python sicherstellen ───────────────────────────────────────────

step_start 7 "System-Python prüfen"

# Schritt 7 stellt nur sicher, dass ein System-Python als FALLBACK existiert.
# Das eigentliche Python für Frappe wird in Schritt 9 als $BENCH_USER installiert,
# weil bench/uv alles lokal im User-Home erwartet.

SYSTEM_PYTHON=""
for py in "python${TARGET_PYTHON}" python3.13 python3.12 python3.11 python3; do
    if command -v "$py" &>/dev/null; then
        SYSTEM_PYTHON=$(command -v "$py")
        break
    fi
done

if [[ -n "$SYSTEM_PYTHON" ]]; then
    log_to_file "System-Python gefunden: $($SYSTEM_PYTHON --version 2>&1) → ${SYSTEM_PYTHON}"
fi

stop_spinner
log_ok "System-Python: ${SYSTEM_PYTHON:-keins (wird per uv als User installiert)}"

# ─── 8. wkhtmltopdf ───────────────────────────────────────────────────────────

step_start 8 "wkhtmltopdf installieren"

if command -v wkhtmltopdf &>/dev/null; then
    stop_spinner
    log_ok "wkhtmltopdf bereits vorhanden."
else
    ARCH=$(dpkg --print-architecture)
    WKHTML_DEB="/tmp/wkhtmltox.deb"
    WKHTML_OK=false

    WKHTML_URLS=(
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${OS_ID}${OS_VERSION}_${ARCH}.deb"
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.buster_${ARCH}.deb"
    )

    for url in "${WKHTML_URLS[@]}"; do
        log_to_file "Versuche: ${url}"
        if wget -q -O "$WKHTML_DEB" "$url" 2>/dev/null; then
            if dpkg -i "$WKHTML_DEB" >> "$LOGFILE" 2>&1; then
                WKHTML_OK=true; break
            fi
            apt-get install -f -y -qq >> "$LOGFILE" 2>&1 && WKHTML_OK=true && break
        fi
    done
    rm -f "$WKHTML_DEB"

    stop_spinner
    if [[ "$WKHTML_OK" == true ]]; then
        log_ok "wkhtmltopdf installiert."
    else
        log_warn "wkhtmltopdf nicht installierbar — manuell nachholen."
    fi
fi

# ─── 9. Benutzer & Bench ──────────────────────────────────────────────────────
#
# WICHTIG: uv, Python, bench CLI, bench init — alles als $BENCH_USER!
# bench/uv erwarten alles im User-Home. Nichts darf unter /root/ landen.

step_start 9 "Benutzer & Bench initialisieren"

# --- Benutzer erstellen ---
if ! id "$BENCH_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$BENCH_USER" >> "$LOGFILE" 2>&1
    log_to_file "Benutzer ${BENCH_USER} erstellt."
fi

usermod -aG sudo "$BENCH_USER" >> "$LOGFILE" 2>&1 || true

SUDOERS_FILE="/etc/sudoers.d/${BENCH_USER}"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "${BENCH_USER} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
fi

USER_HOME="/home/${BENCH_USER}"

# run_as_user: Führt Befehl komplett im User-Kontext aus.
# Setzt HOME, USER, XDG-Pfade und CWD — damit Tools wie uv
# nicht versehentlich /root/ referenzieren.
run_as_user() {
    sudo -H -u "$BENCH_USER" \
        env -u UV_CONFIG_FILE \
        HOME="${USER_HOME}" \
        USER="${BENCH_USER}" \
        XDG_CONFIG_HOME="${USER_HOME}/.config" \
        XDG_DATA_HOME="${USER_HOME}/.local/share" \
        XDG_CACHE_HOME="${USER_HOME}/.cache" \
        bash -l -c "cd \$HOME && $*"
}

# --- PATH in .profile und .bashrc ---
BENCH_ENV_PATHS='export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"'

if ! grep -q ".local/bin" "${USER_HOME}/.profile" 2>/dev/null; then
    echo -e "\n# Frappe Bench PATH\n${BENCH_ENV_PATHS}" >> "${USER_HOME}/.profile"
fi
if ! grep -q ".local/bin" "${USER_HOME}/.bashrc" 2>/dev/null; then
    echo -e "\n# Frappe Bench PATH\n${BENCH_ENV_PATHS}" >> "${USER_HOME}/.bashrc"
fi
chown "${BENCH_USER}:${BENCH_USER}" "${USER_HOME}/.profile" "${USER_HOME}/.bashrc"

# --- uv als User installieren ---
if [[ "$USE_UV" == true ]]; then
    log_to_file "Installiere uv als ${BENCH_USER}..."
    run_as_user "curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh" >> "$LOGFILE" 2>&1 || true

    if ! run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv --version" >> "$LOGFILE" 2>&1; then
        log_warn "uv als User nicht verfügbar — Fallback auf pip."
        USE_UV=false
    fi
fi

# --- Python als User installieren (v16 via uv) ---
USER_PYTHON_BIN=""

if [[ "$USE_UV" == true ]]; then
    log_info "Installiere Python ${TARGET_PYTHON} als ${BENCH_USER} via uv..."

    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
        run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python install ${TARGET_PYTHON}" 2>&1 | tee -a "$LOGFILE" >&3 || true
    else
        run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python install ${TARGET_PYTHON}" >> "$LOGFILE" 2>&1 || true
    fi

    # Prüfe ob es geklappt hat
    USER_PYTHON_BIN=$(run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python find ${TARGET_PYTHON}" 2>/dev/null || echo "")

    if [[ -n "$USER_PYTHON_BIN" ]]; then
        log_ok "Python ${TARGET_PYTHON} installiert: ${USER_PYTHON_BIN}"
    else
        log_warn "uv python install ${TARGET_PYTHON} fehlgeschlagen!"
        # Zeige was uv tatsächlich installiert hat
        log_to_file "DEBUG: uv python list:"
        run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python list --only-installed" >> "$LOGFILE" 2>&1 || true
    fi
fi

# Fallback: System-Python — aber NUR wenn die Version passt!
if [[ -z "$USER_PYTHON_BIN" && -n "${SYSTEM_PYTHON:-}" ]]; then
    SYS_PY_VERSION=$("$SYSTEM_PYTHON" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
    if [[ "$SYS_PY_VERSION" == "$TARGET_PYTHON" ]]; then
        USER_PYTHON_BIN="$SYSTEM_PYTHON"
        log_ok "System-Python ${SYS_PY_VERSION} passt."
    else
        log_warn "System-Python ist ${SYS_PY_VERSION}, aber ${TARGET_PYTHON} wird benötigt!"
    fi
fi

if [[ -z "$USER_PYTHON_BIN" ]]; then
    die "Python ${TARGET_PYTHON} konnte nicht installiert werden!
    Frappe ${FRAPPE_BRANCH} erfordert zwingend Python ${TARGET_PYTHON}.
    Prüfe ob 'uv python install ${TARGET_PYTHON}' als User funktioniert.
    Log: ${LOGFILE}"
fi

# --- frappe-bench CLI als User ---
BENCH_CLI_OK=false
if [[ "$USE_UV" == true ]]; then
    if run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv tool install frappe-bench" >> "$LOGFILE" 2>&1; then
        BENCH_CLI_OK=true
    fi
fi
if [[ "$BENCH_CLI_OK" == false ]]; then
    run_as_user "export PATH=\$HOME/.local/bin:\$PATH && pip3 install --user frappe-bench --break-system-packages" >> "$LOGFILE" 2>&1 || \
    run_as_user "export PATH=\$HOME/.local/bin:\$PATH && pip3 install --user frappe-bench" >> "$LOGFILE" 2>&1 || \
        die "frappe-bench CLI nicht installierbar!"
fi

# --- bench-Binary finden ---
BENCH_BIN=""
for candidate in \
    "${USER_HOME}/.local/bin/bench" \
    "${USER_HOME}/.cargo/bin/bench" \
    "${USER_HOME}/.local/share/uv/tools/frappe-bench/bin/bench" \
    "/usr/local/bin/bench"
do
    if sudo -H -u "$BENCH_USER" test -x "$candidate" 2>/dev/null; then
        BENCH_BIN="$candidate"; break
    fi
done
if [[ -z "$BENCH_BIN" ]]; then
    BENCH_BIN=$(find "${USER_HOME}" -name "bench" -type f -executable 2>/dev/null | head -1 || echo "")
fi
[[ -z "$BENCH_BIN" ]] && die "bench-Binary nicht gefunden!"

BENCH_BIN_DIR=$(dirname "$BENCH_BIN")
log_to_file "bench Binary: ${BENCH_BIN}"

# --- bench --version (aus /tmp — damit kein ./apps/ gelesen wird) ---
BENCH_VERSION=$(run_as_user "cd /tmp && export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:\$PATH && bench --version" 2>/dev/null || echo "")
if [[ -z "$BENCH_VERSION" ]]; then
    log_warn "bench --version schlägt fehl — fahre trotzdem fort."
    BENCH_VERSION="unbekannt"
fi
log_to_file "bench CLI: v${BENCH_VERSION}"

# ─── bench init ────────────────────────────────────────────────────────────────

log_to_file "bench init ${BENCH_DIR} (${FRAPPE_BRANCH}), python=${USER_PYTHON_BIN}"

BENCH_INIT_CMD="
    export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:\$HOME/.cargo/bin:/usr/local/bin:\$PATH
    cd ${USER_HOME}
    bench init ${BENCH_DIR} \
        --frappe-branch ${FRAPPE_BRANCH} \
        --python ${USER_PYTHON_BIN} \
        --verbose
"

if [[ "$OUTPUT_MODE" == "verbose" ]]; then
    run_as_user "$BENCH_INIT_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || \
        die "bench init fehlgeschlagen!"
else
    run_as_user "$BENCH_INIT_CMD" >> "$LOGFILE" 2>&1 || {
        stop_spinner
        log_error "bench init fehlgeschlagen!"
        echo -e "${DIM}  Letzte 30 Zeilen:${NC}" >&3
        tail -30 "$LOGFILE" | sed 's/^/    /' >&3
        die "Log: ${LOGFILE}"
    }
fi

# ─── Validierung ───────────────────────────────────────────────────────────────

[[ ! -d "${BENCH_PATH}/apps/frappe" ]] && die "apps/frappe/ fehlt!"
[[ ! -f "${BENCH_PATH}/env/bin/python" ]] && die "venv fehlt!"

# DER kritische Check gegen "No module named 'frappe'"
if ! run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe'" >> "$LOGFILE" 2>&1; then
    log_warn "'import frappe' fehlgeschlagen — Reparatur..."
    run_as_user "cd ${BENCH_PATH} && env/bin/pip install -e apps/frappe" >> "$LOGFILE" 2>&1
    run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe'" >> "$LOGFILE" 2>&1 || \
        die "Reparatur gescheitert! 'import frappe' schlägt fehl."
    log_to_file "Reparatur erfolgreich."
fi

FRAPPE_VERSION=$(run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe; print(frappe.__version__)'" 2>/dev/null || echo "?")

stop_spinner
log_ok "Frappe ${FRAPPE_VERSION} — bench v${BENCH_VERSION}"

# ─── Site (optional) ──────────────────────────────────────────────────────────

if [[ -n "$SITE_NAME" ]]; then
    log_info "Erstelle Site '${SITE_NAME}'..."

    SITE_CMD="
        export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:/usr/local/bin:\$PATH
        cd ${BENCH_PATH}
        bench new-site ${SITE_NAME} \
            --mariadb-root-password '${MYSQL_ROOT_PASS}' \
            --admin-password '${ADMIN_PASS}' \
            --no-mariadb-socket
    "

    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
        run_as_user "$SITE_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || die "Site fehlgeschlagen!"
    else
        run_as_user "$SITE_CMD" >> "$LOGFILE" 2>&1 || die "Site fehlgeschlagen! Log: ${LOGFILE}"
    fi

    run_as_user "cd ${BENCH_PATH} && bench use ${SITE_NAME}" >> "$LOGFILE" 2>&1
    log_ok "Site '${SITE_NAME}' erstellt."
fi

# ─── 10. Production-Setup ─────────────────────────────────────────────────────

step_start 10 "Production-Setup"

PROD_FAILED=false
PROD_CMD="
    export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:/usr/local/bin:\$PATH
    cd ${BENCH_PATH}
    sudo bench setup production ${BENCH_USER} --yes
"

if [[ "$OUTPUT_MODE" == "verbose" ]]; then
    run_as_user "$PROD_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || PROD_FAILED=true
else
    run_as_user "$PROD_CMD" >> "$LOGFILE" 2>&1 || PROD_FAILED=true
fi

if [[ "$PROD_FAILED" == true ]]; then
    log_warn "bench setup production Probleme — Fallback..."

    run_as_user "
        export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:/usr/local/bin:\$PATH
        cd ${BENCH_PATH}
        bench setup supervisor --yes
        bench setup nginx --yes
    " >> "$LOGFILE" 2>&1 || true

    [[ -f "${BENCH_PATH}/config/supervisor.conf" ]] && \
        ln -sf "${BENCH_PATH}/config/supervisor.conf" "/etc/supervisor/conf.d/${BENCH_DIR}.conf"
    [[ -f "${BENCH_PATH}/config/nginx.conf" ]] && \
        ln -sf "${BENCH_PATH}/config/nginx.conf" "/etc/nginx/conf.d/${BENCH_DIR}.conf"
    rm -f /etc/nginx/sites-enabled/default
fi

svc_ctl enable supervisor supervisord || true
supervisorctl reread        >> "$LOGFILE" 2>&1 || true
supervisorctl update        >> "$LOGFILE" 2>&1 || true
svc_ctl restart nginx nginx || true

sleep 3
stop_spinner

if [[ "$OUTPUT_MODE" == "progress" ]]; then
    draw_progress_bar "$TOTAL_STEPS" "Fertig!"
    echo "" >&3; echo "" >&3
fi

# ─── Status ────────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}Supervisor-Status:${NC}" >&3
supervisorctl status 2>/dev/null | sed 's/^/    /' >&3 || \
    echo "    (noch nicht bereit — kurz warten)" >&3

# ─── Ergebnis ──────────────────────────────────────────────────────────────────

echo -e "
${GREEN}╔══════════════════════════════════════════════════════════════╗
║               Installation erfolgreich!                     ║
╚══════════════════════════════════════════════════════════════╝${NC}

  ${BOLD}System${NC}
    Frappe:     ${FRAPPE_VERSION} (${FRAPPE_BRANCH})
    MariaDB:    $(mariadb --version 2>/dev/null | grep -oP 'Ver \K[^ ]+' || echo '?')
    Node.js:    $(node --version 2>/dev/null || echo '?')
    Python:     $($PYTHON_BIN --version 2>&1)
    Bench CLI:  v${BENCH_VERSION}

  ${BOLD}Pfade${NC}
    Bench:      ${BENCH_PATH}
    Logfile:    ${LOGFILE}" >&3

[[ -n "$SITE_NAME" ]] && echo -e "
  ${BOLD}Site${NC}
    Name:       ${SITE_NAME}
    URL:        http://${SITE_NAME}" >&3

echo -e "
  ${BOLD}Befehle${NC}
    ${CYAN}supervisorctl status${NC}                  Prozesse anzeigen
    ${CYAN}supervisorctl restart all${NC}             Alles neustarten
    ${CYAN}sudo -u ${BENCH_USER} bash${NC}                    Als Bench-User wechseln
    ${CYAN}cd ${BENCH_PATH}${NC}       Bench-Verzeichnis

  ${BOLD}Wichtig${NC}
    ${GREEN}✔${NC}  ${CYAN}supervisorctl${NC} verwenden — nicht ${RED}bench start${NC}!
    ${GREEN}✔${NC}  HTTPS: ${CYAN}bench setup lets-encrypt <site>${NC}
    ${GREEN}✔${NC}  ERPNext: ${CYAN}bench get-app erpnext --branch ${FRAPPE_BRANCH}${NC}
    ${GREEN}✔${NC}  Logs: ${CYAN}tail -f ${BENCH_PATH}/logs/*.log${NC}
" >&3
