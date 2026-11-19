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
cada ~10 minutos (cadena autodisparada, ver más abajo):

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
2. Si el siguiente eslabón (~10 min después) también falla → debounce
   cumplido → ping `/fail` inmediato a healthchecks.io → aviso a Telegram
   (down) casi al instante.
3. En cuanto una ejecución vuelve a ver los 4 dominios sanos → ping normal →
   healthchecks.io pasa a "up" → aviso de recuperación.

## Por qué una cadena y no el cron (20-nov-2026)

El cron `*/10` de un repo **público** no sirve de reloj: GitHub retrasa o
descarta casi todas sus ejecuciones. Medido con
`gh api repos/juanmixto/homelab-edge-watchdog/actions/workflows/watchdog.yml/runs`:
del 4 al 19-nov solo hubo **3-5 ejecuciones al día** (huecos de 4 a 10 h)
en vez de 144. Consecuencias:

- el check de healthchecks.io (ya subido a periodo 5 h) se ponía en «down»
  por falta de ping unas dos veces al día desde el 16-nov, y otra vez «up»
  al llegar el siguiente: ruido por correo y por HealthchecksBot;
- y lo grave: con el debounce de 2 ejecuciones, un 403 real se habría
  confirmado **entre 8 y 20 h** después. El incidente del 8-sep duró 12 h.

Ahora el workflow es una **cadena que se dispara a sí misma**:

1. cada eslabón (`workflow_dispatch` con `cadena=true`) espera **9 min** en el
   entorno `espera-cadena`, que tiene un `wait_timer` de 9 min: GitHub retiene
   el job **sin ocupar runner**;
2. comprueba los 4 dominios (`scripts/check.sh`, igual que antes);
3. `scripts/encadenar.sh` lanza el siguiente eslabón con el `GITHUB_TOKEN`
   (`actions: write` solo en ese job). Es la excepción documentada por
   GitHub: los eventos del `GITHUB_TOKEN` no lanzan workflows **salvo**
   `workflow_dispatch` y `repository_dispatch`. No hay ningún token personal.

Ritmo resultante: un eslabón cada ~10-11 min. Coste: cero (repo público).

Protecciones:

- **Nunca dos cadenas**: `concurrency: edge-watchdog` deja como mucho una
  ejecución en curso y una pendiente, y `encadenar.sh` no dispara si ya hay
  otra sin terminar (la cadena sigue por esa).
- **Un dominio caído no para la vigilancia**: el job `siguiente` corre
  siempre (`always()`), y lleva `continue-on-error` para no poner el run en
  rojo (el rojo es la memoria del debounce).
- **Si la cadena se rompe** (fallo de la API tras 3 intentos), el cron
  `*/10` sigue ahí como **resucitador**: cuando GitHub lo deja entrar,
  comprueba y vuelve a encadenar. Y si tarda, el dead-man de healthchecks.io
  lo ve por falta de ping.
- Las **pruebas** (`test_url`) nunca continúan la cadena, y el debounce
  ignora las ejecuciones canceladas (una pendiente que sustituye otra no
  cuenta como «la anterior»).
- El entorno crea un registro de *deployment* por eslabón (pestaña
  Deployments del repo). Es ruido inofensivo.

Si hubiera que rehacer el entorno:
`gh api -X PUT repos/juanmixto/homelab-edge-watchdog/environments/espera-cadena -F wait_timer=9`.
Para **parar** la cadena: deshabilitar el workflow
(`gh workflow disable watchdog.yml`); el eslabón en espera se cancela a mano.

Alternativas que se miraron y por qué no:

| Opción | Coste | Por qué no |
|---|---|---|
| Repo privado | ~4.300 min/mes de Actions (2.000 gratis) | Pago, y el repo solo nombra subdominios públicos |
| Disparador externo de `workflow_dispatch` (timer del CT113) | Token fino con `Actions: write` solo en este repo | Un token nuevo es decisión de Juan; la cadena hace lo mismo sin él |
| Sonda en la BeeStation de los padres | Montar y mantener un script allí | Más piezas fuera de casa sin acceso fácil; no necesario |
| Solo ajustar periodo y grace al ritmo real (~12 h) | Nada | Quita el ruido pero deja la detección en 8-20 h: no vigila |

### Periodo y grace del check de healthchecks.io

El camino principal de aviso es el `/fail` explícito tras 2 eslabones
seguidos en fallo (~20 min). El periodo del check es la **red de seguridad**
por si la cadena muere. Con la cadena funcionando, el periodo de 5 h ya no
da falsos «down»; bajarlo (p. ej. a 30 min con grace 30 min) acortaría el
aviso de «la cadena murió», y se hace desde la web de healthchecks.io
(el proyecto de este check no es el de `/root/bin/hc` del CT113).

## `keepalive.yml`: por qué existe un segundo workflow

GitHub apaga en silencio los `schedule` de un repo sin actividad 60 días.
Este job hace un commit trivial una vez al mes (día 1, 05:00 UTC) para que
el repo nunca esté "inactivo" — sin eso, el vigilante podría dejar de
correr sin que nadie lo note, que es exactamente el fallo que este repo
existe para cerrar.

## Probar sin tocar producción

`workflow_dispatch` acepta `test_url`: si se rellena, sustituye a los 4
dominios reales por esa única URL para esa ejecución. Para forzar el
debounce completo sin tocar CrowdSec ni los dominios de Juan (lánzalas
seguidas: si un eslabón real termina entre dos pruebas, la segunda ya no ve
«la anterior en fallo»). `httpstat.us` dejó de resolver en nov-2026: con esa
URL la prueba avisaría por un fallo de DNS, no por un 403.

```
gh workflow run watchdog.yml -f test_url=https://httpbin.org/status/403   # falla 1 (no avisa)
gh workflow run watchdog.yml -f test_url=https://httpbin.org/status/403   # falla 2 (avisa)
gh workflow run watchdog.yml -f test_url=https://httpbin.org/status/200   # recupera (avisa)
```

## Secret necesario

- `HC_PING_URL`: URL de ping del check de healthchecks.io (formato
  `https://hc-ping.com/<uuid>`), como **secret del repo**. No aparece en
  logs ni en el código.
