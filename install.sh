#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#   SVM+ V11.3 • ANKITCODER • PRODUCTION INSTALLER / UPGRADER
#
#   sudo bash install.sh
#   sudo bash install.sh --configure
#   sudo bash install.sh --local-bot FILE
#   sudo bash install.sh --non-interactive
#   sudo bash install.sh --rollback [SNAPSHOT]
#   sudo bash install.sh --no-start
#   sudo bash install.sh ai-install|ai-start|ai-stop|ai-restart|ai-status|ai-models|ai-doctor
#   sudo bash install.sh status | doctor
#
#   V11 ZIP:
#     Put v11.zip beside install.sh.
#     unzip is bootstrapped first.
#     v11.zip is extracted into a safe staging directory.
#     Existing .env + DB are backed up before deployment.
#
#   Non-interactive example:
#     SVM_ENV_DISCORD_TOKEN=xxx SVM_ENV_MAIN_ADMIN_ID=123 \
#     SVM_ENV_PAYMENT_GATEWAYS=razorpay,upi sudo -E bash install.sh --non-interactive
# ══════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail

REPO="${SVM_REPO:-https://github.com/AnkitKing7/Svm-v11.3-bot.git}"
BRANCH="${SVM_BRANCH:-main}"
APP_DIR="${SVM_DIR:-/opt/svm}"
SERVICE="${SVM_SERVICE:-svm}"
ENV_FILE="${APP_DIR}/.env"
BACKUP_DIR="${APP_DIR}/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCK_FILE="/var/lock/svm-plus-ankitcoder.lock"
KEEP_SNAPSHOTS="${SVM_KEEP_SNAPSHOTS:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────── V11 ZIP SETTINGS ────────────────────────────────
V11_ZIP="${SVM_V11_ZIP:-${SCRIPT_DIR}/v11.zip}"
V11_ZIP_STAGE=""
V11_ZIP_ROOT=""

MODE="install"
INTERACTIVE=1
NO_START=0
LOCAL_BOT="${SVM_LOCAL_BOT:-}"
ROLLBACK_TARGET=""

[[ -t 0 ]] || INTERACTIVE=0

R='\033[0m'
B='\033[1m'
C='\033[36m'
G='\033[32m'
Y='\033[33m'
E='\033[31m'

info(){ printf "${C}➜${R} %s\n" "$*"; }
ok(){ printf "${G}✓${R} %s\n" "$*"; }
warn(){ printf "${Y}!${R} %s\n" "$*"; }
die(){ printf "${E}✗${R} %s\n" "$*" >&2; exit 1; }

section(){
    printf "\n${B}${C}━━━ %s ━━━${R}\n" "$*"
}

banner() {
cat <<'EOF'

  ╔════════════════════════════════════════════════════════════╗
  ║   S V M +   V 1 1 . 3  —  A N K I T C O D E R              ║
  ║   VPS • IP POOL • PORT FORWARDING • PAYMENT GATEWAYS       ║
  ║   ZIP UPGRADER • SAFE BACKUP • AI AGENT • PRODUCTION       ║
  ╚════════════════════════════════════════════════════════════╝

EOF
}

# ─────────────────────────── .env helpers ───────────────────────────────────

get_env() {
    local key="$1"
    local line

    [[ -f "$ENV_FILE" ]] || return 0

    line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)"
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

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "Invalid env key: $key"

    [[ "$val" != *$'\n'* && "$val" != *"'"* ]] \
        || die "Value for $key may not contain a newline or a single quote"

    ENV_KEY="$key" \
    ENV_VAL="$val" \
    ENV_PATH="$ENV_FILE" \
    python3 - <<'PY'
import os
import re

key = os.environ["ENV_KEY"]
val = os.environ["ENV_VAL"]
path = os.environ["ENV_PATH"]

lines = open(path).read().splitlines() if os.path.exists(path) else []

new = f"{key}='{val}'"
done = False

for i, line in enumerate(lines):
    if re.match(rf"^\s*(export\s+)?{re.escape(key)}=", line):
        lines[i] = new
        done = True

if not done:
    lines.append(new)

fd = os.open(
    path,
    os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
    0o600
)

with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}

ensure_env() {
    local key="$1"
    local val="$2"

    grep -qE "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null \
        || set_env "$key" "$val"
}

apply_env_overrides() {
    local var
    local key

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
    local cur
    local reply
    local shown

    cur="$(get_env "$key")"

    [[ -n "$cur" ]] && def="$cur"

    (( INTERACTIVE )) || return 0

    if [[ "$secret" == "secret" ]]; then
        shown=""
        [[ -n "$cur" ]] && shown=" [keep current]"

        read -r -s -p "  ${prompt}${shown}: " reply
        echo
    else
        shown=""
        [[ -n "$def" ]] && shown=" [${def}]"

        read -r -p "  ${prompt}${shown}: " reply
    fi

    reply="${reply:-$def}"

    [[ -n "$reply" ]] && set_env "$key" "$reply"

    return 0
}

yesno() {
    local q="$1"
    local def="${2:-n}"
    local reply

    (( INTERACTIVE )) || {
        [[ "$def" == y ]]
        return
    }

    read -r -p \
        "  ${q} [$([[ $def == y ]] && echo Y/n || echo y/N)]: " \
        reply

    reply="${reply:-$def}"

    [[ "${reply,,}" == y* ]]
}

detect_public_ip() {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' |
            head -n1 \
        || true
}

default_iface() {
    ip -4 route show default 2>/dev/null |
        awk '{print $5}' |
        head -n1
}

# ═════════════════════════ V11 ZIP BOOTSTRAP ═════════════════════════════════

