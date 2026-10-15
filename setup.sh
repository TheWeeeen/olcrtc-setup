#!/usr/bin/env bash
# olcrtc-setup — поднимает olcRTC-туннель (трафик внутри WebRTC-звонка) на VPS
# и выдаёт готовый конфиг для клиента.
#
#   сервер:  sudo ./setup.sh --mode srv --host meet.egovm.ru
#   клиент:  ./setup.sh --mode cnc --host meet.egovm.ru --room olcrtc-xxx --key <hex64>
#
# Скрипт ничего не знает про твои ключи заранее: он их генерирует сам и кладёт
# в файлы с правами 600. В лог ключ попадает только по явному --show-key.
set -euo pipefail

REPO_URL="${OLCRTC_REPO:-https://github.com/ghostlane-project/olcrtc.git}"
BRANCH="${OLCRTC_BRANCH:-proofkit}"
GO_VERSION="${OLCRTC_GO_VERSION:-1.26.3}"
BIN_DST="${OLCRTC_BIN:-/usr/local/bin/olcrtc}"
UNIT_NAME="olcrtc-srv"
SRC_DIR="/usr/local/src/olcrtc"

MODE="srv"
PROVIDER="jitsi"
TRANSPORT="datachannel"
HOST=""
ROOM=""
KEY=""
DNS="8.8.8.8:53"
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="10808"
SOCKS_USER=""
SOCKS_PASS=""
CFG_DIR=""
UNIT=""
DO_BUILD=0
DO_SYSTEMD=1
DO_SWAP=0
SHOW_KEY=0
FORCE=0

usage() {
    cat <<'EOF'
olcrtc-setup — туннель поверх WebRTC-звонка (olcRTC)

Основное:
  --mode srv|cnc          сервер (выход в интернет) или клиент (SOCKS5 локально). По умолчанию srv
  --host HOST             хост звонка, напр. meet.egovm.ru (для jitsi — обязательно)
  --room ROOM             имя комнаты. По умолчанию генерируется
  --key HEX64             64 hex-символа. По умолчанию генерируется
  --provider NAME         jitsi | telemost | wbstream | salutejazz | vkcalls | mtslink. По умолчанию jitsi
  --transport NAME        datachannel | vp8channel | seichannel | videochannel. По умолчанию datachannel

Клиент (--mode cnc):
  --socks-port PORT       локальный SOCKS5, по умолчанию 10808
  --socks-host ADDR       адрес прослушивания, по умолчанию 127.0.0.1
  --socks-user USER       логин SOCKS5 (нужен вместе с --socks-pass, если слушать не на loopback)
  --socks-pass PASS       пароль SOCKS5

Прочее:
  --dir DIR               куда писать конфиги (srv: /etc/olcrtc, cnc: ./olcrtc)
  --dns HOST:PORT         резолвер внутри туннеля, по умолчанию 8.8.8.8:53
  --build                 собрать бинарь из исходников (по умолчанию — только если его нет)
  --no-systemd            не ставить systemd-юнит (сервер)
  --unit NAME             имя юнита, по умолчанию olcrtc-srv
  --swap                  создать swap-файл 4G, если RAM < 4G (сборка иначе падает)
  --show-key              напечатать ключ в выводе (по умолчанию маскируется)
  --force                 перезаписать существующие конфиги
  -h, --help              эта справка

Примеры:
  sudo ./setup.sh --mode srv --host meet.egovm.ru
  ./setup.sh --mode cnc --host meet.egovm.ru --room olcrtc-1a2b3c4d --key $KEY
EOF
}

die() { echo "[X] $*" >&2; exit 1; }
log() { echo "[*] $*"; }
ok()  { echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "нужен root (sudo $0 ...)"
}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"
    elif command -v doas >/dev/null 2>&1; then SUDO="doas"
    fi
fi

