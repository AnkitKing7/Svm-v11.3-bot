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
#   sudo bash install.sh ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor
#   sudo bash install.sh status|doctor
#   sudo bash install.sh motd install|status|preview|uninstall
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

LOCALAI_CONTAINER="${SVM_LOCALAI_CONTAINER:-svm-localai}"
LOCALAI_IMAGE="${SVM_LOCALAI_IMAGE:-localai/localai:latest-aio-cpu}"
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
            # Show typed characters so users can see/paste the token correctly.
            # Warning: the Discord token will be visible on screen while entering it.
            [[ -n "$cur" ]] && shown=" [press Enter to keep current]"
            read -r -p "  ${prompt}${shown}: " reply </dev/tty || die "Could not read ${key} from terminal."
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
    ensure_env LOCALAI_BASE_URL "http://127.0.0.1:8080"
    ensure_env LOCALAI_API_KEY ""
    ensure_env LOCALAI_MODEL ""
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
    ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor)
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
    printf '%s' "${u:-http://127.0.0.1:8080}"
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

install_localai_docker() {
    section "LOCALAI DOCKER"
    command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker first."

    mkdir -p "$LOCALAI_DIR/models"
    info "Image: $LOCALAI_IMAGE"
    if (( INTERACTIVE )); then
        yesno "Pull and start LocalAI now?" y || {
            info "Skipped. Run: svm ai-install"
            return
        }
    fi

    docker pull "$LOCALAI_IMAGE"
    docker rm -f "$LOCALAI_CONTAINER" >/dev/null 2>&1 || true
    docker run -d \
        --name "$LOCALAI_CONTAINER" \
        --restart unless-stopped \
        -p 127.0.0.1:8080:8080 \
        -e MODELS_PATH=/models \
        -v "$LOCALAI_DIR/models:/models" \
        "$LOCALAI_IMAGE" >/dev/null

    set_env LOCALAI_BASE_URL "http://127.0.0.1:8080"
    ok "LocalAI Docker container started"
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
ExecStart=${bin} run --models-path ${LOCALAI_DIR}/models --address 127.0.0.1:8080
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
    set_env LOCALAI_BASE_URL "http://127.0.0.1:8080"
    ok "svm-localai.service started"
}

ai_install() {
    section "AI INSTALL"
    if ai_curl /v1/models >/dev/null 2>&1; then
        ok "LocalAI already reachable at $(localai_base_url)"
        return
    fi

    if command -v docker >/dev/null 2>&1; then
        install_localai_docker
        return
    fi

    if command -v local-ai >/dev/null 2>&1; then
        install_localai_systemd
        return
    fi

    warn "Neither Docker nor local-ai is installed."
    if command -v apt-get >/dev/null 2>&1 && yesno "Install Docker automatically?" y; then
        curl -fsSL https://get.docker.com | sh
        install_localai_docker
    else
        die "Install Docker or local-ai, then run: bash install.sh ai-install"
    fi
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
    ai_models_list | sed 's/^/  - /'
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
                ask LOCALAI_BASE_URL "LocalAI base URL" "http://127.0.0.1:8080"
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

Diagnostics:
  sudo bash install.sh status
  sudo bash install.sh doctor

Host MOTD (self-contained; no separate motd file needed):
  sudo bash install.sh motd install
  sudo bash install.sh motd status
  sudo bash install.sh motd preview
  sudo bash install.sh motd uninstall
  sudo bash install.sh motd repair-guest INSTANCE_NAME
  sudo bash install.sh motd-install|motd-status|motd-preview|motd-uninstall
HELP
                exit 0
                ;;
            status)
                MODE="status"
                ;;
            doctor)
                MODE="doctor"
                ;;
            ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor)
                MODE="$1"
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
    setup_venv
    validate_bot
    install_cli
    install_service
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