install_unzip_first() {
    section "V11 ZIP BOOTSTRAP"

    export DEBIAN_FRONTEND=noninteractive

    if command -v unzip >/dev/null 2>&1; then
        ok "unzip already installed"
        return 0
    fi

    info "unzip is missing — installing it BEFORE the normal installer..."

    local log="/tmp/svm-unzip-${STAMP}.log"

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -y >"$log" 2>&1 \
            || warn "apt-get update reported problems; continuing"

        apt-get install -y unzip >>"$log" 2>&1 \
            || die "Failed to install unzip. Check: $log"

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y unzip >"$log" 2>&1 \
            || die "Failed to install unzip. Check: $log"

    elif command -v yum >/dev/null 2>&1; then

        yum install -y unzip >"$log" 2>&1 \
            || die "Failed to install unzip. Check: $log"

    elif command -v apk >/dev/null 2>&1; then

        apk add unzip >"$log" 2>&1 \
            || die "Failed to install unzip. Check: $log"

    else
        die "No supported package manager found. Install unzip manually."
    fi

    command -v unzip >/dev/null 2>&1 \
        || die "unzip installation completed but command is unavailable"

    ok "unzip installed successfully"
}

prepare_v11_zip() {
    section "V11 ZIP PACKAGE"

    if [[ ! -f "$V11_ZIP" ]]; then
        warn "v11.zip not found:"
        warn "  $V11_ZIP"
        info "Continuing with local/GitHub source fallback."
        return 0
    fi

    [[ -s "$V11_ZIP" ]] \
        || die "v11.zip exists but is empty: $V11_ZIP"

    command -v unzip >/dev/null 2>&1 \
        || die "unzip is required before extracting v11.zip"

    V11_ZIP_STAGE="$(mktemp -d /tmp/svm-v11-zip.XXXXXX)"

    info "Found V11 package:"
    info "  $V11_ZIP"

    info "Checking ZIP integrity..."

    unzip -t "$V11_ZIP" >/tmp/svm-v11-zip-test.log 2>&1 \
        || die "v11.zip is corrupted. Check /tmp/svm-v11-zip-test.log"

    info "Extracting V11 package safely..."

    unzip -o "$V11_ZIP" "$V11_ZIP_STAGE" >/tmp/svm-v11-zip.log 2>&1 \
        || {
            # Some unzip implementations require -d instead.
            rm -rf "$V11_ZIP_STAGE"
            V11_ZIP_STAGE="$(mktemp -d /tmp/svm-v11-zip.XXXXXX)"

            unzip -o "$V11_ZIP" -d "$V11_ZIP_STAGE" \
                >/tmp/svm-v11-zip.log 2>&1 \
                || die "Failed to extract v11.zip. Check /tmp/svm-v11-zip.log"
        }

    # Normalize the extracted directory.
    # Supports:
    #
    # v11.zip
    # ├── bot.py
    # ├── requirements.txt
    #
    # OR:
    #
    # v11.zip
    # └── v11/
    #     ├── bot.py
    #     └── requirements.txt

    if [[ -f "$V11_ZIP_STAGE/bot.py" ]]; then
        V11_ZIP_ROOT="$V11_ZIP_STAGE"

    else
        local candidate=""
        local count=0
        local d

        while IFS= read -r -d '' d; do
            candidate="$d"
            count=$((count + 1))
        done < <(
            find "$V11_ZIP_STAGE" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                -print0
        )

        if (( count == 1 )) && [[ -f "$candidate/bot.py" ]]; then
            V11_ZIP_ROOT="$candidate"
        else
            V11_ZIP_ROOT="$V11_ZIP_STAGE"
        fi
    fi

    [[ -f "$V11_ZIP_ROOT/bot.py" ]] \
        || {
            warn "v11.zip extracted successfully, but bot.py was not found."
            warn "Falling back to local/GitHub source."
            V11_ZIP_ROOT=""
            return 0
        }

    ok "v11.zip extracted successfully"
    info "ZIP source root: $V11_ZIP_ROOT"

    [[ -f "$V11_ZIP_ROOT/requirements.txt" ]] &&
        ok "requirements.txt found in V11 ZIP" ||
        warn "requirements.txt missing in V11 ZIP"

    [[ -f "$V11_ZIP_ROOT/webssh.html" ]] &&
        ok "webssh.html found in V11 ZIP" ||
        warn "webssh.html missing in V11 ZIP"

    return 0
}

cleanup_v11_zip() {
    if [[ -n "${V11_ZIP_STAGE:-}" &&
          -d "${V11_ZIP_STAGE:-}" ]]; then
        rm -rf "$V11_ZIP_STAGE" || true
    fi
}

# ─────────────────────── defaults merged into .env ──────────────────────────

write_default_env() {
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

    for k in USERS VPS NODES RESOURCES NETWORK IP_POOL PORTS AI_TASKS; do
        ensure_env "STATUS_SHOW_${k}" "true"
    done
}

# ────────────────────────── configuration wizard ────────────────────────────

