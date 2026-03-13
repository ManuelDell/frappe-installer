#!/usr/bin/env bash
###############################################################################
#  install_frappe_bench.sh — Frappe Bench Installation Script
#  Platform: Debian 12+ / Ubuntu 22.04+ (incl. LXC containers)
#  Supports: Frappe v15 (stable) and v16 (develop)
#  Run as:   root
#
#  Author: Dells Dienste  |  Date: 2026-03-13
###############################################################################

set -euo pipefail

# ─── Logfile ──────────────────────────────────────────────────────────────────

LOGFILE="/var/log/install_frappe_bench_$(date +%Y%m%d_%H%M%S).log"
touch "$LOGFILE"
exec 3>&1 4>&2

log_to_file() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
SPINNER_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
OUTPUT_MODE="progress"

# ─── Output ───────────────────────────────────────────────────────────────────

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

# ─── Spinner & Progress ───────────────────────────────────────────────────────

TOTAL_STEPS=10; CURRENT_STEP=0; SPINNER_PID=""

draw_progress_bar() {
    local step="$1" label="$2"
    local pct=$(( step * 100 / TOTAL_STEPS ))
    local filled=$(( step * 30 / TOTAL_STEPS )) empty=$(( 30 - step * 30 / TOTAL_STEPS ))
    local bar="" i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty;  i++)); do bar+="░"; done
    echo -ne "\r  ${BOLD}[${GREEN}${bar}${NC}${BOLD}] ${pct}%${NC}  ${CYAN}${label}${NC}    \033[K" >&3
}

start_spinner() {
    local label="$1"
    [[ "$OUTPUT_MODE" != "progress" ]] && return
    ( local i=0
      while true; do
          echo -ne "\r    ${CYAN}${SPINNER_CHARS[$i]}${NC} ${DIM}${label}${NC}    \033[K" >&3
          i=$(( (i+1) % ${#SPINNER_CHARS[@]} )); sleep 0.1
      done ) &
    SPINNER_PID=$!; disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""; echo -ne "\r\033[K" >&3
    fi
}

cleanup() { stop_spinner; exec 1>&3 2>&4 2>/dev/null || true; }
trap cleanup EXIT

step_start() {
    local n="$1" label="$2"
    CURRENT_STEP=$n; stop_spinner
    log_to_file "═══ STEP ${n}/${TOTAL_STEPS}: ${label} ═══"
    if [[ "$OUTPUT_MODE" == "progress" ]]; then
        draw_progress_bar "$n" "$label"; echo "" >&3; start_spinner "$label"
    else
        echo -e "\n${BOLD}━━━ ${n}/${TOTAL_STEPS} — ${label} ━━━${NC}" >&3
    fi
}

# ─── Command wrapper ──────────────────────────────────────────────────────────

run_cmd() {
    local desc="$1"; shift; log_to_file "CMD: $*"
    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
        if "$@" 2>&1 | tee -a "$LOGFILE" >&3; then return 0
        else local rc=$?; log_error "${desc} (rc=${rc})"; return $rc; fi
    else
        if "$@" >> "$LOGFILE" 2>&1; then return 0
        else
            local rc=$?; stop_spinner; log_error "${desc} (rc=${rc})"
            echo -e "${DIM}  ${T_LASTLINES}:${NC}" >&3
            tail -10 "$LOGFILE" | sed 's/^/    /' >&3
            start_spinner "${T_CONTINUING}..."; return $rc
        fi
    fi
}

run_cmd_or_die() { local d="$1"; shift; run_cmd "$d" "$@" || die "${d} — ${T_ABORT} Log: ${LOGFILE}"; }

# ─── Service controller (LXC-safe) ────────────────────────────────────────────

svc_ctl() {
    local action="$1" service="$2" proc="${3:-$2}"
    log_to_file "SVC: systemctl ${action} ${service}"
    if systemctl "$action" "$service" >> "$LOGFILE" 2>&1; then return 0; fi
    local rc=$?; log_to_file "SVC WARN: rc=${rc}"
    [[ "$action" == "enable" ]] && return 0
    if [[ "$action" == "stop" ]]; then
        sleep 1; ! pgrep -x "$proc" > /dev/null 2>&1 && return 0; return 1
    fi
    sleep 2
    pgrep -x "$proc" > /dev/null 2>&1 && return 0
    service "$service" "$action" >> "$LOGFILE" 2>&1 && sleep 2 && pgrep -x "$proc" > /dev/null 2>&1 && return 0
    if [[ "$action" =~ ^(start|restart)$ ]]; then
        case "$service" in
            mariadb|mysql)
                mariadbd --user=mysql >> "$LOGFILE" 2>&1 &
                sleep 3; pgrep -x "mariadbd" > /dev/null 2>&1 && return 0 ;;
            redis-server)
                redis-server /etc/redis/redis.conf >> "$LOGFILE" 2>&1 &
                sleep 2; pgrep -x "redis-server" > /dev/null 2>&1 && return 0 ;;
        esac
    fi
    return 1
}

# ─── Package installer ────────────────────────────────────────────────────────

FAILED_PKGS=(); INSTALLED_PKGS=()

install_pkg() {
    local mode="$1"; shift
    for pkg in "$@"; do
        log_to_file "pkg: ${pkg} (${mode})"
        if apt-get install -y -qq "$pkg" >> "$LOGFILE" 2>&1; then
            INSTALLED_PKGS+=("$pkg")
        else
            [[ "$mode" == "required" ]] && log_warn "${T_PKG_UNAVAIL}: ${pkg}"
            FAILED_PKGS+=("$pkg")
        fi
    done
}

# ─── Password generator ───────────────────────────────────────────────────────

generate_password() { (set +o pipefail; tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 20); }

# ─── Root check ───────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then echo -e "${RED}  ✘  Run as root: sudo bash $0${NC}"; exit 1; fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo unknown)}"
else
    echo -e "${RED}  ✘  /etc/os-release missing.${NC}"; exit 1
fi
case "$OS_ID" in debian|ubuntu) ;; *) echo -e "${RED}  ✘  Debian/Ubuntu only (found: ${OS_ID}).${NC}"; exit 1 ;; esac

# ═══════════════════════════════════════════════════════════════════════════════
#  LANGUAGE SELECTION  (before everything else — no translated strings yet)
# ═══════════════════════════════════════════════════════════════════════════════

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

LANG_CODE="de"
echo -e "${BOLD}Sprache / Language:${NC}"
echo "  1) Deutsch  (Standard)"
echo "  2) English"
echo ""
while true; do
    read -rp "Auswahl / Choice [1/2] (default: 1): " _LC
    _LC="${_LC:-1}"
    case "$_LC" in
        1) LANG_CODE="de"; break ;;
        2) LANG_CODE="en"; break ;;
        *) echo "  1 or 2." ;;
    esac
