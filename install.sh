#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# SVM+ V11.3 • ANKITCODER • PRODUCTION INSTALLER / UPGRADER
#
# Usage:
#   sudo bash install.sh
#   sudo bash install.sh --configure
#   sudo bash install.sh --local-bot /path/to/bot.py
#   sudo bash install.sh --non-interactive
#   sudo bash install.sh --no-start
#   sudo bash install.sh --rollback [SNAPSHOT]
#   sudo bash install.sh ai-install
#   sudo bash install.sh ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor|ai-test|ai-logs|ai-configure|ai-update
#   sudo bash install.sh status|doctor
#
# Source priority:
#   1. v11.zip beside install.sh
#   2. local bot.py/webssh.html/requirements.txt
#   3. GitHub repository
#
# Important fixes:
#   • Correct unzip destination: unzip -o ZIP -d STAGE
#   • Complete AI wizard and command dispatcher
#   • No malformed [[ ... ]] expressions
#   • Safe .env preservation
#   • SQLite backup + upgrade snapshots
#   • Startup health check + automatic bot rollback
#   • Optional LocalAI Docker/systemd runtime
# ══════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
IFS=$'\n\t'

REPO="${SVM_REPO:-https://github.com/AnkitKing7/Svm-v11.3-bot.git}"
BRANCH="${SVM_BRANCH:-main}"
APP_DIR="${SVM_DIR:-/opt/svm}"
SERVICE="${SVM_SERVICE:-svm}"
ENV_FILE="${APP_DIR}/.env"
BACKUP_DIR="${APP_DIR}/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCK_FILE="/var/lock/svm-plus-ankitcoder.lock"
KEEP_SNAPSHOTS="${SVM_KEEP_SNAPSHOTS:-10}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
V11_ZIP="${SVM_V11_ZIP:-${SCRIPT_DIR}/v11.zip}"

MODE="install"
INTERACTIVE=1
NO_START=0
LOCAL_BOT="${SVM_LOCAL_BOT:-}"
ROLLBACK_TARGET=""
SETUP_CADDY=0

TMP_DIR=""
V11_ZIP_STAGE=""
V11_ZIP_ROOT=""
SNAP=""

PY=""
PIP=""
SRC_BOT=""
SRC_WEBSSH=""
SRC_REQ=""

LOCALAI_CONTAINER="${SVM_LOCALAI_CONTAINER:-local-ai}"
LOCALAI_IMAGE="${SVM_LOCALAI_IMAGE:-localai/localai:latest-cpu}"
LOCALAI_DIR="${APP_DIR}/localai"

R='\033[0m'
B='\033[1m'
C='\033[36m'
G='\033[32m'
Y='\033[33m'
E='\033[31m'

info() { printf "${C}➜${R} %s\n" "$*"; }
ok() { printf "${G}✓${R} %s\n" "$*"; }
warn() { printf "${Y}!${R} %s\n" "$*" >&2; }
die() { printf "${E}✗${R} %s\n" "$*" >&2; exit 1; }

section() {
    printf "\n${B}${C}━━━ %s ━━━${R}\n" "$*"
}

banner() {
    cat <<'EOF'

  ╔══════════════════════════════════════════════════════════════════════╗
  ║   S V M +   V 1 1 . 3  —  A N K I T C O D E R                    ║
  ║   VPS • IP POOL • PORT FORWARDING • PAYMENT GATEWAYS               ║
  ║   ZIP UPGRADER • SAFE BACKUP • AI AGENT • PRODUCTION               ║
  ╚══════════════════════════════════════════════════════════════════════╝

EOF
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf -- "$TMP_DIR" || true
    fi
    if [[ -n "${V11_ZIP_STAGE:-}" && -d "${V11_ZIP_STAGE:-}" ]]; then
        rm -rf -- "$V11_ZIP_STAGE" || true
    fi
}
trap cleanup EXIT

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
}

lock_installer() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another SVM installer process is already running."
}

get_env() {
    local key="$1"
    local line=""
    [[ -f "$ENV_FILE" ]] || return 0
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" | tail -n1 || true)"
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    line="${line%\'}"
    line="${line#\'}"
    printf '%s' "$line"
}

set_env() {
    local key="$1"
    local val="$2"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid env key: $key"
    [[ "$val" != *$'\n'* ]] || die "Value for $key contains a newline."
    [[ "$val" != *"'"* ]] || die "Value for $key contains a single quote; unsupported by this .env writer."

    mkdir -p "$APP_DIR"
    ENV_KEY="$key" ENV_VAL="$val" ENV_PATH="$ENV_FILE" python3 - <<'PY'
import os, re
key = os.environ["ENV_KEY"]
val = os.environ["ENV_VAL"]
path = os.environ["ENV_PATH"]

lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
new = f"{key}='{val}'"
done = False

for i, line in enumerate(lines):
    if re.match(rf"^\s*(?:export\s+)?{re.escape(key)}=", line):
        lines[i] = new
        done = True

if not done:
    lines.append(new)

fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines).rstrip("\n") + "\n")
PY
    chmod 600 "$ENV_FILE"
}

ensure_env() {
    local key="$1"
    local val="$2"
    if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" 2>/dev/null; then
        set_env "$key" "$val"
    fi
}

apply_env_overrides() {
    local var key
    while IFS='=' read -r var _; do
        [[ "$var" == SVM_ENV_* ]] || continue
        key="${var#SVM_ENV_}"
        set_env "$key" "${!var}"
    done < <(env)
}

ask() {
    local key="$1"
    local prompt="$2"
    local def="${3:-}"
    local secret="${4:-}"
    local cur reply shown required

    cur="$(get_env "$key")"
    [[ -n "$cur" ]] && def="$cur"
    (( INTERACTIVE )) || return 0

    required=0
    case "$key" in
        DISCORD_TOKEN|MAIN_ADMIN_ID) required=1 ;;
    esac

    if [[ ! -r /dev/tty ]]; then
        die "Interactive configuration needs a terminal. Run: sudo bash install.sh --configure"
    fi

    while :; do
        reply=""
        shown=""
        if [[ "$secret" == "secret" ]]; then
            [[ -n "$cur" ]] && shown=" [press Enter to keep current]"
            # WebSSH/xterm.js terminals may not visibly echo characters for read -s.
            # Use normal read so pasted tokens are visible and users can confirm paste.
            # Warn users not to share screenshots while entering credentials.
            read -r -p "  ${prompt}${shown} (input visible): " reply </dev/tty || die "Could not read ${key} from terminal."
        else
            [[ -n "$def" ]] && shown=" [${def}]"
            read -r -p "  ${prompt}${shown}: " reply </dev/tty || die "Could not read ${key} from terminal."
        fi

        reply="${reply:-$def}"
        if (( required )) && [[ -z "$reply" ]]; then
            warn "${prompt} is required. Please enter a value."
            continue
        fi
        if [[ -n "$reply" ]]; then
            set_env "$key" "$reply"
            return 0
        fi
        return 0
    done
}

yesno() {
    local q="$1"
    local def="${2:-n}"
    local reply=""
    if (( ! INTERACTIVE )); then
        [[ "$def" == "y" ]]
        return
    fi

    if [[ "$def" == "y" ]]; then
        if [[ -r /dev/tty ]]; then
            read -r -p "  ${q} [Y/n]: " reply </dev/tty || reply=""
        else
            read -r -p "  ${q} [Y/n]: " reply || reply=""
        fi
    else
        if [[ -r /dev/tty ]]; then
            read -r -p "  ${q} [y/N]: " reply </dev/tty || reply=""
        else
            read -r -p "  ${q} [y/N]: " reply || reply=""
        fi
    fi
    reply="${reply:-$def}"
    [[ "${reply,,}" == y* ]]
}

detect_public_ip() {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null ||
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' |
        head -n1 || true
}

default_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1
}

install_unzip_first() {
    section "V11 ZIP BOOTSTRAP"
    export DEBIAN_FRONTEND=noninteractive

    if command -v unzip >/dev/null 2>&1; then
        ok "unzip already installed"
        return
    fi

    local log="/tmp/svm-unzip-${STAMP}.log"
    info "unzip is missing — installing it first."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >"$log" 2>&1 || warn "apt update reported problems: $log"
        apt-get install -y unzip >>"$log" 2>&1 || die "Failed to install unzip: $log"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y unzip >"$log" 2>&1 || die "Failed to install unzip: $log"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y unzip >"$log" 2>&1 || die "Failed to install unzip: $log"
    elif command -v apk >/dev/null 2>&1; then
        apk add unzip >"$log" 2>&1 || die "Failed to install unzip: $log"
    else
        die "No supported package manager found. Install unzip manually."
    fi

    command -v unzip >/dev/null 2>&1 || die "unzip is still unavailable."
    ok "unzip installed successfully"
}

