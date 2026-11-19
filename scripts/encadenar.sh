#!/usr/bin/env bash
# Dispara el siguiente eslabon de la cadena del vigilante (workflow_dispatch
# con cadena=true), salvo que ya haya otra ejecucion sin terminar: entonces la
# cadena sigue por esa (p. ej. un cron resucitador que entro en cola), y asi
# nunca hay dos cadenas a la vez. Las pruebas (run-name "PRUEBA ...") no
# cuentan: nunca continuan la cadena. Con concurrency: edge-watchdog solo puede
# haber una ejecucion en curso y otra pendiente, asi que no hay carrera.
set -uo pipefail

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}" "${REF:?}"

otros="$(gh run list --workflow watchdog.yml --repo "$GITHUB_REPOSITORY" --limit 30 \
  --json databaseId,status,displayTitle \
  --jq '[.[] | select(.databaseId != '"$GITHUB_RUN_ID"') | select(.status != "completed")
         | select(.displayTitle | startswith("PRUEBA") | not)] | length')" \
  || otros="error"

if [ "$otros" = "error" ]; then
  echo "::warning::no pude leer el historial de runs; disparo igualmente (concurrency evita duplicados en curso)"
elif [ "$otros" -gt 0 ]; then
  echo "Ya hay $otros ejecucion(es) sin terminar: la cadena continua por ella. No disparo otra."
  exit 0
fi

for intento in 1 2 3; do
  if gh workflow run watchdog.yml --repo "$GITHUB_REPOSITORY" --ref "$REF" -f cadena=true; then
    echo "Siguiente eslabon disparado (ref $REF, intento $intento)."
    exit 0
  fi
  echo "::warning::fallo al disparar el siguiente eslabon (intento $intento)"
  sleep 20
done

echo "::error::la cadena se rompe aqui: la resucitara el cron, y si tarda, el dead-man de healthchecks.io lo vera"
exit 1