done
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
#  TRANSLATION STRINGS
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$LANG_CODE" == "en" ]]; then
    # ── English ────────────────────────────────────────────────────────────────
    T_INSTALL_MODE_TITLE="Installation Mode"
    T_INSTALL_MODE_1="Interactive    — choose version, user, path, passwords yourself"
    T_INSTALL_MODE_2="Quick-Install  — fully automatic (v16, user: frappe, bench: ~/frappe-bench,"
    T_INSTALL_MODE_2B="                 site: frappe.localhost, passwords generated + saved to ~/pwd.txt)"
    T_CHOICE_DEFAULT1="Choice [1/2] (default: 1): "
    T_PLEASE_12="  Please enter 1 or 2."

    T_QUICK_ACTIVE="  Quick-Install activated:"
    T_QUICK_BRANCH="    Branch:      "
    T_QUICK_USER="    User:        "
    T_QUICK_BENCH="    Bench:       "
    T_QUICK_SITE="    Site:        "
    T_QUICK_PWDS="    Passwords:   generated automatically → "
    T_STARTS_IN="  Starting in: "
    T_ABORT_CTRL="  (Abort: Ctrl+C)"

    T_OUTPUT_TITLE="Output Mode"
    T_OUTPUT_1="1) Progress bar  — clean output, details in logfile"
    T_OUTPUT_2="2) Verbose       — everything live on terminal"

    T_VERSION_TITLE="Frappe Version"
    T_VERSION_1="1) version-15  (stable — Python 3.10+, Node 20, MariaDB 10.x)"
    T_VERSION_2="2) version-16  (develop — Python 3.14, Node 24, MariaDB 11.8)"

    T_USER_PROMPT="Linux username (e.g. frappe): "
    T_USER_INVALID="  Lowercase letters, numbers, '-', '_' only (must start with a letter)."
    T_BENCH_PROMPT="Bench folder name (in /home/USER/): "
    T_BENCH_INVALID="  Letters, numbers, '.', '-', '_' only."

    T_MYSQL_PW="MariaDB root password: "
    T_MYSQL_PW_EMPTY="  Must not be empty."
    T_MYSQL_PW_SHORT="  Min. 6 characters."
    T_MYSQL_PW_CONFIRM="  Confirm: "
    T_MYSQL_PW_MISMATCH="  Passwords do not match."
    T_MYSQL_PW_OK="MariaDB root password set."

    T_CREATE_SITE="Create a site now? [y/N]: "
    T_SITE_NAME="Site name (e.g. erp.example.com): "
    T_SITE_INVALID="  Invalid name."
    T_ADMIN_PW="Admin password: "
    T_ADMIN_PW_CONFIRM="  Confirm: "

    T_SUMMARY_TITLE="═══ Summary ═══"
    T_SUMMARY_MODE="  Mode:          "
    T_SUMMARY_MODE_PROG="Progress bar"
    T_SUMMARY_MODE_VERB="Verbose"
    T_SUMMARY_BRANCH="  Branch:        "
    T_SUMMARY_USER="  User:          "
    T_SUMMARY_PATH="  Bench path:    "
    T_SUMMARY_MYSQL="  MariaDB root:  (set)"
    T_SUMMARY_SITE="  Site:          "
    T_START_PROMPT="Start? [Y/n]: "
    T_ABORTED="Aborted."

    T_EXISTING_TITLE="  ⚠  Previous installation detected:"
    T_EXISTING_NOTE="  All existing instances and MariaDB data will be deleted."
    T_EXISTING_CONFIRM="  Continue and delete everything? [y/N]: "
    T_QUICK_AUTO="  (Quick-Install: proceeding automatically)"
    T_CLEANUP="Cleaning up..."
    T_DELETED="Deleted: "
    T_USER_ENV_CLEANED="User environment cleaned: "
    T_NODE_REMOVED="Node.js v"
    T_NODE_REMOVED2=" removed."
    T_CLEANUP_DONE="Cleanup complete."

    T_STEP1="Update system"
    T_STEP2="Install dependencies"
    T_STEP3="Install MariaDB"
    T_STEP4="Configure MariaDB"
    T_STEP5="Configure Redis"
    T_STEP6="Install Node.js"
    T_STEP7="Check system Python"
    T_STEP8="Install wkhtmltopdf"
    T_STEP9="Initialize user & bench"
    T_STEP10="Production setup"

    T_SYS_UPDATED="System updated."
    T_PKGS_INSTALLED=" packages installed."
    T_PKG_UNAVAIL="Package unavailable"
    T_PKGS_FAILED="Not installed"
    T_CRITICAL_MISSING="Critical packages missing"

    T_MARIADB_PURGE="Removing existing MariaDB (purge)..."
    T_MARIADB_PURGED="MariaDB fully removed (incl. data files)."
    T_MARIADB_RUNNING="MariaDB installed and running."
    T_MARIADB_FAIL="MariaDB could not be started!"
    T_MARIADB_PW_SET="MariaDB root password set & secured."
    T_MARIADB_PW_OK="MariaDB root password already correct."
    T_MARIADB_PW_WARN="MariaDB root has a different password — please check!"
    T_MARIADB_NO_RESPONSE="MariaDB not responding after restart — check config."
    T_MARIADB_DB_DELETE="Deleting old MariaDB databases: "
    T_MARIADB_DB_OK="DB deleted: "
    T_MARIADB_DB_FAIL="DB deletion failed: "
    T_MARIADB_CLEANUP_DONE="MariaDB cleanup complete"
    T_MARIADB_FRESH="MariaDB freshly installed and started."

    T_REDIS_RUNNING="Redis running."
    T_REDIS_FAIL="Redis could not be started."

    T_NODE_FOUND="Node.js v"
    T_NODE_FOUND2=" found, need v"
    T_NODE_FOUND3=" — replacing..."
    T_NODE_WRONG="Node.js v"
    T_NODE_WRONG2=" installed instead of v"
    T_NODE_WARN="!"

    T_SYSPY="System Python: "
    T_SYSPY_NONE="none (will be installed via uv as user)"

    T_WKHTML_EXISTS="wkhtmltopdf already present."
    T_WKHTML_OK="wkhtmltopdf installed."
    T_WKHTML_FAIL="wkhtmltopdf not installable — PDF generation limited."
    T_WKHTML_MANUAL="→ Manual: https://wkhtmltopdf.org/downloads.html"

    T_USER_CREATED="User "
    T_USER_CREATED2=" created."
    T_PWD_SAVED="Passwords saved: "
    T_UV_INSTALL="Installing uv as "
    T_UV_FAIL="uv not available as user — falling back to pip."
    T_PY_INSTALL="Installing Python "
    T_PY_INSTALL2=" as "
    T_PY_INSTALL3=" via uv..."
    T_PY_OK="Python "
    T_PY_OK2=" installed: "
    T_PY_FAIL="uv python install "
    T_PY_FAIL2=" failed!"
    T_PY_EXACT_NEED="System Python is "
    T_PY_EXACT_NEED2=", but exactly "
    T_PY_EXACT_NEED3=" is required!"
    T_PY_FITS="System Python "
    T_PY_FITS2=" >= "
    T_PY_FITS3=" — OK."
    T_PY_NOT_FOUND="No Python >= "
    T_PY_NOT_FOUND2=" available!"
    T_PY_DIE="Python "
    T_PY_DIE2=" could not be installed!"
    T_PY_DIE3="Frappe "
    T_PY_DIE4=" requires exactly Python "

    T_BENCH_CLI_FAIL="frappe-bench CLI could not be installed!"
    T_BENCH_BIN_FAIL="bench binary not found!"
    T_BENCH_VER_FAIL="bench --version failed — continuing."
    T_BENCH_INIT_FAIL="bench init failed!"
    T_BENCH_LASTLINES="Last 30 lines"
    T_BENCH_REPAIR="'import frappe' failed — repairing..."
    T_BENCH_REPAIR_FAIL="Repair failed! Log: "
    T_BENCH_REPAIR_OK="Repair successful."
    T_BENCH_OK="Frappe "
    T_APPS_MISSING="apps/frappe/ missing!"
    T_VENV_MISSING="venv missing!"

    T_SITE_CREATING="Creating site '"
    T_SITE_CREATING2="'..."
    T_SITE_FAIL="Site creation failed!"
    T_SITE_FAIL2="Site creation failed! Log: "
    T_SITE_OK="Site '"
    T_SITE_OK2="' created."

    T_PROD_FAIL="bench setup production issues — falling back..."
    T_NGINX_BAD="Nginx config invalid — check: nginx -t"
    T_DONE="Done!"

    T_RESULT_TITLE="Installation successful!"
    T_RESULT_SYSTEM="System"
    T_RESULT_PATHS="Paths"
    T_RESULT_BENCH="Bench:      "
    T_RESULT_LOG="Logfile:    "
    T_RESULT_SITE="Site"
    T_RESULT_NAME="Name:       "
    T_RESULT_LOGIN="Login:      Administrator / (see below)"
    T_RESULT_WEB="Website"
    T_RESULT_WEB_HINT="Available at "
    T_RESULT_WEB_HINT2=" once a site is created:"
    T_RESULT_PW_TITLE="⚠  Passwords (also in "
    T_RESULT_PW_TITLE2="):"
    T_RESULT_PW_DB="MariaDB Root : "
    T_RESULT_PW_ADMIN="Admin        : "
    T_RESULT_PW_HINT="→ Delete this file after saving: rm "
    T_RESULT_CMDS="Commands"
    T_RESULT_CMD1="Show processes"
    T_RESULT_CMD2="Restart everything"
    T_RESULT_CMD3="Switch to bench user"
    T_RESULT_CMD4="Bench directory"
    T_RESULT_IMPORTANT="Important"
    T_RESULT_IMP1="Use supervisorctl — not bench start!"
    T_RESULT_IMP2="HTTPS: "
    T_RESULT_IMP3="ERPNext: "
    T_RESULT_IMP4="Logs: "
    T_SUPERVISOR_STATUS="Supervisor status:"
    T_SUPERVISOR_WAIT="(not ready yet — wait a moment)"

    T_LASTLINES="Last log lines"
    T_CONTINUING="Continuing"
    T_ABORT="Abort."
    T_PWD_HEADER="# Frappe Bench — Generated Passwords"
    T_PWD_CREATED="# Created: "
    T_PWD_WARN="# !! IMPORTANT: Keep this file safe and delete it afterwards !!"
    T_PWD_LOGIN="Login"