configure_env() {
    section "CONFIGURATION WIZARD"

    (( INTERACTIVE )) &&
        info "Press Enter to keep the value shown in [brackets]. Secrets are hidden while typing." ||
        info "Non-interactive: using SVM_ENV_* variables and existing .env values."

    if (( INTERACTIVE )); then

        echo
        info "1/5  Discord"

        ask DISCORD_TOKEN "Discord bot token" "" secret
        ask MAIN_ADMIN_ID "Main admin Discord user ID"

        local ip
        ip="$(get_env YOUR_SERVER_IP)"

        if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
            ip="$(detect_public_ip)"
        fi

        ask YOUR_SERVER_IP \
            "Public server IP (shown to users for SSH/ports)" \
            "${ip}"

        echo
        info "2/5  Public webhook URL"

        ask SVM_PUBLIC_URL \
            "Public HTTPS URL, e.g. https://pay.example.com (blank = no auto-payments)"

        local url
        url="$(get_env SVM_PUBLIC_URL)"

        if [[ "$url" == https://* ]]; then
            if yesno "Install Caddy as an HTTPS reverse proxy for ${url}?" y; then
                SETUP_CADDY=1
            fi
        fi

        echo
        info "3/5  Payment gateways"

        local gws=()

        if yesno "Enable Razorpay (cards/UPI/netbanking, auto verification)?" y; then
            gws+=(razorpay)

            ask RAZORPAY_KEY_ID "  Razorpay Key ID"
            ask RAZORPAY_KEY_SECRET "  Razorpay Key Secret" "" secret

            if [[ -z "$(get_env RAZORPAY_WEBHOOK_SECRET)" ]]; then
                set_env RAZORPAY_WEBHOOK_SECRET "$(openssl rand -hex 24)"
            fi

            info "  Razorpay dashboard → Webhooks: URL ${url:-https://YOUR-DOMAIN}/razorpay/webhook"
            info "  events: payment_link.paid, payment.captured"
        fi

        if yesno "Enable Stripe Checkout (international cards)?" n; then
            gws+=(stripe)

            ask STRIPE_SECRET_KEY \
                "  Stripe secret key (sk_live_/sk_test_)" \
                "" secret

            ask STRIPE_WEBHOOK_SECRET \
                "  Stripe webhook signing secret (whsec_)" \
                "" secret

            ask STRIPE_CURRENCY \
                "  Stripe currency code" \
                "inr"

            ask STRIPE_AMOUNT_RATE \
                "  Conversion rate: INR paise → Stripe minor units (1.0 for INR)" \
                "1.0"

            info "  Stripe dashboard → Webhooks: ${url:-https://YOUR-DOMAIN}/stripe/webhook"
        fi

        if yesno "Enable manual UPI (admin approves each payment)?" y; then
            gws+=(upi)
            set_env UPI_ENABLED true

            ask UPI_ID "  UPI ID (VPA)"
            ask UPI_NAME "  Payee name" "AnkitCoder"
            ask UPI_QR_URL "  QR image URL (optional)"
        else
            set_env UPI_ENABLED false
        fi

        if ((${#gws[@]})); then
            set_env PAYMENT_GATEWAYS "$(IFS=,; echo "${gws[*]}")"
            ask DEFAULT_GATEWAY \
                "  Default gateway for !buy" \
                "${gws[0]}"
        fi

        ask PLAN_STARTER_PRICE \
            "  Price ₹ Starter (1 vCPU/2 GB/20 GB)" "0"

        ask PLAN_BASIC_PRICE \
            "  Price ₹ Basic (2 vCPU/4 GB/40 GB)" "0"

        ask PLAN_STANDARD_PRICE \
            "  Price ₹ Standard (4 vCPU/8 GB/80 GB)" "0"

        ask PLAN_PRO_PRICE \
            "  Price ₹ Pro (8 vCPU/16 GB/160 GB)" "0"

        ask PAYMENT_ADMIN_CHANNEL_ID \
            "  Discord channel ID for payment alerts (0 = DM main admin)" \
            "0"

        echo
        info "4/5  IP pool"

        ask IPAM_BIND_MODE \
            "  Bind mode: record | bridged | nat" \
            "record"

        if [[ "$(get_env IPAM_BIND_MODE)" == "nat" ]]; then
            ask IPAM_HOST_IFACE \
                "  Host interface that carries the public IPs" \
                "$(default_iface)"
        fi

        if yesno "Auto-assign a pool IP to every newly purchased VPS?" n; then
            set_env IPAM_AUTO_ASSIGN true
        else
            set_env IPAM_AUTO_ASSIGN false
        fi

        ask IPAM_POOLS \
            "  Pools: name|cidr|gateway|node_id;name2|cidr2"

        echo
        info "5/5  Port forwarding"

        ask PORT_RANGE_START \
            "  Public port range start" \
            "20000"

        ask PORT_RANGE_END \
            "  Public port range end" \
            "50000"

        ask PORT_RESERVED \
            "  Reserved ports (comma separated)" \
            ""

        ask PORT_MAX_PER_VPS \
            "  Max forwards per VPS" \
            "20"

        if yesno "Let users pick their own public port?" n; then
            set_env PORT_ALLOW_CUSTOM true
        else
            set_env PORT_ALLOW_CUSTOM false
        fi
    fi

    if [[ "$(get_env SVM_PUBLIC_URL)" == https://* &&
          "${SETUP_CADDY:-0}" == "1" ]]; then

        set_env PAYMENT_WEBHOOK_HOST "127.0.0.1"

    elif [[ -n "$(get_env SVM_PUBLIC_URL)" &&
            "${SETUP_CADDY:-0}" != "1" ]]; then

        warn "Webhook server stays on ${APP_DIR}/.env host."
        warn "Put your own HTTPS proxy in front of port $(get_env PAYMENT_WEBHOOK_PORT)."
    fi

    validate_env
}

validate_env() {
    local n
    local lo
    local hi
    local tok

    lo="$(get_env PORT_RANGE_START)"
    hi="$(get_env PORT_RANGE_END)"

    for n in "$lo" "$hi"; do
        [[ "$n" =~ ^[0-9]+$ ]] ||
            die "Port range values must be numbers"
    done

    (( lo >= 1024 && hi <= 65535 && lo < hi )) ||
        die "Port range must satisfy 1024 <= start < end <= 65535"

    case "$(get_env IPAM_BIND_MODE)" in
        record|bridged|nat) ;;
        *) die "IPAM_BIND_MODE must be record, bridged or nat" ;;
    esac

    local adm
    adm="$(get_env MAIN_ADMIN_ID)"

    if [[ -z "$adm" ]]; then
        warn "MAIN_ADMIN_ID is empty — set your Discord user ID."
    elif ! [[ "$adm" =~ ^[0-9]{15,21}$ ]]; then
        die "MAIN_ADMIN_ID must be a numeric Discord user ID"
    fi

    tok="$(get_env DISCORD_TOKEN)"

    if [[ -z "$tok" || "$tok" == "your_discord_bot_token_here" ]]; then
        warn "DISCORD_TOKEN is not set yet."
    fi

    if [[ "$(get_env PAYMENT_GATEWAYS)" == *razorpay* ]]; then
        [[ -n "$(get_env RAZORPAY_KEY_ID)" &&
           -n "$(get_env RAZORPAY_KEY_SECRET)" ]] ||
            warn "Razorpay is enabled but credentials are missing."
    fi

    ok "Configuration validated"
}

# ─────────────────────────── system pieces ──────────────────────────────────

install_packages() {
    section "SYSTEM DEPENDENCIES"

    export DEBIAN_FRONTEND=noninteractive

    local log="/tmp/svm-install-pkgs-${STAMP}.log"

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -y >"$log" 2>&1 ||
            warn "apt-get update reported problems (see $log)"

        apt-get install -y \
            python3 \
            python3-venv \
            python3-pip \
            python3-dev \
            curl \
            ca-certificates \
            git \
            sqlite3 \
            openssh-client \
            iproute2 \
            iptables \
            procps \
            util-linux \
            rsync \
            unzip \
            jq \
            openssl \
            >>"$log" 2>&1 ||
            die "Core packages failed to install (see $log)"

        local pkg

        for pkg in \
            dnsutils \
            librsvg2-bin \
            lxc \
            lxc-utils \
            libvirt-clients \
            qemu-utils \
            qemu-system-x86 \
            qemu-kvm
        do
            apt-get install -y "$pkg" >>"$log" 2>&1 ||
                warn "Optional package unavailable: $pkg"
        done

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            python3 \
            python3-pip \
            python3-devel \
            curl \
            ca-certificates \
            git \
            sqlite \
            openssh-clients \
            iproute \
            iptables \
            procps-ng \
            rsync \
            unzip \
            jq \
            openssl \
            qemu-img \
            libvirt-client \
            >"$log" 2>&1 ||
            warn "Some packages unavailable (see $log)"

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            python3 \
            python3-pip \
            curl \
            ca-certificates \
            git \
            sqlite \
            openssh-clients \
            iproute \
            iptables \
            procps-ng \
            rsync \
            unzip \
            jq \
            openssl \
            qemu-img \
            libvirt-client \
            >"$log" 2>&1 ||
            warn "Some packages unavailable (see $log)"

    else
        warn "No supported package manager detected."
    fi

    for c in python3 git curl openssl; do
        command -v "$c" >/dev/null 2>&1 ||
            die "$c is required"
    done

    python3 -c \
        'import sys; assert sys.version_info >= (3,9), sys.version' ||
        die "Python 3.9+ is required"

    ok "System dependencies ready"
}

backup_snapshot() {
    section "SAFE BACKUP"

    mkdir -p \
        "$APP_DIR" \
        "$BACKUP_DIR" \
        "$APP_DIR/data" \
        "$APP_DIR/logs" \
        "$APP_DIR/db_backups"

    chmod 700 \
        "$APP_DIR" \
        "$APP_DIR/data" \
        "$BACKUP_DIR"

    SNAP="${BACKUP_DIR}/upgrade-${STAMP}"

    mkdir -p "$SNAP"

    local f

    for f in \
        bot.py \
        webssh.html \
        requirements.txt \
        .env
    do
        if [[ -f "$APP_DIR/$f" ]]; then
            cp -a "$APP_DIR/$f" "$SNAP/$f"
        fi
    done

    if [[ -f "$APP_DIR/vps.db" ]]; then
        sqlite3 "$APP_DIR/vps.db" \
            ".backup '$SNAP/vps.db'" \
            2>/dev/null ||
            cp -a "$APP_DIR/vps.db" "$SNAP/vps.db"
    fi

    chmod 700 "$SNAP"

    {
        ls -1dt "$BACKUP_DIR"/upgrade-* 2>/dev/null || true
    } |
        tail -n +"$((KEEP_SNAPSHOTS + 1))" |
        xargs -r rm -rf

    ok "Backup created: $SNAP"
    info "Keeping last $KEEP_SNAPSHOTS snapshots"
}

# ─────────────────────────── source fetching ─────────────────────────────────

fetch_sources() {
    section "SOURCES"

    TMP_DIR="$(mktemp -d)"

    local need_clone=0
    local zip_source=0

    # V11 ZIP has highest source priority.
    if [[ -n "${V11_ZIP_ROOT:-}" &&
          -f "${V11_ZIP_ROOT}/bot.py" ]]; then
        zip_source=1
        info "Using v11.zip as primary source"
    fi

    # ───────────────────── ZIP SOURCE ─────────────────────

    if (( zip_source )); then

        mkdir -p "$TMP_DIR/repo"

        cp -a "$V11_ZIP_ROOT/." "$TMP_DIR/repo/"

        SRC_BOT="$TMP_DIR/repo/bot.py"

        if [[ -f "$TMP_DIR/repo/webssh.html" ]]; then
            SRC_WEBSSH="$TMP_DIR/repo/webssh.html"
        elif [[ -f "$SCRIPT_DIR/webssh.html" ]]; then
            SRC_WEBSSH="$SCRIPT_DIR/webssh.html"
        else
            SRC_WEBSSH=""
        fi

        if [[ -f "$TMP_DIR/repo/requirements.txt" ]]; then
            SRC_REQ="$TMP_DIR/repo/requirements.txt"
        elif [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
            SRC_REQ="$SCRIPT_DIR/requirements.txt"
        else
            SRC_REQ=""
        fi

        # Optional ZIP files remain available:
        # .env.example
        # motd/
        # source/
        # assets/
        # etc.

        ok "V11 ZIP source prepared"

    else

        # ───────────────────── EXISTING LOCAL/GITHUB FLOW ─────────────────────

        [[ -z "$LOCAL_BOT" &&
           -f "$SCRIPT_DIR/bot.py" ]] &&
            LOCAL_BOT="$SCRIPT_DIR/bot.py"

        [[ -z "$LOCAL_BOT" ]] &&
            need_clone=1

        [[ -f "$SCRIPT_DIR/webssh.html" ]] ||
            need_clone=1

        [[ -f "$SCRIPT_DIR/requirements.txt" ]] ||
            need_clone=1

        if (( need_clone )); then

            if git clone \
                --depth 1 \
                --branch "$BRANCH" \
                "$REPO" \
                "$TMP_DIR/repo" \
                >/dev/null 2>&1
            then
                ok "Cloned $REPO"

            else

                [[ -n "$LOCAL_BOT" &&
                   -f "$APP_DIR/webssh.html" &&
                   -f "$APP_DIR/requirements.txt" ]] ||
                    die "Could not clone $REPO and no local files were provided"

                warn "Clone failed; reusing installed webssh.html/requirements.txt"

                mkdir -p "$TMP_DIR/repo"

                cp "$APP_DIR/webssh.html" \
                    "$APP_DIR/requirements.txt" \
                    "$TMP_DIR/repo/"
            fi

        else
            mkdir -p "$TMP_DIR/repo"
        fi

        SRC_BOT="${LOCAL_BOT:-$TMP_DIR/repo/bot.py}"

        SRC_WEBSSH="$SCRIPT_DIR/webssh.html"
        [[ -f "$SRC_WEBSSH" ]] ||
            SRC_WEBSSH="$TMP_DIR/repo/webssh.html"

        SRC_REQ="$SCRIPT_DIR/requirements.txt"
        [[ -f "$SRC_REQ" ]] ||
            SRC_REQ="$TMP_DIR/repo/requirements.txt"
    fi

    [[ -f "$SRC_BOT" ]] ||
        die "bot.py not found"

    [[ -f "$SRC_WEBSSH" ]] ||
        die "webssh.html not found"

    [[ -f "$SRC_REQ" ]] ||
        die "requirements.txt not found"

    [[ -n "$LOCAL_BOT" ]] &&
        info "Using local bot.py: $LOCAL_BOT"

    info "bot.py: $(wc -l < "$SRC_BOT") lines"
    info "bot.py size: $(du -h "$SRC_BOT" | awk '{print $1}')"

    if [[ -f "$TMP_DIR/repo/.env.example" ]]; then
        ok ".env.example available"
    fi

    if [[ -d "$TMP_DIR/repo/motd" ]]; then
        ok "MOTD package available"
    fi
}

# ───────────────────────────── env merge ─────────────────────────────────────

merge_env() {
    section "ENVIRONMENT"

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

        local line
        local key

        while IFS= read -r line || [[ -n "$line" ]]; do

            [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] ||
                continue

            key="${BASH_REMATCH[1]}"

            grep -qE \
                "^[[:space:]]*${key}=" \
                "$ENV_FILE" ||
                printf '%s\n' "$line" >> "$ENV_FILE"

        done < "$TMP_DIR/repo/.env.example"
    fi

    chmod 600 "$ENV_FILE"

    ensure_env BOT_NAME "SVM V11.2"
    ensure_env PREFIX "!"
    ensure_env YOUR_SERVER_IP "127.0.0.1"

    ensure_env BOT_VERSION "11.3-PLUS"
    ensure_env DISCORD_TOKEN ""
    ensure_env MAIN_ADMIN_ID ""

    write_default_env
    apply_env_overrides

    ok "New keys merged (existing values untouched)"
}

# ───────────────────────────── deployment ────────────────────────────────────

deploy_files() {
    section "DEPLOY"

    install -m 750 \
        "$SRC_BOT" \
        "$APP_DIR/bot.py"

    install -m 644 \
        "$SRC_WEBSSH" \
        "$APP_DIR/webssh.html"

    install -m 644 \
        "$SRC_REQ" \
        "$APP_DIR/requirements.txt"

    local motd_src="$SCRIPT_DIR/motd/svm-motd-installer.sh"

    [[ -f "$motd_src" ]] ||
        motd_src="$TMP_DIR/repo/motd/svm-motd-installer.sh"

    mkdir -p "$APP_DIR/motd"

    if [[ -f "$motd_src" ]]; then

        install -m 644 \
            "$motd_src" \
            "$APP_DIR/motd/svm-motd-installer.sh"

        ok "MOTD script deployed"

    elif [[ -f "$APP_DIR/motd/svm-motd-installer.sh" ]]; then

        info "Keeping existing MOTD script"

    else

        warn "motd/svm-motd-installer.sh not found"
        warn "New VPS will get no custom MOTD"

    fi

    if [[ -f "$TMP_DIR/repo/.env.example" ]]; then
        install -m 644 \
            "$TMP_DIR/repo/.env.example" \
            "$APP_DIR/.env.example"

    elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        install -m 644 \
            "$SCRIPT_DIR/.env.example" \
            "$APP_DIR/.env.example"
    fi

    # Preserve optional ZIP assets/directories.
    for dir in assets templates static source scripts; do
        if [[ -d "$TMP_DIR/repo/$dir" ]]; then
            mkdir -p "$APP_DIR/$dir"
            cp -a "$TMP_DIR/repo/$dir/." "$APP_DIR/$dir/"
            info "Deployed optional directory: $dir/"
        fi
    done

    ok "bot.py + webssh.html + requirements.txt deployed"
}

# ───────────────────────────── Python venv ───────────────────────────────────

setup_venv() {
    section "PYTHON ENVIRONMENT"

    PY="$APP_DIR/venv/bin/python"
    PIP="$APP_DIR/venv/bin/pip"

    [[ -x "$PY" ]] ||
        python3 -m venv "$APP_DIR/venv"

    "$PY" -m pip install \
        --quiet \
        --upgrade \
        pip setuptools wheel

    "$PIP" install \
        --quiet \
        --upgrade \
        -r "$APP_DIR/requirements.txt"

    "$PIP" install \
        --quiet \
        "discord.py>=2.3" \
        python-dotenv \
        requests \
        paramiko \
        flask \
        flask-cors

    "$PIP" install \
        --quiet \
        cairosvg >/dev/null 2>&1 ||
        warn "cairosvg unavailable — PNG dashboards use rsvg-convert if installed"

    ok "Python dependencies installed"
}

# ─────────────────────────── static validation ───────────────────────────────

validate_bot() {
    section "STATIC VALIDATION"

    APP_DIR_FOR_PY="$APP_DIR" \
        "$PY" - <<'PY'
import ast
import os
import sys
from pathlib import Path

src = (
    Path(os.environ["APP_DIR_FOR_PY"]) / "bot.py"
).read_text(encoding="utf-8")

tree = ast.parse(src)

for needle in (
    "import discord",
    "from dotenv import load_dotenv",
    "import sqlite3",
    "from flask import Flask",
):
    if needle not in src:
        sys.exit(f"Required component missing: {needle}")

runs = [
    n.lineno
    for n in ast.walk(tree)
    if isinstance(n, ast.Call)
    and getattr(n.func, "attr", "") == "run"
    and getattr(
        getattr(n.func, "value", None),
        "id",
        ""
    ) == "bot"
]

last_def = max(
    (
        n.end_lineno
        for n in tree.body
        if isinstance(
            n,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        )
    ),
    default=0,
)

if runs and min(runs) < last_def:
    sys.exit(
        f"bot.run() at line {min(runs)} is before code "
        f"that ends at line {last_def}: "
        f"everything after it would never load!"
    )

print(
    f"AST OK • {len(src.splitlines())} lines • "
    f"bot.run() is last"
)
PY

    ok "bot.py validated"
}

# ───────────────────────────── firewall ──────────────────────────────────────

setup_firewall() {
    section "FIREWALL"

    local lo
    local hi
    local port

    lo="$(get_env PORT_RANGE_START)"
    hi="$(get_env PORT_RANGE_END)"
    port="$(get_env PAYMENT_WEBHOOK_PORT)"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null |
       grep -q "Status: active"
    then

        ufw allow "${lo}:${hi}/tcp" >/dev/null
        ufw allow "${lo}:${hi}/udp" >/dev/null

        if [[ "${SETUP_CADDY:-0}" == "1" ]]; then
            ufw allow 80/tcp >/dev/null
            ufw allow 443/tcp >/dev/null
        fi

        ok "ufw: opened ${lo}-${hi} tcp+udp"

    else
        info "ufw not active"
        info "Make sure cloud firewall/security group allows ${lo}-${hi}"
    fi

    if [[ "$(get_env PAYMENT_WEBHOOK_HOST)" == "0.0.0.0" ]]; then
        warn "Webhook port ${port} listens on 0.0.0.0 over plain HTTP"
        warn "Use an HTTPS proxy."
    fi

    return 0
}

# ─────────────────────────────── Caddy ───────────────────────────────────────

setup_caddy() {
    [[ "${SETUP_CADDY:-0}" == "1" ]] ||
        return 0

    section "HTTPS REVERSE PROXY (Caddy)"

    local url
    local host
    local port

    url="$(get_env SVM_PUBLIC_URL)"
    host="${url#https://}"
    host="${host%%/*}"
    port="$(get_env PAYMENT_WEBHOOK_PORT)"

    command -v caddy >/dev/null 2>&1 ||
        {
            apt-get install -y caddy >/dev/null 2>&1 ||
                {
                    warn "Could not install caddy"
                    return 0
                }
        }

    mkdir -p /etc/caddy
    touch /etc/caddy/Caddyfile

    python3 - "$host" "$port" <<'PY'
import re
import sys

host, port = sys.argv[1], sys.argv[2]
path = "/etc/caddy/Caddyfile"

text = open(path).read()

text = re.sub(
    r"\n?# SVM\+ BEGIN.*?# SVM\+ END\n?",
    "\n",
    text,
    flags=re.S,
)

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

open(path, "w").write(
    text.rstrip("\n") + "\n" + block
)
PY

    systemctl enable caddy >/dev/null 2>&1 || true

    systemctl reload caddy 2>/dev/null ||
        systemctl restart caddy 2>/dev/null ||
        warn "Caddy failed to reload"

    ok "Caddy configured for https://${host}"
}

# ───────────────────────────── systemd ───────────────────────────────────────

install_service() {
    section "SYSTEMD"

    cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=SVM+ V11.3 VPS Platform — Made by AnkitCoder
Documentation=https://github.com/AnkitKing7/Svm-v11.2-bot
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
Description=SVM+ database backup

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

    systemctl enable \
        "${SERVICE}.service" \
        "${SERVICE}-backup.timer" \
        >/dev/null 2>&1

    systemctl start \
        "${SERVICE}-backup.timer" \
        >/dev/null 2>&1 || true

    ok "service + daily backup timer installed"
}

# ───────────────────────────── CLI ───────────────────────────────────────────

install_cli() {
    cat > /usr/local/bin/svm <<'CLI'
#!/usr/bin/env bash

APP_DIR="__APP_DIR__"
SERVICE="__SERVICE__"
ENV_FILE="$APP_DIR/.env"

envval() {
    grep -E "^$1=" "$ENV_FILE" 2>/dev/null |
        tail -n1 |
        cut -d= -f2- |
        sed -E "s/^['\"]//; s/['\"]$//"
}

case "${1:-help}" in

    status)
        systemctl status "$SERVICE" --no-pager
        ;;

    logs)
        journalctl -u "$SERVICE" -f -n "${2:-100}"
        ;;

    restart)
        systemctl restart "$SERVICE" &&
            echo restarted
        ;;

    stop)
        systemctl stop "$SERVICE"
        ;;

    config)
        "${EDITOR:-nano}" "$ENV_FILE" &&
            echo "Run: svm restart"
        ;;

    env)
        if [[ -n "${2:-}" ]]; then
            envval "$2"
            echo
        else
            echo "usage: svm env KEY"
        fi
        ;;

    backup)
        dest="$APP_DIR/db_backups/vps-$(date +%Y%m%d-%H%M%S).db"

        mkdir -p "$APP_DIR/db_backups"

        sqlite3 "$APP_DIR/vps.db" \
            ".backup '$dest'" &&
            chmod 600 "$dest"

        ls -1t \
            "$APP_DIR"/db_backups/vps-*.db \
            2>/dev/null |
            tail -n +15 |
            xargs -r rm -f

        [[ "${2:-}" == "--quiet" ]] ||
            echo "Backup: $dest"
        ;;

    rollback)
        shift
        exec bash \
            "$APP_DIR/source/install.sh" \
            --rollback "$@"
        ;;

    update)
        shift
        exec bash \
            "$APP_DIR/source/install.sh" \
            "$@"
        ;;

    ai-*)
        exec bash \
            "$APP_DIR/source/install.sh" \
            "$@"
        ;;

    doctor)
        echo "service : $(systemctl is-active "$SERVICE")"
        echo "token   : $([[ -n "$(envval DISCORD_TOKEN)" ]] && echo set || echo MISSING)"
        echo "gateways: $(envval PAYMENT_GATEWAYS)"
        echo "ip mode : $(envval IPAM_BIND_MODE)"
        echo "ports   : $(envval PORT_RANGE_START)-$(envval PORT_RANGE_END)"

        p="$(envval PAYMENT_WEBHOOK_PORT)"

        if curl -fsS \
            --max-time 3 \
            "http://127.0.0.1:${p:-8787}/health" \
            >/dev/null 2>&1
        then
            echo "webhook : up on :${p:-8787}"
        else
            echo "webhook : down"
        fi

        u="$(envval SVM_PUBLIC_URL)"

        if [[ -n "$u" ]]; then
            if curl -fsS \
                --max-time 5 \
                "$u/health" \
                >/dev/null 2>&1
            then
                echo "public  : $u reachable"
            else
                echo "public  : $u NOT reachable"
            fi
        fi

        journalctl \
            -u "$SERVICE" \
            -n 80 \
            --no-pager |
            grep -Ei "traceback|error" |
            tail -n 5
        ;;

    *)
        echo "svm status|logs|restart|stop|config|env KEY|backup|rollback [snapshot]|update|doctor|ai-status|ai-models|ai-doctor|ai-install|ai-start|ai-stop|ai-restart"
        ;;