prepare_v11_zip() {
    section "V11 ZIP PACKAGE"

    [[ -f "$V11_ZIP" ]] || {
        warn "v11.zip not found: $V11_ZIP"
        info "Falling back to local files / GitHub."
        return
    }

    [[ -s "$V11_ZIP" ]] || die "v11.zip is empty."
    command -v unzip >/dev/null 2>&1 || die "unzip is required."

    V11_ZIP_STAGE="$(mktemp -d /tmp/svm-v11-zip.XXXXXX)"

    info "Checking ZIP integrity..."
    unzip -t "$V11_ZIP" >/tmp/svm-v11-zip-test.log 2>&1 ||
        die "v11.zip is corrupted. See /tmp/svm-v11-zip-test.log"

    info "Extracting V11 ZIP..."
    # FIXED: the old script incorrectly used the stage path as a ZIP member.
    unzip -o "$V11_ZIP" -d "$V11_ZIP_STAGE" >/tmp/svm-v11-zip.log 2>&1 ||
        die "Failed to extract v11.zip. See /tmp/svm-v11-zip.log"

    if [[ -f "$V11_ZIP_STAGE/bot.py" ]]; then
        V11_ZIP_ROOT="$V11_ZIP_STAGE"
    else
        local candidate="" count=0 d
        while IFS= read -r -d '' d; do
            candidate="$d"
            count=$((count + 1))
        done < <(find "$V11_ZIP_STAGE" -mindepth 1 -maxdepth 1 -type d -print0)

        if (( count == 1 )) && [[ -f "$candidate/bot.py" ]]; then
            V11_ZIP_ROOT="$candidate"
        else
            V11_ZIP_ROOT="$V11_ZIP_STAGE"
        fi
    fi

    [[ -f "$V11_ZIP_ROOT/bot.py" ]] || {
        warn "ZIP extracted but bot.py was not found; using fallback source."
        V11_ZIP_ROOT=""
        return
    }

    ok "V11 ZIP extracted successfully"
    info "ZIP root: $V11_ZIP_ROOT"
    [[ -f "$V11_ZIP_ROOT/requirements.txt" ]] && ok "requirements.txt found" || warn "requirements.txt missing"
    [[ -f "$V11_ZIP_ROOT/webssh.html" ]] && ok "webssh.html found" || warn "webssh.html missing"
}

write_default_env() {
    ensure_env BOT_NAME "SVM V11.3"
    ensure_env PREFIX "!"
    ensure_env YOUR_SERVER_IP "127.0.0.1"
    ensure_env BOT_VERSION "11.3-PLUS"
    ensure_env DISCORD_TOKEN ""
    ensure_env MAIN_ADMIN_ID ""

    ensure_env PAYMENT_GATEWAYS "razorpay,upi"
    ensure_env DEFAULT_GATEWAY ""
    ensure_env RAZORPAY_KEY_ID ""
    ensure_env RAZORPAY_KEY_SECRET ""
    ensure_env RAZORPAY_WEBHOOK_SECRET ""
    ensure_env RAZORPAY_ACCEPT_AUTHORIZED "false"
    ensure_env STRIPE_SECRET_KEY ""
    ensure_env STRIPE_WEBHOOK_SECRET ""
    ensure_env STRIPE_CURRENCY "inr"
    ensure_env STRIPE_AMOUNT_RATE "1.0"
    ensure_env UPI_ENABLED "false"
    ensure_env UPI_ID ""
    ensure_env UPI_NAME "AnkitCoder"
    ensure_env UPI_QR_URL ""
    ensure_env PAYMENT_WEBHOOK_HOST "127.0.0.1"
    ensure_env PAYMENT_WEBHOOK_PORT "8787"
    ensure_env SVM_PUBLIC_URL ""
    ensure_env PAYMENT_SUCCESS_URL ""
    ensure_env PAYMENT_ADMIN_CHANNEL_ID "0"
    ensure_env ORDER_TTL_MINUTES "60"
    ensure_env UPI_ORDER_TTL_MINUTES "1440"
    ensure_env MAX_PENDING_ORDERS "3"
    ensure_env RENEW_DAYS "30"
    ensure_env PLAN_PERIOD_DAYS "30"

    ensure_env PLAN_STARTER_PRICE "0"
    ensure_env PLAN_BASIC_PRICE "0"
    ensure_env PLAN_STANDARD_PRICE "0"
    ensure_env PLAN_PRO_PRICE "0"

    ensure_env PORT_RANGE_START "20000"
    ensure_env PORT_RANGE_END "50000"
    ensure_env PORT_RESERVED ""
    ensure_env PORT_MAX_PER_VPS "20"
    ensure_env PORT_ALLOW_CUSTOM "false"

    ensure_env IPAM_BIND_MODE "record"
    ensure_env IPAM_AUTO_ASSIGN "false"
    ensure_env IPAM_HOST_IFACE ""
    ensure_env IPAM_POOLS ""
    ensure_env IPAM_POOL_MAX_ADDRS "4096"

    ensure_env DEFAULT_V11_2V_OS "ubuntu:22.04"
    ensure_env HOST_MOTD ""

    ensure_env AI_ENABLED "true"
    ensure_env AI_PROVIDER "localai"
    ensure_env AI_AGENT_ENABLED "true"
    ensure_env LOCALAI_BASE_URL "http://127.0.0.1:18080"
    ensure_env LOCALAI_API_KEY ""
    ensure_env LOCALAI_MODEL "llama-3.2-1b-instruct:q4_k_m"
    ensure_env LOCALAI_AUTO_INSTALL_MODEL "true"
    ensure_env LOCALAI_VISION_MODEL ""
    ensure_env LOCALAI_IMAGE_MODEL ""
    ensure_env AI_STREAMING "true"
    ensure_env AI_MEMORY "true"
    ensure_env AI_TOOLS "true"
    ensure_env AI_FILE_TOOLS "true"
    ensure_env AI_CODE_TOOLS "true"
    ensure_env AI_VISION "true"
    ensure_env AI_IMAGE_ENABLED "false"
    ensure_env AI_MAX_CONTEXT "32768"
    ensure_env AI_MAX_OUTPUT "4096"
    ensure_env AI_TIMEOUT "180"
    ensure_env AI_USER_RPM "10"
    ensure_env AI_USER_DAILY_LIMIT "200"
    ensure_env AI_MAX_CONCURRENT_TASKS "3"
    ensure_env AI_SANDBOX_ENABLED "true"
    ensure_env AI_SANDBOX_IMAGE "python:3.12-slim"
    ensure_env AI_SANDBOX_CPU_LIMIT ""
    ensure_env AI_SANDBOX_MEMORY_LIMIT ""
    ensure_env AI_SANDBOX_TIMEOUT "60"
    ensure_env AI_SANDBOX_ALLOW_USERS "false"
    ensure_env AI_AUTO_CHANNEL "false"
    ensure_env AI_AUTO_CHANNEL_ID ""
    ensure_env AI_CONFIRM_DESTRUCTIVE "true"

    ensure_env STATUS_AUTO_UPDATE "true"
    ensure_env STATUS_UPDATE_INTERVAL "30"
    ensure_env STATUS_CHANNEL_ID ""
    ensure_env AI_STATUS_CHANNEL_ID ""
    ensure_env STATUS_SVG_ENABLED "true"
    ensure_env STATUS_PNG_ENABLED "false"
    ensure_env STATUS_AUTO_GENERATE_SVG "false"
    ensure_env STATUS_AUTO_GENERATE_PNG "false"
    ensure_env STATUS_CACHE_TTL "15"
    ensure_env LOCALAI_HEALTH_CACHE_TTL "10"
    ensure_env PRESENCE_ROTATE "false"

    local k
    for k in USERS VPS NODES RESOURCES NETWORK IP_POOL PORTS AI_TASKS; do
        ensure_env "STATUS_SHOW_${k}" "true"
    done
}

