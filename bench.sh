#!/usr/bin/env bash
# bench.sh — перебирает Jitsi-хосты и говорит, какие из них реально поднимают
# туннель и с какой задержкой. Нужен, чтобы выбрать хост, который проходит
# у твоего оператора в белом списке и вообще живой.
#
#   ./bench.sh                     # список хостов по умолчанию
#   ./bench.sh meet.egovm.ru a.b.c # свои хосты
#   TIMEOUT=25 ./bench.sh          # сколько ждать на хост, сек (по умолчанию 45)
#
# Ничего не настраивает и не трогает рабочие конфиги: гоняет всё во временном
# каталоге, свой srv+cnc на паре портов, ключ одноразовый.
set -uo pipefail

OLCRTC="${OLCRTC_BIN:-}"
[ -z "$OLCRTC" ] && OLCRTC="$(command -v olcrtc || true)"
[ -x "$OLCRTC" ] || { echo "[X] бинарь olcrtc не найден (OLCRTC_BIN=/путь/olcrtc)"; exit 1; }

TIMEOUT="${TIMEOUT:-45}"
TRANSPORT="${TRANSPORT:-datachannel}"
WORK="$(mktemp -d -t olcrtc-bench.XXXXXX)"
trap 'pkill -P $$ 2>/dev/null; rm -rf "$WORK"' EXIT

DEFAULT_HOSTS=(
    meet.egovm.ru
    meet.mamba.group
    m.catonmoon.com
    webinar.devknomarylms.ru
    meet.geotec.ru
    jitsi.etudevs.ru
    meet.riddlerx.org
    conference.ct.placetime.team
    meet.playform.ru
    conf.hyperia.space
)

HOSTS=("$@")
[ "${#HOSTS[@]}" -eq 0 ] && HOSTS=("${DEFAULT_HOSTS[@]}")

KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

echo "ХОСТ | СТАТУС | ЗАДЕРЖКА | IP_ВЫХОДА"
echo "----------------------------------------"

for i in "${!HOSTS[@]}"; do
    host="${HOSTS[$i]}"
    room="olcrtc-bench-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    srv="$WORK/srv-$i.yaml"
    cnc="$WORK/cnc-$i.yaml"
    port=$((18900 + i))

    cat > "$srv" <<EOF
mode: srv
auth:
  provider: jitsi
room:
  id: "https://$host/$room"
crypto:
  key: "$KEY"
net:
  transport: $TRANSPORT
  dns: "8.8.8.8:53"
debug: false
EOF
    cat > "$cnc" <<EOF
mode: cnc
auth:
  provider: jitsi
room:
  id: "https://$host/$room"
crypto:
  key: "$KEY"
net:
  transport: $TRANSPORT
  dns: "8.8.8.8:53"
socks:
  host: "127.0.0.1"
  port: $port
debug: false
EOF

    "$OLCRTC" "$srv" > "$WORK/srv-$i.log" 2>&1 &
    srv_pid=$!
    sleep 2
    "$OLCRTC" "$cnc" > "$WORK/cnc-$i.log" 2>&1 &
    cnc_pid=$!

    status="FAIL"; lat="—"; ip=""
    start=$(date +%s)
    while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
        kill -0 "$cnc_pid" 2>/dev/null || break
        if out="$(curl -s --max-time 4 --socks5-hostname "127.0.0.1:$port" https://icanhazip.com 2>/dev/null)"; then
            if [ -n "$out" ]; then
                status="OK"
                lat="$(awk -v s="$start" 'BEGIN{printf "%.1fs", systime()-s}')"
                ip="$out"
                break
            fi
        fi
        sleep 1
    done

    kill "$cnc_pid" "$srv_pid" 2>/dev/null
    wait "$cnc_pid" "$srv_pid" 2>/dev/null
    printf '%-34s %-8s %-10s %s\n' "$host" "$status" "$lat" "$ip"
done

echo
echo "OK + низкая задержка = хост живой. Проверь, что его IP в белом списке твоего"
echo "оператора (иначе вне Wi-Fi туннель не поднимется), и подставляй в --host."
