# edge-watchdog — vigilante externo del borde del homelab

El 8-sep-2026 el homelab estuvo **12 horas sirviendo 403 desde Internet**
(Grafana, alicante, cms-alicante, agentes) sin que nadie se enterase. La
causa fue CrowdSec; el motivo de que nadie lo viera fue estructural: **Kuma,
y cualquier chequeo lanzado desde dentro de casa, son ciegos a este fallo**
porque `clientTrustedIPs` en el bouncer de Traefik exime a
`192.168.1.0/24` y `172.19.0.0/16` (LAN y red Docker) — Kuma y agent-master
viven ahí, así que su "verde" no significa nada sobre esto.

Este repo existe para ver la caída **desde fuera de verdad**. Corre en
runners de GitHub Actions (por definición fuera de ambas redes) y comprueba
cada 10 minutos:

- `grafana.feldescloud.com`
- `alicante.feldescloud.com`
- `cms-alicante.feldescloud.com`
- `agentes.feldescloud.com`

## Por qué dead-man y no llamar a Telegram directamente

El primer diseño llamaba a la API de Telegram con el token del bot del
homelab desde el runner. Eso es meter una credencial del homelab en un
tercero (GitHub) — evitable. En su lugar:

- El workflow **solo hace ping a un check de healthchecks.io cuando los 4
  dominios responden sano**. Si algo falla, calla (o manda un ping `/fail`
  explícito una vez confirmado el fallo, ver debounce abajo).
- **healthchecks.io** es quien avisa a Telegram, con un canal que ya estaba
  verificado extremo a extremo para otro check de este homelab.
- Lo único que sale de casa hacia GitHub es una **URL de ping de un solo
  uso** (secret `HC_PING_URL`) — no puede leer ni tocar nada del homelab,
  como mucho alguien podría forjar un aviso falso si la adivinara (UUID v4,
  no es plausible).
- Contrapartida asumida a propósito: si el propio runner de GitHub se rompe
  del todo (no solo el chequeo, sino que deja de ejecutarse), el check de
  healthchecks.io lo nota por **ausencia de ping** (ver "grace" abajo) y
  también avisa. Fallar visible, no en silencio.

## Debounce: 2 ejecuciones seguidas en fallo

No se avisa por un hipo de red de un único run. El estado de "¿la ejecución
anterior también falló?" se lee del **historial de runs de este mismo
workflow** vía la API de GitHub (con el token que Actions ya inyecta) — no
hay fichero de estado que commitear ni caché que se pueda desincronizar.

1. Un dominio falla (403 / 5xx / timeout) → el run se marca en rojo en la
   pestaña Actions (esa es su única función: es la memoria del debounce) y
   **no se avisa todavía**.
2. Si la siguiente ejecución (10 min después) también falla → debounce
   cumplido → ping `/fail` inmediato a healthchecks.io → aviso a Telegram
   (down) casi al instante.
3. En cuanto una ejecución vuelve a ver los 4 dominios sanos → ping normal →
   healthchecks.io pasa a "up" → aviso de recuperación.

## Por qué el check de healthchecks.io tiene grace de 25 min

Es una **red de seguridad**, no el camino principal de aviso (ese es el
`/fail` explícito del punto 2, mucho más rápido). Con período 20 min /
gracia 25 min, un solo retraso típico del cron de GitHub Actions (que
GitHub documenta que puede sufrir bajo carga) no dispara un falso aviso;
solo dispara si GitHub deja de ejecutar el workflow del todo durante ~45
min seguidos.

## `keepalive.yml`: por qué existe un segundo workflow

GitHub apaga en silencio los `schedule` de un repo sin actividad 60 días.
Este job hace un commit trivial una vez al mes (día 1, 05:00 UTC) para que
el repo nunca esté "inactivo" — sin eso, el vigilante podría dejar de
correr sin que nadie lo note, que es exactamente el fallo que este repo
existe para cerrar.

## Probar sin tocar producción

`workflow_dispatch` acepta `test_url`: si se rellena, sustituye a los 4
dominios reales por esa única URL para esa ejecución. Para forzar el
debounce completo sin tocar CrowdSec ni los dominios de Juan:

```
gh workflow run watchdog.yml -f test_url=https://httpstat.us/403   # falla 1 (no avisa)
gh workflow run watchdog.yml -f test_url=https://httpstat.us/403   # falla 2 (avisa)
gh workflow run watchdog.yml -f test_url=https://httpstat.us/200   # recupera (avisa)
```

## Secret necesario

- `HC_PING_URL`: URL de ping del check de healthchecks.io (formato
  `https://hc-ping.com/<uuid>`), como **secret del repo**. No aparece en
  logs ni en el código.