configure_env() {
    section "CONFIGURATION WIZARD"

    if (( ! INTERACTIVE )); then
        info "Non-interactive mode: SVM_ENV_* overrides + existing .env values."
        validate_env
        return
    fi

    info "Press Enter to keep the current/default value."
    info "Discord bot token and admin user ID are required; blank input will be asked again."
    echo
    info "1/5 Discord"
    info "WebSSH note: the bot token input is visible so clipboard paste can be confirmed; do not share screenshots or terminal recordings."
    ask DISCORD_TOKEN "Discord bot token" "" secret
    ask MAIN_ADMIN_ID "Main admin Discord user ID"

    local ip
    ip="$(get_env YOUR_SERVER_IP)"
    if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
        ip="$(detect_public_ip)"
    fi
    ask YOUR_SERVER_IP "Public server IP" "${ip:-127.0.0.1}"

    echo
    info "2/5 Public URL / HTTPS"
    ask SVM_PUBLIC_URL "Public HTTPS URL, e.g. https://pay.example.com"

    local url
    url="$(get_env SVM_PUBLIC_URL)"
    if [[ "$url" == https://* ]]; then
        if yesno "Install/configure Caddy for ${url}?" y; then
            SETUP_CADDY=1
        fi
    fi

    echo
    info "3/5 Payment gateways"
    local gws=()

    if yesno "Enable Razorpay?" y; then
        gws+=(razorpay)
        ask RAZORPAY_KEY_ID "Razorpay Key ID"
        ask RAZORPAY_KEY_SECRET "Razorpay Key Secret" "" secret
        if [[ -z "$(get_env RAZORPAY_WEBHOOK_SECRET)" ]]; then
            set_env RAZORPAY_WEBHOOK_SECRET "$(openssl rand -hex 24)"
        fi
        info "Razorpay webhook: ${url:-https://YOUR-DOMAIN}/razorpay/webhook"
    fi

    if yesno "Enable Stripe Checkout?" n; then
        gws+=(stripe)
        ask STRIPE_SECRET_KEY "Stripe secret key" "" secret
        ask STRIPE_WEBHOOK_SECRET "Stripe webhook secret" "" secret
        ask STRIPE_CURRENCY "Stripe currency" "inr"
        ask STRIPE_AMOUNT_RATE "Stripe conversion rate" "1.0"
        info "Stripe webhook: ${url:-https://YOUR-DOMAIN}/stripe/webhook"
    fi

    if yesno "Enable manual UPI?" y; then
        gws+=(upi)
        set_env UPI_ENABLED true
        ask UPI_ID "UPI ID"
        ask UPI_NAME "Payee name" "AnkitCoder"
        ask UPI_QR_URL "UPI QR URL (optional)"
    else
        set_env UPI_ENABLED false
    fi

    if ((${#gws[@]})); then
        set_env PAYMENT_GATEWAYS "$(IFS=,; echo "${gws[*]}")"
        ask DEFAULT_GATEWAY "Default gateway" "${gws[0]}"
    fi

    ask PLAN_STARTER_PRICE "Starter price ₹ (1 vCPU / 2 GB / 20 GB)" "0"
    ask PLAN_BASIC_PRICE "Basic price ₹ (2 vCPU / 4 GB / 40 GB)" "0"
    ask PLAN_STANDARD_PRICE "Standard price ₹ (4 vCPU / 8 GB / 80 GB)" "0"
    ask PLAN_PRO_PRICE "Pro price ₹ (8 vCPU / 16 GB / 160 GB)" "0"
    ask PAYMENT_ADMIN_CHANNEL_ID "Payment admin channel ID (0 = DM)" "0"

    echo
    info "4/5 IP pool"
    ask IPAM_BIND_MODE "Bind mode: record | bridged | nat" "record"
    if [[ "$(get_env IPAM_BIND_MODE)" == "nat" ]]; then
        ask IPAM_HOST_IFACE "Host interface" "$(default_iface)"
    fi
    if yesno "Auto-assign a pool IP to every purchased VPS?" n; then
        set_env IPAM_AUTO_ASSIGN true
    else
        set_env IPAM_AUTO_ASSIGN false
    fi
    ask IPAM_POOLS "Pools: name|cidr|gateway|node_id;name2|cidr2"

    echo
    info "5/5 Port forwarding"
    ask PORT_RANGE_START "Public port range start" "20000"
    ask PORT_RANGE_END "Public port range end" "50000"
    ask PORT_RESERVED "Reserved ports (comma separated)"
    ask PORT_MAX_PER_VPS "Max forwards per VPS" "20"
    if yesno "Allow users to select their own public port?" n; then
        set_env PORT_ALLOW_CUSTOM true
    else
        set_env PORT_ALLOW_CUSTOM false
    fi

    validate_env
}

validate_env() {
    local lo hi adm tok mode
    lo="$(get_env PORT_RANGE_START)"
    hi="$(get_env PORT_RANGE_END)"
    [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] ||
        die "Port range values must be numeric."
    (( lo >= 1024 && hi <= 65535 && lo < hi )) ||
        die "Port range must satisfy 1024 <= start < end <= 65535."

    mode="$(get_env IPAM_BIND_MODE)"
    case "$mode" in
        record|bridged|nat) ;;
        *) die "IPAM_BIND_MODE must be record, bridged or nat." ;;
    esac

    adm="$(get_env MAIN_ADMIN_ID)"
    [[ -n "$adm" ]] || die "MAIN_ADMIN_ID is required. Re-run the configuration wizard."
    [[ "$adm" =~ ^[0-9]{15,21}$ ]] ||
        die "MAIN_ADMIN_ID must be a numeric Discord user ID (15–21 digits)."

    tok="$(get_env DISCORD_TOKEN)"
    [[ -n "$tok" ]] || die "DISCORD_TOKEN is required. Re-run the configuration wizard."

    if [[ "$(get_env PAYMENT_GATEWAYS)" == *razorpay* ]]; then
        [[ -n "$(get_env RAZORPAY_KEY_ID)" && -n "$(get_env RAZORPAY_KEY_SECRET)" ]] ||
            warn "Razorpay enabled but credentials are missing."
    fi

    ok "Configuration validated"
}

install_packages() {
    section "SYSTEM DEPENDENCIES"
    export DEBIAN_FRONTEND=noninteractive
    local log="/tmp/svm-install-pkgs-${STAMP}.log"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >"$log" 2>&1 || warn "apt update had warnings: $log"
        apt-get install -y \
            python3 python3-venv python3-pip python3-dev curl ca-certificates \
            git sqlite3 openssh-client iproute2 iptables procps util-linux \
            rsync unzip jq openssl >/dev/null 2>"$log" ||
            die "Core package installation failed: $log"

        local pkg
        for pkg in dnsutils librsvg2-bin lxc lxc-utils libvirt-clients qemu-utils qemu-system-x86 qemu-kvm; do
            apt-get install -y "$pkg" >>"$log" 2>&1 || warn "Optional package unavailable: $pkg"
        done
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 python3-pip python3-devel curl ca-certificates git sqlite \
            openssh-clients iproute iptables procps-ng rsync unzip jq openssl \
            qemu-img libvirt-client >>"$log" 2>&1 || warn "Some packages unavailable: $log"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 python3-pip curl ca-certificates git sqlite \
            openssh-clients iproute iptables procps-ng rsync unzip jq openssl \
            qemu-img libvirt-client >>"$log" 2>&1 || warn "Some packages unavailable: $log"
    else
        die "Unsupported package manager."
    fi

    local c
    for c in python3 git curl openssl; do
        command -v "$c" >/dev/null 2>&1 || die "$c is required."
    done
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' ||
        die "Python 3.9+ is required."
    ok "System dependencies ready"
}

backup_snapshot() {
    section "SAFE BACKUP"
    mkdir -p "$APP_DIR" "$BACKUP_DIR" "$APP_DIR/data" "$APP_DIR/logs" "$APP_DIR/db_backups"
    chmod 700 "$APP_DIR" "$APP_DIR/data" "$BACKUP_DIR"

    SNAP="${BACKUP_DIR}/upgrade-${STAMP}"
    mkdir -p "$SNAP"

    local f
    for f in bot.py webssh.html requirements.txt .env; do
        [[ -f "$APP_DIR/$f" ]] && cp -a "$APP_DIR/$f" "$SNAP/$f"
    done

    if [[ -f "$APP_DIR/vps.db" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$APP_DIR/vps.db" ".backup '$SNAP/vps.db'" 2>/dev/null ||
                cp -a "$APP_DIR/vps.db" "$SNAP/vps.db"
        else
            cp -a "$APP_DIR/vps.db" "$SNAP/vps.db"
        fi
    fi

    chmod 700 "$SNAP"
    mapfile -t snaps < <(ls -1dt "$BACKUP_DIR"/upgrade-* 2>/dev/null || true)
    if ((${#snaps[@]} > KEEP_SNAPSHOTS)); then
        for ((i=KEEP_SNAPSHOTS; i<${#snaps[@]}; i++)); do
            rm -rf -- "${snaps[$i]}"
        done
    fi

    ok "Backup created: $SNAP"
}

fetch_sources() {
    section "SOURCES"
    TMP_DIR="$(mktemp -d /tmp/svm-install.XXXXXX)"
    mkdir -p "$TMP_DIR/repo"

    if [[ -n "${V11_ZIP_ROOT:-}" && -f "${V11_ZIP_ROOT}/bot.py" ]]; then
        cp -a "$V11_ZIP_ROOT/." "$TMP_DIR/repo/"
        ok "Using v11.zip as primary source"
    else
        if [[ -z "$LOCAL_BOT" && -f "$SCRIPT_DIR/bot.py" ]]; then
            LOCAL_BOT="$SCRIPT_DIR/bot.py"
        fi

        local have_local=0
        [[ -f "$SCRIPT_DIR/webssh.html" ]] && [[ -f "$SCRIPT_DIR/requirements.txt" ]] && have_local=1

        if (( ! have_local )); then
            git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMP_DIR/repo" >/dev/null 2>&1 ||
                die "Git clone failed and local package is incomplete."
            ok "Cloned $REPO"
        else
            cp -a "$SCRIPT_DIR/." "$TMP_DIR/repo/" 2>/dev/null || true
            ok "Using local installer directory as source"
        fi
    fi

    SRC_BOT="${LOCAL_BOT:-$TMP_DIR/repo/bot.py}"
    SRC_WEBSSH="$TMP_DIR/repo/webssh.html"
    SRC_REQ="$TMP_DIR/repo/requirements.txt"

    [[ -f "$SRC_BOT" ]] || die "bot.py not found."
    [[ -f "$SRC_WEBSSH" ]] || die "webssh.html not found."
    [[ -f "$SRC_REQ" ]] || die "requirements.txt not found."

    info "bot.py: $(wc -l < "$SRC_BOT") lines"
    info "bot.py size: $(du -h "$SRC_BOT" | awk '{print $1}')"
}

merge_env() {
    section "ENVIRONMENT"
    mkdir -p "$APP_DIR"

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "$TMP_DIR/repo/.env.example" ]]; then
            cp "$TMP_DIR/repo/.env.example" "$ENV_FILE"
        else
            : > "$ENV_FILE"
        fi
        chmod 600 "$ENV_FILE"
        ok "Created $ENV_FILE"
    else
        ok "Existing .env preserved"
    fi

    if [[ -f "$TMP_DIR/repo/.env.example" ]]; then
        local line key
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
            key="${BASH_REMATCH[1]}"
            grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" ||
                printf '%s\n' "$line" >> "$ENV_FILE"
        done < "$TMP_DIR/repo/.env.example"
    fi

    write_default_env
    apply_env_overrides
    chmod 600 "$ENV_FILE"
    ok "Environment merged without overwriting existing values"
}

deploy_files() {
    section "DEPLOY"
    mkdir -p "$APP_DIR" "$APP_DIR/motd"

    install -m 750 "$SRC_BOT" "$APP_DIR/bot.py"
    install -m 644 "$SRC_WEBSSH" "$APP_DIR/webssh.html"
    install -m 644 "$SRC_REQ" "$APP_DIR/requirements.txt"

    local motd_src=""
    if [[ -f "$TMP_DIR/repo/motd/svm-motd-installer.sh" ]]; then
        motd_src="$TMP_DIR/repo/motd/svm-motd-installer.sh"
    elif [[ -f "$SCRIPT_DIR/motd/svm-motd-installer.sh" ]]; then
        motd_src="$SCRIPT_DIR/motd/svm-motd-installer.sh"
    fi
    if [[ -n "$motd_src" ]]; then
        install -m 755 "$motd_src" "$APP_DIR/motd/svm-motd-installer.sh"
        ok "MOTD script deployed"
    fi

    [[ -f "$TMP_DIR/repo/.env.example" ]] &&
        install -m 644 "$TMP_DIR/repo/.env.example" "$APP_DIR/.env.example" || true

    local dir
    for dir in assets templates static source scripts tests; do
        if [[ -d "$TMP_DIR/repo/$dir" ]]; then
            mkdir -p "$APP_DIR/$dir"
            cp -a "$TMP_DIR/repo/$dir/." "$APP_DIR/$dir/"
            info "Deployed $dir/"
        fi
    done

    # Keep a copy of the exact installer used for svm update/rollback.
    mkdir -p "$APP_DIR/source"
    install -m 700 "${BASH_SOURCE[0]}" "$APP_DIR/source/install.sh"

    ok "Application files deployed"
}

setup_venv() {
    section "PYTHON ENVIRONMENT"
    PY="$APP_DIR/venv/bin/python"
    PIP="$APP_DIR/venv/bin/pip"

    [[ -x "$PY" ]] || python3 -m venv "$APP_DIR/venv"
    "$PY" -m pip install --quiet --upgrade pip setuptools wheel
    "$PIP" install --quiet --upgrade -r "$APP_DIR/requirements.txt"

    # Common runtime dependencies; existing requirements remain authoritative.
    "$PIP" install --quiet --upgrade discord.py python-dotenv requests paramiko flask flask-cors

    "$PIP" install --quiet cairosvg >/dev/null 2>&1 ||
        warn "cairosvg unavailable; SVG/rsvg fallback may be used."

    ok "Python environment ready"
}


patch_bot_runtime() {
    section "BOT RUNTIME COMPATIBILITY"
    # Make the deployed bot load its own .env first, then fall back to the
    # installer's canonical /opt/svm/.env when launched from the source repo.
    python3 - "$APP_DIR/bot.py" "$ENV_FILE" <<'PYBOT'
import ast, os, re, sys, tempfile
path, env_file = sys.argv[1:3]
src = open(path, encoding="utf-8").read()
original = src
# Path is used by MOTD/database helpers in some V11.3 builds. Ensure import
# exists before any runtime code, while preserving __future__ import rules.
if not re.search(r"(?m)^\s*from\s+pathlib\s+import\s+.*\bPath\b", src):
    lines = src.splitlines(True)
    insert_at = 0
    # Preserve shebang, encoding comment, module docstring, and future imports.
    if lines and lines[0].startswith("#!"):
        insert_at = 1
    while insert_at < len(lines) and (not lines[insert_at].strip() or lines[insert_at].lstrip().startswith("#")):
        insert_at += 1
    # If a module docstring is present, skip it safely via AST.
    try:
        tree = ast.parse(src)
        if ast.get_docstring(tree) and tree.body and isinstance(tree.body[0], ast.Expr):
            insert_at = tree.body[0].end_lineno
            while insert_at < len(lines) and not lines[insert_at].strip():
                insert_at += 1
        for node in tree.body:
            if isinstance(node, ast.ImportFrom) and node.module == "__future__":
                insert_at = max(insert_at, node.end_lineno)
    except SyntaxError:
        pass
    lines.insert(insert_at, "from pathlib import Path\n")
    src = "".join(lines)
# Replace bare load_dotenv() with deterministic paths. Use source-tree .env if
# it has a token; otherwise load canonical installer env from /opt/svm/.env.
pattern = r"(?m)^\s*load_dotenv\(\s*\)\s*$"
replacement = (
    "_svm_local_env = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')\n"
    "load_dotenv(_svm_local_env)\n"
    f"if not os.getenv('DISCORD_TOKEN') and os.path.isfile({env_file!r}):\n"
    f"    load_dotenv({env_file!r}, override=True)"
)
if re.search(pattern, src):
    src = re.sub(pattern, replacement, src, count=1)
else:
    # Handle builds that don't use python-dotenv's no-argument form.
    if "from dotenv import load_dotenv" in src and "_svm_local_env" not in src:
        needle = "from dotenv import load_dotenv"
        # Do not risk injecting a second loader in an unexpected layout.
        src = src.replace(needle, needle + "\n# SVM installer env path compatibility", 1)
# Validate syntax before atomically replacing the live file.
ast.parse(src, filename=path)
if src != original:
    fd, tmp = tempfile.mkstemp(prefix=".bot.py.", dir=os.path.dirname(path), text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(src)
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)
print("Path import and .env lookup verified")
PYBOT
    ok "Bot runtime compatibility patch applied"
}

validate_bot() {
    section "STATIC VALIDATION"
    APP_DIR_FOR_PY="$APP_DIR" "$PY" - <<'PY'
import ast, os, sys
from pathlib import Path

path = Path(os.environ["APP_DIR_FOR_PY"]) / "bot.py"
src = path.read_text(encoding="utf-8")
tree = ast.parse(src)

required = (
    "import discord",
    "sqlite3",
    "from flask import Flask",
)
for needle in required:
    if needle not in src:
        raise SystemExit(f"Required component missing: {needle}")

runs = [
    n.lineno for n in ast.walk(tree)
    if isinstance(n, ast.Call)
    and getattr(n.func, "attr", "") == "run"
    and getattr(getattr(n.func, "value", None), "id", "") == "bot"
]
defs_end = max(
    (n.end_lineno for n in tree.body
     if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))),
    default=0
)
if runs and min(runs) < defs_end:
    raise SystemExit(
        f"bot.run() at line {min(runs)} appears before code ending at line {defs_end}."
    )

print(f"AST OK • {len(src.splitlines())} lines")
PY
    ok "bot.py syntax/component validation passed"
}

setup_firewall() {
    section "FIREWALL"
    local lo hi port
    lo="$(get_env PORT_RANGE_START)"
    hi="$(get_env PORT_RANGE_END)"
    port="$(get_env PAYMENT_WEBHOOK_PORT)"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${lo}:${hi}/tcp" >/dev/null || true
        ufw allow "${lo}:${hi}/udp" >/dev/null || true
        if (( SETUP_CADDY )); then
            ufw allow 80/tcp >/dev/null || true
            ufw allow 443/tcp >/dev/null || true
        fi
        ok "ufw rules applied for ${lo}-${hi}"
    else
        info "ufw is not active; check your cloud firewall/security group."
    fi

    if [[ "$(get_env PAYMENT_WEBHOOK_HOST)" == "0.0.0.0" ]]; then
        warn "Webhook port ${port} is exposed over plain HTTP. Use HTTPS proxy."
    fi
}

setup_caddy() {
    (( SETUP_CADDY )) || return 0
    section "HTTPS / CADDY"

    local url host port
    url="$(get_env SVM_PUBLIC_URL)"
    host="${url#https://}"
    host="${host%%/*}"
    port="$(get_env PAYMENT_WEBHOOK_PORT)"

    if ! command -v caddy >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y caddy >/dev/null 2>&1 ||
                warn "Could not install Caddy; configure HTTPS manually."
        else
            warn "Automatic Caddy installation requires apt on this installer."
        fi
    fi
    command -v caddy >/dev/null 2>&1 || return 0

    mkdir -p /etc/caddy
    touch /etc/caddy/Caddyfile

    python3 - "$host" "$port" <<'PY'
import re, sys
host, port = sys.argv[1], sys.argv[2]
path = "/etc/caddy/Caddyfile"
text = open(path, encoding="utf-8").read()
text = re.sub(r"\n?# SVM\+ BEGIN.*?# SVM\+ END\n?", "\n", text, flags=re.S)
block = f"""
# SVM+ BEGIN
{host} {{
    @svm path /razorpay/webhook /stripe/webhook /health
    handle @svm {{
        reverse_proxy 127.0.0.1:{port}
    }}
    handle {{
        respond "Not found" 404
    }}
}}
# SVM+ END
"""
open(path, "w", encoding="utf-8").write(text.rstrip() + "\n" + block)
PY

    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy >/dev/null 2>&1 ||
        systemctl restart caddy >/dev/null 2>&1 ||
        warn "Caddy failed to reload."
    ok "Caddy configured for https://${host}"
}

install_service() {
    section "SYSTEMD"

    cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=SVM+ V11.3 VPS Platform — Made by AnkitCoder
Documentation=https://github.com/AnkitKing7/Svm-v11.3-bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/bot.py
Restart=always
RestartSec=5
StartLimitIntervalSec=120
StartLimitBurst=10
TimeoutStopSec=30
KillSignal=SIGINT
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=svm

[Install]
WantedBy=multi-user.target
UNIT

    cat > "/etc/systemd/system/${SERVICE}-backup.service" <<UNIT
[Unit]
Description=SVM+ SQLite database backup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/svm backup --quiet
UNIT

    cat > "/etc/systemd/system/${SERVICE}-backup.timer" <<UNIT
[Unit]
Description=Daily SVM+ database backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable "${SERVICE}.service" "${SERVICE}-backup.timer" >/dev/null 2>&1 || true
    systemctl start "${SERVICE}-backup.timer" >/dev/null 2>&1 || true
    ok "systemd service + daily backup timer installed"
}

install_cli() {
    section "SVM CLI"

    cat > /usr/local/bin/svm <<'CLI'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="__APP_DIR__"
SERVICE="__SERVICE__"
ENV_FILE="$APP_DIR/.env"
INSTALLER="$APP_DIR/source/install.sh"

envval() {
    local k="$1"
    grep -E "^[[:space:]]*(export[[:space:]]+)?${k}=" "$ENV_FILE" 2>/dev/null |
        tail -n1 | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]$//"
}

case "${1:-help}" in
    status)
        systemctl status "$SERVICE" --no-pager
        ;;
    logs)
        journalctl -u "$SERVICE" -f -n "${2:-100}"
        ;;
    restart)
        systemctl restart "$SERVICE"
        echo "SVM restarted."
        ;;
    stop)
        systemctl stop "$SERVICE"
        echo "SVM stopped."
        ;;
    start)
        systemctl start "$SERVICE"
        echo "SVM started."
        ;;
    config)
        "${EDITOR:-nano}" "$ENV_FILE"
        echo "Run: svm restart"
        ;;
    env)
        if [[ -n "${2:-}" ]]; then
            envval "$2"
            echo
        else
            echo "Usage: svm env KEY"
        fi
        ;;
    backup)
        dest="$APP_DIR/db_backups/vps-$(date +%Y%m%d-%H%M%S).db"
        mkdir -p "$APP_DIR/db_backups"
        if [[ -f "$APP_DIR/vps.db" ]]; then
            sqlite3 "$APP_DIR/vps.db" ".backup '$dest'"
            chmod 600 "$dest"
            ls -1t "$APP_DIR"/db_backups/vps-*.db 2>/dev/null |
                tail -n +15 | xargs -r rm -f
            [[ "${2:-}" == "--quiet" ]] || echo "Backup: $dest"
        else
            [[ "${2:-}" == "--quiet" ]] || echo "vps.db not found yet."
        fi
        ;;
    rollback)
        shift
        exec bash "$INSTALLER" --rollback "$@"
        ;;
    update)
        shift
        exec bash "$INSTALLER" "$@"
        ;;
    ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor|ai-test|ai-logs|ai-configure|ai-update|ai-remove-model)
        exec bash "$INSTALLER" "$@"
        ;;
    doctor)
        echo "service : $(systemctl is-active "$SERVICE" 2>/dev/null || true)"
        echo "token   : $([[ -n "$(envval DISCORD_TOKEN)" ]] && echo set || echo MISSING)"
        echo "gateways: $(envval PAYMENT_GATEWAYS)"
        echo "ip mode : $(envval IPAM_BIND_MODE)"
        echo "ports   : $(envval PORT_RANGE_START)-$(envval PORT_RANGE_END)"
        p="$(envval PAYMENT_WEBHOOK_PORT)"
        if curl -fsS --max-time 3 "http://127.0.0.1:${p:-8787}/health" >/dev/null 2>&1; then
            echo "webhook : up on :${p:-8787}"
        else
            echo "webhook : down/unavailable"
        fi
        u="$(envval SVM_PUBLIC_URL)"
        if [[ -n "$u" ]]; then
            if curl -fsS --max-time 5 "$u/health" >/dev/null 2>&1; then
                echo "public  : $u reachable"
            else
                echo "public  : $u NOT reachable"
            fi
        fi
        ;;
    *)
        cat <<EOF
