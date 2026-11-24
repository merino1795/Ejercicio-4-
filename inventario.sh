#!/usr/bin/env bash
# ==============================================================================
# Script:      inventario.sh
# Autores:     Grupo 7
# Descripción: Escanea una red CIDR con nmap (-F --open -oG -), convierte el
#              resultado en un inventario JSON validado con jq -e, lo compara
#              con el inventario anterior para detectar cambios (equipos nuevos,
#              equipos desaparecidos, puertos abiertos y cerrados) y notifica
#              por webhook al canal "inventario".
#
# Ampliaciones incluidas (Fase 2):
#   1. Detección de puertos abiertos y cerrados por equipo.
#   2. Control de equipos autorizados mediante autorizados.json (severidad alta).
#   3. Detección de puertos de riesgo (21, 23, 445, 1433, 3306, 3389, 5900, 6379)
#      incluso en equipos conocidos.
#   4. Modo vigilancia periódico (-v [segundos], por defecto 120s).
#   5. Generación automática de informe legible en Markdown (informe.md) con jq -r.
#
# Uso:
#   ./inventario.sh <red_cidr> [opciones]
#
# Ejemplos:
#   ./inventario.sh 192.168.56.0/24
#   ./inventario.sh 192.168.56.0/24 -v 120
#   ./inventario.sh 192.168.56.0/24 --enviar-inventario --auditar
#   ./inventario.sh 192.168.56.0/24 -w http://SERVIDOR_AULA:9007/webhook/TU_TOKEN
#   ./inventario.sh 192.168.56.0/24 --dry-run
#   ./inventario.sh --ver-sync
#
# Variables de entorno opcionales (también se leen de .env si existe):
#   WEBHOOK_URL       URL POST del webhook
#   SYNC_URL          URL GET para consultar eventos recibidos
#   ESCANER           Identificador del escáner (por defecto: kali-g7)
#   CANAL             Nombre del canal (por defecto: inventario)
#   PUERTOS_RIESGO    Lista CSV de puertos de riesgo
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cargar_env_local() {
  local archivo clave valor
  for archivo in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../.env"; do
    [[ -f "$archivo" ]] || continue
    while IFS='=' read -r clave valor; do
      [[ -z "$clave" || "$clave" == \#* ]] && continue
      valor="${valor%$'\r'}"
      valor="${valor#\"}"
      valor="${valor%\"}"
      case "$clave" in
        WEBHOOK_URL) [[ -z "${WEBHOOK_URL:-}" ]] && WEBHOOK_URL="$valor" ;;
        SYNC_URL)    [[ -z "${SYNC_URL:-}" ]] && SYNC_URL="$valor" ;;
      esac
    done < "$archivo"
  done
}

cargar_env_local

# Valores por defecto (Grupo 7 — sobreescribir con .env, variables de entorno o -w)
WEBHOOK_URL="${WEBHOOK_URL:-http://SERVIDOR_AULA:9007/webhook/TU_TOKEN}"
SYNC_URL="${SYNC_URL:-http://SERVIDOR_AULA:8087/sync}"
ESCANER="${ESCANER:-kali-g7}"
CANAL="${CANAL:-inventario}"
INV_DIR="${INV_DIR:-$SCRIPT_DIR/inventarios}"
AUTORIZADOS_FILE="${AUTORIZADOS_FILE:-$SCRIPT_DIR/autorizados.json}"
INFORME_FILE="${INFORME_FILE:-$SCRIPT_DIR/informe.md}"
PUERTOS_RIESGO="${PUERTOS_RIESGO:-21,23,445,1433,3306,3389,5900,6379}"

MODO_VIGILANCIA=false
INTERVALO_VIGILANCIA=120
GENERAR_INFORME=true
ENVIAR_INICIAL=false
MODO_AUDITAR=false
DRY_RUN=false
VER_SYNC=false
MODO_PRUEBA=false
DESDE_ARCHIVO=""
RED_CIDR=""