install_pkg() {
    local pkg="$1"
    log "ставлю пакет $pkg"
    if command -v apt >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y "$pkg"
    elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y "$pkg"
    elif command -v pacman >/dev/null 2>&1; then $SUDO pacman -Sy --noconfirm "$pkg"
    elif command -v apk >/dev/null 2>&1; then $SUDO apk add "$pkg"
    else die "не знаю пакетный менеджер — поставь $pkg руками"; fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="${2:?}"; shift 2 ;;
        --host) HOST="${2:?}"; shift 2 ;;
        --room) ROOM="${2:?}"; shift 2 ;;
        --key) KEY="${2:?}"; shift 2 ;;
        --provider) PROVIDER="${2:?}"; shift 2 ;;
        --transport) TRANSPORT="${2:?}"; shift 2 ;;
        --socks-port) SOCKS_PORT="${2:?}"; shift 2 ;;
        --socks-host) SOCKS_HOST="${2:?}"; shift 2 ;;
        --socks-user) SOCKS_USER="${2:?}"; shift 2 ;;
        --socks-pass) SOCKS_PASS="${2:?}"; shift 2 ;;
        --dns) DNS="${2:?}"; shift 2 ;;
        --dir) CFG_DIR="${2:?}"; shift 2 ;;
        --unit) UNIT_NAME="${2:?}"; shift 2 ;;
        --build) DO_BUILD=1; shift ;;
        --no-systemd) DO_SYSTEMD=0; shift ;;
        --swap) DO_SWAP=1; shift ;;
        --show-key) SHOW_KEY=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (--help)" ;;
    esac
done

case "$MODE" in srv|cnc) ;; *) die "--mode только srv или cnc" ;; esac
case "$TRANSPORT" in datachannel|vp8channel|seichannel|videochannel) ;; *) die "неизвестный --transport" ;; esac
case "$PROVIDER" in jitsi|telemost|wbstream|salutejazz|vkcalls|mtslink|none) ;; *) die "неизвестный --provider" ;; esac

if [ -n "$KEY" ]; then
    case "$KEY" in *[!0-9a-fA-F]*) die "--key: только hex" ;; esac
    [ "${#KEY}" -eq 64 ] || die "--key: нужно ровно 64 hex-символа (32 байта)"
fi
if [ -n "$SOCKS_USER" ] && [ -z "$SOCKS_PASS" ]; then die "--socks-user без --socks-pass"; fi
if [ -n "$SOCKS_PASS" ] && [ -z "$SOCKS_USER" ]; then die "--socks-pass без --socks-user"; fi

if [ -z "$ROOM" ]; then ROOM="olcrtc-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
if [ -z "$KEY" ]; then KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi

# --- комната ---
case "$PROVIDER" in
    jitsi)
        [ -n "$HOST" ] || die "для jitsi нужен --host (напр. meet.egovm.ru)"
        HOST="${HOST#http://}"; HOST="${HOST#https://}"; HOST="${HOST%%/*}"
        ROOM_ID="https://$HOST/$ROOM"
        ;;
    *)
        # salutejazz/telemost/vkcalls/mtslink/wbstream берут id комнаты строкой
        if [ -z "$HOST" ] && [ -z "$ROOM" ]; then die "нужен --room"; fi
        if [ -n "$HOST" ] && [ "$HOST" != "$ROOM" ]; then ROOM_ID="$HOST:$ROOM"; else ROOM_ID="$ROOM"; fi
        ;;
esac

# --- swap (сборка Go на маленьком VPS падает) ---
maybe_swap() {
    local total_kb swap_kb
    total_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
    if [ "$total_kb" -lt 3800000 ] && [ "$swap_kb" -lt 1000000 ]; then
        if [ "$DO_SWAP" -eq 1 ]; then
            need_root
            log "мало RAM и нет swap — создаю /swapfile2 4G"
            if [ ! -f /swapfile2 ]; then
                fallocate -l 4G /swapfile2 || dd if=/dev/zero of=/swapfile2 bs=1M count=4096
                chmod 600 /swapfile2 && mkswap /swapfile2 >/dev/null
            fi
            swapon /swapfile2 2>/dev/null || true
            grep -q '^/swapfile2' /etc/fstab || echo '/swapfile2 none swap sw 0 0' >> /etc/fstab
            ok "swap подключён"
        else
            warn "RAM меньше 4G и swap нет — сборка может упасть. Запусти с --swap"
        fi
    fi
}

# --- бинарь ---
have_bin() { command -v olcrtc >/dev/null 2>&1 || [ -x "$BIN_DST" ]; }
bin_path() { if [ -x "$BIN_DST" ]; then echo "$BIN_DST"; else command -v olcrtc; fi; }

[ -x /usr/local/go/bin/go ] && case ":$PATH:" in *":/usr/local/go/bin:"*) ;; *) PATH="/usr/local/go/bin:$PATH" ;; esac