SVM+ CLI
  svm status
  svm logs [N]
  svm start|stop|restart
  svm config
  svm env KEY
  svm backup
  svm rollback [SNAPSHOT]
  svm update [installer options]
  svm doctor
  svm ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor
  svm ai-test|ai-logs [N]|ai-configure [BASE_URL] [MODEL]|ai-update
  svm ai-remove-model MODEL_ID
EOF
        ;;
esac
CLI

    sed -i "s|__APP_DIR__|${APP_DIR}|g; s|__SERVICE__|${SERVICE}|g" /usr/local/bin/svm
    chmod 755 /usr/local/bin/svm
    ok "CLI installed: svm status / logs / doctor / backup / ai-*"
}

localai_base_url() {
    local u
    u="$(get_env LOCALAI_BASE_URL)"
    printf '%s' "${u:-http://127.0.0.1:18080}"
}

ai_curl() {
    local path="$1"
    local timeout="${2:-8}"
    local key
    key="$(get_env LOCALAI_API_KEY)"
    if [[ -n "$key" ]]; then
        curl -fsS --max-time "$timeout" -H "Authorization: Bearer ${key}" "$(localai_base_url)$path"
    else
        curl -fsS --max-time "$timeout" "$(localai_base_url)$path"
    fi
}

localai_runtime() {
    if command -v docker >/dev/null 2>&1 &&
       docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$LOCALAI_CONTAINER"; then
        echo docker
    elif systemctl list-unit-files 2>/dev/null | grep -q '^svm-localai.service'; then
        echo systemd
    else
        echo external
    fi
}