mostrar_uso() {
  cat <<EOF
Uso:
  $(basename "$0") <red_cidr> [opciones]
  $(basename "$0") --prueba [-w URL]
  $(basename "$0") --ver-sync

Parámetros:
  <red_cidr>                    Red objetivo en formato CIDR (ej. 192.168.1.0/24)

Opciones:
  -w, --webhook URL             URL POST del webhook (defecto: $WEBHOOK_URL)
  -e, --escaner NOMBRE          Nombre del escáner (defecto: $ESCANER)
  -a, --autorizados FICHERO     Fichero JSON de IPs autorizadas (defecto: $AUTORIZADOS_FILE)
  -d, --directorio DIR          Carpeta para guardar inventarios (defecto: $INV_DIR)
  -v, --vigilancia [SEGUNDOS]   Modo vigilancia: repite cada N seg (defecto: 120)
  -i, --informe FICHERO         Ruta del informe Markdown (defecto: $INFORME_FILE)
      --sin-informe             No generar informe.md
      --enviar-inventario       Enviar también el JSON "inventario" en el primer escaneo
      --auditar                 Enviar alertas de IPs no autorizadas y puertos de riesgo
                                presentes en el inventario actual (aunque no sean nuevos)
      --prueba                  Enviar un mensaje JSON de prueba al webhook para depurar
      --dry-run                 Simular envíos al webhook sin ejecutar peticiones POST
      --desde-archivo FICHERO   Leer salida nmap -oG desde un fichero (pruebas/depuración)
      --ver-sync                Consultar eventos en $SYNC_URL (GET)
  -h, --help                    Mostrar esta ayuda
EOF
}