else
    # ── Deutsch ────────────────────────────────────────────────────────────────
    T_INSTALL_MODE_TITLE="Installations-Modus"
    T_INSTALL_MODE_1="Interaktiv     — Frappe-Version, Benutzer, Pfad, Passwörter selbst wählen"
    T_INSTALL_MODE_2="Quick-Install  — Vollautomatisch (v16, user: frappe, bench: ~/frappe-bench,"
    T_INSTALL_MODE_2B="                 site: frappe.localhost, Passwörter generiert + in ~/pwd.txt)"
    T_CHOICE_DEFAULT1="Auswahl [1/2] (Standard: 1): "
    T_PLEASE_12="  Bitte 1 oder 2."

    T_QUICK_ACTIVE="  Quick-Install aktiviert:"
    T_QUICK_BRANCH="    Branch:      "
    T_QUICK_USER="    Benutzer:    "
    T_QUICK_BENCH="    Bench:       "
    T_QUICK_SITE="    Site:        "
    T_QUICK_PWDS="    Passwörter:  werden automatisch generiert → "
    T_STARTS_IN="  Startet in: "
    T_ABORT_CTRL="  (Abbruch: Ctrl+C)"

    T_OUTPUT_TITLE="Ausgabe-Modus"
    T_OUTPUT_1="1) Fortschrittsbalken  — sauber, Details im Logfile"
    T_OUTPUT_2="2) Verbose             — alles live auf dem Terminal"

    T_VERSION_TITLE="Frappe-Version"
    T_VERSION_1="1) version-15  (stable — Python 3.10+, Node 20, MariaDB 10.x)"
    T_VERSION_2="2) version-16  (develop — Python 3.14, Node 24, MariaDB 11.8)"

    T_USER_PROMPT="Linux-Benutzername (z.B. frappe): "
    T_USER_INVALID="  Nur Kleinbuchstaben, Zahlen, '-', '_' (Anfang: Buchstabe)."
    T_BENCH_PROMPT="Bench-Ordnername (in /home/USER/): "
    T_BENCH_INVALID="  Nur Buchstaben, Zahlen, '.', '-', '_'."

    T_MYSQL_PW="MariaDB Root-Passwort: "
    T_MYSQL_PW_EMPTY="  Darf nicht leer sein."
    T_MYSQL_PW_SHORT="  Min. 6 Zeichen."
    T_MYSQL_PW_CONFIRM="  Bestätigen: "
    T_MYSQL_PW_MISMATCH="  Stimmt nicht überein."
    T_MYSQL_PW_OK="MariaDB Root-Passwort gesetzt."

    T_CREATE_SITE="Gleich eine Site erstellen? [j/N]: "
    T_SITE_NAME="Site-Name (z.B. erp.example.com): "
    T_SITE_INVALID="  Ungültiger Name."
    T_ADMIN_PW="Admin-Passwort: "
    T_ADMIN_PW_CONFIRM="  Bestätigen: "

    T_SUMMARY_TITLE="═══ Zusammenfassung ═══"
    T_SUMMARY_MODE="  Modus:         "
    T_SUMMARY_MODE_PROG="Fortschrittsbalken"
    T_SUMMARY_MODE_VERB="Verbose"
    T_SUMMARY_BRANCH="  Branch:        "
    T_SUMMARY_USER="  Benutzer:      "
    T_SUMMARY_PATH="  Bench-Pfad:    "
    T_SUMMARY_MYSQL="  MariaDB Root:  (gesetzt)"
    T_SUMMARY_SITE="  Site:          "
    T_START_PROMPT="Starten? [J/n]: "
    T_ABORTED="Abgebrochen."

    T_EXISTING_TITLE="  ⚠  Vorherige Installation erkannt:"
    T_EXISTING_NOTE="  Alle bestehenden Instanzen und MariaDB-Daten werden gelöscht."
    T_EXISTING_CONFIRM="  Fortfahren und alles löschen? [j/N]: "
    T_QUICK_AUTO="  (Quick-Install: automatisch fortfahren)"
    T_CLEANUP="Räume auf..."
    T_DELETED="Gelöscht: "
    T_USER_ENV_CLEANED="User-Environment bereinigt: "
    T_NODE_REMOVED="Node.js v"
    T_NODE_REMOVED2=" entfernt."
    T_CLEANUP_DONE="Aufräumen abgeschlossen."

    T_STEP1="System aktualisieren"
    T_STEP2="Abhängigkeiten installieren"
    T_STEP3="MariaDB installieren"
    T_STEP4="MariaDB konfigurieren"
    T_STEP5="Redis konfigurieren"
    T_STEP6="Node.js installieren"
    T_STEP7="System-Python prüfen"
    T_STEP8="wkhtmltopdf installieren"
    T_STEP9="Benutzer & Bench initialisieren"
    T_STEP10="Production-Setup"

    T_SYS_UPDATED="System aktualisiert."
    T_PKGS_INSTALLED=" Pakete installiert."
    T_PKG_UNAVAIL="Paket nicht verfügbar"
    T_PKGS_FAILED="Nicht installiert"
    T_CRITICAL_MISSING="Kritische Pakete fehlen"

    T_MARIADB_PURGE="Bestehende MariaDB wird entfernt (purge)..."
    T_MARIADB_PURGED="MariaDB vollständig entfernt (inkl. Datendateien)."
    T_MARIADB_RUNNING="MariaDB installiert und läuft."
    T_MARIADB_FAIL="MariaDB konnte nicht gestartet werden!"
    T_MARIADB_PW_SET="MariaDB Root-Passwort gesetzt & abgesichert."
    T_MARIADB_PW_OK="MariaDB Root-Passwort bereits korrekt."
    T_MARIADB_PW_WARN="MariaDB Root hat ein anderes Passwort — bitte prüfen!"
    T_MARIADB_NO_RESPONSE="MariaDB antwortet nicht nach Restart — Config evtl. fehlerhaft."
    T_MARIADB_DB_DELETE="Lösche alte MariaDB-Datenbanken: "
    T_MARIADB_DB_OK="DB gelöscht: "
    T_MARIADB_DB_FAIL="DB löschen fehlgeschlagen: "
    T_MARIADB_CLEANUP_DONE="MariaDB-Cleanup abgeschlossen"
    T_MARIADB_FRESH="MariaDB frisch installiert und gestartet."

    T_REDIS_RUNNING="Redis läuft."
    T_REDIS_FAIL="Redis konnte nicht gestartet werden."

    T_NODE_FOUND="Node.js v"
    T_NODE_FOUND2=" gefunden, benötigt v"
    T_NODE_FOUND3=" — ersetze..."
    T_NODE_WRONG="Node.js v"
    T_NODE_WRONG2=" installiert statt v"
    T_NODE_WARN="!"

    T_SYSPY="System-Python: "
    T_SYSPY_NONE="keins (wird per uv als User installiert)"

    T_WKHTML_EXISTS="wkhtmltopdf bereits vorhanden."
    T_WKHTML_OK="wkhtmltopdf installiert."
    T_WKHTML_FAIL="wkhtmltopdf nicht installierbar — PDF-Generierung eingeschränkt."
    T_WKHTML_MANUAL="→ Manuell: https://wkhtmltopdf.org/downloads.html"

    T_USER_CREATED="Benutzer "
    T_USER_CREATED2=" erstellt."
    T_PWD_SAVED="Passwörter gespeichert: "
    T_UV_INSTALL="Installiere uv als "
    T_UV_FAIL="uv als User nicht verfügbar — Fallback auf pip."
    T_PY_INSTALL="Installiere Python "
    T_PY_INSTALL2=" als "
    T_PY_INSTALL3=" via uv..."
    T_PY_OK="Python "
    T_PY_OK2=" installiert: "
    T_PY_FAIL="uv python install "
    T_PY_FAIL2=" fehlgeschlagen!"
    T_PY_EXACT_NEED="System-Python ist "
    T_PY_EXACT_NEED2=", aber exakt "
    T_PY_EXACT_NEED3=" wird benötigt!"
    T_PY_FITS="System-Python "
    T_PY_FITS2=" >= "
    T_PY_FITS3=" — passt."
    T_PY_NOT_FOUND="Kein Python >= "
    T_PY_NOT_FOUND2=" verfügbar!"
    T_PY_DIE="Python "
    T_PY_DIE2=" konnte nicht installiert werden!"
    T_PY_DIE3="Frappe "
    T_PY_DIE4=" erfordert zwingend Python "

    T_BENCH_CLI_FAIL="frappe-bench CLI nicht installierbar!"
    T_BENCH_BIN_FAIL="bench-Binary nicht gefunden!"
    T_BENCH_VER_FAIL="bench --version schlägt fehl — fahre fort."
    T_BENCH_INIT_FAIL="bench init fehlgeschlagen!"
    T_BENCH_LASTLINES="Letzte 30 Zeilen"
    T_BENCH_REPAIR="'import frappe' fehlgeschlagen — Reparatur..."
    T_BENCH_REPAIR_FAIL="Reparatur gescheitert! Log: "
    T_BENCH_REPAIR_OK="Reparatur erfolgreich."
    T_BENCH_OK="Frappe "
    T_APPS_MISSING="apps/frappe/ fehlt!"
    T_VENV_MISSING="venv fehlt!"

    T_SITE_CREATING="Erstelle Site '"
    T_SITE_CREATING2="'..."
    T_SITE_FAIL="Site fehlgeschlagen!"
    T_SITE_FAIL2="Site fehlgeschlagen! Log: "
    T_SITE_OK="Site '"
    T_SITE_OK2="' erstellt."

    T_PROD_FAIL="bench setup production Probleme — Fallback..."
    T_NGINX_BAD="Nginx-Config fehlerhaft — prüfe: nginx -t"
    T_DONE="Fertig!"

    T_RESULT_TITLE="Installation erfolgreich!"
    T_RESULT_SYSTEM="System"
    T_RESULT_PATHS="Pfade"
    T_RESULT_BENCH="Bench:      "
    T_RESULT_LOG="Logfile:    "
    T_RESULT_SITE="Site"
    T_RESULT_NAME="Name:       "
    T_RESULT_LOGIN="Login:      Administrator / (siehe unten)"
    T_RESULT_WEB="Website"
    T_RESULT_WEB_HINT="Erreichbar unter "
    T_RESULT_WEB_HINT2=" sobald eine Site erstellt wird:"
    T_RESULT_PW_TITLE="⚠  Passwörter (auch in "
    T_RESULT_PW_TITLE2="):"
    T_RESULT_PW_DB="MariaDB Root : "
    T_RESULT_PW_ADMIN="Admin        : "
    T_RESULT_PW_HINT="→ Datei nach dem Speichern löschen: rm "
    T_RESULT_CMDS="Befehle"
    T_RESULT_CMD1="Prozesse anzeigen"
    T_RESULT_CMD2="Alles neustarten"
    T_RESULT_CMD3="Als Bench-User wechseln"
    T_RESULT_CMD4="Bench-Verzeichnis"
    T_RESULT_IMPORTANT="Wichtig"
    T_RESULT_IMP1="supervisorctl verwenden — nicht bench start!"
    T_RESULT_IMP2="HTTPS: "
    T_RESULT_IMP3="ERPNext: "
    T_RESULT_IMP4="Logs: "
    T_SUPERVISOR_STATUS="Supervisor-Status:"
    T_SUPERVISOR_WAIT="(noch nicht bereit — kurz warten)"

    T_LASTLINES="Letzte Log-Zeilen"
    T_CONTINUING="Fortfahren"
    T_ABORT="Abbruch."
    T_PWD_HEADER="# Frappe Bench — Generierte Passwörter"
    T_PWD_CREATED="# Erstellt: "
    T_PWD_WARN="# !! WICHTIG: Diese Datei sicher aufbewahren und danach löschen !!"
    T_PWD_LOGIN="Login"