ai_models_list() {
    ai_curl /v1/models 2>/dev/null |
        python3 -c 'import json,sys; print("\n".join(x.get("id","") for x in json.load(sys.stdin).get("data",[])))' 2>/dev/null || true
}

ai_apply_model() {
    local model="${1:-llama-3.2-1b-instruct:q4_k_m}"
    local key response uuid job_url status error i
    key="$(get_env LOCALAI_API_KEY)"
    info "No LocalAI models found; requesting gallery install: ${model}"
    if [[ -n "$key" ]]; then
        response="$(curl -fsS --max-time 30 -X POST \
            -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
            -d "{\"id\":\"${model}\"}" "$(localai_base_url)/models/apply")" || {
                warn "LocalAI model install request failed (API key/network/gallery)."
                return 1
            }
    else
        response="$(curl -fsS --max-time 30 -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"id\":\"${model}\"}" "$(localai_base_url)/models/apply")" || {
                warn "LocalAI model install request failed (network/gallery)."
                return 1
            }
    fi
    # Some LocalAI versions complete /models/apply synchronously and return no job UUID.
    if ai_models_list | grep -Fqx "$model"; then
        set_env LOCALAI_MODEL "$model"
        ok "LocalAI model installed: $model"
        return 0
    fi
    uuid="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uuid", ""))' 2>/dev/null || true)"
    job_url="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
    if [[ -z "$uuid" && -z "$job_url" ]]; then
        warn "LocalAI returned no model-install job ID: ${response:0:300}"
        return 1
    fi
    [[ -n "$job_url" ]] || job_url="$(localai_base_url)/models/jobs/${uuid}"
    info "Model download started. This may take several minutes and needs free disk space."
    for i in $(seq 1 900); do
        if [[ -n "$key" ]]; then
            status="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${key}" "$job_url" 2>/dev/null || true)"
        else
            status="$(curl -fsS --max-time 10 "$job_url" 2>/dev/null || true)"
        fi
        if [[ -n "$status" ]]; then
            error="$(printf '%s' "$status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error") or "")' 2>/dev/null || true)"
            if [[ -n "$error" && "$error" != "None" ]]; then
                warn "LocalAI model install failed: $error"
                return 1
            fi
            if printf '%s' "$status" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("processed") is True else 1)' 2>/dev/null; then
                break
            fi
        fi
        sleep 2
    done
    if ! ai_models_list | grep -Fqx "$model"; then
        local first
        first="$(ai_models_list | head -n1)"
        if [[ -z "$first" ]]; then
            warn "Model job finished but /v1/models is still empty. Check: svm ai-doctor; docker logs ${LOCALAI_CONTAINER}"
            return 1
        fi
        model="$first"
    fi
    # Always persist the model that is actually present. The requested gallery
    # name may resolve to a different installed ID, so never keep a stale value.
    set_env LOCALAI_MODEL "$model"
    ok "LocalAI model available and configured: $model"
}

ai_ensure_model() {
    local models model
    models="$(ai_models_list)"
    if [[ -n "$models" ]]; then
        model="$(get_env LOCALAI_MODEL)"
        if [[ -z "$model" ]] || ! printf '%s\n' "$models" | grep -Fqx "$model"; then
            model="$(printf '%s\n' "$models" | head -n1)"
            set_env LOCALAI_MODEL "$model"
            info "Selected installed LocalAI model: $model"
        fi
        return 0
    fi
    [[ "$(get_env LOCALAI_AUTO_INSTALL_MODEL)" == "false" ]] && {
        warn "No LocalAI models installed and automatic model install is disabled."
        return 1
    }
    ai_apply_model "$(get_env LOCALAI_MODEL)"
}