# ── Embedded SVM Host MOTD installer (self-contained; no extra file required) ──
svm_motd_dispatch() {
    local motd_tmp
    motd_tmp="$(mktemp /tmp/svm-motd-installer.XXXXXX.sh)" || die "Cannot create temporary MOTD installer."
    cat > "$motd_tmp" <<'__SVM_MOTD_EMBEDDED_PAYLOAD_20261011__'
#!/usr/bin/env bash
# SVM+ ADVANCED SSH HOST MOTD — Made by AnkitCoder
# Commands: install | preview | status | uninstall | repair-guest INSTANCE
set -Eeuo pipefail
MOTD_FILE="/etc/profile.d/svm-motd.sh"
BACKUP_DIR="/var/backups/svm-motd"
C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; W='\033[0;37m'; M='\033[0;35m'
info(){ printf "${C}[SVM]${R} %s\n" "$*"; }
ok(){ printf "${G}[OK]${R} %s\n" "$*"; }
warn(){ printf "${Y}[WARN]${R} %s\n" "$*"; }
fail(){ printf "${R}[ERROR]${R} %s\n" "$*" >&2; }
need_root(){ if [[ $EUID -ne 0 ]]; then fail "Run as root: sudo bash $0 ${1:-install}"; exit 1; fi; }

write_motd(){
  mkdir -p /etc/profile.d
  cat > "$MOTD_FILE" <<'MOTD'
# SVM+ Advanced Host MOTD — Made by AnkitCoder
# Interactive login only; does not print into scripts, SCP/SFTP, or noninteractive commands.
case "$-" in *i*) ;; *) return 0 ;; esac
[ "${SVM_MOTD_SHOWN:-0}" = "1" ] && return 0
export SVM_MOTD_SHOWN=1

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; W='\033[0;37m'; M='\033[0;35m'; D='\033[0;90m'
svm_cmd(){ command "$@" 2>/dev/null || true; }
svm_line(){ printf "${D}────────────────────────────────────────────────────────────${R}\n"; }
svm_os=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")
svm_host=$(svm_cmd hostname); svm_fqdn=$(svm_cmd hostname -f); svm_kernel=$(svm_cmd uname -r)
svm_arch=$(svm_cmd uname -m); svm_uptime=$(svm_cmd uptime -p); [ -n "$svm_uptime" ] || svm_uptime=$(svm_cmd uptime)
svm_load=$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg 2>/dev/null)
svm_cpu_count=$(svm_cmd nproc); [ -n "$svm_cpu_count" ] || svm_cpu_count='?'
svm_cpu_model=$(awk -F': ' '/model name|Hardware/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
[ -n "$svm_cpu_model" ] || svm_cpu_model='Not reported by hypervisor'
svm_ipv4=$(svm_cmd ip -o -4 addr show scope global | awk '{split($4,a,"/"); printf "%s%s",sep a[1]; sep="  "}')
svm_ipv6=$(svm_cmd ip -o -6 addr show scope global | awk '{split($4,a,"/"); printf "%s%s",sep a[1]; sep="  "}')
[ -n "$svm_ipv4" ] || svm_ipv4=$(svm_cmd hostname -I | awk '{print $1}')
[ -n "$svm_ipv4" ] || svm_ipv4='Not detected'
[ -n "$svm_ipv6" ] || svm_ipv6='Not detected'
svm_primary_if=$(svm_cmd ip route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -n "$svm_primary_if" ] || svm_primary_if='unknown'
svm_gateway=$(svm_cmd ip route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
[ -n "$svm_gateway" ] || svm_gateway='not reported'
svm_dns=$(awk '/^nameserver/ {printf "%s%s",sep,$2; sep="  "}' /etc/resolv.conf 2>/dev/null)
[ -n "$svm_dns" ] || svm_dns='not reported'
svm_root_disk=$(df -hP / 2>/dev/null | awk 'NR==2 {printf "%s used / %s total (%s used)",$3,$2,$5}')
[ -n "$svm_root_disk" ] || svm_root_disk='unavailable'
svm_root_inode=$(df -iP / 2>/dev/null | awk 'NR==2 {printf "%s used (%s)",$3,$5}')
svm_mem_total=$(awk '/^MemTotal:/ {printf "%.2f GiB",$2/1048576}' /proc/meminfo 2>/dev/null)
svm_mem_avail=$(awk '/^MemAvailable:/ {printf "%.2f GiB",$2/1048576}' /proc/meminfo 2>/dev/null)
svm_mem_used=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3}')
svm_swap=$(free -h 2>/dev/null | awk '/^Swap:/ {print $3 " used / " $2}')
[ -n "$svm_swap" ] || svm_swap='unavailable'
svm_logged_user=${USER:-$(id -un 2>/dev/null)}
svm_shell=${SHELL:-unknown}
svm_now=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
svm_users=$(who 2>/dev/null | wc -l | tr -d ' ')
svm_processes=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')
svm_failed_units=$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')
svm_listen_count=$(ss -lnt 2>/dev/null | awk 'NR>1 {n++} END {print n+0}')

printf '\n'
printf "${C}╔════════════════════════════════════════════════════════════╗${R}\n"
printf "${C}║${W}                   ⚡ ANKITCODER • SVM+                     ${C}║${R}\n"
printf "${C}║${W}              ADVANCED HOST CONTROL CENTER                 ${C}║${R}\n"
printf "${C}╚════════════════════════════════════════════════════════════╝${R}\n"
printf "${M}SYSTEM IDENTITY${R}\n"
printf "${G}Hostname       ${R}: %s\n" "${svm_host:-unknown}"
printf "${G}FQDN           ${R}: %s\n" "${svm_fqdn:-not configured}"
printf "${G}Operating OS   ${R}: %s\n" "$svm_os"
printf "${G}Kernel / Arch  ${R}: %s / %s\n" "${svm_kernel:-unknown}" "${svm_arch:-unknown}"
printf "${G}Login / Shell  ${R}: %s / %s\n" "${svm_logged_user:-unknown}" "$svm_shell"
printf "${G}Server Time    ${R}: %s\n" "${svm_now:-unknown}"
printf "${G}Uptime         ${R}: %s\n" "${svm_uptime:-unknown}"
printf "${G}Load (1/5/15)  ${R}: %s\n" "${svm_load:-unknown}"
svm_line
printf "${M}CPU • MEMORY • STORAGE${R}\n"
printf "${G}CPU            ${R}: %s logical cores\n" "$svm_cpu_count"
printf "${G}CPU Model      ${R}: %s\n" "$svm_cpu_model"
printf "${G}RAM            ${R}: %s total | %s available | %s used\n" "${svm_mem_total:-?}" "${svm_mem_avail:-?}" "${svm_mem_used:-?}"
printf "${G}Swap           ${R}: %s\n" "$svm_swap"
printf "${G}Root Disk      ${R}: %s\n" "$svm_root_disk"
printf "${G}Root Inodes    ${R}: %s\n" "${svm_root_inode:-unknown}"
printf "${G}Processes      ${R}: %s | Active logins: %s\n" "${svm_processes:-?}" "${svm_users:-?}"
svm_line
printf "${M}NETWORK • INTERFACES • LISTENERS${R}\n"
printf "${G}IPv4           ${R}: %s\n" "$svm_ipv4"
printf "${G}IPv6           ${R}: %s\n" "$svm_ipv6"
printf "${G}Default NIC    ${R}: %s\n" "$svm_primary_if"
printf "${G}Gateway        ${R}: %s\n" "$svm_gateway"
printf "${G}DNS Servers    ${R}: %s\n" "$svm_dns"
printf "${G}TCP Listeners  ${R}: %s listening sockets\n" "${svm_listen_count:-?}"
if [ "${SVM_MOTD_NETWORK_DETAILS:-0}" = "1" ]; then
  printf "${D}Interface summary:${R}\n"; svm_cmd ip -brief address | head -n 12
  printf "${D}Default routes:${R}\n"; svm_cmd ip route show default | head -n 4
fi
svm_line
printf "${M}PLATFORM • VIRTUALIZATION • BOT SERVICES${R}\n"
if command -v docker >/dev/null 2>&1; then
  svm_docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  svm_docker_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$svm_docker_ver" ]; then printf "${G}Docker         ${R}: online v%s | %s running containers\n" "$svm_docker_ver" "$svm_docker_count"; else printf "${Y}Docker         ${R}: installed, daemon unavailable/no permission\n"; fi
else printf "${D}Docker         : not installed${R}\n"; fi
if command -v lxc >/dev/null 2>&1; then
  svm_lxc_version=$(lxc version 2>/dev/null | head -n 1 | tr -d '\r' || true)
  printf "${G}LXC/Incus      ${R}: CLI available %s\n" "${svm_lxc_version:-}"
  if [ "${SVM_MOTD_SHOW_INSTANCES:-0}" = "1" ]; then lxc list 2>/dev/null | head -n 12 || true; fi
else printf "${D}LXC/Incus      : CLI not installed${R}\n"; fi
if command -v virsh >/dev/null 2>&1; then
  svm_vm_count=$(virsh list --all --name 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
  printf "${G}libvirt/KVM    ${R}: available | %s defined VMs\n" "$svm_vm_count"
elif command -v qemu-system-x86_64 >/dev/null 2>&1; then printf "${G}QEMU           ${R}: executable installed\n"; else printf "${D}KVM/QEMU       : not detected${R}\n"; fi
if [ -r /dev/kvm ]; then printf "${G}/dev/kvm       ${R}: accessible device node exists\n"; else printf "${Y}/dev/kvm       ${R}: missing or not exposed to this host${R}\n"; fi
if command -v systemctl >/dev/null 2>&1; then
  for svm_unit in svm svm-bot docker ssh sshd; do
    svm_state=$(systemctl is-active "$svm_unit" 2>/dev/null || true)
    [ -n "$svm_state" ] || svm_state='unknown'
    case "$svm_state" in active) printf "${G}Service %-8s${R}: %s\n" "$svm_unit" "$svm_state";; inactive|failed) printf "${Y}Service %-8s${R}: %s\n" "$svm_unit" "$svm_state";; *) :;; esac
  done
  printf "${G}Failed Units   ${R}: %s (systemctl --failed)\n" "${svm_failed_units:-?}"
