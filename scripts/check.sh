#!/usr/bin/env bash
# Vigilante EXTERNO de los 4 dominios publicos del homelab de Juan.
# Corre en GitHub Actions (fuera de 192.168.1.0/24 y 172.19.0.0/16, las dos
# CIDR que clientTrustedIPs exime en el bouncer de CrowdSec) -- por eso ve
# lo que Kuma y cualquier chequeo desde dentro de casa NO pueden ver.
#
# Patron dead-man, no push directo a Telegram: este script solo hace PING a
# healthchecks.io cuando los 4 dominios estan sanos. Si algo falla, calla
# (o manda /fail si el fallo ya esta confirmado, ver mas abajo) y es
# healthchecks.io quien avisa a Telegram -- por su canal YA verificado
# extremo a extremo (ver memoria healthchecks-api-access), sin exportar el
# token del bot del homelab a un tercero.
set -uo pipefail  # SIN -e: queremos evaluar los 4 dominios aunque uno falle

: "${HC_PING_URL:?falta HC_PING_URL (secret del repo)}"

TIMEOUT_CONNECT=10
TIMEOUT_TOTAL=15

if [ -n "${TEST_URL:-}" ]; then
  echo "::warning::MODO PRUEBA -- comprobando SOLO $TEST_URL, no los dominios reales de Juan"
  DOMAINS=("$TEST_URL")
else
  DOMAINS=(
    "https://grafana.feldescloud.com"
    "https://alicante.feldescloud.com"
    "https://cms-alicante.feldescloud.com"
    "https://agentes.feldescloud.com"
  )
fi

# "Sano" incluye 401/redirects de Authelia (el borde responde, solo pide
# login). Lo que cuenta como caida: 403 (bouncer de CrowdSec o similar),
# cualquier 5xx, o el propio curl fallando (DNS/TLS/timeout/conexion).
HEALTHY_REGEX='^(200|201|202|204|301|302|303|307|308|401)$'

fail=0
detail=()
for url in "${DOMAINS[@]}"; do
  err_file="$(mktemp)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$TIMEOUT_CONNECT" --max-time "$TIMEOUT_TOTAL" \
    "$url" 2>"$err_file")"
  rc=$?
  if [ $rc -ne 0 ]; then
    msg="curl_exit=$rc $(tr '\n' ' ' < "$err_file")"
    echo "FAIL  $url  $msg"
    detail+=("$url: $msg")
    fail=1
  elif [[ "$code" =~ $HEALTHY_REGEX ]]; then
    echo "OK    $url  http=$code"
  else
    echo "FAIL  $url  http=$code"
    detail+=("$url: http=$code")
    fail=1
  fi
  rm -f "$err_file"
done

if [ "$fail" -eq 0 ]; then
  echo "Los $(( ${#DOMAINS[@]} )) dominio(s) responden sano. Ping de exito a healthchecks.io."
  curl -fsS -m 10 "$HC_PING_URL" -o /dev/null
  exit 0
fi

echo "CAIDA detectada: ${detail[*]}"

# ---- Debounce: 2 ejecuciones SEGUIDAS en fallo antes de avisar ----
# El estado es el historial de runs de este propio workflow (API de GitHub,
# token ya inyectado por Actions) -- no hay fichero que commitear ni cache
# que pueda desincronizarse entre ejecuciones.
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_RUN_ID:?}"

# Las pruebas (run-name "PRUEBA ...") solo se comparan con pruebas, y las
# reales solo con reales: una prueba en rojo no adelanta el aviso de una
# caida real, ni al reves. Las canceladas no cuentan como "la anterior".
if [ -n "${TEST_URL:-}" ]; then
  filtro_prueba='startswith("PRUEBA")'
else
  filtro_prueba='startswith("PRUEBA") | not'
fi
prev_conclusion="$(gh run list \
  --workflow watchdog.yml \
  --repo "$GITHUB_REPOSITORY" \
  --limit 30 \
  --json databaseId,conclusion,status,createdAt,displayTitle \
  --jq '[.[] | select(.status=="completed") | select(.conclusion=="success" or .conclusion=="failure") | select(.displayTitle | '"$filtro_prueba"') | select(.databaseId != '"$GITHUB_RUN_ID"')] | sort_by(.createdAt) | last | .conclusion // "ninguna"' \
  2>&1)" || prev_conclusion="error_consultando_historial"

echo "Conclusion de la ejecucion completada anterior: $prev_conclusion"

if [ "$prev_conclusion" = "failure" ]; then
  echo "Segunda ejecucion seguida en fallo -> DEBOUNCE CUMPLIDO. Aviso inmediato (ping /fail)."
  curl -fsS -m 10 "${HC_PING_URL}/fail" -o /dev/null
else
  echo "Primera ejecucion en fallo (o sin historial previo valido): NO se avisa todavia."
  echo "Si en la siguiente pasada (~10 min, siguiente eslabon) persiste, se confirmara entonces."
fi

# El run queda en rojo en la pestana Actions a proposito: es la MEMORIA del
# debounce para la siguiente ejecucion, no un aviso -- eso solo lo decide
# el bloque de arriba.
exit 1
