#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
#  Inventario de red con nmap + detección de cambios
#  Canal: inventario · Webhook: http://62.238.114.81:9007/webhook/0WzszSAemPOL
# ═══════════════════════════════════════════════════════════════════════════

# ── Colores ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  ROJO=$'\033[0;31m'; VERDE=$'\033[0;32m'; AMARILLO=$'\033[0;33m'
  AZUL=$'\033[0;34m'; RESET=$'\033[0m'
  NEGRITA=$'\033[1m'
else
  ROJO=""; VERDE=""; AMARILLO=""; AZUL=""; RESET=""; NEGRITA=""
fi

USO() {
  cat <<EOF
Uso: $0 <CIDR> [opciones]

Opciones:
  -e <escaner>        Nombre del escáner (default: hostname)
  -w <url-webhook>    URL del webhook
  -v <segundos>       Modo vigilancia: repetir cada N segundos (default: 300)
  -i                  Solo inventario (no vigila)
  -r                  Generar informe (informe.md)
  -c <archivo>        Fichero de configuración (default: inventario.conf)
  -h                  Ayuda

Ejemplos:
  $0 192.168.0.0/22
  $0 192.168.0.0/22 -v 60 -r
  $0 192.168.0.0/22 -e kali-g4 -i
  $0 192.168.0.0/22 -c mi_config.conf
EOF
}

# ── Defaults ─────────────────────────────────────────────────────────────────
ESCANER="$(hostname 2>/dev/null || echo desconocido)"
WEBHOOK="http://62.238.114.81:9007/webhook/0WzszSAemPOL"
SYNC_URL="http://62.238.114.81:8087/sync"
VIGILANCIA=300
SOLO_INV=false
GENERAR_INFORME=false
SYNC_FALLOS=0
SYNC_MAX_FALLOS=5
SYNC_ACTIVADO=true
WEBHOOK_FALLOS=0
WEBHOOK_MAX_FALLOS=5
WEBHOOK_ACTIVADO=true

# Puertos a escanear (todos los puertos)
PUERTOS_SCAN="1-65535"
RETRY_NMAP=3
RETRY_BACKOFF=(5 15)  # esperas entre reintentos: 5s, 15s

# ── Argumentos ───────────────────────────────────────────────────────────────
CONFIG_FILE=""

while getopts ':e:w:v:ic:rh' opt; do
  case "$opt" in
    e) ESCANER="$OPTARG" ;;
    w) WEBHOOK="$OPTARG" ;;
    v) VIGILANCIA="$OPTARG" ;;
    i) SOLO_INV=true ;;
    r) GENERAR_INFORME=true ;;
    c) CONFIG_FILE="$OPTARG" ;;
    h) uso; exit 0 ;;
    \?) echo "${ROJO}[ERROR]${RESET} Opción desconocida: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# ── Config file ─────────────────────────────────────────────────────────────
if [[ -z "$CONFIG_FILE" ]]; then
  CONFIG_FILE="$(pwd)/inventario.conf"
fi
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  echo "${AZUL}[*]${RESET} Config: $CONFIG_FILE"
else
  # Crear plantilla si no existe
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<CONFEOF
# Inventario de red — configuración
# Sobrescribe los valores por defecto del script

WEBHOOK="http://62.238.114.81:9007/webhook/0WzszSAemPOL"
SYNC_URL="http://62.238.114.81:8087/sync"
VIGILANCIA=300
ESCANER="$(hostname 2>/dev/null || echo desconocido)"
PUERTOS_SCAN="1-65535"
RETRY_NMAP=3
CONFEOF
    echo "${AMARILLO}[*]${RESET} Config creada: $CONFIG_FILE"
  fi
fi