fi
# LocalAI is tested only through the local loopback address; no external network request.
if command -v curl >/dev/null 2>&1; then
  svm_ai_url=''
  if [ -r /opt/svm/.env ]; then svm_ai_url=$(sed -n 's/^LOCALAI_BASE_URL=//p' /opt/svm/.env | tail -n1 | tr -d '"\047 '); fi
  [ -n "$svm_ai_url" ] || svm_ai_url='http://127.0.0.1:18080'
  case "$svm_ai_url" in http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*)
    if curl -fsS --max-time 1 "$svm_ai_url/v1/models" >/dev/null 2>&1; then printf "${G}LocalAI        ${R}: API responding at %s\n" "$svm_ai_url"; else printf "${Y}LocalAI        ${R}: no API response at %s\n" "$svm_ai_url"; fi;;
    *) printf "${D}LocalAI        : configured endpoint not loopback; skipped active probe${R}\n";;
  esac
fi
svm_line
printf "${M}QUICK COMMANDS${R}\n"
printf "${W}htop / top${R}                 Live process and CPU view\n"
printf "${W}free -h && df -h${R}          Memory and disk usage\n"
printf "${W}ip -brief address${R}         Network addresses\n"
printf "${W}ss -lntup${R}                 Listening ports/sockets\n"
printf "${W}systemctl --failed${R}        Failed system services\n"
printf "${W}docker ps${R}                 Running containers\n"
printf "${W}lxc list${R}                  LXC/Incus instances (if installed)\n"
printf "${W}virsh list --all${R}          KVM/libvirt VMs (if installed)\n"
printf "${W}journalctl -u svm -n 60${R}   Recent SVM bot logs\n"
printf "${D}MOTD controls: SVM_MOTD_NETWORK_DETAILS=1 and SVM_MOTD_SHOW_INSTANCES=1${R}\n"
printf "${C}════════════════════════════════════════════════════════════${R}\n\n"
unset svm_os svm_host svm_fqdn svm_kernel svm_arch svm_uptime svm_load svm_cpu_count svm_cpu_model svm_ipv4 svm_ipv6 svm_primary_if svm_gateway svm_dns svm_root_disk svm_root_inode svm_mem_total svm_mem_avail svm_mem_used svm_swap svm_logged_user svm_shell svm_now svm_users svm_processes svm_failed_units svm_listen_count svm_docker_ver svm_docker_count svm_lxc_version svm_vm_count svm_state svm_ai_url
MOTD
  chmod 0644 "$MOTD_FILE"
}