fi

# Helper for yes/no input (handles j/y for DE, y for EN)
is_yes() {
    local val="${1,,}"
    [[ "$val" == "j" || "$val" == "y" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALLATION MODE
# ═══════════════════════════════════════════════════════════════════════════════

QUICK_INSTALL=false

echo -e "${BOLD}${T_INSTALL_MODE_TITLE}:${NC}"
echo "  1) ${T_INSTALL_MODE_1}"
echo "  2) ${T_INSTALL_MODE_2}"
echo "     ${T_INSTALL_MODE_2B}"
echo ""
while true; do
    read -rp "${T_CHOICE_DEFAULT1}" _MC; _MC="${_MC:-1}"
    case "$_MC" in 1) QUICK_INSTALL=false; break ;; 2) QUICK_INSTALL=true; break ;; *) echo "${T_PLEASE_12}" ;; esac
done
echo ""

# ─── Quick-Install defaults ───────────────────────────────────────────────────

if [[ "$QUICK_INSTALL" == true ]]; then
    OUTPUT_MODE="progress"
    FRAPPE_BRANCH="version-16"
    BENCH_USER="frappe"
    BENCH_DIR="frappe-bench"
    BENCH_PATH="/home/${BENCH_USER}/${BENCH_DIR}"
    SITE_NAME="frappe.localhost"
    MYSQL_ROOT_PASS=$(generate_password)
    ADMIN_PASS=$(generate_password)
    PWD_FILE="/home/${BENCH_USER}/pwd.txt"

    echo -e "${GREEN}${BOLD}${T_QUICK_ACTIVE}${NC}"
    echo -e "${T_QUICK_BRANCH}${FRAPPE_BRANCH}"
    echo -e "${T_QUICK_USER}${BENCH_USER}"
    echo -e "${T_QUICK_BENCH}${BENCH_PATH}"
    echo -e "${T_QUICK_SITE}${SITE_NAME}"
    echo -e "${T_QUICK_PWDS}${PWD_FILE}"
    echo ""
    echo -ne "  ${T_STARTS_IN}"
    for i in 3 2 1; do echo -ne "${BOLD}${i}${NC}${DIM}... ${NC}"; sleep 1; done
    echo -e "\n${DIM}${T_ABORT_CTRL}${NC}\n"