esac
CLI

    sed -i \
        "s|__APP_DIR__|${APP_DIR}|g; s|__SERVICE__|${SERVICE}|g" \
        /usr/local/bin/svm

    chmod 755 /usr/local/bin/svm

    mkdir -p "$APP_DIR/source"

    if [[ "$(readlink -f "${BASH_SOURCE[0]}")" !=
          "$APP_DIR/source/install.sh" ]]
    then
        cp -f \
            "${BASH_SOURCE[0]}" \
            "$APP_DIR/source/install.sh"
    fi

    chmod 700 "$APP_DIR/source/install.sh"

    ok "CLI installed: svm status | logs | restart | config | backup | rollback | update | doctor"
}

# ─────────────────────────── health / rollback ───────────────────────────────

health_check_or_rollback() {
    section "HEALTH CHECK"

    if (( NO_START )); then
        warn "--no-start: skipping restart"
        return 0
    fi

    systemctl restart "${SERVICE}.service"

    local i
    local healthy=0

    for i in $(seq 1 20); do

        sleep 2

        systemctl is-active \
            --quiet \
            "${SERVICE}.service" ||
            continue

        if (( i >= 5 )) &&
           ! journalctl \
                -u "${SERVICE}.service" \
                --since "-30s" \
                --no-pager 2>/dev/null |
                grep -Eq \
                    'Traceback|SyntaxError|ImportError|ModuleNotFoundError'
        then
            healthy=1
            break
        fi
    done

    if (( healthy )); then
        ok "Service is running with no startup errors"
        return 0
    fi

    warn "Service unhealthy after upgrade"
    warn "Rolling bot.py back to the previous version"

    journalctl \
        -u "${SERVICE}.service" \
        -n 40 \
        --no-pager ||
        true

    if [[ -f "$SNAP/bot.py" ]]; then

        cp -a \
            "$SNAP/bot.py" \
            "$APP_DIR/bot.py"

        if [[ -f "$SNAP/requirements.txt" ]]; then
            cp -a \
                "$SNAP/requirements.txt" \
                "$APP_DIR/requirements.txt"
        fi

        systemctl restart \
            "${SERVICE}.service" ||
            true

        die "Upgrade failed; previous bot.py restored from $SNAP"
    fi

    die "Upgrade failed and there was no previous version to restore."
}