install_motd(){
  need_root install
  mkdir -p "$BACKUP_DIR"
  if [[ -e "$MOTD_FILE" ]]; then local stamp; stamp=$(date +%Y%m%d-%H%M%S); cp -a "$MOTD_FILE" "$BACKUP_DIR/svm-motd.sh.$stamp.bak"; info "Backed up existing MOTD to $BACKUP_DIR"; fi
  write_motd
  ok "Installed: $MOTD_FILE"
  echo "Preview: sudo bash $0 preview"
  echo "Status:  sudo bash $0 status"
  echo "The dashboard appears on the next interactive SSH login."
}
preview_motd(){
  if [[ ! -r "$MOTD_FILE" ]]; then fail "Not installed. Run: sudo bash $0 install"; exit 1; fi
  # Profile files return early in noninteractive shells; emulate interactive bash.
  SVM_MOTD_SHOWN=0 bash -ic "source '$MOTD_FILE'" 2>/dev/null || true
}
status_motd(){
  echo '=== SVM+ HOST MOTD STATUS ==='
  if [[ -f "$MOTD_FILE" ]]; then ok "Installed: $MOTD_FILE"; stat -c 'Permissions: %a | Owner: %U:%G | Modified: %y' "$MOTD_FILE" 2>/dev/null || true; else warn 'Not installed'; fi
  echo; echo '=== Host summary ==='; hostnamectl 2>/dev/null | head -n 8 || true
  echo; echo '=== SSH service ==='; if command -v systemctl >/dev/null 2>&1; then systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true; fi
  echo; echo '=== Recent backups ==='; ls -1t "$BACKUP_DIR" 2>/dev/null | head -n 5 || true
}
uninstall_motd(){
  need_root uninstall
  if [[ -f "$MOTD_FILE" ]]; then rm -f "$MOTD_FILE"; ok "Removed $MOTD_FILE"; info 'SSH service, SSH settings, bot files, and containers were not changed.'; else warn 'MOTD was not installed'; fi
}
repair_guest(){
  need_root repair-guest
  local guest="${2:-}"
  if [[ -z "$guest" ]]; then fail "Usage: sudo bash $0 repair-guest INSTANCE_NAME"; exit 2; fi
  command -v lxc >/dev/null 2>&1 || { fail "LXC/Incus 'lxc' command not found"; exit 1; }
  lxc info "$guest" >/dev/null 2>&1 || { fail "Instance '$guest' not found. Check: lxc list"; exit 1; }
  info "Checking OpenSSH in guest: $guest"
  if lxc exec "$guest" -- bash -s <<'GUEST'
set -Eeuo pipefail
. /etc/os-release
printf 'Guest OS: %s\n' "${PRETTY_NAME:-unknown}"
if ! command -v sshd >/dev/null 2>&1; then
  case "${ID:-}" in ubuntu|debian) export DEBIAN_FRONTEND=noninteractive; apt-get -o Acquire::http::Timeout=12 -o Acquire::https::Timeout=12 -o Acquire::Retries=1 update; apt-get install -y openssh-server;; *) echo 'Automatic installation supports Ubuntu/Debian only.'; exit 1;; esac