install_localai_docker() {
    section "LOCALAI DOCKER"
    command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker first."

    # Respect the existing SVM host setup: LocalAI runs on loopback :18080.
    # Port :8080 belongs to another service (hkvm) and must never be replaced.
    set_env LOCALAI_BASE_URL "http://127.0.0.1:18080"
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fqx "$LOCALAI_CONTAINER"; then
        info "Found existing container '$LOCALAI_CONTAINER'; preserving its volumes and configuration."
        docker start "$LOCALAI_CONTAINER" >/dev/null 2>&1 || true
        ok "Existing LocalAI container retained"
        return 0
    fi

    docker volume create localai-models >/dev/null
    docker volume create localai-backends >/dev/null
    docker volume create localai-configuration >/dev/null
    docker volume create localai-data >/dev/null
    info "Image: $LOCALAI_IMAGE"
    docker pull "$LOCALAI_IMAGE"
    docker run -d \
        --name "$LOCALAI_CONTAINER" \
        --restart unless-stopped \
        -p 127.0.0.1:18080:8080 \
        -v localai-models:/models \
        -v localai-backends:/backends \
        -v localai-configuration:/configuration \
        -v localai-data:/data \
        "$LOCALAI_IMAGE" --models-path /models >/dev/null

    ok "LocalAI Docker container started at 127.0.0.1:18080"
}

install_localai_systemd() {
    section "LOCALAI SYSTEMD"
    local bin
    bin="$(command -v local-ai || true)"
    [[ -n "$bin" ]] || die "local-ai binary not found."

    id localai >/dev/null 2>&1 || useradd --system --home "$LOCALAI_DIR" --shell /usr/sbin/nologin localai
    mkdir -p "$LOCALAI_DIR/models"
    chown -R localai:localai "$LOCALAI_DIR"

    cat > /etc/systemd/system/svm-localai.service <<UNIT
[Unit]
Description=SVM+ LocalAI runtime
After=network-online.target
Wants=network-online.target

[Service]
User=localai
Group=localai
WorkingDirectory=${LOCALAI_DIR}
ExecStart=${bin} run --models-path ${LOCALAI_DIR}/models --address 127.0.0.1:18080
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
StandardOutput=journal
StandardError=journal
SyslogIdentifier=svm-localai

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now svm-localai.service
    set_env LOCALAI_BASE_URL "http://127.0.0.1:18080"
    ok "svm-localai.service started"
}

ai_install() {
    section "AI INSTALL"
    if ! ai_curl /v1/models >/dev/null 2>&1; then
        if command -v docker >/dev/null 2>&1; then
            install_localai_docker
        elif command -v local-ai >/dev/null 2>&1; then
            install_localai_systemd
        else
            warn "Neither Docker nor local-ai is installed."
            if command -v apt-get >/dev/null 2>&1 && yesno "Install Docker automatically?" y; then
                curl -fsSL https://get.docker.com | sh
                install_localai_docker
            else
                die "Install Docker or local-ai, then run: bash install.sh ai-install"
            fi
        fi
    else
        ok "LocalAI already reachable at $(localai_base_url)"
    fi

    local attempt
    for attempt in $(seq 1 60); do
        if ai_curl /v1/models >/dev/null 2>&1; then break; fi
        sleep 2
    done
    ai_curl /v1/models >/dev/null 2>&1 || {
        warn "LocalAI did not become ready at $(localai_base_url)."
        info "Check: docker logs ${LOCALAI_CONTAINER} OR journalctl -u svm-localai -n 80 --no-pager"
        return 1
    }
    # Repair blank/stale model configuration and ensure bot + LocalAI agree.
    if [[ -z "$(get_env LOCALAI_MODEL)" ]]; then
        set_env LOCALAI_MODEL "llama-3.2-1b-instruct:q4_k_m"
    fi
    ai_ensure_model || return 1
    local selected
    selected="$(get_env LOCALAI_MODEL)"
    if [[ -z "$selected" ]]; then
        selected="$(ai_models_list | head -n1)"
        [[ -n "$selected" ]] || { warn "No model ID returned by LocalAI; LOCALAI_MODEL remains unset."; return 1; }
        set_env LOCALAI_MODEL "$selected"
    fi
    if ! printf '%s\n' "$(ai_models_list)" | grep -Fqx "$selected"; then
        selected="$(ai_models_list | head -n1)"
        [[ -n "$selected" ]] || { warn "No installed LocalAI model is available."; return 1; }
        set_env LOCALAI_MODEL "$selected"
    fi
    ok "LOCALAI_MODEL configured: $(get_env LOCALAI_MODEL)"
}

ai_start() {
    case "$(localai_runtime)" in
        docker)
            docker start "$LOCALAI_CONTAINER" >/dev/null
            ;;
        systemd)
            systemctl start svm-localai.service
            ;;
        *)
            warn "No managed LocalAI runtime detected."
            return 1
            ;;
    esac
    ok "LocalAI started"
}

ai_stop() {
    case "$(localai_runtime)" in
        docker)
            docker stop "$LOCALAI_CONTAINER" >/dev/null
            ;;
        systemd)
            systemctl stop svm-localai.service
            ;;
        *)
            warn "No managed LocalAI runtime detected."
            return 1
            ;;
    esac
    ok "LocalAI stopped"
}

ai_restart() {
    ai_stop || true
    ai_start
}

ai_status() {
    section "AI STATUS"
    echo "provider : $(get_env AI_PROVIDER)"
    echo "enabled  : $(get_env AI_ENABLED)"
    echo "endpoint : $(localai_base_url)"
    echo "runtime  : $(localai_runtime)"

    if ai_curl /v1/models >/dev/null 2>&1; then
        echo "api      : reachable"
        echo "models:"
        ai_models_list | sed 's/^/  - /'
    else
        echo "api      : unreachable"
    fi
}

ai_models() {
    section "LOCALAI MODELS"
    ai_curl /v1/models >/dev/null 2>&1 ||
        die "LocalAI is not reachable at $(localai_base_url)"
    local models
    models="$(ai_models_list)"
    if [[ -z "$models" ]]; then
        warn "No LocalAI models installed. Run: bash install.sh ai-install"
        return 1
    fi
    printf '%s\n' "$models" | sed 's/^/  - /'
}

ai_doctor() {
    section "AI DOCTOR"
    echo "AI_ENABLED      = $(get_env AI_ENABLED)"
    echo "AI_PROVIDER     = $(get_env AI_PROVIDER)"
    echo "AI_AGENT_ENABLED= $(get_env AI_AGENT_ENABLED)"
    echo "AI_STREAMING    = $(get_env AI_STREAMING)"
    echo "AI_MEMORY       = $(get_env AI_MEMORY)"
    echo "AI_TOOLS        = $(get_env AI_TOOLS)"
    echo "AI_FILE_TOOLS   = $(get_env AI_FILE_TOOLS)"
    echo "AI_CODE_TOOLS   = $(get_env AI_CODE_TOOLS)"
    echo "AI_VISION       = $(get_env AI_VISION)"
    echo "AI_IMAGE_ENABLED= $(get_env AI_IMAGE_ENABLED)"
    echo "AI_SANDBOX      = $(get_env AI_SANDBOX_ENABLED)"
    echo "endpoint        = $(localai_base_url)"
    echo "LOCALAI_MODEL  = $(get_env LOCALAI_MODEL)"

    if ai_curl /v1/models >/dev/null 2>&1; then
        ok "LocalAI API reachable"
        local count
        count="$(ai_models_list | sed '/^$/d' | wc -l)"
        echo "models          = $count"
        (( count > 0 )) || warn "No LocalAI models installed."
    else
        warn "LocalAI API is unreachable."
        info "Try: svm ai-install"
    fi
}


ai_test() {
    section "LOCALAI INFERENCE TEST"
    local model payload response
    model="$(get_env LOCALAI_MODEL)"
    [[ -n "$model" ]] || die "LOCALAI_MODEL is empty. Run: bash install.sh ai-install"
    ai_curl /v1/models >/dev/null 2>&1 || die "LocalAI API is unreachable at $(localai_base_url)"
    payload="$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"Reply exactly: SVM AI is working!"}],"stream":False}))' "$model")"
    if [[ -n "$(get_env LOCALAI_API_KEY)" ]]; then
        response="$(curl -fsS --max-time 180 -H "Authorization: Bearer $(get_env LOCALAI_API_KEY)" -H 'Content-Type: application/json' -d "$payload" "$(localai_base_url)/v1/chat/completions")" || die "Inference failed. Check: bash install.sh ai-doctor; bash install.sh ai-logs"
    else
        response="$(curl -fsS --max-time 180 -H 'Content-Type: application/json' -d "$payload" "$(localai_base_url)/v1/chat/completions")" || die "Inference failed. Check: bash install.sh ai-doctor; bash install.sh ai-logs"
    fi
    printf '%s\n' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content", "Inference completed, but no message content was returned."))'
    ok "LocalAI chat inference succeeded"
}

ai_logs() {
    section "LOCALAI LOGS"
    case "$(localai_runtime)" in
        docker) docker logs --tail "${2:-100}" "$LOCALAI_CONTAINER" ;;
        systemd) journalctl -u svm-localai.service -n "${2:-100}" --no-pager ;;
        *) warn "No managed LocalAI runtime found; showing API reachability instead."; ai_status ;;
    esac
}