# ───────────────────────────── rollback ──────────────────────────────────────

do_rollback() {
    section "ROLLBACK"

    local target="${ROLLBACK_TARGET:-}"

    [[ -n "$target" ]] ||
        target="$(
            ls -1dt \
                "$BACKUP_DIR"/upgrade-* \
                2>/dev/null |
            head -n1 ||
            true
        )"

    [[ -d "$target" ]] ||
        target="$BACKUP_DIR/$target"

    [[ -d "$target" ]] ||
        die "No snapshot found. Available: $(ls "$BACKUP_DIR" 2>/dev/null | tr '\n' ' ')"

    [[ -f "$target/bot.py" ]] ||
        die "Snapshot has no bot.py"

    cp -a \
        "$target/bot.py" \
        "$APP_DIR/bot.py"

    [[ -f "$target/requirements.txt" ]] &&
        cp -a \
            "$target/requirements.txt" \
            "$APP_DIR/requirements.txt"

    [[ -f "$target/webssh.html" ]] &&
        cp -a \
            "$target/webssh.html" \
            "$APP_DIR/webssh.html"

    systemctl restart "${SERVICE}.service"

    ok "Restored bot.py from $target"
    info "Your .env and vps.db were not touched."
}

# ═════════════════════════════ AI AGENT ══════════════════════════════════════