else

    # ── Output mode ─────────────────────────────────────────────────────────────
    echo -e "${BOLD}${T_OUTPUT_TITLE}:${NC}"
    echo "  ${T_OUTPUT_1}"; echo "  ${T_OUTPUT_2}"; echo ""
    while true; do
        read -rp "${T_CHOICE_DEFAULT1}" _OC; _OC="${_OC:-1}"
        case "$_OC" in 1) OUTPUT_MODE="progress"; break ;; 2) OUTPUT_MODE="verbose"; break ;; *) echo "${T_PLEASE_12}" ;; esac
    done
    echo ""

    # ── Frappe version ──────────────────────────────────────────────────────────
    echo -e "${BOLD}${T_VERSION_TITLE}:${NC}"
    echo "  ${T_VERSION_1}"; echo "  ${T_VERSION_2}"; echo ""
    while true; do
        read -rp "${T_CHOICE_DEFAULT1}" _VC; _VC="${_VC:-1}"
        case "$_VC" in 1) FRAPPE_BRANCH="version-15"; break ;; 2) FRAPPE_BRANCH="version-16"; break ;; *) echo "${T_PLEASE_12}" ;; esac
    done
    log_ok "Branch: ${FRAPPE_BRANCH}"; echo ""

    # ── Username ────────────────────────────────────────────────────────────────
    while true; do
        read -rp "$(echo -e "${BOLD}${T_USER_PROMPT}${NC}")" BENCH_USER
        BENCH_USER="${BENCH_USER:-frappe}"
        [[ "$BENCH_USER" =~ ^[a-z][a-z0-9_-]*$ ]] && break
        echo "${T_USER_INVALID}"
    done
    log_ok "$(echo -e "${T_SUMMARY_USER}${BENCH_USER}")"; echo ""

    # ── Bench folder ────────────────────────────────────────────────────────────
    while true; do
        read -rp "$(echo -e "${BOLD}${T_BENCH_PROMPT}${NC}")" BENCH_DIR
        BENCH_DIR="${BENCH_DIR:-frappe-bench}"
        [[ "$BENCH_DIR" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]] && break
        echo "${T_BENCH_INVALID}"
    done
    BENCH_PATH="/home/${BENCH_USER}/${BENCH_DIR}"
    log_ok "$(echo -e "${T_SUMMARY_PATH}${BENCH_PATH}")"; echo ""

    # ── MariaDB root password ───────────────────────────────────────────────────
    while true; do
        read -rsp "$(echo -e "${BOLD}${T_MYSQL_PW}${NC}")" MYSQL_ROOT_PASS; echo ""
        [[ -z "$MYSQL_ROOT_PASS" ]] && echo "${T_MYSQL_PW_EMPTY}" && continue
        [[ ${#MYSQL_ROOT_PASS} -lt 6 ]] && echo "${T_MYSQL_PW_SHORT}" && continue
        read -rsp "$(echo -e "${BOLD}${T_MYSQL_PW_CONFIRM}${NC}")" _MCONF; echo ""
        [[ "$MYSQL_ROOT_PASS" == "$_MCONF" ]] && break
        echo "${T_MYSQL_PW_MISMATCH}"
    done
    log_ok "${T_MYSQL_PW_OK}"; echo ""

    # ── Optional site ───────────────────────────────────────────────────────────
    read -rp "$(echo -e "${BOLD}${T_CREATE_SITE}${NC}")" _CS; _CS="${_CS:-n}"
    SITE_NAME=""; ADMIN_PASS=""
    if is_yes "$_CS"; then
        echo ""
        while true; do
            read -rp "$(echo -e "${BOLD}${T_SITE_NAME}${NC}")" SITE_NAME
            [[ -n "$SITE_NAME" && "$SITE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] && break
            echo "${T_SITE_INVALID}"
        done
        while true; do
            read -rsp "$(echo -e "${BOLD}${T_ADMIN_PW}${NC}")" ADMIN_PASS; echo ""
            [[ -z "$ADMIN_PASS" ]] && echo "${T_MYSQL_PW_EMPTY}" && continue
            read -rsp "$(echo -e "${BOLD}${T_ADMIN_PW_CONFIRM}${NC}")" _ACONF; echo ""
            [[ "$ADMIN_PASS" == "$_ACONF" ]] && break
            echo "${T_MYSQL_PW_MISMATCH}"
        done
    fi
    PWD_FILE=""

    # ── Summary ─────────────────────────────────────────────────────────────────
    echo -e "\n${BOLD}${T_SUMMARY_TITLE}${NC}"
    echo -e "${T_SUMMARY_MODE}$([[ "$OUTPUT_MODE" == "progress" ]] && echo "${T_SUMMARY_MODE_PROG}" || echo "${T_SUMMARY_MODE_VERB}")"
    echo -e "${T_SUMMARY_BRANCH}${FRAPPE_BRANCH}"
    echo -e "${T_SUMMARY_USER}${BENCH_USER}"
    echo -e "${T_SUMMARY_PATH}${BENCH_PATH}"
    echo -e "${T_SUMMARY_MYSQL}"
    [[ -n "$SITE_NAME" ]] && echo -e "${T_SUMMARY_SITE}${SITE_NAME}"
    echo ""
    read -rp "$(echo -e "${BOLD}${T_START_PROMPT}${NC}")" _CONF; _CONF="${_CONF:-j}"
    is_yes "$_CONF" || { log_warn "${T_ABORTED}"; exit 0; }
    echo ""
fi

# ─── Version variables ────────────────────────────────────────────────────────

if [[ "$FRAPPE_BRANCH" == "version-15" ]]; then
    PYTHON_MIN="3.10"; PYTHON_EXACT=""; NODE_VERSION="20"
    USE_UV=true; MARIADB_FROM_REPO=false
else
    PYTHON_MIN="3.14"; PYTHON_EXACT="3.14"; NODE_VERSION="24"
    USE_UV=true; MARIADB_FROM_REPO=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
command -v debconf-set-selections &>/dev/null && \
    echo "mariadb-server mariadb-server/feedback_plugin_enable boolean false" \
    | debconf-set-selections 2>/dev/null || true

# ─── Detect previous installation ────────────────────────────────────────────

EXISTING_ITEMS=()
[[ -d "$BENCH_PATH" ]] && EXISTING_ITEMS+=("Bench: ${BENCH_PATH}")

if id "$BENCH_USER" &>/dev/null; then
    UH="/home/${BENCH_USER}"
    [[ -d "${UH}/.local/share/uv" ]] && EXISTING_ITEMS+=("uv: ${UH}/.local/share/uv/")
    [[ -f "${UH}/.local/bin/bench" ]] && EXISTING_ITEMS+=("bench CLI: ${UH}/.local/bin/bench")
    find "${UH}/.local/lib" -path "*/site-packages/bench" -type d 2>/dev/null | grep -q . && \
        EXISTING_ITEMS+=("pip bench: ${UH}/.local/lib/")
fi

command -v node &>/dev/null && {
    _EN=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    [[ "$_EN" -ne "$NODE_VERSION" ]] 2>/dev/null && \
        EXISTING_ITEMS+=("Node.js v${_EN} (need: v${NODE_VERSION})")
}

ls /etc/supervisor/conf.d/*"${BENCH_DIR}"* &>/dev/null 2>&1 && \
    EXISTING_ITEMS+=("Supervisor config: ${BENCH_DIR}")
ls /etc/nginx/conf.d/*"${BENCH_DIR}"* &>/dev/null 2>&1 && \
    EXISTING_ITEMS+=("Nginx config: ${BENCH_DIR}")

dpkg -l mariadb-server 2>/dev/null | grep -q "^ii" && \
    EXISTING_ITEMS+=("MariaDB (wird neu installiert / will be reinstalled)")

if [[ ${#EXISTING_ITEMS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}${T_EXISTING_TITLE}${NC}"
    for item in "${EXISTING_ITEMS[@]}"; do echo -e "     • ${item}"; done
    echo ""
    echo -e "${T_EXISTING_NOTE}"
    if [[ "$QUICK_INSTALL" == false ]]; then
        read -rp "$(echo -e "${BOLD}${T_EXISTING_CONFIRM}${NC}")" _CC
        is_yes "${_CC:-n}" || { log_warn "${T_ABORTED}"; exit 0; }
    else
        echo -e "${DIM}${T_QUICK_AUTO}${NC}"
    fi

    log_info "${T_CLEANUP}"

    command -v supervisorctl &>/dev/null && supervisorctl stop all >> "$LOGFILE" 2>&1 || true

    if [[ -d "$BENCH_PATH" ]]; then rm -rf "$BENCH_PATH"; log_ok "${T_DELETED}${BENCH_PATH}"; fi

    rm -f /etc/supervisor/conf.d/*"${BENCH_DIR}"* 2>/dev/null
    rm -f /etc/nginx/conf.d/*"${BENCH_DIR}"* 2>/dev/null
    supervisorctl reread >> "$LOGFILE" 2>&1 || true
    supervisorctl update >> "$LOGFILE" 2>&1 || true

    if id "$BENCH_USER" &>/dev/null; then
        UH="/home/${BENCH_USER}"
        rm -rf "${UH}/.local/share/uv" "${UH}/.cache/uv" 2>/dev/null
        rm -f  "${UH}/.local/bin/bench" "${UH}/.local/bin/uv" "${UH}/.local/bin/uvx" 2>/dev/null
        rm -f  "${UH}/.cargo/bin/uv"    "${UH}/.cargo/bin/uvx" 2>/dev/null
        find "${UH}/.local/lib" -maxdepth 4 -type d \
            \( -name "bench" -o -name "bench-*" -o -name "frappe_bench*" \) \
            -exec rm -rf {} + 2>/dev/null || true
        log_ok "${T_USER_ENV_CLEANED}${UH}/.local/"
    fi

    if command -v node &>/dev/null; then
        _ON=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
        if [[ "$_ON" -ne "$NODE_VERSION" ]] 2>/dev/null; then
            apt-get remove -y -qq nodejs >> "$LOGFILE" 2>&1 || true
            apt-get autoremove -y -qq    >> "$LOGFILE" 2>&1 || true
            rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* 2>/dev/null
            log_ok "${T_NODE_REMOVED}${_ON}${T_NODE_REMOVED2}"
        fi
    fi

    rm -rf /root/.local/share/uv /root/.cache/uv /root/uv.toml 2>/dev/null
    log_ok "${T_CLEANUP_DONE}"
    echo ""
fi

# ─── 1. Update system ─────────────────────────────────────────────────────────

step_start 1 "${T_STEP1}"
run_cmd_or_die "apt update"  apt-get update -qq
run_cmd_or_die "apt upgrade" apt-get upgrade -y -qq
stop_spinner; log_ok "${T_SYS_UPDATED}"

# ─── 2. Dependencies ──────────────────────────────────────────────────────────

step_start 2 "${T_STEP2}"

REQUIRED_PKGS=(
    git curl wget sudo gnupg2 ca-certificates lsb-release
    apt-transport-https build-essential python3-dev python3-setuptools
    python3-venv libffi-dev libssl-dev libjpeg-dev zlib1g-dev
    libfreetype6-dev liblcms2-dev libwebp-dev libharfbuzz-dev
    libfribidi-dev libxcb1-dev libpq-dev libmariadb-dev
    default-libmysqlclient-dev pkg-config
    libldap2-dev libsasl2-dev redis-server supervisor nginx
    xvfb libfontconfig fontconfig cron
)
OPTIONAL_PKGS=(software-properties-common python3-pip python3-distutils fail2ban)

install_pkg "required" "${REQUIRED_PKGS[@]}"
install_pkg "optional" "${OPTIONAL_PKGS[@]}"
stop_spinner

[[ ${#FAILED_PKGS[@]} -gt 0 ]] && log_warn "${T_PKGS_FAILED} (${#FAILED_PKGS[@]}): ${FAILED_PKGS[*]}"
log_ok "${#INSTALLED_PKGS[@]}${T_PKGS_INSTALLED}"

CRITICAL_MISSING=()
for pkg in git curl build-essential python3-dev redis-server supervisor nginx libmariadb-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || CRITICAL_MISSING+=("$pkg")
done
[[ ${#CRITICAL_MISSING[@]} -gt 0 ]] && die "${T_CRITICAL_MISSING}: ${CRITICAL_MISSING[*]}"

# ─── 3. MariaDB install ───────────────────────────────────────────────────────

step_start 3 "${T_STEP3}"

# Always purge & reinstall: guarantees empty state, no password, no old DBs
if dpkg -l mariadb-server 2>/dev/null | grep -q "^ii"; then
    log_to_file "${T_MARIADB_PURGE}"
    svc_ctl stop mariadb mariadbd || true
    pkill -x mariadbd 2>/dev/null || true; sleep 2
    run_cmd "purge" apt-get purge -y -qq mariadb-server mariadb-client mariadb-common
    run_cmd "autoremove" apt-get autoremove -y -qq
    rm -rf /var/lib/mysql /etc/mysql/mariadb.conf.d/99-frappe.cnf 2>/dev/null || true
    log_ok "${T_MARIADB_PURGED}"
fi

if [[ "$MARIADB_FROM_REPO" == true ]]; then
    curl -fsSL "https://mariadb.org/mariadb_release_signing_key.pgp" \
        | gpg --dearmor --yes -o /usr/share/keyrings/mariadb-keyring.gpg 2>/dev/null
    cat > /etc/apt/sources.list.d/mariadb.list <<EOF
deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.8/repo/${OS_ID} ${OS_CODENAME} main
EOF
    run_cmd "MariaDB repo update" apt-get update -qq
fi

run_cmd_or_die "MariaDB install" apt-get install -y -qq mariadb-server mariadb-client

# Re-install dev headers — apt autoremove may have removed them with MariaDB
run_cmd_or_die "mysqlclient dev headers" apt-get install -y -qq \
    libmariadb-dev default-libmysqlclient-dev pkg-config

svc_ctl enable mariadb mariadbd || true
svc_ctl start mariadb mariadbd || die "${T_MARIADB_FAIL}"
stop_spinner; log_ok "${T_MARIADB_FRESH}"

# ─── 4. Configure MariaDB ─────────────────────────────────────────────────────

step_start 4 "${T_STEP4}"

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
sleep 2
mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1 || { sleep 3; mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1 || log_warn "${T_MARIADB_NO_RESPONSE}"; }

if mariadb -u root -e "SELECT 1;" >> "$LOGFILE" 2>&1; then
    mariadb -u root >> "$LOGFILE" 2>&1 <<EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
    stop_spinner; log_ok "${T_MARIADB_PW_SET}"
elif mariadb -u root -p"${MYSQL_ROOT_PASS}" -e "SELECT 1;" >> "$LOGFILE" 2>&1; then
    stop_spinner; log_ok "${T_MARIADB_PW_OK}"
else
    stop_spinner; log_warn "${T_MARIADB_PW_WARN}"
fi

# ─── 5. Redis ─────────────────────────────────────────────────────────────────

step_start 5 "${T_STEP5}"
svc_ctl enable redis-server redis-server || true
svc_ctl start  redis-server redis-server || log_warn "${T_REDIS_FAIL}"
grep -q "vm.overcommit_memory" /etc/sysctl.conf 2>/dev/null || \
    { echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf; sysctl vm.overcommit_memory=1 >> "$LOGFILE" 2>&1 || true; }
stop_spinner; log_ok "${T_REDIS_RUNNING}"

# ─── 6. Node.js ───────────────────────────────────────────────────────────────

step_start 6 "${T_STEP6} ${NODE_VERSION}"
NEED_NODE=true
if command -v node &>/dev/null; then
    _EM=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [[ "$_EM" -eq "$NODE_VERSION" ]] 2>/dev/null; then
        NEED_NODE=false
    else
        log_info "${T_NODE_FOUND}${_EM}${T_NODE_FOUND2}${NODE_VERSION}${T_NODE_FOUND3}"
        apt-get remove -y -qq nodejs >> "$LOGFILE" 2>&1 || true
        apt-get autoremove -y -qq    >> "$LOGFILE" 2>&1 || true
        rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* \
              /usr/share/keyrings/nodesource* 2>/dev/null
        apt-get update -qq >> "$LOGFILE" 2>&1 || true
    fi
fi
if [[ "$NEED_NODE" == true ]]; then
    rm -f /etc/apt/sources.list.d/nodesource* /etc/apt/keyrings/nodesource* 2>/dev/null
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" 2>/dev/null | bash - >> "$LOGFILE" 2>&1
    run_cmd_or_die "Node.js" apt-get install -y -qq nodejs
    _IN=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    [[ "$_IN" -ne "$NODE_VERSION" ]] 2>/dev/null && log_warn "${T_NODE_WRONG}${_IN}${T_NODE_WRONG2}${NODE_VERSION}${T_NODE_WARN}"
fi
command -v yarn &>/dev/null || run_cmd "yarn" npm install -g yarn
stop_spinner; log_ok "Node.js $(node --version 2>/dev/null), Yarn $(yarn --version 2>/dev/null)"

# ─── 7. System Python ─────────────────────────────────────────────────────────

step_start 7 "${T_STEP7}"
SYSTEM_PYTHON=""
for py in python3.14 python3.13 python3.12 python3.11 python3; do
    command -v "$py" &>/dev/null && { SYSTEM_PYTHON=$(command -v "$py"); break; }
done
[[ -n "$SYSTEM_PYTHON" ]] && log_to_file "System Python: $($SYSTEM_PYTHON --version 2>&1) → ${SYSTEM_PYTHON}"
stop_spinner; log_ok "${T_SYSPY}${SYSTEM_PYTHON:-${T_SYSPY_NONE}}"

# ─── 8. wkhtmltopdf ───────────────────────────────────────────────────────────

step_start 8 "${T_STEP8}"
if command -v wkhtmltopdf &>/dev/null; then
    stop_spinner; log_ok "${T_WKHTML_EXISTS}"
else
    for dep in xfonts-75dpi xfonts-base libxrender1 libxext6; do
        apt-get install -y -qq "$dep" >> "$LOGFILE" 2>&1 || true
    done
    ARCH=$(dpkg --print-architecture); WKHTML_DEB="/tmp/wkhtmltox.deb"; WKHTML_OK=false
    for url in \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${OS_ID}${OS_VERSION}_${ARCH}.deb" \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_${ARCH}.deb" \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${ARCH}.deb" \
        "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.buster_${ARCH}.deb"
    do
        wget -q -O "$WKHTML_DEB" "$url" 2>/dev/null || continue
        dpkg -i "$WKHTML_DEB" >> "$LOGFILE" 2>&1 || true
        apt-get install -f -y -qq >> "$LOGFILE" 2>&1 || true
        if command -v wkhtmltopdf &>/dev/null; then WKHTML_OK=true; break
        else dpkg --remove wkhtmltox >> "$LOGFILE" 2>&1 || true; fi
    done
    rm -f "$WKHTML_DEB"; stop_spinner
    if [[ "$WKHTML_OK" == true ]]; then log_ok "${T_WKHTML_OK}"
    else log_warn "${T_WKHTML_FAIL}"; log_warn "${T_WKHTML_MANUAL}"; fi
fi

# ─── 9. User & Bench ──────────────────────────────────────────────────────────

step_start 9 "${T_STEP9}"

id "$BENCH_USER" &>/dev/null || {
    useradd -m -s /bin/bash "$BENCH_USER" >> "$LOGFILE" 2>&1
    log_to_file "${T_USER_CREATED}${BENCH_USER}${T_USER_CREATED2}"
}
usermod -aG sudo "$BENCH_USER" >> "$LOGFILE" 2>/dev/null || true
SUDOERS_FILE="/etc/sudoers.d/${BENCH_USER}"
[[ -f "$SUDOERS_FILE" ]] || { echo "${BENCH_USER} ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"; chmod 0440 "$SUDOERS_FILE"; }

USER_HOME="/home/${BENCH_USER}"

# Save passwords (Quick-Install)
if [[ "$QUICK_INSTALL" == true ]]; then
    PWD_FILE="${USER_HOME}/pwd.txt"
    cat > "$PWD_FILE" <<PWDEOF
${T_PWD_HEADER}
${T_PWD_CREATED}$(date '+%Y-%m-%d %H:%M:%S')
${T_PWD_WARN}

${T_RESULT_PW_DB}${MYSQL_ROOT_PASS}
${T_RESULT_PW_ADMIN}${ADMIN_PASS}

Site     : ${SITE_NAME}
Bench    : ${BENCH_PATH}
${T_PWD_LOGIN}    : http://<IP>  →  Administrator / ${ADMIN_PASS}
PWDEOF
    chmod 600 "$PWD_FILE"; chown "${BENCH_USER}:${BENCH_USER}" "$PWD_FILE"
    log_ok "${T_PWD_SAVED}${PWD_FILE}"
fi

run_as_user() {
    sudo -H -u "$BENCH_USER" \
        env -u UV_CONFIG_FILE \
        HOME="${USER_HOME}" USER="${BENCH_USER}" \
        XDG_CONFIG_HOME="${USER_HOME}/.config" \
        XDG_DATA_HOME="${USER_HOME}/.local/share" \
        XDG_CACHE_HOME="${USER_HOME}/.cache" \
        bash -l -c "cd \$HOME && $*"
}

BENCH_ENV_PATHS='export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:$PATH"'
grep -q ".local/bin" "${USER_HOME}/.profile" 2>/dev/null || \
    echo -e "\n# Frappe Bench PATH\n${BENCH_ENV_PATHS}" >> "${USER_HOME}/.profile"
grep -q ".local/bin" "${USER_HOME}/.bashrc" 2>/dev/null || \
    echo -e "\n# Frappe Bench PATH\n${BENCH_ENV_PATHS}" >> "${USER_HOME}/.bashrc"
chown "${BENCH_USER}:${BENCH_USER}" "${USER_HOME}/.profile" "${USER_HOME}/.bashrc"

# Install uv
if [[ "$USE_UV" == true ]]; then
    log_to_file "${T_UV_INSTALL}${BENCH_USER}..."
    run_as_user "curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh" >> "$LOGFILE" 2>&1 || true
    run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv --version" >> "$LOGFILE" 2>&1 || \
        { log_warn "${T_UV_FAIL}"; USE_UV=false; }
fi

# Python version check helper
python_version_ge() {
    local hM="${1%%.*}" hm="${1#*.}" nM="${2%%.*}" nm="${2#*.}"
    hm="${hm%%.*}"; nm="${nm%%.*}"
    [[ "$hM" -gt "$nM" ]] 2>/dev/null && return 0
    [[ "$hM" -eq "$nM" && "$hm" -ge "$nm" ]] 2>/dev/null && return 0
    return 1
}

USER_PYTHON_BIN=""

if [[ -n "$PYTHON_EXACT" ]]; then
    log_info "${T_PY_INSTALL}${PYTHON_EXACT}${T_PY_INSTALL2}${BENCH_USER}${T_PY_INSTALL3}"
    if [[ "$USE_UV" == true ]]; then
        [[ "$OUTPUT_MODE" == "verbose" ]] && \
            run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python install ${PYTHON_EXACT}" 2>&1 | tee -a "$LOGFILE" >&3 || true || \
            run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python install ${PYTHON_EXACT}" >> "$LOGFILE" 2>&1 || true
        USER_PYTHON_BIN=$(run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python find ${PYTHON_EXACT}" 2>/dev/null || echo "")
        [[ -n "$USER_PYTHON_BIN" ]] && log_ok "${T_PY_OK}${PYTHON_EXACT}${T_PY_OK2}${USER_PYTHON_BIN}" || \
            { log_warn "${T_PY_FAIL}${PYTHON_EXACT}${T_PY_FAIL2}"
              run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python list --only-installed" >> "$LOGFILE" 2>&1 || true; }
    fi
    if [[ -z "$USER_PYTHON_BIN" && -n "${SYSTEM_PYTHON:-}" ]]; then
        _SV=$("$SYSTEM_PYTHON" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        [[ "$_SV" == "$PYTHON_EXACT" ]] && USER_PYTHON_BIN="$SYSTEM_PYTHON" && log_ok "${T_PY_OK}${_SV}${T_PY_OK2}${SYSTEM_PYTHON}" || \
            log_warn "${T_PY_EXACT_NEED}${_SV}${T_PY_EXACT_NEED2}${PYTHON_EXACT}${T_PY_EXACT_NEED3}"
    fi
    [[ -z "$USER_PYTHON_BIN" ]] && die "${T_PY_DIE}${PYTHON_EXACT}${T_PY_DIE2}\n    ${T_PY_DIE3}${FRAPPE_BRANCH}${T_PY_DIE4}${PYTHON_EXACT}.\n    Log: ${LOGFILE}"
else
    if [[ -n "${SYSTEM_PYTHON:-}" ]]; then
        _SV=$("$SYSTEM_PYTHON" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        python_version_ge "$_SV" "$PYTHON_MIN" && \
            USER_PYTHON_BIN="$SYSTEM_PYTHON" && log_ok "${T_PY_FITS}${_SV}${T_PY_FITS2}${PYTHON_MIN}${T_PY_FITS3}" || \
            log_warn "${T_PY_NOT_FOUND}${PYTHON_MIN}${T_PY_NOT_FOUND2}"
    fi
    if [[ -z "$USER_PYTHON_BIN" ]]; then
        log_info "${T_PY_INSTALL}${PYTHON_MIN}${T_PY_INSTALL2}${BENCH_USER}${T_PY_INSTALL3}"
        run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv --version" >> "$LOGFILE" 2>&1 || \
            run_as_user "curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh" >> "$LOGFILE" 2>&1 || true
        run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python install ${PYTHON_MIN}" >> "$LOGFILE" 2>&1 || true
        USER_PYTHON_BIN=$(run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv python find ${PYTHON_MIN}" 2>/dev/null || echo "")
        [[ -n "$USER_PYTHON_BIN" ]] && log_ok "${T_PY_OK}${PYTHON_MIN}${T_PY_OK2}${USER_PYTHON_BIN}"
    fi
    [[ -z "$USER_PYTHON_BIN" ]] && die "${T_PY_NOT_FOUND}${PYTHON_MIN}${T_PY_NOT_FOUND2}"
fi

log_to_file "Python for bench: ${USER_PYTHON_BIN}"

# Install frappe-bench CLI
BENCH_CLI_OK=false
[[ "$USE_UV" == true ]] && \
    run_as_user "export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH && uv tool install frappe-bench" >> "$LOGFILE" 2>&1 && \
    BENCH_CLI_OK=true
if [[ "$BENCH_CLI_OK" == false ]]; then
    run_as_user "export PATH=\$HOME/.local/bin:\$PATH && pip3 install --user frappe-bench --break-system-packages" >> "$LOGFILE" 2>&1 || \
    run_as_user "export PATH=\$HOME/.local/bin:\$PATH && pip3 install --user frappe-bench" >> "$LOGFILE" 2>&1 || \
        die "${T_BENCH_CLI_FAIL}"
fi

# Find bench binary
BENCH_BIN=""
for _c in "${USER_HOME}/.local/bin/bench" "${USER_HOME}/.cargo/bin/bench" \
          "${USER_HOME}/.local/share/uv/tools/frappe-bench/bin/bench" "/usr/local/bin/bench"; do
    sudo -H -u "$BENCH_USER" test -x "$_c" 2>/dev/null && { BENCH_BIN="$_c"; break; }
done
[[ -z "$BENCH_BIN" ]] && BENCH_BIN=$(find "${USER_HOME}" -name "bench" -type f -executable 2>/dev/null | head -1 || echo "")
[[ -z "$BENCH_BIN" ]] && die "${T_BENCH_BIN_FAIL}"
BENCH_BIN_DIR=$(dirname "$BENCH_BIN")
log_to_file "bench binary: ${BENCH_BIN}"

BENCH_VERSION=$(run_as_user "cd /tmp && export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:\$PATH && bench --version" 2>/dev/null || echo "")
[[ -z "$BENCH_VERSION" ]] && { log_warn "${T_BENCH_VER_FAIL}"; BENCH_VERSION="unknown"; }

# bench init — with MYSQLCLIENT env vars to avoid pkg-config failures
BENCH_INIT_CMD="
    export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:\$HOME/.cargo/bin:/usr/local/bin:\$PATH
    export MYSQLCLIENT_CFLAGS=\$(pkg-config --cflags mysqlclient 2>/dev/null || echo '-I/usr/include/mysql')
    export MYSQLCLIENT_LDFLAGS=\$(pkg-config --libs mysqlclient 2>/dev/null || echo '-lmysqlclient')
    cd ${USER_HOME}
    bench init ${BENCH_DIR} --frappe-branch ${FRAPPE_BRANCH} --python ${USER_PYTHON_BIN} --verbose
"

if [[ "$OUTPUT_MODE" == "verbose" ]]; then
    run_as_user "$BENCH_INIT_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || die "${T_BENCH_INIT_FAIL}"
else
    run_as_user "$BENCH_INIT_CMD" >> "$LOGFILE" 2>&1 || {
        stop_spinner; log_error "${T_BENCH_INIT_FAIL}"
        echo -e "${DIM}  ${T_BENCH_LASTLINES}:${NC}" >&3
        tail -30 "$LOGFILE" | sed 's/^/    /' >&3
        die "Log: ${LOGFILE}"
    }
fi

[[ ! -d "${BENCH_PATH}/apps/frappe" ]] && die "${T_APPS_MISSING}"
[[ ! -f "${BENCH_PATH}/env/bin/python" ]] && die "${T_VENV_MISSING}"

if ! run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe'" >> "$LOGFILE" 2>&1; then
    log_warn "${T_BENCH_REPAIR}"
    run_as_user "cd ${BENCH_PATH} && env/bin/pip install -e apps/frappe" >> "$LOGFILE" 2>&1
    run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe'" >> "$LOGFILE" 2>&1 || \
        die "${T_BENCH_REPAIR_FAIL}${LOGFILE}"
    log_to_file "${T_BENCH_REPAIR_OK}"
fi

FRAPPE_VERSION=$(run_as_user "cd ${BENCH_PATH} && env/bin/python -c 'import frappe; print(frappe.__version__)'" 2>/dev/null || echo "?")
stop_spinner; log_ok "${T_BENCH_OK}${FRAPPE_VERSION} — bench v${BENCH_VERSION}"

# ─── Site ─────────────────────────────────────────────────────────────────────

if [[ -n "$SITE_NAME" ]]; then
    log_info "${T_SITE_CREATING}${SITE_NAME}${T_SITE_CREATING2}"
    SITE_CMD="
        export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:/usr/local/bin:\$PATH
        cd ${BENCH_PATH} || exit 1
        bench new-site ${SITE_NAME} \
            --db-root-username root \
            --mariadb-root-password '${MYSQL_ROOT_PASS}' \
            --admin-password '${ADMIN_PASS}' \
            --mariadb-user-host-login-scope='%'
    "
    if [[ "$OUTPUT_MODE" == "verbose" ]]; then
        run_as_user "$SITE_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || die "${T_SITE_FAIL}"
    else
        run_as_user "$SITE_CMD" >> "$LOGFILE" 2>&1 || die "${T_SITE_FAIL2}${LOGFILE}"
    fi
    run_as_user "cd ${BENCH_PATH} && bench use ${SITE_NAME}" >> "$LOGFILE" 2>&1
    log_ok "${T_SITE_OK}${SITE_NAME}${T_SITE_OK2}"
fi

# ─── 10. Production setup ─────────────────────────────────────────────────────

step_start 10 "${T_STEP10}"

PROD_FAILED=false
PROD_CMD="
    export PATH=${BENCH_BIN_DIR}:\$HOME/.local/bin:/usr/local/bin:\$PATH
    cd ${BENCH_PATH}
    bench setup production ${BENCH_USER} --yes
"
if [[ "$OUTPUT_MODE" == "verbose" ]]; then
    run_as_user "$PROD_CMD" 2>&1 | tee -a "$LOGFILE" >&3 || PROD_FAILED=true
else
    run_as_user "$PROD_CMD" >> "$LOGFILE" 2>&1 || PROD_FAILED=true
fi

if [[ "$PROD_FAILED" == true ]]; then
    log_warn "${T_PROD_FAIL}"
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
supervisorctl reread >> "$LOGFILE" 2>&1 || true
supervisorctl update >> "$LOGFILE" 2>&1 || true

NGINX_BENCH_CONF="/etc/nginx/conf.d/${BENCH_DIR}.conf"
[[ -f "$NGINX_BENCH_CONF" ]] && grep -q 'access_log.*main' "$NGINX_BENCH_CONF" 2>/dev/null && \
    sed -i 's|access_log\(.*\) main;|access_log\1;|g' "$NGINX_BENCH_CONF"

rm -f /etc/nginx/sites-enabled/default 2>/dev/null
nginx -t >> "$LOGFILE" 2>&1 && svc_ctl restart nginx nginx || log_warn "${T_NGINX_BAD}"

chmod 711 "${USER_HOME}"
chmod -R 755 "${BENCH_PATH}/sites" 2>/dev/null || true

sleep 3; stop_spinner
[[ "$OUTPUT_MODE" == "progress" ]] && { draw_progress_bar "$TOTAL_STEPS" "${T_DONE}"; echo "" >&3; echo "" >&3; }

# ─── Result ───────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}${T_SUPERVISOR_STATUS}${NC}" >&3
supervisorctl status 2>/dev/null | sed 's/^/    /' >&3 || echo "    (${T_SUPERVISOR_WAIT})" >&3

INSTANCE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$INSTANCE_IP" ]] && INSTANCE_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
[[ -z "$INSTANCE_IP" ]] && INSTANCE_IP="<IP>"

NGINX_PORT="80"
[[ -f "${BENCH_PATH}/config/nginx.conf" ]] && \
    _DP=$(grep -oP 'listen\s+\K\d+' "${BENCH_PATH}/config/nginx.conf" 2>/dev/null | head -1) && \
    [[ -n "${_DP:-}" ]] && NGINX_PORT="$_DP"
[[ "$NGINX_PORT" == "80" ]] && SITE_URL="http://${INSTANCE_IP}" || SITE_URL="http://${INSTANCE_IP}:${NGINX_PORT}"

echo -e "
${GREEN}╔══════════════════════════════════════════════════════════════╗
║           ${T_RESULT_TITLE}                     ║
╚══════════════════════════════════════════════════════════════╝${NC}

  ${BOLD}${T_RESULT_SYSTEM}${NC}
    Frappe:     ${FRAPPE_VERSION} (${FRAPPE_BRANCH})
    MariaDB:    $(mariadb --version 2>/dev/null | grep -oP 'Ver \K[^ ]+' || echo '?')
    Node.js:    $(node --version 2>/dev/null || echo '?')
    Python:     $(${USER_PYTHON_BIN} --version 2>/dev/null || echo '?')
    Bench CLI:  v${BENCH_VERSION}

  ${BOLD}${T_RESULT_PATHS}${NC}
    ${T_RESULT_BENCH}${BENCH_PATH}
    ${T_RESULT_LOG}${LOGFILE}" >&3

if [[ -n "$SITE_NAME" ]]; then
    echo -e "
  ${BOLD}${T_RESULT_SITE}${NC}
    ${T_RESULT_NAME}${SITE_NAME}
    ${GREEN}${BOLD}Website:    ${SITE_URL}${NC}
    ${T_RESULT_LOGIN}" >&3
else
    echo -e "
  ${BOLD}${T_RESULT_WEB}${NC}
    ${DIM}${T_RESULT_WEB_HINT}${SITE_URL}${T_RESULT_WEB_HINT2}${NC}
    ${CYAN}cd ${BENCH_PATH} && bench new-site <name> --admin-password <pw> --mariadb-root-password <pw>${NC}" >&3
fi

if [[ "$QUICK_INSTALL" == true && -f "${PWD_FILE}" ]]; then
    echo -e "
  ${BOLD}${YELLOW}${T_RESULT_PW_TITLE}${PWD_FILE}${T_RESULT_PW_TITLE2}${NC}
    ${T_RESULT_PW_DB}${MYSQL_ROOT_PASS}
    ${T_RESULT_PW_ADMIN}${ADMIN_PASS}
    ${DIM}${T_RESULT_PW_HINT}${PWD_FILE}${NC}" >&3
fi

echo -e "
  ${BOLD}${T_RESULT_CMDS}${NC}
    ${CYAN}supervisorctl status${NC}              ${T_RESULT_CMD1}
    ${CYAN}supervisorctl restart all${NC}         ${T_RESULT_CMD2}
    ${CYAN}sudo -u ${BENCH_USER} bash${NC}                ${T_RESULT_CMD3}
    ${CYAN}cd ${BENCH_PATH}${NC}   ${T_RESULT_CMD4}

  ${BOLD}${T_RESULT_IMPORTANT}${NC}
    ${GREEN}✔${NC}  ${CYAN}supervisorctl${NC} — ${T_RESULT_IMP1}
    ${GREEN}✔${NC}  ${T_RESULT_IMP2}${CYAN}bench setup lets-encrypt <site>${NC}
    ${GREEN}✔${NC}  ${T_RESULT_IMP3}${CYAN}bench get-app erpnext --branch ${FRAPPE_BRANCH}${NC}
    ${GREEN}✔${NC}  ${T_RESULT_IMP4}${CYAN}tail -f ${BENCH_PATH}/logs/*.log${NC}
" >&3
