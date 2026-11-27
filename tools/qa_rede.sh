#!/usr/bin/env bash
# QA da rede de verdade (QA_SUITE=rede): o net/discord.zig do executável de debug, com o
# WebSocket, o zlib-stream, o RESUME e o REST de verdade, contra o Discord de mentira de
# tools/discord_falso.py em 127.0.0.1. Nada sai da máquina e o token é o de mentira fixo
# (src/net/enderecos.zig), só para esta bateria. Precisa de python3 (sem pacotes do pip).
#   tools/qa_rede.sh [executável]   (padrão: .zig-cache/qa/bin/larpercord)
set -uo pipefail
cd "$(dirname "$0")/.."
bin="${1:-./.zig-cache/qa/bin/larpercord}"
[ -x "$bin" ] || { echo "rede: falta o executável do QA ($bin)"; exit 1; }
command -v python3 >/dev/null || { echo "rede: precisa de python3"; exit 1; }
token=larper-qa-token-falso-nao-e-do-discord
coproc SRV { exec python3 -I tools/discord_falso.py; }
srv_pid=$SRV_PID
trap 'kill "$srv_pid" 2>/dev/null' EXIT
# A primeira linha do servidor é a porta (ele só escuta em 127.0.0.1).
port=""
read -r -t 10 port <&"${SRV[0]}" || true
[[ "$port" =~ ^[0-9]+$ ]] || { echo "rede: o Discord de mentira não subiu"; exit 1; }
base="http://127.0.0.1:$port"
mkdir -p qa-out && rm -rf qa-out/cache
start=$(date +%s)
# A saída inteira fica em qa-out/rede.log (a CI guarda o qa-out/).
env QA_SUITE=rede LARPER_QA_DISCORD="$base" LARPER_TOKEN="$token" timeout 150 "$bin" --qa --theme classico > qa-out/rede.log 2>&1
out=$(grep -v '^info:' qa-out/rede.log)
line=$(echo "$out" | grep 'passaram')
printf "%-24s %s\n" "rede (discord falso)" "${line:-saiu antes do fim, sem o resumo}"
fail=0
if ! echo "$line" | grep -q ' 0 falharam'; then
    fail=1
    if [ -z "$line" ]; then
        echo "$out" | tail -n 25 | sed 's/^/    /'
    else
        echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
    fi
fi
# O que o servidor viu: o porquê de cada checagem que falhou e os caminhos que ele não conhece.
python3 -I - "$base" ${QA_REDE_STATE:+"$QA_REDE_STATE"} <<'EOF' | sed 's/^/    /'
import json, sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1] + "/ctl/summary", timeout=5) as r:
        for line in json.load(r)["lines"]:
            print(line)
    if len(sys.argv) > 2:
        with urllib.request.urlopen(sys.argv[1] + "/ctl/state", timeout=5) as r, open(sys.argv[2], "w") as f:
            f.write(r.read().decode())
except OSError as e:
    print(f"(o servidor não respondeu: {e})")
EOF
echo "    $(( $(date +%s) - start )) s no total"
[ "$fail" = 0 ] && echo "rede: tudo passou" || { echo "rede: houve falhas"; exit 1; }