LOCALAI_CONTAINER="${SVM_LOCALAI_CONTAINER:-svm-localai}"
LOCALAI_IMAGE="${SVM_LOCALAI_IMAGE:-localai/localai:latest-aio-cpu}"
LOCALAI_DIR="${APP_DIR}/localai"

ai_url() {
    local u
    u="$(get_env LOCALAI_BASE_URL)"

    printf '%s' "${u:-http://127.0.0.1:8080}"
}

ai_curl() {
    local key
    key="$(get_env LOCALAI_API_KEY)"

    if [[ -n "$key" ]]; then

        curl -fsS \
            --max-time "${2:-6}" \
            -H "Authorization: Bearer ${key}" \
            "$(ai_url)$1"

    else

        curl -fsS \
            --max-time "${2:-6}" \
            "$(ai_url)$1"
    fi
}

localai_runtime() {
    if command -v docker >/dev/null 2>&1 &&
       docker ps -a \
            --format '{{.Names}}' 2>/dev/null |
       grep -qx "$LOCALAI_CONTAINER"
    then
        echo docker

    elif systemctl list-unit-files 2>/dev/null |
         grep -q '^svm-localai.service'
    then
        echo systemd

    else
        echo external
    fi
}

ai_models_list() {
    ai_curl /v1/models 2>/dev/null |
        python3 -c '
import sys,json
[print(m["id"]) for m in json.load(sys.stdin).get("data",[])]
' 2>/dev/null ||
        true
}