have_go() {
    command -v go >/dev/null 2>&1 || return 1
    local v maj min
    v="$(go version 2>/dev/null | awk '{print $3}')" || return 1
    v="${v#go}"
    maj="${v%%.*}"
    min="${v#*.}"; min="${min%%.*}"
    case "$maj" in ''|*[!0-9]*) return 1 ;; esac
    case "$min" in ''|*[!0-9]*) return 1 ;; esac
    [ "$maj" -gt 1 ] && return 0
    [ "$maj" -eq 1 ] && [ "$min" -ge 26 ] && return 0
    return 1
}

build_bin() {
    need_root
    command -v git >/dev/null 2>&1 || install_pkg git
    command -v curl >/dev/null 2>&1 || install_pkg curl

    if ! have_go; then
        log "ставлю Go $GO_VERSION (нужен >= 1.26)"
        local arch tgz
        case "$(uname -m)" in
            x86_64|amd64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
            *) die "неизвестная архитектура $(uname -m)" ;;
        esac
        tgz="go$GO_VERSION.linux-$arch.tar.gz"
        curl -fsSL "https://go.dev/dl/$tgz" -o "/tmp/$tgz" || die "не скачался $tgz"
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "/tmp/$tgz" || die "tar не распаковался"
        rm -f "/tmp/$tgz"
        PATH="/usr/local/go/bin:$PATH"
    fi
    export PATH
    have_go || die "go не работает — проверь PATH"
    log "Go: $(go version 2>/dev/null | awk '{print $3}')"

    export GOCACHE="${GOCACHE:-/var/cache/olcrtc-gobuild}"
    export GOMODCACHE="${GOMODCACHE:-/var/cache/olcrtc-gomod}"
    mkdir -p "$GOCACHE" "$GOMODCACHE"

    if [ -d "$SRC_DIR/.git" ]; then
        log "обновляю исходники в $SRC_DIR"
        git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH" -q && git -C "$SRC_DIR" checkout -q FETCH_HEAD
    else
        log "клонирую $REPO_URL ($BRANCH)"
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$SRC_DIR" -q || die "git clone не прошёл"
    fi

    log "собираю бинарь (это несколько минут)"
    ( cd "$SRC_DIR" && go build -trimpath -ldflags='-s -w' -o "$BIN_DST" ./cmd/olcrtc ) \
        || die "сборка не прошла"
    chmod 755 "$BIN_DST"
    ok "бинарь: $BIN_DST ($(du -h "$BIN_DST" | cut -f1))"
}

if [ "$DO_BUILD" -eq 1 ] || ! have_bin; then
    maybe_swap
    build_bin
else
    ok "бинарь уже есть: $(bin_path)"
fi
OLCRTC="$(bin_path)"
_bin_out="$("$OLCRTC" 2>&1 || true)"
case "$_bin_out" in
    *"usage: olcrtc"*) ok "бинарь отвечает: $(basename "$OLCRTC")" ;;
    *) warn "бинарь не ответил на запуск без аргументов — проверь вручную: $OLCRTC" ;;
esac
unset _bin_out

mask() { if [ "$SHOW_KEY" -eq 1 ]; then echo "$1"; else echo "${1:0:8}…${1: -4} (--show-key, чтобы увидеть целиком)"; fi; }

# --- сервер ---
if [ "$MODE" = "srv" ]; then
    need_root
    CFG_DIR="${CFG_DIR:-/etc/olcrtc}"
    mkdir -p "$CFG_DIR"
    CFG="$CFG_DIR/srv.yaml"

    if [ -e "$CFG" ] && [ "$FORCE" -ne 1 ]; then
        die "$CFG уже существует — добавь --force, если правда хочешь перезаписать"
    fi

    umask 077
    cat > "$CFG" <<EOF
# olcRTC, режим сервера: трафик клиента выходит отсюда.
# Ключ и комната = пароль от туннеля. Файл читают только root.
mode: srv
auth:
  provider: $PROVIDER
room:
  id: "$ROOM_ID"
crypto:
  key: "$KEY"
net:
  transport: $TRANSPORT
  dns: "$DNS"
liveness:
  interval: 10s
  timeout: 15s
  failures: 4
lifecycle:
  max_session_duration: 6h