ai_configure() {
    section "LOCALAI CONFIGURATION"
    local endpoint model key
    endpoint="${2:-}"
    model="${3:-}"
    if [[ -z "$endpoint" ]]; then
        if (( INTERACTIVE )); then
            ask LOCALAI_BASE_URL "LocalAI base URL" "$(localai_base_url)"
            ask LOCALAI_MODEL "Chat model ID" "$(get_env LOCALAI_MODEL)"
            ask LOCALAI_API_KEY "LocalAI API key (blank if none)" "" secret
        else
            die "Usage: bash install.sh ai-configure BASE_URL [MODEL]"
        fi
    else
        [[ "$endpoint" =~ ^https?:// ]] || die "Endpoint must start with http:// or https://"
        set_env LOCALAI_BASE_URL "${endpoint%/}"
        [[ -z "$model" ]] || set_env LOCALAI_MODEL "$model"
        ok "LocalAI endpoint/model settings saved to $ENV_FILE"
    fi
    if systemctl cat "$SERVICE" >/dev/null 2>&1; then
        systemctl restart "$SERVICE" && ok "SVM restarted to load AI settings" || warn "Settings saved, but SVM restart failed."
    fi
}

ai_update() {
    section "LOCALAI IMAGE UPDATE"
    [[ "$(localai_runtime)" == docker ]] || die "Managed LocalAI Docker container '$LOCALAI_CONTAINER' not found."
    info "Pulling updated image: $LOCALAI_IMAGE"
    docker pull "$LOCALAI_IMAGE"
    # Preserve the existing container and model volumes; recreate only when it is the known managed container.
    docker inspect "$LOCALAI_CONTAINER" >/dev/null 2>&1 || die "Container disappeared during update."
    local mounts
    mounts="$(docker inspect -f '{{range .Mounts}}{{.Name}}={{.Destination}};{{end}}' "$LOCALAI_CONTAINER")"
    if [[ "$mounts" != *"localai-models=/models"* || "$mounts" != *"localai-backends=/backends"* || "$mounts" != *"localai-configuration=/configuration"* || "$mounts" != *"localai-data=/data"* ]]; then
        die "Container volumes do not match the safe SVM LocalAI layout. Image was pulled, but container was not recreated. Inspect: docker inspect $LOCALAI_CONTAINER"
    fi
    info "Recreating the standard LocalAI container while retaining all four named data volumes."
    docker stop "$LOCALAI_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$LOCALAI_CONTAINER" >/dev/null
    docker run -d \
        --name "$LOCALAI_CONTAINER" \
        --restart unless-stopped \
        -p 127.0.0.1:18080:8080 \
        -v localai-models:/models \
        -v localai-backends:/backends \
        -v localai-configuration:/configuration \
        -v localai-data:/data \
        "$LOCALAI_IMAGE" --models-path /models >/dev/null
    set_env LOCALAI_BASE_URL "http://127.0.0.1:18080"
    ok "LocalAI container updated; persistent model/configuration volumes preserved."
    info "Run: bash install.sh ai-doctor && bash install.sh ai-test"
}

ai_remove_model() {
    local model="${2:-}"
    [[ -n "$model" ]] || die "Usage: bash install.sh ai-remove-model MODEL_ID"
    ai_curl /v1/models >/dev/null 2>&1 || die "LocalAI API is unreachable at $(localai_base_url)"
    if (( INTERACTIVE )); then
        yesno "Remove model '$model' from LocalAI?" n || { info "Cancelled."; return 0; }
    else
        die "Model removal is destructive; run interactively to confirm: bash install.sh ai-remove-model '$model'"
    fi
    local key
    key="$(get_env LOCALAI_API_KEY)"
    if [[ -n "$key" ]]; then
        curl -fsS --max-time 60 -X DELETE -H "Authorization: Bearer $key" "$(localai_base_url)/models/delete/$model" || die "LocalAI model deletion failed."
    else
        curl -fsS --max-time 60 -X DELETE "$(localai_base_url)/models/delete/$model" || die "LocalAI model deletion failed."
    fi
    if [[ "$(get_env LOCALAI_MODEL)" == "$model" ]]; then
        set_env LOCALAI_MODEL ""
        warn "Removed model was selected as LOCALAI_MODEL; choose another with ai-configure or ai-install."
    fi
    ok "Model removal request completed: $model"
}

ai_pick_model() {
    local key="$1"
    local label="$2"
    local models=() m pick i=1

    while IFS= read -r m; do
        [[ -n "$m" ]] && models+=("$m")
    done < <(ai_models_list)

    if ((${#models[@]} == 0)); then
        ask "$key" "$label"
        return
    fi

    printf '  Installed models:\n'
    for m in "${models[@]}"; do
        printf '   [%d] %s\n' "$i" "$m"
        i=$((i + 1))
    done

    (( INTERACTIVE )) || return
    read -r -p "  ${label} (number or model name, blank=keep): " pick
    [[ -z "$pick" ]] && return

    if [[ "$pick" =~ ^[0-9]+$ ]] &&
       (( pick >= 1 && pick <= ${#models[@]} )); then
        pick="${models[$((pick - 1))]}"
    fi
    set_env "$key" "$pick"
}

ai_wizard() {
    section "SVM+ AI AGENT SETUP"
    cat <<'EOF'
  ╔══════════════════════════════════════════════╗
  ║              SVM+ AI AGENT                  ║
  ║ LocalAI • Memory • Tools • Coding • Vision  ║
  ╚══════════════════════════════════════════════╝
EOF

    (( INTERACTIVE )) || {
        info "Non-interactive AI setup: preserving .env/SVM_ENV_* values."
        return
    }

    local choice
    while true; do
        cat <<MENU

  [1] Enable AI              ($(get_env AI_ENABLED))
  [2] Configure endpoint     ($(localai_base_url))
  [3] Select chat model     ($(get_env LOCALAI_MODEL))
  [4] Streaming             ($(get_env AI_STREAMING))
  [5] Memory                ($(get_env AI_MEMORY))
  [6] Coding agent          ($(get_env AI_CODE_TOOLS))
  [7] Sandbox               ($(get_env AI_SANDBOX_ENABLED))
  [8] Vision                ($(get_env AI_VISION))
  [9] Image generation      ($(get_env AI_IMAGE_ENABLED))
  [10] Status channel       ($(get_env STATUS_CHANNEL_ID))
  [11] Live SVG             ($(get_env STATUS_SVG_ENABLED))
  [12] Live PNG             ($(get_env STATUS_PNG_ENABLED))
  [13] Install/check LocalAI
  [14] AI doctor
  [15] Finish

MENU
        read -r -p "  Choose [1-15]: " choice

        case "$choice" in
            1)
                if yesno "Enable AI?" y; then
                    set_env AI_ENABLED true
                    set_env AI_AGENT_ENABLED true
                else
                    set_env AI_ENABLED false
                fi
                ;;
            2)
                ask LOCALAI_BASE_URL "LocalAI base URL" "http://127.0.0.1:18080"
                ask LOCALAI_API_KEY "LocalAI API key (blank if none)" "" secret
                ;;
            3)
                ai_pick_model LOCALAI_MODEL "Chat model"
                ;;
            4)
                if yesno "Stream AI responses?" y; then set_env AI_STREAMING true; else set_env AI_STREAMING false; fi
                ;;
            5)
                if yesno "Enable AI memory?" y; then set_env AI_MEMORY true; else set_env AI_MEMORY false; fi
                ;;
            6)
                if yesno "Enable coding tools?" y; then set_env AI_CODE_TOOLS true; else set_env AI_CODE_TOOLS false; fi
                ;;
            7)
                if yesno "Enable sandbox?" y; then set_env AI_SANDBOX_ENABLED true; else set_env AI_SANDBOX_ENABLED false; fi
                ;;
            8)
                if yesno "Enable vision?" y; then set_env AI_VISION true; else set_env AI_VISION false; fi
                ai_pick_model LOCALAI_VISION_MODEL "Vision model"
                ;;
            9)
                if yesno "Enable image generation?" n; then set_env AI_IMAGE_ENABLED true; else set_env AI_IMAGE_ENABLED false; fi
                ai_pick_model LOCALAI_IMAGE_MODEL "Image model"
                ;;
            10)
                ask STATUS_CHANNEL_ID "Status channel ID"
                ask AI_STATUS_CHANNEL_ID "AI status channel ID"
                ;;
            11)
                if yesno "Enable SVG status?" y; then set_env STATUS_SVG_ENABLED true; else set_env STATUS_SVG_ENABLED false; fi
                ;;
            12)
                if yesno "Enable PNG status?" n; then set_env STATUS_PNG_ENABLED true; else set_env STATUS_PNG_ENABLED false; fi
                ;;
            13)
                ai_install
                ;;
            14)
                ai_doctor
                ;;
            15)
                break
                ;;
            *)
                warn "Choose 1-15."
                ;;
        esac
    done
}

health_check_or_rollback() {
    section "HEALTH CHECK"

    if (( NO_START )); then
        warn "--no-start: service restart skipped."
        return
    fi

    systemctl restart "${SERVICE}.service"

    local i healthy=0
    for i in $(seq 1 20); do
        sleep 2
        systemctl is-active --quiet "${SERVICE}.service" || continue
        if (( i >= 5 )); then
            if ! journalctl -u "${SERVICE}.service" --since "-30s" --no-pager 2>/dev/null |
                grep -Eq 'Traceback|SyntaxError|ImportError|ModuleNotFoundError'; then
                healthy=1
                break
            fi
        fi
    done

    if (( healthy )); then
        ok "SVM service is running with no startup errors."
        return
    fi

    warn "Service failed health check."
    journalctl -u "${SERVICE}.service" -n 60 --no-pager || true

    if [[ -n "$SNAP" && -f "$SNAP/bot.py" ]]; then
        cp -a "$SNAP/bot.py" "$APP_DIR/bot.py"
        [[ -f "$SNAP/requirements.txt" ]] &&
            cp -a "$SNAP/requirements.txt" "$APP_DIR/requirements.txt"
        systemctl restart "${SERVICE}.service" || true
        die "Upgrade failed. Previous bot.py restored from $SNAP."
    fi

    die "Upgrade failed and no previous bot snapshot was available."
}