if [[ $# -lt 1 ]]; then
  uso
  exit 1
fi
RED="$1"

# ── Validación CIDR ─────────────────────────────────────────────────────────
if ! [[ "$RED" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
  echo "${ROJO}[ERROR]${RESET} '$RED' no es un CIDR válido (ej.: 192.168.0.0/22)" >&2
  exit 1
fi
oct=$(( 10#${RED%%.*} )); rest="${RED#*.}"
oct2=$(( 10#${rest%%.*} )); rest="${rest#*.}"
oct3=$(( 10#${rest%%.*} )); rest="${rest#*.}"
oct4=$(( 10#${rest%%/} )); prefijo=$(( 10#${RED##*/} ))
for o in "$oct" "$oct2" "$oct3" "$oct4"; do
  (( o > 255 )) && { echo "${ROJO}[ERROR]${RESET} Octeto '$o' fuera de rango" >&2; exit 1; }
done
(( prefijo < 1 || prefijo > 32 )) && { echo "${ROJO}[ERROR]${RESET} Prefijo '$prefijo' fuera de rango" >&2; exit 1; }

# ── Directorios y ficheros ──────────────────────────────────────────────────
DIR_INV="$(pwd)/inventarios"
mkdir -p "$DIR_INV"
DIR_AUTH="$(pwd)/autorizados"
mkdir -p "$DIR_AUTH"
DIR_LOG="$(pwd)/logs"
mkdir -p "$DIR_LOG"
LOG_FILE="${DIR_LOG}/inventario_$(date +%Y%m%d_%H%M%S).log"

# Fichero de autorizados: plantilla si no existe
if [[ ! -f "${DIR_AUTH}/autorizados.json" ]]; then
  echo '[]' > "${DIR_AUTH}/autorizados.json"
  echo "${AMARILLO}[*]${RESET} Plantilla de autorizados creada: ${DIR_AUTH}/autorizados.json"
fi
AUTH_FILE="${DIR_AUTH}/autorizados.json"

# Puertos de riesgo
RIESGO_FILE="${DIR_AUTH}/puertos_riesgo.txt"
if [[ ! -f "$RIESGO_FILE" ]]; then
  cat > "$RIESGO_FILE" <<'PORTS'
23
445
3389
5900
873
21
PORTS
  echo "${AMARILLO}[*]${RESET} Puertos de riesgo creados: $RIESGO_FILE"
fi

# ── Función: log ────────────────────────────────────────────────────────────
log() {
  local msg="$1"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $msg" >> "$LOG_FILE"
}

# ── Función: nmap con retry ────────────────────────────────────────────────
nmap_retry() {
  local xml_tmp="$1"
  local attempt=1
  local total_attempts=$(( RETRY_NMAP + 1 ))

  while (( attempt <= total_attempts )); do
    local exit_code=0
    nmap -T4 --max-rtt-timeout 3 -p "$PUERTOS_SCAN" --open -oX "$xml_tmp" "$RED" 2>/dev/null || exit_code=$?

    if (( exit_code == 0 )) && [[ -s "$xml_tmp" ]]; then
      return 0
    fi

    if (( attempt < total_attempts )); then
      local backoff="${RETRY_BACKOFF[$(( attempt - 1 ))]:-${RETRY_BACKOFF[-1]}}"
      echo "${AMARILLO}[*]${RESET} nmap falló (intento $attempt/$total_attempts). Reintentando en ${backoff}s..."
      log "RETRY: nmap intento $attempt falló, backoff ${backoff}s"
      sleep "$backoff"
    fi
    attempt=$(( attempt + 1 ))
  done

  echo "${ROJO}[ERROR]${RESET} nmap falló tras $total_attempts intentos" >&2
  log "ERROR: nmap falló tras $total_attempts intentos"
  return 1
}

# ── Función: escanear y generar inventario ──────────────────────────────────
escanear() {
  local xml_tmp
  xml_tmp="$(mktemp /tmp/nmap_xml_XXXXXX)"
  local inicio=$(date +%s)

  nmap_retry "$xml_tmp" || { rm -f "$xml_tmp"; return 1; }
  local fin=$(date +%s)
  local duracion=$(( fin - inicio ))

  # Validar que es XML válido
  if ! head -c 100 "$xml_tmp" | grep -q '<nmaprun\|<?xml'; then
    echo "${ROJO}[ERROR]${RESET} XML de nmap inválido o incompleto" >&2
    log "ERROR: XML inválido"
    rm -f "$xml_tmp"
    return 1
  fi

  local TS
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  INVENTARIO_JSON="$(python3 - "$xml_tmp" "$ESCANER" "$RED" "$TS" <<'PYEOF'
import sys, json
from xml.etree import ElementTree as ET

xml_path, escaner, red, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
tree = ET.parse(xml_path)
root = tree.getroot()

hosts = []
for host_el in root.iter('host'):
    addr = host_el.find('address')
    ip = addr.get('addr') if addr is not None else ''
    if not ip:
        continue
    hostname_el = host_el.find('hostnames/hostname')
    nombre = hostname_el.text if hostname_el is not None and hostname_el.text else 'sin_nombre'

    mac_el = host_el.find('address[@addrtype="mac"]')
    mac = mac_el.get('addr', '') if mac_el is not None else ''

    puertos = []
    for port in host_el.findall('ports/port'):
        svc_el = port.find('service')
        svc_name = svc_el.get('name', '') if svc_el is not None else ''
        puertos.append({
            'puerto': int(port.get('portid', 0)),
            'proto': 'tcp',
            'servicio': svc_name
        })

    hosts.append({
        'ip': ip,
        'nombre': nombre,
        'mac': mac,
        'puertos': puertos
    })

print(json.dumps({
    'tipo': 'inventario',
    'escaner': escaner,
    'red': red,
    'ts': ts,
    'hosts': hosts,
}, ensure_ascii=False))
PYEOF
)" || { rm -f "$xml_tmp"; return 1; }
  rm -f "$xml_tmp"

  local fecha
  fecha="$(date +%Y%m%d_%H%M%S)"
  local archivo
  archivo="${DIR_INV}/inv_${fecha}.json"
  echo "$INVENTARIO_JSON" | jq -e '.' > "$archivo" || {
    echo "${ROJO}[ERROR]${RESET} JSON inventario inválido" >&2
    return 1
  }

  local num_hosts
  num_hosts="$(echo "$INVENTARIO_JSON" | jq '.hosts | length')"
  echo "${VERDE}[*]${RESET} Inventario: $archivo (${num_hosts} hosts, ${duracion}s)"
  log "OK: inventario $archivo - ${num_hosts} hosts - ${duracion}s"
  return 0
}

# ── Función: generar cambios vs inventario anterior ─────────────────────────
generar_cambios() {
  local archivo_actual="$1"
  local previos
  previos="$(ls -t "$DIR_INV"/inv_*.json 2>/dev/null || true)"
  local previos_excl=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$archivo_actual" ]] && previos_excl+=("$p")
  done <<< "$previos"
  if [ ${#previos_excl[@]} -eq 0 ]; then
    echo "${AMARILLO}[*]${RESET} No hay inventario anterior. Baseline establecido."
    log "INFO: baseline establecido"
    return 1
  fi
  local previo="${previos_excl[0]}"
  echo "${AZUL}[*]${RESET} Comparando con: $previo"

  CAMBIOS_JSON="$(jq -n \
    --slurpfile viejo "$previo" \
    --slurpfile nuevo "$archivo_actual" '
    ($viejo[0].hosts | map(.ip)) as $v |
    ($nuevo[0].hosts | map(.ip)) as $n
    | ($n - $v) as $nuevos
    | ($v - $n) as $desaparecidos
    | ([$nuevo[0].hosts[] | .ip as $ip | .puertos[] | {ip: $ip, puerto: .puerto}]) as $pn
    | ([$viejo[0].hosts[] | .ip as $ip | .puertos[] | {ip: $ip, puerto: .puerto}]) as $pv
    | {
        tipo: "cambios_red",
        escaner: $nuevo[0].escaner,
        ts: $nuevo[0].ts,
        nuevos: $nuevos,
        desaparecidos: $desaparecidos,
        puertos_abiertos: ($pn - $pv),
        puertos_cerrados: ($pv - $pn)
      }')"

  # Detección de IPs no autorizadas
  local no_autorizadas
  no_autorizadas="$(python3 - "$archivo_actual" "$AUTH_FILE" <<'PYEOF'
import sys, json, ipaddress

inv_path, auth_path = sys.argv[1], sys.argv[2]
with open(inv_path) as f:
    inv = json.load(f)
try:
    with open(auth_path) as f:
        auth = json.load(f)
except:
    auth = []

auth_ips = set()
for entry in auth:
    if isinstance(entry, dict):
        if 'ip' in entry:
            try:
                ipaddress.IPv4Address(entry['ip'])
                auth_ips.add(entry['ip'])
            except ValueError:
                pass
        elif 'cidr' in entry:
            try:
                net = ipaddress.ip_network(entry['cidr'], strict=False)
                for ip in net.hosts():
                    auth_ips.add(str(ip))
                auth_ips.add(str(net.network_address))
                auth_ips.add(str(net.broadcast_address))
            except ValueError:
                pass
    elif isinstance(entry, str):
        try:
            ipaddress.IPv4Address(entry)
            auth_ips.add(entry)
        except ValueError:
            pass

todas_ips = [h['ip'] for h in inv.get('hosts', [])]
no_auth = [ip for ip in todas_ips if ip not in auth_ips]

if no_auth:
    print(json.dumps({
        "tipo": "dispositivo_no_autorizado",
        "escaner": inv.get("escaner", ""),
        "ts": inv.get("ts", ""),
        "severidad": "alta",
        "dispositivos_no_autorizados": no_auth
    }, ensure_ascii=False))
PYEOF
)" || no_autorizadas=""

  if [[ -n "$no_autorizadas" ]]; then
    CAMBIOS_JSON="$(jq -n \
      --argjson cambios "$CAMBIOS_JSON" \
      --argjson evento "$no_autorizadas" \
      '$cambios + {alertas_no_autorizadas: [$evento]}')"
    local num_no_auth
    num_no_auth="$(echo "$no_autorizadas" | jq '.dispositivos_no_autorizados | length')"
    log "ALERTA: ${num_no_auth} dispositivos no autorizados"
  fi

  # Detección de puertos de riesgo
  local puertos_riesgo_json
  puertos_riesgo_json="$(jq -R 'split("\n") | map(select(length > 0) | tonumber)' "$RIESGO_FILE" | jq -s .)"
  local puertos_activos_riesgo
  puertos_activos_riesgo="$(jq -n \
    --slurpfile inv "$archivo_actual" \
    --argjson riesgo "$puertos_riesgo_json" '
    ([$inv[0].hosts[] | .ip as $ip | .puertos[] | select(.puerto as $p | $riesgo | index($p) != null) | {ip: $ip, puerto: .puerto}]) as $activos
    | ($activos | map({puerto: .puerto}) | unique) as $unicos
    | if ($unicos | length) > 0 then
        {
          tipo: "puertos_de_riesgo_activos",
          escaner: $inv[0].escaner,
          ts: $inv[0].ts,
          puertos_riesgo: $unicos,
          dispositivos: $activos
        }
      else
        null
      end')"

  if [[ -n "$puertos_activos_riesgo" && "$puertos_activos_riesgo" != "null" ]]; then
    CAMBIOS_JSON="$(jq -n \
      --argjson cambios "$CAMBIOS_JSON" \
      --argjson riesgo "$puertos_activos_riesgo" \
      '$cambios + {alertas_riesgo: [$riesgo]}')"
    local num_riesgo
    num_riesgo="$(echo "$puertos_activos_riesgo" | jq '.puertos_riesgo | length')"
    log "ALERTA: ${num_riesgo} puertos de riesgo activos"
  fi

  CAMBIOS_DETECTADOS="$(echo "$CAMBIOS_JSON" | jq '[
      (.nuevos // [] | length),
      (.desaparecidos // [] | length),
      (.puertos_abiertos // [] | length),
      (.puertos_cerrados // [] | length),
      (.alertas_no_autorizadas // [] | length),
      (.alertas_riesgo // [] | length)
    ] | add // 0')"

  log "CAMBIOS: ${CAMBIOS_DETECTADOS} cambios detectados"
  return 0
}

# ── Función: sincronizar (GET /sync) con backoff ─────────────────────────────
sincronizar() {
  [[ "$SYNC_ACTIVADO" == true ]] || return 0

  local sync_data
  sync_data="$(curl -s -f --max-time 10 "$SYNC_URL" 2>/dev/null)" || {
    SYNC_FALLOS=$((SYNC_FALLOS + 1))
    log "WARN: sync falló ($SYNC_FALLOS/$SYNC_MAX_FALLOS)"
    if (( SYNC_FALLOS >= SYNC_MAX_FALLOS )); then
      echo "${AMARILLO}[WARN]${RESET} /sync falló ${SYNC_MAX_FALLOS} veces. Desactivado hasta próximo reinicio." >&2
      SYNC_ACTIVADO=false
      log "SYNC: desactivado tras ${SYNC_MAX_FALLOS} fallos"
    fi
    return 1
  }

  SYNC_FALLOS=0

  echo "$sync_data" | jq -e '.autorizados' >/dev/null 2>&1 && {
    echo "$sync_data" | jq '.autorizados' > "$AUTH_FILE"
    echo "${VERDE}[*]${RESET} autorizados.json actualizado desde /sync"
    log "SYNC: autorizados actualizados"
  }
  echo "$sync_data" | jq -e '.puertos_riesgo' >/dev/null 2>&1 && {
    echo "$sync_data" | jq -r '.puertos_riesgo[]' > "$RIESGO_FILE"
    echo "${VERDE}[*]${RESET} puertos_riesgo.txt actualizado desde /sync"
    log "SYNC: puertos_riesgo actualizados"
  }
}

# ── Función: health check del webhook ────────────────────────────────────────
comprobar_webhook() {
  [[ "$WEBHOOK_ACTIVADO" == true ]] || return 0
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$WEBHOOK" 2>/dev/null)" || code="000"
  if [[ "$code" == "000" || "$code" == "404" || "$code" == "503" ]]; then
    WEBHOOK_FALLOS=$((WEBHOOK_FALLOS + 1))
    log "WEBHOOK: health check fallo ($code) - $WEBHOOK_FALLOS/$WEBHOOK_MAX_FALLOS"
    if (( WEBHOOK_FALLOS >= WEBHOOK_MAX_FALLOS )); then
      echo "${AMARILLO}[WARN]${RESET} Webhook caído ${WEBHOOK_MAX_FALLOS} veces. Desactivado hasta próximo reinicio." >&2
      WEBHOOK_ACTIVADO=false
      log "WEBHOOK: desactivado tras ${WEBHOOK_MAX_FALLOS} fallos"
    fi
  else
    WEBHOOK_FALLOS=0
  fi
}

# ── Función: enviar webhook (POST) ───────────────────────────────────────────
enviar_webhook() {
  local payload="$1"
  [[ "$WEBHOOK_ACTIVADO" == true ]] || {
    echo "${AMARILLO}[SKIP]${RESET} Webhook desactivado (fallo previo), no se envía." >&2
    log "WEBHOOK: omitido (desactivado)"
    return 1
  }

  local resp
  resp="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$WEBHOOK" 2>/dev/null)" || resp="000"

  if [[ "$resp" == "200" || "$resp" == "201" || "$resp" == "202" ]]; then
    echo "${VERDE}[WEBHOOK]${RESET} HTTP $resp → $WEBHOOK"
    log "WEBHOOK: enviado ($resp)"
  else
    echo "${AMARILLO}[WEBHOOK]${RESET} HTTP $resp → $WEBHOOK"
    log "WEBHOOK: fallo ($resp)"
  fi
}

# ── Función: generar informe legible ─────────────────────────────────────────
generar_informe() {
  local archivo="$1"
  local informe="${DIR_INV}/informe_$(date +%Y%m%d_%H%M%S).md"
  echo "${AZUL}[*]${RESET} Generando informe: $informe"
  jq -r '
    "## Inventario de red — \(.ts)",
    "",
    "- **Escáner:** \(.escaner)",
    "- **Red:** \(.red)",
    "- **Hosts activos:** \(.hosts | length)",
    "",
    "| IP | Nombre | MAC | Puertos abiertos |",
    "|---|---|---|---|",
    (.hosts[] | "| \(.ip) | \(.nombre) | \(.mac // "N/A") | \([.puertos[].puerto] | join(\", \")) |"),
    "",
    "## Puertos de riesgo detectados",
    "",
    (.hosts[] | select(.puertos | map(.puerto) | (index(23) or index(445) or index(3389) or index(5900))) |
      "\- **\(.ip)** (\(.nombre)): puertos de riesgo: \([.puertos[] | select(.puerto as $p | [23,445,3389,5900] | index($p) != null) | .puerto] | join(\", \"))"),
    ""
  ' "$archivo" > "$informe"
  echo "${VERDE}[*]${RESET} Informe: $informe"
  log "INFORME: generado $informe"
}

# ── Ejecución principal ──────────────────────────────────────────────────────
echo "${NEGRITA}═══ Inventario de red · $(date -u) ═══${RESET}"
echo "Red: $RED · Escáner: $ESCANER · Webhook: $WEBHOOK"
echo "Log: $LOG_FILE · Puertos: $PUERTOS_SCAN · Retry: $RETRY_NMAP"
if [[ "$SOLO_INV" == true ]]; then
  echo "${AZUL}[*] Modo: solo inventario${RESET}"
else
  echo "${AZUL}[*] Modo vigilancia: cada ${VIGILANCIA}s (${VIGILANCIA/60} min). Ctrl+C para salir.${RESET}"
fi
echo
log "INICIO: red=$RED escaner=$ESCANER solo_inv=$SOLO_INV puertos=$PUERTOS_SCAN"

ciclo() {
  comprobar_webhook || true
  sincronizar || true

  local exito=0
  escanear || exito=1
  if (( exito )); then
    echo "${ROJO}[ERROR]${RESET} Fallo en escaneo, volviendo a intentarlo en el próximo ciclo"
    return 1
  fi

  local archivo_actual
  archivo_actual="$(ls -t "$DIR_INV"/inv_*.json | head -1)"

  find "$DIR_INV" -name 'inv_*.json' -mtime +30 -delete 2>/dev/null || true

  if [[ "$SOLO_INV" == true ]]; then
    echo "$INVENTARIO_JSON" | jq .
    [[ "$GENERAR_INFORME" == true ]] && generar_informe "$archivo_actual"
    return 0
  fi

  local hay_cambios=0
  if generar_cambios "$archivo_actual"; then
    hay_cambios="$CAMBIOS_DETECTADOS"
  fi

  if (( hay_cambios == 0 )); then
    echo "${VERDE}Sin cambios${RESET}"
    [[ "$GENERAR_INFORME" == true ]] && generar_informe "$archivo_actual"
  else
    echo "${NEGRITA}${AMARILLO}[*] Cambios detectados:${RESET}"

    echo "$CAMBIOS_JSON" | jq -r '
      if .nuevos | length > 0 then
        "  \(.nuevos | length) hosts NUEVOS: " + ([.nuevos[] | " " + .] | join(" · "))
      else "" end
    ' 2>/dev/null || true

    echo "$CAMBIOS_JSON" | jq -r '
      if .desaparecidos | length > 0 then
        "  " + (.desaparecidos | length | tostring) + " hosts DESAPARECIDOS: " + ([.desaparecidos[] | " " + .] | join(" · "))
      else "" end
    ' 2>/dev/null || true

    echo "$CAMBIOS_JSON" | jq -r '
      if .puertos_abiertos | length > 0 then
        "  " + (.puertos_abiertos | length | tostring) + " puertos ABIERTOS: " + ([.puertos_abiertos[] | " " + .ip + ":" + (.puerto | tostring)] | join(" · "))
      else "" end
    ' 2>/dev/null || true

    echo "$CAMBIOS_JSON" | jq -r '
      if .puertos_cerrados | length > 0 then
        "  " + (.puertos_cerrados | length | tostring) + " puertos CERRADOS: " + ([.puertos_cerrados[] | " " + .ip + ":" + (.puerto | tostring)] | join(" · "))
      else "" end
    ' 2>/dev/null || true

    if [[ -n "$(echo "$CAMBIOS_JSON" | jq -r '.alertas_no_autorizadas // empty')" ]]; then
      local num_alertas
      num_alertas="$(echo "$CAMBIOS_JSON" | jq '.alertas_no_autorizadas | length')"
      echo "${ROJO}  [ALERTA] ${num_alertas} dispositivos NO AUTORIZADOS:${RESET}"
      echo "$CAMBIOS_JSON" | jq -r '.alertas_no_autorizadas[0].dispositivos_no_autorizados[] | "    - " + .'
    fi

    if [[ -n "$(echo "$CAMBIOS_JSON" | jq -r '.alertas_riesgo // empty')" ]]; then
      local num_riesgo
      num_riesgo="$(echo "$CAMBIOS_JSON" | jq '.alertas_riesgo[0].puertos_riesgo | length')"
      echo "${AMARILLO}  [RIESGO] ${num_riesgo} puertos de riesgo activos:${RESET}"
      echo "$CAMBIOS_JSON" | jq -r '.alertas_riesgo[0].puertos_riesgo[] | "    - puerto " + (. | tostring)'
    fi

    [[ "$GENERAR_INFORME" == true ]] && generar_informe "$archivo_actual"
    [[ -n "$WEBHOOK" ]] && enviar_webhook "$CAMBIOS_JSON"
  fi

  return 0
}

if [[ "$SOLO_INV" == true ]]; then
  ciclo
  exit 0
fi

# Modo vigilancia
trap 'echo; echo "${VERDE}[*] Vigilancia finalizada.${RESET}" ; exit 0' INT TERM
while true; do
  ciclo || true
  sleep "$VIGILANCIA"
done