debug: false
EOF
    chmod 600 "$CFG"
    ok "конфиг сервера: $CFG"

    if [ "$DO_SYSTEMD" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
        cat > "/etc/systemd/system/$UNIT_NAME.service" <<EOF
[Unit]
Description=olcRTC relay ($PROVIDER/$TRANSPORT) - tunnel over a video call
Documentation=https://github.com/ghostlane-project/olcrtc
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$OLCRTC $CFG
Restart=always
RestartSec=15
LimitNOFILE=65535
# конфиг с ключом читает только root
User=root
StandardOutput=append:/var/log/$UNIT_NAME.log
StandardError=append:/var/log/$UNIT_NAME.log

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$UNIT_NAME" >/dev/null 2>&1 || true
        sleep 3
        if systemctl is-active --quiet "$UNIT_NAME"; then
            ok "сервис $UNIT_NAME запущен и в автозапуске"
        else
            warn "сервис не поднялся — смотри: journalctl -u $UNIT_NAME -n 50"
        fi
        log "логи: tail -f /var/log/$UNIT_NAME.log"
    else
        log "systemd пропущен. Запуск вручную: $OLCRTC $CFG"
    fi

    cat <<EOF

================ ДЛЯ ДРУГОГО УСТРОЙСТВА (клиент) ================
Ключ: $(mask "$KEY")
Комната: $ROOM_ID

1) Ссылка для клиента, который её понимает (owenclave, olcbox):
olcrtc://$PROVIDER?$TRANSPORT@$ROOM_ID#$KEY\$RU / $PROVIDER

2) Или свой cnc.yaml (провайдер $PROVIDER, транспорт $TRANSPORT):
mode: cnc
auth:
  provider: $PROVIDER
room:
  id: "$ROOM_ID"
crypto:
  key: "$KEY"
net:
  transport: $TRANSPORT
  dns: "$DNS"
liveness:
  interval: 10s
  timeout: 15s
  failures: 4
socks:
  host: "127.0.0.1"
  port: $SOCKS_PORT

3) Проверка, что туннель живой (на клиенте):
curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://icanhazip.com
Должен показать IP этого сервера.

НЕ пересылай этот блок в чаты и не показывай на стриме: ключ = доступ к туннелю.
===============================================================
EOF
    if [ -n "${SSH_CONNECTION:-}" ]; then
        log "порт наружу открывать не нужно: сервер сам звонит в $HOST"
    fi
    exit 0
fi

# --- клиент ---
CFG_DIR="${CFG_DIR:-$PWD/olcrtc}"
mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/cnc.yaml"
[ -e "$CFG" ] && [ "$FORCE" -ne 1 ] && die "$CFG уже есть — добавь --force"

umask 077
{
cat <<EOF
# olcRTC, режим клиента: поднимает локальный SOCKS5 и уводит его в звонок.
mode: cnc
auth:
  provider: $PROVIDER
room:
  id: "$ROOM_ID"
crypto:
  key: "$KEY"
net:
  transport: $TRANSPORT
  dns: "$DNS"
liveness:
  interval: 10s
  timeout: 15s
  failures: 4
socks:
  host: "$SOCKS_HOST"
  port: $SOCKS_PORT
EOF
if [ -n "$SOCKS_USER" ]; then
cat <<EOF
  user: "$SOCKS_USER"
  pass: "$SOCKS_PASS"
EOF
fi
} > "$CFG"
chmod 600 "$CFG"
ok "конфиг клиента: $CFG"

if [ "$SOCKS_HOST" != "127.0.0.1" ] && [ "$SOCKS_HOST" != "localhost" ] && [ -z "$SOCKS_USER" ]; then
    warn "SOCKS слушает $SOCKS_HOST без логина/пароля — так делать нельзя, добавь --socks-user/--socks-pass"
fi

cat <<EOF

Запуск:  $OLCRTC $CFG
SOCKS5:  $SOCKS_HOST:$SOCKS_PORT
Проверка: curl --socks5-hostname $SOCKS_HOST:$SOCKS_PORT https://icanhazip.com
EOF
if [ -n "$SOCKS_USER" ]; then
    echo "С логином: curl --socks5-hostname $SOCKS_USER:$SOCKS_PASS@$SOCKS_HOST:$SOCKS_PORT https://icanhazip.com"
fi