do_rollback() {
    section "ROLLBACK"
    local target="${ROLLBACK_TARGET:-}"

    if [[ -z "$target" ]]; then
        target="$(ls -1dt "$BACKUP_DIR"/upgrade-* 2>/dev/null | head -n1 || true)"
    elif [[ ! -d "$target" ]]; then
        target="$BACKUP_DIR/$target"
    fi

    [[ -d "$target" ]] || die "Snapshot not found: ${ROLLBACK_TARGET:-latest}"
    [[ -f "$target/bot.py" ]] || die "Snapshot has no bot.py."

    cp -a "$target/bot.py" "$APP_DIR/bot.py"
    [[ -f "$target/requirements.txt" ]] &&
        cp -a "$target/requirements.txt" "$APP_DIR/requirements.txt"
    [[ -f "$target/webssh.html" ]] &&
        cp -a "$target/webssh.html" "$APP_DIR/webssh.html"

    if [[ -f "$target/vps.db" && -f "$APP_DIR/vps.db" ]]; then
        if yesno "Restore database too?" n; then
            cp -a "$target/vps.db" "$APP_DIR/vps.db"
        fi
    elif [[ -f "$target/vps.db" ]]; then
        cp -a "$target/vps.db" "$APP_DIR/vps.db"
    fi

    systemctl restart "${SERVICE}.service" || true
    ok "Rollback restored: $target"
    info ".env was preserved."
}

status_cmd() {
    section "SVM+ STATUS"
    echo "Service : $(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    echo "Version : $(get_env BOT_VERSION)"
    echo "Bot     : $(get_env BOT_NAME)"
    echo "IP      : $(get_env YOUR_SERVER_IP)"
    echo "Ports   : $(get_env PORT_RANGE_START)-$(get_env PORT_RANGE_END)"
    echo "IPAM    : $(get_env IPAM_BIND_MODE)"
    echo "Payment : $(get_env PAYMENT_GATEWAYS)"
    echo "AI      : $(get_env AI_ENABLED) / $(get_env AI_PROVIDER)"
    echo "URL     : $(get_env SVM_PUBLIC_URL)"
}

doctor_cmd() {
    section "SVM+ DOCTOR"
    status_cmd
    echo
    if [[ -f "$APP_DIR/vps.db" ]]; then
        sqlite3 "$APP_DIR/vps.db" "PRAGMA quick_check;" 2>/dev/null || true
    else
        echo "DB      : not created yet"
    fi

    local p
    p="$(get_env PAYMENT_WEBHOOK_PORT)"
    if curl -fsS --max-time 3 "http://127.0.0.1:${p:-8787}/health" >/dev/null 2>&1; then
        echo "Webhook : healthy"
    else
        echo "Webhook : unavailable"
    fi

    journalctl -u "$SERVICE" -n 50 --no-pager 2>/dev/null |
        grep -Ei 'traceback|syntaxerror|importerror|moduleNotFoundError|error' |
        tail -n 10 || true
}

parse_args() {
    while (($#)); do
        case "$1" in
            --configure)
                MODE="configure"
                ;;
            --non-interactive)
                INTERACTIVE=0
                ;;
            --no-start)
                NO_START=1
                ;;
            --local-bot)
                shift
                [[ $# -gt 0 ]] || die "--local-bot requires a file."
                LOCAL_BOT="$1"
                [[ -f "$LOCAL_BOT" ]] || die "Local bot not found: $LOCAL_BOT"
                ;;
            --rollback)
                MODE="rollback"
                if [[ -n "${2:-}" && "${2:-}" != --* ]]; then
                    ROLLBACK_TARGET="$2"
                    shift
                fi
                ;;
            --help|-h)
                cat <<'HELP'
SVM+ V11.3 installer

Install/upgrade:
  sudo bash install.sh
  sudo bash install.sh --configure
  sudo bash install.sh --local-bot /path/bot.py
  sudo bash install.sh --non-interactive
  sudo bash install.sh --no-start

Rollback:
  sudo bash install.sh --rollback
  sudo bash install.sh --rollback upgrade-YYYYMMDD-HHMMSS

AI:
  sudo bash install.sh ai-install
  sudo bash install.sh ai-start
  sudo bash install.sh ai-stop
  sudo bash install.sh ai-restart
  sudo bash install.sh ai-status
  sudo bash install.sh ai-models
  sudo bash install.sh ai-doctor
  sudo bash install.sh ai-test
  sudo bash install.sh ai-logs [N]
  sudo bash install.sh ai-configure [BASE_URL] [MODEL]
  sudo bash install.sh ai-update
  sudo bash install.sh ai-remove-model MODEL_ID

Diagnostics:
  sudo bash install.sh status
  sudo bash install.sh doctor
HELP
                exit 0
                ;;
            status)
                MODE="status"
                ;;
            doctor)
                MODE="doctor"
                ;;
            ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor|ai-test|ai-logs|ai-configure|ai-update|ai-remove-model)
                MODE="$1"
                # AI subcommands may accept positional arguments (log count, endpoint/model, model ID).
                break
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
        shift
    done
}

main_install() {
    banner
    install_unzip_first
    prepare_v11_zip
    install_packages

    mkdir -p "$APP_DIR"
    if [[ -f "$APP_DIR/bot.py" || -f "$APP_DIR/vps.db" || -f "$ENV_FILE" ]]; then
        backup_snapshot
    else
        SNAP="$BACKUP_DIR/initial-${STAMP}"
        mkdir -p "$SNAP"
    fi

    fetch_sources
    merge_env
    configure_env
    deploy_files
    patch_bot_runtime
    setup_venv
    validate_bot
    install_cli
    install_service
    if [[ "$(get_env AI_ENABLED)" == "true" && "$(get_env AI_PROVIDER)" == "localai" ]]; then
        section "LOCALAI AUTO-SETUP"
        if ! ai_install; then
            warn "SVM installation is continuing, but LocalAI/model setup did not complete. Retry: bash install.sh ai-install"
        fi
    fi
    setup_caddy
    setup_firewall
    health_check_or_rollback

    section "INSTALL COMPLETE"
    ok "SVM+ V11.3 is installed."
    echo
    echo "  App directory : $APP_DIR"
    echo "  Config        : $ENV_FILE"
    echo "  Service       : $SERVICE"
    echo "  CLI           : svm"
    echo
    echo "  Commands:"
    echo "    svm status"
    echo "    svm logs"
    echo "    svm doctor"
    echo "    svm config"
    echo "    svm backup"
    echo "    svm ai-status"
    echo "    svm ai-doctor"
    echo
    echo "  Journal:"
    echo "    journalctl -u ${SERVICE} -f"
    echo
}

main() {
    require_root
    parse_args "$@"
    lock_installer

    case "$MODE" in
        status)
            [[ -f "$ENV_FILE" ]] || die "SVM is not installed at $APP_DIR."
            status_cmd
            ;;
        doctor)
            [[ -f "$ENV_FILE" ]] || die "SVM is not installed at $APP_DIR."
            doctor_cmd
            ;;
        configure)
            [[ -f "$ENV_FILE" ]] || die "Run a normal install first."
            # Repair missing defaults before the wizard validates/edits the file.
            # ensure_env only adds absent keys; existing user values are preserved.
            write_default_env
            configure_env
            validate_env
            chmod 600 "$ENV_FILE"
            if systemctl is-active --quiet "$SERVICE" 2>/dev/null ||
               systemctl cat "$SERVICE" >/dev/null 2>&1; then
                if systemctl restart "$SERVICE"; then
                    ok "Configuration saved and SVM service restarted."
                else
                    die "Configuration was saved, but service restart failed. Check: journalctl -u ${SERVICE} -n 80 --no-pager"
                fi
            else
                warn "Configuration saved. SVM service is not installed yet; start it after installation."
            fi
            ;;
        rollback)
            do_rollback
            ;;
        ai-install)
            [[ -f "$ENV_FILE" ]] || die "Run a normal install first."
            ai_install || die "LocalAI/model setup failed. Run: bash install.sh ai-doctor"
            [[ -n "$(get_env LOCALAI_MODEL)" ]] || die "LOCALAI_MODEL is still empty; refusing to restart SVM."
            # systemd reads EnvironmentFile on every start; restart so the bot
            # receives the newly selected model instead of its old environment.
            if systemctl cat "$SERVICE" >/dev/null 2>&1; then
                systemctl restart "$SERVICE" || die "Model configured, but SVM restart failed. Check: journalctl -u ${SERVICE} -n 80 --no-pager"
                ok "SVM restarted with LOCALAI_MODEL configured."
            else
                info "SVM service not installed; LOCALAI_MODEL is saved in $ENV_FILE."
            fi
            ;;
        ai-start)
            ai_start
            ;;
        ai-stop)
            ai_stop
            ;;
        ai-restart)
            ai_restart
            ;;
        ai-status)
            ai_status
            ;;
        ai-models)
            ai_models
            ;;
        ai-doctor)
            ai_doctor
            ;;
        ai-test)
            ai_test
            ;;
        ai-logs)
            ai_logs "$@"
            ;;
        ai-configure)
            ai_configure "$@"
            ;;
        ai-update)
            ai_update
            ;;
        ai-remove-model)
            ai_remove_model "$@"
            ;;
        install)
            main_install
            ;;
        *)
            die "Invalid installer mode: $MODE"
            ;;
    esac
}

main "$@"