fi
mkdir -p /run/sshd
/usr/sbin/sshd -t
if command -v systemctl >/dev/null 2>&1; then systemctl enable ssh >/dev/null 2>&1 || true; systemctl restart ssh || systemctl restart sshd; else pgrep -x sshd >/dev/null || /usr/sbin/sshd; fi
echo '--- SSH listeners ---'; ss -lntp 2>/dev/null | grep -E '(:22[[:space:]]|:22$)' || true
echo '--- Guest IP ---'; hostname -I 2>/dev/null || true
GUEST
  then ok 'Guest SSH check/repair completed.'; else fail 'Guest SSH repair failed; review output above.'; exit 1; fi
  local ip; ip=$(lxc list "$guest" -c 4 --format csv 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)
  if [[ -n "$ip" ]]; then info "Guest IPv4: $ip"; if command -v ssh-keyscan >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then timeout 8 ssh-keyscan -T 5 "$ip" 2>&1 | head -n 8 || true; else warn 'ssh-keyscan/timeout unavailable; install openssh-client/coreutils for a banner test'; fi; else warn 'No IPv4 detected for guest'; fi
}
usage(){ cat <<USAGE
SVM+ ADVANCED SSH HOST MOTD — Made by AnkitCoder

Usage:
  sudo bash $0 install
  sudo bash $0 preview
  sudo bash $0 status
  sudo bash $0 uninstall
  sudo bash $0 repair-guest INSTANCE_NAME

Commands:
  install                Install/update the colorful host login dashboard
  preview                Display dashboard immediately
  status                 Show installation, host and SSH status
  uninstall              Remove only the SVM MOTD profile script
  repair-guest NAME      Check/repair OpenSSH in an Ubuntu/Debian LXC guest

Optional dashboard details:
  SVM_MOTD_NETWORK_DETAILS=1   Show interface and default-route summaries
  SVM_MOTD_SHOW_INSTANCES=1    Include LXC/Incus instance listing

Safety:
  - Does not alter sshd_config, firewall rules, SSH port, or host services.
  - Does not make public-IP lookups or other external requests.
  - LocalAI probe is limited to loopback endpoints.
USAGE
}
case "${1:-install}" in
  install) install_motd;;
  preview) preview_motd;;
  status) status_motd;;
  uninstall) uninstall_motd;;
  repair-guest) repair_guest "$@";;
  help|-h|--help) usage;;
  *) fail "Unknown command: $1"; usage; exit 2;;
esac
__SVM_MOTD_EMBEDDED_PAYLOAD_20261011__
    chmod 700 "$motd_tmp"
    bash "$motd_tmp" "${@:-install}"
    local rc=$?
    rm -f "$motd_tmp"
    return "$rc"
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
            ai_install
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
        install)
            main_install
            ;;
        *)
            die "Invalid installer mode: $MODE"
            ;;
    esac
}

# MOTD commands are dispatched before the normal SVM installer's root/lock flow.
# Usage: bash install.sh motd install|status|preview|uninstall|repair-guest NAME
case "${1:-}" in
    motd)
        shift
        svm_motd_dispatch "${@:-install}"
        exit $?
        ;;
    motd-install)
        svm_motd_dispatch install
        exit $?
        ;;
    motd-status)
        svm_motd_dispatch status
        exit $?
        ;;
    motd-preview)
        svm_motd_dispatch preview
        exit $?
        ;;
    motd-uninstall)
        svm_motd_dispatch uninstall
        exit $?
        ;;
esac
main "$@"