comprobar_dependencias() {
  echo "[PASO 1/6] Comprobando dependencias (nmap, jq, curl)..."
  local faltan=()
  local cmd
  for cmd in nmap jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      faltan+=("$cmd")
    fi
  done

  if (( ${#faltan[@]} > 0 )); then
    echo "[ERROR] Faltan dependencias: ${faltan[*]}" >&2
    echo "Instálalas con: sudo apt update && sudo apt install -y ${faltan[*]}" >&2
    exit 1
  fi
  echo "[DEBUG] Dependencias OK: nmap, jq y curl disponibles."
}

validar_cidr() {
  local cidr="$1"
  echo "[PASO 2/6] Validando formato CIDR de '$cidr'..."
  local octeto='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  local prefijo='(3[0-2]|[12]?[0-9])'
  local regex="^${octeto}\.${octeto}\.${octeto}\.${octeto}/${prefijo}$"

  if [[ ! "$cidr" =~ $regex ]]; then
    echo "[ERROR] Red CIDR no válida: '$cidr'" >&2
    echo "Formato esperado: A.B.C.D/M (ejemplo: 192.168.1.0/24)" >&2
    return 1
  fi
  echo "[DEBUG] CIDR válido: $cidr"
}

enviar_webhook() {
  local payload="$1"
  local etiqueta="$2"
  local payload_con_canal

  payload_con_canal="$(jq -c --arg canal "$CANAL" '{canal: $canal} + .' <<< "$payload")"

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Se enviaría ($etiqueta) a $WEBHOOK_URL (canal: $CANAL):"
    jq . <<< "$payload_con_canal"
    return 0
  fi

  echo "[DEBUG] Enviando POST '$etiqueta' -> $WEBHOOK_URL (canal: $CANAL)"
  echo "[DEBUG] Payload JSON: $payload_con_canal"

  local respuesta http_code cuerpo
  if ! respuesta="$(curl -sS --max-time 15 -w $'\n%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Canal: $CANAL" \
    -d "$payload_con_canal" \
    "$WEBHOOK_URL")"; then
    echo "[ERROR] Fallo de red al enviar '$etiqueta' a $WEBHOOK_URL" >&2
    return 1
  fi

  http_code="${respuesta##*$'\n'}"
  cuerpo="${respuesta%$'\n'*}"
  echo "[DEBUG] Respuesta servidor -> HTTP $http_code | Cuerpo: $cuerpo"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    if jq -e '.ok == true' >/dev/null 2>&1 <<< "$cuerpo"; then
      echo "[OK] Evento '$etiqueta' enviado al canal '$CANAL' (HTTP $http_code, ok: true)."
    elif jq -e 'has("ok") and .ok != true' >/dev/null 2>&1 <<< "$cuerpo"; then
      echo "[ERROR] El webhook respondió HTTP $http_code pero con ok!=true: $cuerpo" >&2
      return 1
    else
      echo "[OK] Evento '$etiqueta' enviado al canal '$CANAL' (HTTP $http_code)."
    fi
  else
    echo "[ERROR] El webhook devolvió HTTP $http_code al enviar '$etiqueta': $cuerpo" >&2
    return 1
  fi
}

obtener_ultimo_inventario() {
  local LC_ALL=C
  local archivos=()
  shopt -s nullglob
  archivos=("$INV_DIR"/inv_*.json)
  shopt -u nullglob

  if (( ${#archivos[@]} > 0 )); then
    printf '%s\n' "${archivos[${#archivos[@]}-1]}"
  fi
}

convertir_nmap_a_json() {
  local salida_nmap="$1"
  local ts="$2"

  jq -R -s \
    --arg escaner "$ESCANER" \
    --arg red "$RED_CIDR" \
    --arg ts "$ts" '
    split("\n")
    | map(select(test("^Host: [^ \t]+[ \t]+\\([^)]*\\)") and (contains("Status: Down") | not)))
    | map(
        (capture("^Host: (?<ip>[^ \t]+)[ \t]+\\((?<nombre>[^)]*)\\)")) as $h
        | (if test("\tPorts: ") then capture("\tPorts: (?<ports>[^\t]+)").ports else "" end) as $pstr
        | {
            ip: $h.ip,
            nombre: $h.nombre,
            puertos: (
              if $pstr == "" then []
              else
                ($pstr
                  | split(", ")
                  | map(split("/"))
                  | map(select((length >= 5) and (.[1] | startswith("open"))))
                  | map({
                      puerto: (.[0] | tonumber),
                      proto: .[2],
                      servicio: (if (.[4] // "") == "" then "desconocido" else .[4] end)
                    })
                )
              end
            )
          }
      )
    | group_by(.ip)
    | map({
        ip: .[0].ip,
        nombre: ((map(.nombre) | map(select(. != "")) | first) // ""),
        puertos: (map(.puertos) | add | unique_by([.puerto, .proto]) | sort_by(.puerto))
      })
    | sort_by(try (.ip | split(".") | map(tonumber)) catch [.ip])
    | {
        tipo: "inventario",
        escaner: $escaner,
        red: $red,
        ts: $ts,
        hosts: .
      }
  ' <<< "$salida_nmap"
}

comparar_inventarios() {
  local inv_anterior="$1"
  local inv_actual="$2"
  local ts="$3"

  jq -n \
    --slurpfile a "$inv_anterior" \
    --slurpfile b "$inv_actual" \
    --arg escaner "$ESCANER" \
    --arg ts "$ts" '
    ($a[0].hosts | map(.ip) | unique) as $v
    | ($b[0].hosts | map(.ip) | unique) as $n
    | ($a[0].hosts | map(.ip as $ip | (.puertos // []) | map({ip: $ip, puerto: .puerto})) | add // [] | unique) as $pv
    | ($b[0].hosts | map(.ip as $ip | (.puertos // []) | map({ip: $ip, puerto: .puerto})) | add // [] | unique) as $pn
    | {
        tipo: "cambios_red",
        escaner: $escaner,
        ts: $ts,
        nuevos: ($n - $v),
        desaparecidos: ($v - $n),
        puertos_abiertos: ($pn - $pv),
        puertos_cerrados: ($pv - $pn)
      }
  '
}

evaluar_no_autorizados() {
  local ips_json="$1"
  local ts="$2"

  if [[ ! -f "$AUTORIZADOS_FILE" ]]; then
    return 0
  fi

  if ! jq -e . "$AUTORIZADOS_FILE" >/dev/null 2>&1; then
    echo "[AVISO] El fichero de autorizados no es JSON válido: $AUTORIZADOS_FILE" >&2
    return 0
  fi

  local alerta_json num_no_auth
  alerta_json="$(jq -n \
    --slurpfile auth "$AUTORIZADOS_FILE" \
    --argjson candidatas "$ips_json" \
    --arg escaner "$ESCANER" \
    --arg ts "$ts" '
    (if ($auth[0] | type) == "array" then $auth[0] else ($auth[0].autorizados // []) end
     | map(if type == "object" then .ip else . end)
     | unique) as $permitidas
    | ($candidatas | unique) - $permitidas
    | {
        tipo: "alerta_no_autorizado",
        severidad: "alta",
        escaner: $escaner,
        ts: $ts,
        ips_no_autorizadas: .
      }
  ')"

  num_no_auth="$(jq '.ips_no_autorizadas | length' <<< "$alerta_json")"
  if (( num_no_auth > 0 )); then
    echo "[ALERTA][ALTA] Detectadas $num_no_auth IP(s) no autorizadas: $(jq -r '.ips_no_autorizadas | join(", ")' <<< "$alerta_json")"
    enviar_webhook "$alerta_json" "alerta_no_autorizado"
  fi
}

evaluar_puertos_riesgo() {
  local inv_actual="$1"
  local puertos_candidatos_json="$2"
  local ts="$3"

  local alerta_json num_riesgo
  alerta_json="$(jq -n \
    --slurpfile inv "$inv_actual" \
    --argjson candidatos "$puertos_candidatos_json" \
    --arg riesgo_csv "$PUERTOS_RIESGO" \
    --arg escaner "$ESCANER" \
    --arg ts "$ts" '
    ($riesgo_csv | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0) | tonumber)) as $riesgo
    | ($inv[0].hosts
        | map(.ip as $ip | (.puertos // []) | map({key: "\($ip):\(.puerto)", value: .servicio}))
        | add // []
        | from_entries) as $servicios
    | ($candidatos
        | map(select(.puerto as $p | $riesgo | index($p) != null))
        | map({
            ip: .ip,
            puerto: .puerto,
            servicio: ($servicios["\(.ip):\(.puerto)"] // "desconocido")
          })
        | unique_by([.ip, .puerto])
        | sort_by([.ip, .puerto]))
    | {
        tipo: "alerta_puertos_riesgo",
        severidad: "alta",
        escaner: $escaner,
        ts: $ts,
        puertos_riesgo: .
      }
  ')"

  num_riesgo="$(jq '.puertos_riesgo | length' <<< "$alerta_json")"
  if (( num_riesgo > 0 )); then
    echo "[ALERTA][RIESGO] Detectados $num_riesgo puerto(s) de riesgo: $(jq -r '.puertos_riesgo | map("\(.ip):\(.puerto)/\(.servicio)") | join(", ")' <<< "$alerta_json")"
    enviar_webhook "$alerta_json" "alerta_puertos_riesgo"
  fi
}

generar_informe_md() {
  local inv_actual="$1"
  local auth_arg="[]"

  if [[ -f "$AUTORIZADOS_FILE" ]] && jq -e . "$AUTORIZADOS_FILE" >/dev/null 2>&1; then
    auth_arg="$(jq '
      (if type == "array" then . else (.autorizados // []) end)
      | map(if type == "object" then .ip else . end)
      | unique
    ' "$AUTORIZADOS_FILE")"
  fi

  jq -r \
    --argjson autorizadas "$auth_arg" \
    --arg riesgo_csv "$PUERTOS_RIESGO" '
    ($riesgo_csv | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0) | tonumber)) as $riesgo
    | ([.hosts[].puertos[]] | length) as $total_puertos
    | "# Informe de Inventario de Red\n",
      "- **Escáner:** `\(.escaner)`",
      "- **Red escaneada:** `\(.red)`",
      "- **Fecha (UTC):** `\(.ts)`",
      "- **Equipos activos detectados:** \(.hosts | length)",
      "- **Total de puertos abiertos:** \($total_puertos)\n",
      "## Equipos detectados\n",
      (if (.hosts | length) == 0 then
        "_No se detectaron equipos activos en este escaneo._\n"
      else
        "| IP | Nombre | Autorizado | Puertos abiertos | Puertos de riesgo |",
        "| --- | --- | --- | --- | --- |",
        (.hosts[] |
          (.ip as $ip |
            if ($autorizadas | length) == 0 then "N/A"
            elif ($autorizadas | index($ip) != null) then "Sí"
            else "NO (severidad alta)"
            end
          ) as $estado_auth
          | (if (.puertos | length) == 0 then "-"
             else (.puertos | map("\(.puerto)/\(.proto) (\(.servicio))") | join(", "))
             end) as $lista_puertos
          | (.puertos | map(select(.puerto as $p | $riesgo | index($p) != null) | "\(.puerto) (\(.servicio))") | join(", ")) as $lista_riesgo
          | "| `\(.ip)` | \(if .nombre == "" then "-" else .nombre end) | \($estado_auth) | \($lista_puertos) | \(if $lista_riesgo == "" then "-" else $lista_riesgo end) |"
        )
      end)
  ' "$inv_actual" > "$INFORME_FILE"

  echo "[INFO] Informe Markdown generado en: $INFORME_FILE"
}

ejecutar_escaneo() {
  mkdir -p "$INV_DIR"

  local inv_anterior
  inv_anterior="$(obtener_ultimo_inventario)"

  echo "[PASO 3/6] Preparando escaneo (directorio: $INV_DIR)..."
  if [[ -n "$inv_anterior" ]]; then
    echo "[DEBUG] Inventario anterior detectado: $inv_anterior"
  else
    echo "[DEBUG] No existe inventario anterior (se creará la línea base)."
  fi

  local ts fecha_archivo inv_actual
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  fecha_archivo="$(date -u +"%Y%m%d_%H%M%S")"
  inv_actual="$INV_DIR/inv_${fecha_archivo}.json"

  # Evitar colisión si se ejecutan dos escaneos en el mismo segundo
  if [[ -e "$inv_actual" ]]; then
    local seq=1
    while [[ -e "$INV_DIR/inv_${fecha_archivo}_$(printf '%02d' "$seq").json" ]]; do
      seq=$((seq + 1))
    done
    inv_actual="$INV_DIR/inv_${fecha_archivo}_$(printf '%02d' "$seq").json"
  fi

  local salida_nmap
  if [[ -n "$DESDE_ARCHIVO" ]]; then
    if [[ ! -f "$DESDE_ARCHIVO" ]]; then
      echo "[ERROR] No existe el fichero de entrada: $DESDE_ARCHIVO" >&2
      exit 1
    fi
    echo "[INFO] Leyendo salida nmap (-oG) desde: $DESDE_ARCHIVO"
    salida_nmap="$(cat "$DESDE_ARCHIVO")"
  else
    echo "[INFO] Ejecutando: nmap -F --open -oG - $RED_CIDR"
    salida_nmap="$(nmap -F --open -oG - "$RED_CIDR")"
  fi

  local lineas_host
  lineas_host="$(grep -c '^Host: ' <<< "$salida_nmap" || true)"
  echo "[DEBUG] Escaneo finalizado. Líneas 'Host:' recibidas de nmap: $lineas_host"

  echo "[PASO 4/6] Convirtiendo salida a JSON y validando con jq -e..."
  convertir_nmap_a_json "$salida_nmap" "$ts" > "$inv_actual"

  # Validar JSON generado con jq -e
  if ! jq -e '.tipo == "inventario" and (.hosts | type == "array")' "$inv_actual" >/dev/null; then
    echo "[ERROR] El inventario generado no es un JSON válido: $inv_actual" >&2
    rm -f "$inv_actual"
    exit 1
  fi

  local total_hosts total_puertos
  total_hosts="$(jq '.hosts | length' "$inv_actual")"
  total_puertos="$(jq '[.hosts[].puertos[]] | length' "$inv_actual")"
  echo "[INFO] Inventario guardado y validado: $inv_actual ($total_hosts equipo(s), $total_puertos puerto(s) abierto(s))"

  if [[ "$GENERAR_INFORME" == true ]]; then
    echo "[PASO 5/6] Generando informe Markdown con jq -r..."
    generar_informe_md "$inv_actual"
  else
    echo "[PASO 5/6] Generación de informe omitida (--sin-informe)."
  fi

  echo "[PASO 6/6] Comparando inventarios y evaluando notificaciones al webhook..."
  # Primer escaneo (no existe inventario previo)
  if [[ -z "$inv_anterior" ]]; then
    echo "[INFO] Primer inventario guardado como línea base."
    if [[ "$ENVIAR_INICIAL" == true ]]; then
      enviar_webhook "$(cat "$inv_actual")" "inventario"
    else
      echo "[DEBUG] No se envía webhook en el primer escaneo (usa --enviar-inventario para enviarlo)."
    fi
    if [[ "$MODO_AUDITAR" == true ]]; then
      local todas_ips todos_puertos
      todas_ips="$(jq '[.hosts[].ip]' "$inv_actual")"
      todos_puertos="$(jq '[.hosts[] | .ip as $ip | (.puertos // [])[] | {ip: $ip, puerto: .puerto}]' "$inv_actual")"
      evaluar_no_autorizados "$todas_ips" "$ts"
      evaluar_puertos_riesgo "$inv_actual" "$todos_puertos" "$ts"
    fi
    return 0
  fi

  # Comparar con el inventario anterior
  echo "[DEBUG] Comparando $(basename "$inv_anterior") -> $(basename "$inv_actual")"
  local cambios_json hay_cambios
  cambios_json="$(comparar_inventarios "$inv_anterior" "$inv_actual" "$ts")"
  hay_cambios="$(jq -r '
    ((.nuevos | length) + (.desaparecidos | length) + (.puertos_abiertos | length) + (.puertos_cerrados | length)) > 0
  ' <<< "$cambios_json")"

  if [[ "$hay_cambios" == "true" ]]; then
    echo "[INFO] Cambios detectados respecto a $(basename "$inv_anterior"):"
    jq . <<< "$cambios_json"
    enviar_webhook "$cambios_json" "cambios_red"
  else
    echo "Sin cambios"
    echo "[DEBUG] No se envía webhook porque el inventario es idéntico al anterior."
  fi

  # Fase 2: evaluar autorizados.json y puertos de riesgo (completo con --auditar, o solo novedades)
  if [[ "$MODO_AUDITAR" == true ]]; then
    local todas_ips todos_puertos
    todas_ips="$(jq '[.hosts[].ip]' "$inv_actual")"
    todos_puertos="$(jq '[.hosts[] | .ip as $ip | (.puertos // [])[] | {ip: $ip, puerto: .puerto}]' "$inv_actual")"
    echo "[DEBUG] Modo --auditar activo: revisando inventario completo..."
    evaluar_no_autorizados "$todas_ips" "$ts"
    evaluar_puertos_riesgo "$inv_actual" "$todos_puertos" "$ts"
  elif [[ "$hay_cambios" == "true" ]]; then
    local nuevas_ips nuevos_puertos
    nuevas_ips="$(jq '.nuevos' <<< "$cambios_json")"
    nuevos_puertos="$(jq '.puertos_abiertos' <<< "$cambios_json")"
    echo "[DEBUG] Evaluando autorizados ($AUTORIZADOS_FILE) y puertos de riesgo ($PUERTOS_RIESGO)..."
    evaluar_no_autorizados "$nuevas_ips" "$ts"
    evaluar_puertos_riesgo "$inv_actual" "$nuevos_puertos" "$ts"
  fi
}

enviar_prueba() {
  local ts payload
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  payload="$(jq -n \
    --arg escaner "$ESCANER" \
    --arg ts "$ts" '
    {
      tipo: "prueba",
      escaner: $escaner,
      ts: $ts,
      detalle: "Mensaje de prueba de conectividad - Grupo 7"
    }
  ')"
  echo "[INFO] Enviando evento de prueba al webhook..."
  enviar_webhook "$payload" "prueba"
}

consultar_sync() {
  echo "[INFO] Consultando $SYNC_URL ..."
  local respuesta
  respuesta="$(curl -sS --max-time 15 "$SYNC_URL")"
  if jq -e . >/dev/null 2>&1 <<< "$respuesta"; then
    jq . <<< "$respuesta"
  else
    printf '%s\n' "$respuesta"
  fi
}

parsear_argumentos() {
  while (( $# > 0 )); do
    case "$1" in
      -w|--webhook)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        WEBHOOK_URL="$2"
        shift 2
        ;;
      -e|--escaner)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        ESCANER="$2"
        shift 2
        ;;
      -a|--autorizados)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        AUTORIZADOS_FILE="$2"
        shift 2
        ;;
      -d|--directorio)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        INV_DIR="$2"
        shift 2
        ;;
      -v|--vigilancia)
        MODO_VIGILANCIA=true
        if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
          INTERVALO_VIGILANCIA="$2"
          shift 2
        else
          shift
        fi
        ;;
      -i|--informe)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        GENERAR_INFORME=true
        INFORME_FILE="$2"
        shift 2
        ;;
      --sin-informe)
        GENERAR_INFORME=false
        shift
        ;;
      --enviar-inventario)
        ENVIAR_INICIAL=true
        shift
        ;;
      --auditar)
        MODO_AUDITAR=true
        shift
        ;;
      --prueba)
        MODO_PRUEBA=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --desde-archivo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        DESDE_ARCHIVO="$2"
        shift 2
        ;;
      --ver-sync)
        VER_SYNC=true
        shift
        ;;
      -h|--help)
        mostrar_uso
        exit 0
        ;;
      -*)
        echo "[ERROR] Opción desconocida: $1" >&2
        mostrar_uso >&2
        exit 1
        ;;
      *)
        if [[ -z "$RED_CIDR" ]]; then
          RED_CIDR="$1"
          shift
        else
          echo "[ERROR] Argumento inesperado: $1" >&2
          mostrar_uso >&2
          exit 1
        fi
        ;;
    esac
  done
}

main() {
  parsear_argumentos "$@"
  comprobar_dependencias

  if [[ "$VER_SYNC" == true ]]; then
    consultar_sync
    exit 0
  fi

  if [[ "$MODO_PRUEBA" == true ]]; then
    enviar_prueba
    exit 0
  fi

  if [[ -z "$RED_CIDR" ]]; then
    echo "[ERROR] Debes indicar la red en formato CIDR." >&2
    mostrar_uso >&2
    exit 1
  fi

  validar_cidr "$RED_CIDR"

  if [[ "$MODO_VIGILANCIA" == true ]]; then
    if (( INTERVALO_VIGILANCIA < 1 )); then
      echo "[ERROR] El intervalo de vigilancia debe ser mayor o igual a 1 segundo." >&2
      exit 1
    fi
    SLEEP_PID=""
    detener_vigilancia() {
      if [[ -n "$SLEEP_PID" ]]; then
        kill "$SLEEP_PID" 2>/dev/null || true
      fi
      echo ""
      echo "[INFO] Modo vigilancia detenido por el usuario."
      exit 0
    }
    trap detener_vigilancia INT TERM
    echo "[INFO] Modo vigilancia activado sobre $RED_CIDR cada ${INTERVALO_VIGILANCIA}s (Ctrl+C para salir)."
    while true; do
      ejecutar_escaneo
      echo "[INFO] Esperando ${INTERVALO_VIGILANCIA}s hasta el próximo escaneo..."
      sleep "$INTERVALO_VIGILANCIA" &
      SLEEP_PID=$!
      wait "$SLEEP_PID" || true
      SLEEP_PID=""
    done
  else
    ejecutar_escaneo
  fi
}

main "$@"