install_localai_docker() {
    command -v docker >/dev/null 2>&1 ||
        die "Docker is not installed."

    warn "This pulls '${LOCALAI_IMAGE}'."
    warn "All-in-one images may be several GB."

    yesno "Download and start LocalAI now?" n ||
        {
            info "Skipped."
            info "Re-run: install.sh ai-install"
            return 0
        }

    mkdir -p "$LOCALAI_DIR/models"

    docker pull "$LOCALAI_IMAGE"

    docker rm -f \
        "$LOCALAI_CONTAINER" \
        >/dev/null 2>&1 ||
        true

    docker run -d \
        --name "$LOCALAI_CONTAINER" \
        --restart unless-stopped \
        -p 127.0.0.1:8080:8080 \
        -e MODELS_PATH=/models \
        -v "$LOCALAI_DIR/models:/models" \
        "$LOCALAI_IMAGE" \
        >/dev/null

    set_env LOCALAI_BASE_URL \
        "http://127.0.0.1:8080"

    ok "LocalAI container '${LOCALAI_CONTAINER}' started"
}

install_localai_systemd() {
    local bin

    bin="$(command -v local-ai || true)"

    [[ -n "$bin" ]] ||
        die "'local-ai' binary not found in PATH"

    id localai >/dev/null 2>&1 ||
        useradd \
            --system \
            --home "$LOCALAI_DIR" \
            --shell /usr/sbin/nologin \
            localai

    mkdir -p "$LOCALAI_DIR/models"

    chown -R \
        localai:localai \
        "$LOCALAI_DIR"

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

    systemctl enable --now \
        svm-localai.service

    set_env LOCALAI_BASE_URL \
        "http://127.0.0.1:8080"

    ok "svm-localai.service installed"
}

ai_pick_model() {
    local key="$1"
    local label="$2"
    local optional="${3:-}"
    local models=()
    local m
    local i=1
    local pick

    while IFS= read -r m; do
        [[ -n "$m" ]] &&
            models+=("$m")
    done < <(ai_models_list)

    if ((${#models[@]} == 0)); then

        warn "No models found at $(ai_url)."

        ask "$key" "$label"

        return 0
    fi

    printf '  Installed models:\n'

    for m in "${models[@]}"; do
        printf '   [%d] %s\n' "$i" "$m"
        i=$((i+1))
    done

    (( INTERACTIVE )) || return 0

    read -r -p \
        "  ${label} (number or name${optional:+, blank to skip}): " \
        pick

    [[ -z "$pick" ]] &&
        return 0

    if [[ "$pick" =~ ^[0-9]+$ ]] &&
       (( pick >= 1 && pick <= ${#models[@]} ))
    then
        pick="${models[$((pick-1))]}"
    fi

    set_env "$key" "$pick"
}

ai_wizard() {
    section "SVM+ AI AGENT SETUP"

    cat <<'BANNER'
  ╔════════════════════════════════════╗
          SVM+ AI AGENT SETUP
  ╚════════════════════════════════════╝
BANNER

    (( INTERACTIVE )) ||
        {
            info "Non-interactive: using SVM_ENV_* and existing .env."
            return 0
        }

    local choice

    while true; do

        cat <<MENU

  [1] Enable LocalAI            (AI_ENABLED=$(get_env AI_ENABLED))
  [2] Configure endpoint        ($(ai_url))
  [3] Select model              ($(get_env LOCALAI_MODEL))
  [4] Streaming                 ($(get_env AI_STREAMING))
  [5] Memory                    ($(get_env AI_MEMORY))
  [6] Coding agent              ($(get_env AI_CODE_TOOLS))
  [7] Sandbox                   ($(get_env AI_SANDBOX_ENABLED))
  [8] Vision                    ($(get_env AI_VISION) / $(get_env LOCALAI_VISION_MODEL))
  [9] Image generation          ($(get_env AI_IMAGE_ENABLED) / $(get_env LOCALAI_IMAGE_MODEL))
  [10] Status channel           ($(get_env STATUS_CHANNEL_ID))
  [11] Live SVG                 ($(get_env STATUS_SVG_ENABLED))
  [12] Live PNG                 ($(get_env STATUS_PNG_ENABLED))
  [13] Finish

MENU

        read -r -p "  Choose [1-13]: " choice

        case "$choice" in

            1)
                if yesno "Enable the AI agent?" y; then
                    set_env AI_ENABLED true
                else
                    set_env AI_ENABLED false
                fi

                if [[ "$(get_env AI_ENABLED)" == true &&
                      "$(localai_runtime)" == external ]] &&
                   ! ai_curl /v1/models >/dev/null 2>&1
                then

                    if command -v local-ai >/dev/null 2>&1 &&
                       yesno \
                           "Install local-ai as the svm-localai systemd service?" \
                           y
                    then
                        install_localai_systemd

                    elif yesno \
                        "Install LocalAI as a Docker container?" \
                        n
                    then
                        install_localai_docker
                    fi
                fi
                ;;

            2)
                ask LOCALAI_BASE_URL \
                    "LocalAI base URL" \
                    "http://127.0.0.1:8080"

                ask LOCALAI_API_KEY \
                    "LocalAI API key (blank if none)" \
                    "" \
                    secret
                ;;

            3)
                ai_pick_model LOCALAI_MODEL "Chat model"
                ;;

            4)
                if yesno "Stream answers?" y; then
                    set_env AI_STREAMING true
                else
                    set_env AI_STREAMING false
                fi
                ;
