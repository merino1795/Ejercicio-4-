#!/usr/bin/env bash
# ==============================================================================
# Script:      panel.sh
# Autores:     Grupo 7
# Descripción: Panel en tiempo real (terminal ANSI + panel web HTML opcional)
#              para el Ejercicio 4 (Inventario de red).
#              Consulta periódicamente GET /sync, filtra exclusivamente los
#              eventos del Ejercicio 4 descartando los del Ejercicio 2
#              ("monitor", "alertas" de recursos) y mensajes de prueba,
#              distingue cada red/escáner/origen por separado y muestra los
#              dispositivos detectados, sus puertos abiertos, puertos de riesgo,
#              equipos no autorizados y últimos cambios recibidos del webhook.
#
# Uso:
#   ./panel.sh [opciones]
#
# Ejemplos:
#   ./panel.sh
#   ./panel.sh --html --servir 8081
#   ./panel.sh -r 192.168.1.0/24 --once
#   ./panel.sh --once --html --desde-archivo muestra_sync.json
# ==============================================================================

set -euo pipefail
export LC_ALL=C

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
        SYNC_URL) [[ -z "${SYNC_URL:-}" ]] && SYNC_URL="$valor" ;;
      esac
    done < "$archivo"
  done
}

cargar_env_local

SYNC_URL="${SYNC_URL:-http://SERVIDOR_AULA:8087/sync}"
CANAL="${CANAL:-inventario}"
PUERTOS_RIESGO="${PUERTOS_RIESGO:-21,23,445,1433,3306,3389,5900,6379}"
HTML_FILE="${HTML_FILE:-$SCRIPT_DIR/panel_inventario.html}"

INTERVALO=10
TIMEOUT_CURL=30
SOLO_CANAL=false
FILTRO_RED=""
FILTRO_ESCANER=""
MODO_HTML=false
SERVIR_HTTP=false
PUERTO_HTTP=8081
SOLO_UNA_VEZ=false
DESDE_ARCHIVO=""
HTTP_PID=""

# Códigos ANSI (solo si la salida es terminal o forzado)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_VERDE=$'\033[32m'
  C_AMARILLO=$'\033[33m'
  C_ROJO_BOLD=$'\033[1;31m'
  C_CIAN=$'\033[36m'
  C_CIAN_BOLD=$'\033[1;36m'
  C_MAGENTA=$'\033[35m'
  C_GRIS=$'\033[90m'
else
  C_RESET=""
  C_BOLD=""
  C_VERDE=""
  C_AMARILLO=""
  C_ROJO_BOLD=""
  C_CIAN=""
  C_CIAN_BOLD=""
  C_MAGENTA=""
  C_GRIS=""
fi

mostrar_uso() {
  cat <<EOF
Uso:
  $(basename "$0") [opciones]

Opciones:
  -i, --intervalo SEGUNDOS    Intervalo de refresco en segundos (defecto: $INTERVALO)
  -s, --sync URL              URL GET del servidor /sync (defecto: $SYNC_URL)
  -t, --timeout SEGUNDOS      Timeout de descarga curl en segundos (defecto: $TIMEOUT_CURL)
  -c, --canal NOMBRE          Nombre del canal de inventario (defecto: $CANAL)
      --solo-canal            Mostrar solo mensajes que incluyan explícitamente canal="$CANAL"
                              (por defecto acepta también eventos de inventario sin campo "canal"
                               descartando siempre "monitor", "alertas" de recursos y "prueba")
  -r, --red FILTRO            Filtrar por red CIDR o subcadena (ej. 192.168.1.0/24)
  -e, --escaner FILTRO        Filtrar por nombre de escáner (ej. kali-g7)
      --html [FICHERO]        Generar panel web HTML con autorrecarga (defecto: $HTML_FILE)
      --servir [PUERTO]       Activa --html y sirve el panel web con python3 (defecto: $PUERTO_HTTP)
  -1, --once                  Ejecutar una única actualización y salir
      --desde-archivo FILE    Leer respuesta /sync desde un fichero JSON local (pruebas offline)
  -h, --help                  Mostrar esta ayuda

Variables de entorno opcionales (o .env):
  SYNC_URL, CANAL, PUERTOS_RIESGO, HTML_FILE
EOF
}

comprobar_dependencias() {
  local faltan=()
  local cmd
  for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      faltan+=("$cmd")
    fi
  done

  if [[ "$SERVIR_HTTP" == true ]] && ! command -v python3 >/dev/null 2>&1; then
    faltan+=("python3")
  fi

  if (( ${#faltan[@]} > 0 )); then
    echo "[ERROR] Faltan dependencias: ${faltan[*]}" >&2
    exit 1
  fi
}

procesar_sync_json() {
  local raw_json="$1"

  jq \
    --arg canal "$CANAL" \
    --argjson solo_canal "$(if [[ "$SOLO_CANAL" == true ]]; then echo true; else echo false; fi)" \
    --arg filtro_red "$FILTRO_RED" \
    --arg filtro_escaner "$FILTRO_ESCANER" \
    --arg riesgo_csv "$PUERTOS_RIESGO" '
    ($riesgo_csv
      | split(",")
      | map(gsub("^\\s+|\\s+$"; "") | select(length > 0) | tonumber)) as $riesgo_list

    | def es_riesgo($p):
        ($riesgo_list | index($p)) != null;

      def es_ipv4:
        type == "string" and test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$");

      def ip_a_num:
        split(".") | map(tonumber) | (((.[0] * 256 + .[1]) * 256 + .[2]) * 256 + .[3]);

      def ip_ord:
        try (split(".") | map(tonumber)) catch [999, 999, 999, 999];

      def num_a_ip:
        [
          ((. / 16777216) | floor) % 256,
          ((. / 65536) | floor) % 256,
          ((. / 256) | floor) % 256,
          (. % 256)
        ] | map(tostring) | join(".");

      def inferir_cidr($ips):
        ($ips | map(select(es_ipv4)) | unique) as $validas
        | if ($validas | length) == 0 then
            "red-desconocida"
          else
            ($validas | map(split(".") | .[0:3] | join(".")) | unique) as $s24
            | if ($s24 | length) == 1 then
                "\($s24[0]).0/24 (inferida)"
              else
                ($validas | map(ip_a_num)) as $nums
                | ($nums | min) as $mn
                | ($nums | max) as $mx
                | ($mn | num_a_ip | split(".") | map(tonumber)) as $a
                | ($mx | num_a_ip | split(".") | map(tonumber)) as $b
                | if $a[0] == $b[0] and $a[1] == $b[1] then
                    # Calcular máscara mínima dentro del /16
                    ([range(0; 8) | select((($a[2] / pow(2; 7 - .)) | floor) != (($b[2] / pow(2; 7 - .)) | floor))] | first // 8) as $diff_bit
                    | (16 + $diff_bit) as $pref
                    | (pow(2; 8 - $diff_bit)) as $bloque
                    | (($a[2] / $bloque | floor) * $bloque) as $oct3
                    | "\($a[0]).\($a[1]).\($oct3).0/\($pref) (inferida)"
                  elif $a[0] == $b[0] then
                    "\($a[0]).0.0.0/8 (inferida)"
                  else
                    "múltiples subredes (\($s24 | length))"
                  end
              end
          end;

      def normalizar_msg:
        (if has("datos") and (.datos | type == "object") then .datos else . end) as $d
        | {
            _id: (._id // 0),
            _recibido: (._recibido // ""),
            _origen: (._origen // "origen-desconocido"),
            canal: (.canal // $d.canal // ""),
            tipo: (.tipo // $d.tipo // ""),
            datos: $d
          };

      def es_evento_ej4:
        # Descartar explícitamente Ejercicio 2 (monitor / alertas de recursos) y mensajes de prueba
        (.canal != "monitor")
        and (.canal != "alertas")
        and (.tipo != "alerta_recurso")
        and (.tipo != "prueba")
        and (.tipo | IN(
              "inventario",
              "cambios_red",
              "alerta_no_autorizado",
              "alerta_puertos_riesgo",
              "dispositivo_no_autorizado",
              "puertos_de_riesgo_activos"
            ))
        and (if $solo_canal then (.canal == $canal) else (.canal == $canal or .canal == "") end);

      def extraer_ips_msg:
        [
          (.datos.hosts // [] | .[]?.ip),
          (.datos.nuevos // [] | .[]?),
          (.datos.desaparecidos // [] | .[]?),
          (.datos.puertos_abiertos // [] | .[]?.ip),
          (.datos.puertos_cerrados // [] | .[]?.ip),
          (.datos.ips_no_autorizadas // [] | .[]?),
          (.datos.dispositivos_no_autorizados // [] | .[]?),
          (.datos.puertos_riesgo // [] | .[]? | if type == "object" then .ip else empty end),
          (.datos.dispositivos // [] | .[]?.ip),
          (.datos.alertas_no_autorizadas // [] | .[]?.dispositivos_no_autorizados // [] | .[]?),
          (.datos.alertas_riesgo // [] | .[]?.dispositivos // [] | .[]?.ip)
        ] | map(select(es_ipv4)) | unique;

      (if type == "object" and has("messages") then .messages
       elif type == "array" then .
       else [] end) as $todos
      | ($todos | map(normalizar_msg)) as $norm
      | ($norm | map(select(es_evento_ej4))) as $ev_ej4
      | ($norm | length) as $total_msgs
      | ($ev_ej4 | length) as $total_ej4
      | ($total_msgs - $total_ej4) as $total_descartados

      # Mapa auxiliar (escaner|origen -> última red explícita reportada en inventario)
      | ($ev_ej4
          | map(select((.datos.red // "") != ""))
          | sort_by([(.datos.ts // ._recibido), ._id])
          | map({key: "\(.datos.escaner // "desconocido")|\(._origen)", value: .datos.red})
          | from_entries) as $red_por_escaner

      # Enriquecer cada evento con su clave de red/escáner/origen
      | ($ev_ej4
          | map(
              (.datos.escaner // "desconocido") as $esc
              | (._origen // "desconocido") as $orig
              | ("\($esc)|\($orig)") as $esc_key
              | (if (.datos.red // "") != "" then .datos.red
                 elif ($red_por_escaner[$esc_key] // "") != "" then $red_por_escaner[$esc_key]
                 else "" end) as $red_resuelta
              | . + {
                  escaner: $esc,
                  origen: $orig,
                  red_explicita: (.datos.red // ""),
                  grupo_key: "\($esc)|\($orig)|\($red_resuelta)"
                }
            )
          | group_by(.grupo_key)
          | map(
              sort_by([(.datos.ts // ._recibido), ._id]) as $eventos
              | ($eventos | last) as $ult
              | ($eventos | map(extraer_ips_msg) | add // [] | unique) as $todas_ips
              | (
                  ($eventos | map(select(.red_explicita != "") | .red_explicita) | last)
                  // ($red_por_escaner["\($ult.escaner)|\($ult.origen)"] // "")
                  | if . == "" then inferir_cidr($todas_ips) else . end
                ) as $red_nombre

              # Reconstruir estado actual de dispositivos y puertos reproduciendo el historial
              | (reduce $eventos[] as $ev (
                  {
                    hosts: {},
                    tiene_inventario: false,
                    ultimo_inventario_ts: "",
                    ultimo_cambio: null,
                    alertas_no_auth: [],
                    alertas_riesgo: [],
                    desaparecidos_recientes: []
                  };
                  ($ev.datos.ts // $ev._recibido // "") as $ets
                  | if $ev.tipo == "inventario" then
                      .tiene_inventario = true
                      | .ultimo_inventario_ts = $ets
                      | .hosts = (
                          ($ev.datos.hosts // [])
                          | map(
                              . as $h
                              | {
                                  key: $h.ip,
                                  value: {
                                    ip: $h.ip,
                                    nombre: (if ($h.nombre // "") == "sin_nombre" then "" else ($h.nombre // "") end),
                                    mac: ($h.mac // ""),
                                    estado: "ACTIVO",
                                    no_autorizado: false,
                                    puertos: (
                                      ($h.puertos // [])
                                      | map({
                                          key: "\(.puerto)/\(.proto // "tcp")",
                                          value: {
                                            puerto: (.puerto | tonumber),
                                            proto: (.proto // "tcp"),
                                            servicio: (if (.servicio // "") == "" then "desconocido" else .servicio end),
                                            riesgo: es_riesgo(.puerto | tonumber)
                                          }
                                        })
                                      | from_entries
                                    ),
                                    ultimo_ts: $ets
                                  }
                                }
                            )
                          | from_entries
                        )
                      | .desaparecidos_recientes = []

                    elif $ev.tipo == "cambios_red" then
                      . as $st
                      | ($ev.datos.nuevos // []) as $nuevos
                      | ($ev.datos.desaparecidos // []) as $desap
                      | ($ev.datos.puertos_abiertos // []) as $pab
                      | ($ev.datos.puertos_cerrados // []) as $pcerr
                      | ($ev.datos.alertas_no_autorizadas // [] | map(.dispositivos_no_autorizados // []) | add // [] | unique) as $emb_noauth
                      | ($ev.datos.alertas_riesgo // [] | map(.dispositivos // []) | add // []) as $emb_riesgo

                      # 1) Añadir nuevos hosts
                      | (reduce $nuevos[] as $ip ($st;
                          .hosts[$ip] = ((.hosts[$ip] // {ip: $ip, nombre: "", mac: "", puertos: {}, no_autorizado: false})
                            + {estado: "NUEVO", ultimo_ts: $ets})
                        ))
                      # 2) Quitar desaparecidos de activos y registrarlos
                      | (reduce $desap[] as $ip (.;
                          del(.hosts[$ip])
                        ))
                      # 3) Aplicar puertos abiertos
                      | (reduce $pab[] as $p (.;
                          ($p.ip) as $ip
                          | ($p.puerto | tonumber) as $num
                          | ("\($num)/\($p.proto // "tcp")") as $pk
                          | .hosts[$ip] = ((.hosts[$ip] // {ip: $ip, nombre: "", mac: "", estado: "ACTIVO", no_autorizado: false, puertos: {}})
                              | .ultimo_ts = $ets
                              | .puertos[$pk] = (.puertos[$pk] // {
                                  puerto: $num,
                                  proto: ($p.proto // "tcp"),
                                  servicio: ($p.servicio // "desconocido"),
                                  riesgo: es_riesgo($num)
                                }))
                        ))
                      # 4) Aplicar puertos cerrados
                      | (reduce $pcerr[] as $p (.;
                          ($p.ip) as $ip
                          | ($p.puerto | tonumber) as $num
                          | if .hosts[$ip] != null then
                              .hosts[$ip].puertos |= with_entries(select(.value.puerto != $num))
                            else . end
                        ))
                      # 5) Procesar alertas embebidas (formato alternativo del grupo)
                      | (if ($emb_noauth | length) > 0 then
                          (reduce $emb_noauth[] as $ip (.;
                            .hosts[$ip] = ((.hosts[$ip] // {ip: $ip, nombre: "", mac: "", estado: "ACTIVO", puertos: {}})
                              + {no_autorizado: true, ultimo_ts: $ets})
                          ))
                          | .alertas_no_auth = $emb_noauth
                        else . end)
                      | (if ($emb_riesgo | length) > 0 then
                          (reduce $emb_riesgo[] as $r (.;
                            ($r.ip) as $ip
                            | ($r.puerto | tonumber) as $num
                            | ("\($num)/tcp") as $pk
                            | .hosts[$ip] = ((.hosts[$ip] // {ip: $ip, nombre: "", mac: "", estado: "ACTIVO", no_autorizado: false, puertos: {}})
                                | .ultimo_ts = $ets
                                | .puertos[$pk] = ((.puertos[$pk] // {puerto: $num, proto: "tcp", servicio: "desconocido"}) + {riesgo: true}))
                          ))
                          | .alertas_riesgo = ($emb_riesgo | map({ip: .ip, puerto: (.puerto | tonumber), servicio: (.servicio // "desconocido")}) | unique_by([.ip, .puerto]))
                        else . end)
                      # 6) Guardar resumen del último cambio real
                      | if (($nuevos | length) + ($desap | length) + ($pab | length) + ($pcerr | length)) > 0 then
                          .ultimo_cambio = {
                            ts: $ets,
                            nuevos: $nuevos,
                            desaparecidos: $desap,
                            puertos_abiertos: $pab,
                            puertos_cerrados: $pcerr
                          }
                          | .desaparecidos_recientes = $desap
                        else . end

                    elif ($ev.tipo == "alerta_no_autorizado" or $ev.tipo == "dispositivo_no_autorizado") then
                      ($ev.datos.ips_no_autorizadas // $ev.datos.dispositivos_no_autorizados // []) as $ips
                      | (reduce $ips[] as $ip (.;
                          if .hosts[$ip] != null then
                            .hosts[$ip].no_autorizado = true
                          else
                            .hosts[$ip] = {ip: $ip, nombre: "", mac: "", estado: "ALERTA", no_autorizado: true, puertos: {}, ultimo_ts: $ets}
                          end
                        ))
                      | .alertas_no_auth = ((.alertas_no_auth + $ips) | unique)

                    elif ($ev.tipo == "alerta_puertos_riesgo" or $ev.tipo == "puertos_de_riesgo_activos") then
                      ($ev.datos.puertos_riesgo // $ev.datos.dispositivos // []
                        | map(select(type == "object" and has("ip") and has("puerto")))) as $items
                      | (reduce $items[] as $r (.;
                          ($r.ip) as $ip
                          | ($r.puerto | tonumber) as $num
                          | ("\($num)/tcp") as $pk
                          | .hosts[$ip] = ((.hosts[$ip] // {ip: $ip, nombre: "", mac: "", estado: "ALERTA", no_autorizado: false, puertos: {}})
                              | .ultimo_ts = $ets
                              | .puertos[$pk] = {
                                  puerto: $num,
                                  proto: ($r.proto // "tcp"),
                                  servicio: (if ($r.servicio // "") == "" then "desconocido" else $r.servicio end),
                                  riesgo: true
                                })
                        ))
                      | .alertas_riesgo = ((.alertas_riesgo + ($items | map({ip: .ip, puerto: (.puerto | tonumber), servicio: (.servicio // "desconocido")}))) | unique_by([.ip, .puerto]))
                    else . end
                )) as $final

              | ($final.hosts
                  | to_entries
                  | map(.value | .puertos = (.puertos | to_entries | map(.value) | sort_by(.puerto)))
                  | sort_by(.ip | ip_ord)) as $hosts_arr

              | ($hosts_arr | map(.puertos | length) | add // 0) as $total_puertos
              | ($hosts_arr | map(.puertos | map(select(.riesgo)) | length) | add // 0) as $total_riesgo
              | ($hosts_arr | map(select(.no_autorizado)) | length) as $total_noauth

              | {
                  red: $red_nombre,
                  escaner: $ult.escaner,
                  origen: $ult.origen,
                  fuente: (if $final.tiene_inventario then "inventario" else "cambios/alertas" end),
                  eventos_count: ($eventos | length),
                  ultimo_ts: ($ult.datos.ts // $ult._recibido // "-"),
                  ultimo_inventario_ts: $final.ultimo_inventario_ts,
                  total_hosts: ($hosts_arr | length),
                  total_puertos: $total_puertos,
                  total_puertos_riesgo: $total_riesgo,
                  total_no_autorizados: $total_noauth,
                  hosts: $hosts_arr,
                  desaparecidos_recientes: $final.desaparecidos_recientes,
                  ultimo_cambio: $final.ultimo_cambio,
                  alertas_no_auth: $final.alertas_no_auth,
                  alertas_riesgo: $final.alertas_riesgo
                }
            )
          | map(select(
              ($filtro_red == "" or (.red | ascii_downcase | contains($filtro_red | ascii_downcase)))
              and ($filtro_escaner == "" or (.escaner | ascii_downcase | contains($filtro_escaner | ascii_downcase)))
            ))
          | sort_by([.ultimo_ts, .red, .escaner])
          | reverse
        ) as $redes

      | {
          stats: {
            total_mensajes_webhook: $total_msgs,
            mensajes_inventario: $total_ej4,
            mensajes_descartados: $total_descartados,
            total_redes: ($redes | length),
            total_hosts: ($redes | map(.total_hosts) | add // 0),
            total_puertos: ($redes | map(.total_puertos) | add // 0),
            total_puertos_riesgo: ($redes | map(.total_puertos_riesgo) | add // 0),
            total_no_autorizados: ($redes | map(.total_no_autorizados) | add // 0)
          },
          redes: $redes
        }
  ' <<< "$raw_json"
}

dibujar_panel_terminal() {
  local data_json="$1"
  local hora_actual="$2"

  local total_msgs ej4_msgs desc_msgs total_redes total_hosts total_puertos total_riesgo total_noauth
  IFS=$'\t' read -r total_msgs ej4_msgs desc_msgs total_redes total_hosts total_puertos total_riesgo total_noauth < <(
    jq -r '[.stats.total_mensajes_webhook, .stats.mensajes_inventario, .stats.mensajes_descartados, .stats.total_redes, .stats.total_hosts, .stats.total_puertos, .stats.total_puertos_riesgo, .stats.total_no_autorizados] | @tsv' <<< "$data_json"
  )

  if [[ -t 1 ]]; then
    if command -v tput >/dev/null 2>&1; then
      tput clear 2>/dev/null || clear 2>/dev/null || true
      tput cup 0 0 2>/dev/null || true
    else
      clear 2>/dev/null || true
    fi
  fi

  printf '%s======================================================================================================================%s\n' "$C_CIAN" "$C_RESET"
  printf '%s PANEL DE INVENTARIO DE RED — EJERCICIO 4 (canal: %s)%s  |  Actualizado: %s UTC\n' \
    "$C_BOLD" "$CANAL" "$C_RESET" "$hora_actual"
  printf ' Webhook: %s%s eventos Ej.4%s (%s%s descartados de otros proyectos%s / %s total) | Redes: %s%s%s | Equipos: %s%s%s | Puertos: %s%s%s | Riesgo: %s%s%s | No auth: %s%s%s\n' \
    "$C_VERDE" "$ej4_msgs" "$C_RESET" \
    "$C_GRIS" "$desc_msgs" "$C_RESET" "$total_msgs" \
    "$C_CIAN_BOLD" "$total_redes" "$C_RESET" \
    "$C_BOLD" "$total_hosts" "$C_RESET" \
    "$C_BOLD" "$total_puertos" "$C_RESET" \
    "$(if (( total_riesgo > 0 )); then printf '%s' "$C_ROJO_BOLD"; else printf '%s' "$C_VERDE"; fi)" "$total_riesgo" "$C_RESET" \
    "$(if (( total_noauth > 0 )); then printf '%s' "$C_AMARILLO"; else printf '%s' "$C_VERDE"; fi)" "$total_noauth" "$C_RESET"
  printf '%s======================================================================================================================%s\n' "$C_CIAN" "$C_RESET"

  if (( total_redes == 0 )); then
    printf '\n  %sNo hay eventos de inventario que mostrar (comprueba %s o filtros aplicados).%s\n\n' "$C_GRIS" "$SYNC_URL" "$C_RESET"
    return 0
  fi

  local idx=0
  local red_json
  while IFS= read -r red_json; do
    [[ -z "$red_json" ]] && continue
    idx=$((idx + 1))

    local red escaner origen fuente ev_cnt ult_ts n_hosts n_puertos n_riesgo n_noauth
    IFS=$'\t' read -r red escaner origen fuente ev_cnt ult_ts n_hosts n_puertos n_riesgo n_noauth < <(
      jq -r '[.red, .escaner, .origen, .fuente, .eventos_count, .ultimo_ts, .total_hosts, .total_puertos, .total_puertos_riesgo, .total_no_autorizados] | @tsv' <<< "$red_json"
    )

    printf '\n%s┌─ [%d] RED: %s%s  %s|%s  ESCÁNER: %s%s%s  %s|%s  ORIGEN: %s%s%s  %s|%s  Fuente: %s (%s ev.)  %s|%s  Último: %s\n' \
      "$C_CIAN_BOLD" "$idx" "$red" "$C_RESET" \
      "$C_GRIS" "$C_RESET" "$C_MAGENTA" "$escaner" "$C_RESET" \
      "$C_GRIS" "$C_RESET" "$C_BOLD" "$origen" "$C_RESET" \
      "$C_GRIS" "$C_RESET" "$fuente" "$ev_cnt" \
      "$C_GRIS" "$C_RESET" "$ult_ts"
    printf '%s│%s  Equipos: %s%s%s · Puertos abiertos: %s%s%s · Puertos de riesgo: %s%s%s · No autorizados: %s%s%s\n' \
      "$C_CIAN" "$C_RESET" \
      "$C_BOLD" "$n_hosts" "$C_RESET" \
      "$C_BOLD" "$n_puertos" "$C_RESET" \
      "$(if (( n_riesgo > 0 )); then printf '%s' "$C_ROJO_BOLD"; else printf '%s' "$C_VERDE"; fi)" "$n_riesgo" "$C_RESET" \
      "$(if (( n_noauth > 0 )); then printf '%s' "$C_AMARILLO"; else printf '%s' "$C_VERDE"; fi)" "$n_noauth" "$C_RESET"

    if (( n_hosts == 0 )); then
      printf '%s│%s  %s(Sin dispositivos activos en los datos recibidos para esta red)%s\n' "$C_CIAN" "$C_RESET" "$C_GRIS" "$C_RESET"
    else
      printf '%s│%s  %s%-16s %-16s %-18s %-14s %s%s\n' \
        "$C_CIAN" "$C_RESET" "$C_BOLD" "IP" "NOMBRE" "MAC" "ESTADO" "PUERTOS ABIERTOS" "$C_RESET"
      printf '%s│%s  %s----------------------------------------------------------------------------------------------------------------%s\n' \
        "$C_CIAN" "$C_RESET" "$C_GRIS" "$C_RESET"

      local ip nombre mac estado no_auth puertos_txt tiene_riesgo
      while IFS=$'\t' read -r ip nombre mac estado no_auth tiene_riesgo puertos_txt; do
        local est_color est_lbl
        if [[ "$no_auth" == "true" ]]; then
          est_color="$C_ROJO_BOLD"
          est_lbl="NO AUTORIZADO "
        elif [[ "$estado" == "NUEVO" ]]; then
          est_color="$C_AMARILLO"
          est_lbl="NUEVO         "
        else
          est_color="$C_VERDE"
          est_lbl="ACTIVO        "
        fi

        local p_color="$C_RESET"
        if [[ "$tiene_riesgo" == "true" ]]; then
          p_color="$C_ROJO_BOLD"
        fi

        printf '%s│%s  %-16s %-16s %-18s %s%s%s %s%s%s\n' \
          "$C_CIAN" "$C_RESET" \
          "${ip:0:16}" \
          "${nombre:0:16}" \
          "${mac:0:18}" \
          "$est_color" "$est_lbl" "$C_RESET" \
          "$p_color" "$puertos_txt" "$C_RESET"
      done < <(jq -r '
        .hosts[]
        | [
            .ip,
            (if (.nombre // "") == "" then "-" else .nombre end),
            (if (.mac // "") == "" then "-" else .mac end),
            .estado,
            (.no_autorizado | tostring),
            (([.puertos[] | select(.riesgo)] | length > 0) | tostring),
            (if (.puertos | length) == 0 then "(sin puertos reportados)"
             else (.puertos | map(
               (if .riesgo then "[!] " else "" end) + "\(.puerto)/\(.proto) (\(.servicio))"
             ) | join(", "))
             end)
          ]
        | @tsv
      ' <<< "$red_json")
    fi

    # Mostrar último cambio si existe
    local resumen_cambio
    resumen_cambio="$(jq -r '
      if .ultimo_cambio == null then ""
      else
        .ultimo_cambio as $c
        | [
            (if ($c.nuevos | length) > 0 then "+Nuevos: " + ($c.nuevos | join(", ")) else empty end),
            (if ($c.desaparecidos | length) > 0 then "-Desaparecidos: " + ($c.desaparecidos | join(", ")) else empty end),
            (if ($c.puertos_abiertos | length) > 0 then "+Puertos: " + ($c.puertos_abiertos | map("\(.ip):\(.puerto)") | join(", ")) else empty end),
            (if ($c.puertos_cerrados | length) > 0 then "-Puertos: " + ($c.puertos_cerrados | map("\(.ip):\(.puerto)") | join(", ")) else empty end)
          ] | join("  |  ")
          | if . != "" then "(\($c.ts)) " + . else "" end
      end
    ' <<< "$red_json")"

    if [[ -n "$resumen_cambio" ]]; then
      printf '%s│%s  %sÚltimo cambio:%s %s\n' "$C_CIAN" "$C_RESET" "$C_AMARILLO" "$C_RESET" "$resumen_cambio"
    fi

    printf '%s└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────%s\n' "$C_CIAN" "$C_RESET"
  done < <(jq -c '.redes[]' <<< "$data_json")

  if [[ "$MODO_HTML" == true ]]; then
    printf '\n Panel web actualizado: %s' "$HTML_FILE"
    if [[ "$SERVIR_HTTP" == true ]]; then
      printf '  (http://0.0.0.0:%s/)' "$PUERTO_HTTP"
    fi
    printf '\n'
  fi
}

generar_panel_html() {
  local data_json="$1"
  local hora_actual="$2"

  local kpi_redes kpi_hosts kpi_puertos kpi_riesgo kpi_noauth kpi_ej4 kpi_desc kpi_total
  IFS=$'\t' read -r kpi_total kpi_ej4 kpi_desc kpi_redes kpi_hosts kpi_puertos kpi_riesgo kpi_noauth < <(
    jq -r '[.stats.total_mensajes_webhook, .stats.mensajes_inventario, .stats.mensajes_descartados, .stats.total_redes, .stats.total_hosts, .stats.total_puertos, .stats.total_puertos_riesgo, .stats.total_no_autorizados] | @tsv' <<< "$data_json"
  )

  local filtros_html secciones_html
  filtros_html="$(jq -r '
    .redes | to_entries | map(
      "<button class=\"net-tab\" data-target=\"net-" + (.key | tostring) + "\">" +
        "<span class=\"dot\"></span>" +
        (.value.red | @html) +
        " <small>(" + (.value.escaner | @html) + " · " + (.value.total_hosts | tostring) + ")</small>" +
      "</button>"
    ) | join("")
  ' <<< "$data_json")"

  secciones_html="$(jq -r '
    if (.redes | length) == 0 then
      "<div class=\"empty-box\">No se han recibido todavía eventos de inventario en el webhook. Ejecuta <code>./inventario.sh 192.168.1.0/24 --enviar-inventario</code>.</div>"
    else
      .redes | to_entries | map(
        .key as $idx
        | .value as $r
        | (if ($r.hosts | length) == 0 then
             "<tr><td colspan=\"5\" class=\"empty-row\">Sin dispositivos activos en los mensajes recibidos para esta red.</td></tr>"
           else
             ($r.hosts | map(
               . as $h
               | (if $h.no_autorizado then "<span class=\"badge badge-crit\">NO AUTORIZADO</span>"
                  elif $h.estado == "NUEVO" then "<span class=\"badge badge-warn\">NUEVO</span>"
                  else "<span class=\"badge badge-ok\">ACTIVO</span>" end) as $est_badge
               | (if ($h.puertos | length) == 0 then
                    "<span class=\"muted-txt\">Sin puertos reportados</span>"
                  else
                    ($h.puertos | map(
                      "<span class=\"port-pill " + (if .riesgo then "port-risk" else "port-ok" end) + "\">" +
                        (if .riesgo then "⚠ " else "" end) +
                        (.puerto | tostring | @html) + "/" + (.proto | @html) +
                        " <em>" + (.servicio | @html) + "</em>" +
                      "</span>"
                    ) | join(""))
                  end) as $ports_html
               | "<tr class=\"host-row\" data-search=\"" + (($h.ip + " " + ($h.nombre // "") + " " + ($h.mac // "") + " " + ($h.puertos | map("\(.puerto) \(.servicio)") | join(" "))) | ascii_downcase | @html) + "\">" +
                   "<td><code class=\"ip-code\">" + ($h.ip | @html) + "</code></td>" +
                   "<td>" + (if ($h.nombre // "") == "" then "<span class=\"muted-txt\">—</span>" else ($h.nombre | @html) end) + "</td>" +
                   "<td>" + (if ($h.mac // "") == "" then "<span class=\"muted-txt\">—</span>" else ("<code class=\"mac-code\">" + ($h.mac | @html) + "</code>") end) + "</td>" +
                   "<td>" + $est_badge + "</td>" +
                   "<td class=\"ports-cell\">" + $ports_html + "</td>" +
                 "</tr>"
             ) | join(""))
           end) as $rows_html
        | (if $r.ultimo_cambio == null then ""
           else
             $r.ultimo_cambio as $c
             | ([
                 (if ($c.nuevos | length) > 0 then "<span class=\"chg chg-add\">+ Nuevos: " + ($c.nuevos | join(", ") | @html) + "</span>" else empty end),
                 (if ($c.desaparecidos | length) > 0 then "<span class=\"chg chg-del\">− Desaparecidos: " + ($c.desaparecidos | join(", ") | @html) + "</span>" else empty end),
                 (if ($c.puertos_abiertos | length) > 0 then "<span class=\"chg chg-add\">+ Puertos abiertos: " + ($c.puertos_abiertos | map("\(.ip):\(.puerto)") | join(", ") | @html) + "</span>" else empty end),
                 (if ($c.puertos_cerrados | length) > 0 then "<span class=\"chg chg-del\">− Puertos cerrados: " + ($c.puertos_cerrados | map("\(.ip):\(.puerto)") | join(", ") | @html) + "</span>" else empty end)
               ] | join("")) as $chg_items
             | if $chg_items != "" then
                 "<div class=\"changes-bar\"><strong>Último cambio (" + ($c.ts | @html) + "):</strong> " + $chg_items + "</div>"
               else "" end
           end) as $changes_html
        | "<section class=\"net-card\" id=\"net-" + ($idx | tostring) + "\">" +
            "<header class=\"net-head\">" +
              "<div class=\"net-title-wrap\">" +
                "<div class=\"net-badges\">" +
                  "<span class=\"pill pill-net\">RED " + ($r.red | @html) + "</span>" +
                  "<span class=\"pill pill-scan\">ESCÁNER " + ($r.escaner | @html) + "</span>" +
                  "<span class=\"pill pill-orig\">ORIGEN " + ($r.origen | @html) + "</span>" +
                  "<span class=\"pill pill-src\">Fuente: " + ($r.fuente | @html) + " (" + ($r.eventos_count | tostring) + " ev.)</span>" +
                "</div>" +
                "<div class=\"net-sub\">Último evento: <code>" + ($r.ultimo_ts | @html) + "</code></div>" +
              "</div>" +
              "<div class=\"net-metrics\">" +
                "<div class=\"mini-kpi\"><span>Equipos</span><strong>" + ($r.total_hosts | tostring) + "</strong></div>" +
                "<div class=\"mini-kpi\"><span>Puertos</span><strong>" + ($r.total_puertos | tostring) + "</strong></div>" +
                "<div class=\"mini-kpi " + (if $r.total_puertos_riesgo > 0 then "kpi-danger" else "" end) + "\"><span>Riesgo</span><strong>" + ($r.total_puertos_riesgo | tostring) + "</strong></div>" +
                "<div class=\"mini-kpi " + (if $r.total_no_autorizados > 0 then "kpi-warn" else "" end) + "\"><span>No auth</span><strong>" + ($r.total_no_autorizados | tostring) + "</strong></div>" +
              "</div>" +
            "</header>" +
            $changes_html +
            "<div class=\"table-wrap\">" +
              "<table>" +
                "<thead><tr><th>IP</th><th>Nombre</th><th>MAC</th><th>Estado</th><th>Puertos abiertos</th></tr></thead>" +
                "<tbody>" + $rows_html + "</tbody>" +
              "</table>" +
            "</div>" +
          "</section>"
      ) | join("")
    end
  ' <<< "$data_json")"

  local tmp_html="${HTML_FILE}.tmp"
  cat <<EOF > "$tmp_html"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="${INTERVALO}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Panel de Inventario de Red — Ejercicio 4 · Grupo 7</title>
  <style>
    :root {
      --bg: #050816;
      --surface: rgba(15, 23, 42, 0.80);
      --surface-2: rgba(30, 41, 59, 0.55);
      --border: rgba(148, 163, 184, 0.18);
      --text: #e2e8f0;
      --muted: #94a3b8;
      --cyan: #38bdf8;
      --violet: #a78bfa;
      --ok: #22c55e;
      --warn: #eab308;
      --crit: #ef4444;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Inter", system-ui, -apple-system, "Segoe UI", sans-serif;
      color: var(--text);
      background:
        radial-gradient(ellipse 80% 45% at 50% -10%, rgba(56, 189, 248, 0.20), transparent 65%),
        radial-gradient(ellipse 60% 40% at 85% 95%, rgba(139, 92, 246, 0.14), transparent 60%),
        var(--bg);
    }
    .container { max-width: 1380px; margin: 0 auto; padding: 26px 22px 48px; }
    .topbar { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 16px; margin-bottom: 22px; }
    h1 {
      margin: 0;
      font-size: clamp(1.45rem, 2.4vw, 2.05rem);
      font-weight: 800;
      letter-spacing: -0.02em;
      background: linear-gradient(95deg, #f8fafc 0%, #38bdf8 55%, #a78bfa 100%);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
    }
    .meta { margin-top: 6px; font-size: 0.86rem; color: var(--muted); display: flex; flex-wrap: wrap; gap: 12px; }
    .filter-pill {
      display: inline-flex; align-items: center; gap: 6px;
      background: rgba(56, 189, 248, 0.10); border: 1px solid rgba(56, 189, 248, 0.30);
      padding: 4px 10px; border-radius: 999px; font-size: 0.8rem; color: #bae6fd;
    }
    .kpis {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
      gap: 14px; margin-bottom: 22px;
    }
    .kpi {
      background: var(--surface); border: 1px solid var(--border);
      border-radius: 14px; padding: 14px 16px; backdrop-filter: blur(10px);
    }
    .kpi span { display: block; font-size: 0.76rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
    .kpi strong { display: block; margin-top: 4px; font-size: 1.65rem; font-weight: 800; }
    .kpi.crit strong { color: #fca5a5; }
    .kpi.warn strong { color: #fde047; }
    .kpi.cyan strong { color: var(--cyan); }
    .controls {
      display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between;
      margin-bottom: 18px;
    }
    .tabs { display: flex; flex-wrap: wrap; gap: 8px; }
    .net-tab {
      background: var(--surface); color: var(--text); border: 1px solid var(--border);
      padding: 7px 12px; border-radius: 999px; font-size: 0.82rem; cursor: pointer;
      display: inline-flex; align-items: center; gap: 7px; transition: 0.15s ease;
    }
    .net-tab:hover, .net-tab.active {
      border-color: var(--cyan); background: rgba(56, 189, 248, 0.16); color: #f8fafc;
    }
    .net-tab .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--cyan); }
    .net-tab small { color: var(--muted); }
    .search-box {
      background: var(--surface); border: 1px solid var(--border); color: var(--text);
      padding: 8px 13px; border-radius: 10px; font-size: 0.85rem; min-width: 240px; outline: none;
    }
    .search-box:focus { border-color: var(--cyan); }
    .net-card {
      background: var(--surface); border: 1px solid var(--border); border-radius: 16px;
      margin-bottom: 20px; overflow: hidden; backdrop-filter: blur(12px);
      box-shadow: 0 12px 32px rgba(0, 0, 0, 0.35);
    }
    .net-head {
      padding: 16px 20px; background: rgba(15, 23, 42, 0.9);
      border-bottom: 1px solid var(--border);
      display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 14px;
    }
    .net-badges { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
    .pill { padding: 4px 10px; border-radius: 999px; font-size: 0.78rem; font-weight: 700; letter-spacing: 0.02em; }
    .pill-net { background: rgba(56, 189, 248, 0.18); color: #7dd3fc; border: 1px solid rgba(56, 189, 248, 0.45); }
    .pill-scan { background: rgba(167, 139, 250, 0.18); color: #ddd6fe; border: 1px solid rgba(167, 139, 250, 0.40); }
    .pill-orig { background: rgba(148, 163, 184, 0.14); color: #cbd5e1; border: 1px solid rgba(148, 163, 184, 0.25); }
    .pill-src { background: rgba(34, 197, 94, 0.12); color: #86efac; border: 1px solid rgba(34, 197, 94, 0.30); font-weight: 600; }
    .net-sub { margin-top: 6px; font-size: 0.8rem; color: var(--muted); }
    .net-metrics { display: flex; gap: 10px; flex-wrap: wrap; }
    .mini-kpi {
      background: var(--surface-2); border: 1px solid var(--border);
      border-radius: 10px; padding: 6px 12px; min-width: 72px; text-align: center;
    }
    .mini-kpi span { display: block; font-size: 0.68rem; color: var(--muted); text-transform: uppercase; }
    .mini-kpi strong { font-size: 1.05rem; }
    .mini-kpi.kpi-danger { border-color: rgba(239, 68, 68, 0.5); background: rgba(239, 68, 68, 0.12); }
    .mini-kpi.kpi-danger strong { color: #fca5a5; }
    .mini-kpi.kpi-warn { border-color: rgba(234, 179, 8, 0.5); background: rgba(234, 179, 8, 0.12); }
    .mini-kpi.kpi-warn strong { color: #fde047; }
    .changes-bar {
      padding: 10px 20px; background: rgba(234, 179, 8, 0.08);
      border-bottom: 1px solid var(--border); font-size: 0.82rem;
      display: flex; flex-wrap: wrap; gap: 10px; align-items: center;
    }
    .chg { padding: 2px 8px; border-radius: 6px; font-family: ui-monospace, monospace; font-size: 0.78rem; }
    .chg-add { background: rgba(34, 197, 94, 0.16); color: #86efac; }
    .chg-del { background: rgba(239, 68, 68, 0.16); color: #fca5a5; }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 0.88rem; }
    th {
      text-align: left; padding: 11px 16px; font-size: 0.74rem; text-transform: uppercase;
      letter-spacing: 0.06em; color: var(--muted); background: rgba(15, 23, 42, 0.55);
      border-bottom: 1px solid var(--border);
    }
    td { padding: 11px 16px; border-bottom: 1px solid rgba(148, 163, 184, 0.10); vertical-align: middle; }
    tr:last-child td { border-bottom: none; }
    tr:hover td { background: rgba(56, 189, 248, 0.04); }
    .ip-code { font-weight: 700; color: #f8fafc; font-size: 0.9rem; }
    .mac-code { color: #cbd5e1; font-size: 0.82rem; }
    .muted-txt { color: var(--muted); font-size: 0.82rem; }
    .badge { display: inline-block; padding: 3px 9px; border-radius: 999px; font-size: 0.72rem; font-weight: 700; }
    .badge-ok { background: rgba(34, 197, 94, 0.18); color: #86efac; border: 1px solid rgba(34, 197, 94, 0.35); }
    .badge-warn { background: rgba(234, 179, 8, 0.18); color: #fde047; border: 1px solid rgba(234, 179, 8, 0.40); }
    .badge-crit { background: rgba(239, 68, 68, 0.20); color: #fca5a5; border: 1px solid rgba(239, 68, 68, 0.45); }
    .ports-cell { display: flex; flex-wrap: wrap; gap: 6px; }
    .port-pill {
      display: inline-flex; align-items: center; gap: 4px;
      padding: 3px 8px; border-radius: 7px; font-size: 0.78rem; font-family: ui-monospace, monospace;
    }
    .port-pill em { font-style: normal; opacity: 0.82; font-family: inherit; }
    .port-ok { background: rgba(56, 189, 248, 0.12); color: #bae6fd; border: 1px solid rgba(56, 189, 248, 0.28); }
    .port-risk { background: rgba(239, 68, 68, 0.20); color: #fecaca; border: 1px solid rgba(239, 68, 68, 0.55); font-weight: 700; }
    .empty-box, .empty-row { text-align: center; padding: 28px; color: var(--muted); }
    .hidden { display: none !important; }
  </style>
</head>
<body>
  <div class="container">
    <header class="topbar">
      <div>
        <h1>Panel de Inventario de Red — Ejercicio 4</h1>
        <div class="meta">
          <span>Actualizado: <strong>${hora_actual} UTC</strong> (refresco cada ${INTERVALO}s)</span>
          <span>Origen: <code>${SYNC_URL}</code></span>
        </div>
      </div>
      <div class="filter-pill">
        Filtro webhook activo: <strong>${kpi_ej4}</strong> eventos Ej.4 · <strong>${kpi_desc}</strong> descartados (Ej.2 / pruebas) de ${kpi_total} totales
      </div>
    </header>

    <section class="kpis">
      <div class="kpi cyan"><span>Redes / Escáneres</span><strong>${kpi_redes}</strong></div>
      <div class="kpi"><span>Dispositivos activos</span><strong>${kpi_hosts}</strong></div>
      <div class="kpi"><span>Puertos abiertos</span><strong>${kpi_puertos}</strong></div>
      <div class="kpi crit"><span>Puertos de riesgo</span><strong>${kpi_riesgo}</strong></div>
      <div class="kpi warn"><span>No autorizados</span><strong>${kpi_noauth}</strong></div>
    </section>

    <div class="controls">
      <div class="tabs">
        <button class="net-tab active" data-target="all"><span class="dot"></span>Todas las redes (${kpi_redes})</button>
        ${filtros_html}
      </div>
      <input id="searchInput" class="search-box" type="search" placeholder="Filtrar por IP, puerto o servicio...">
    </div>

    <main>
      ${secciones_html}
    </main>
  </div>

  <script>
    (function () {
      const tabs = document.querySelectorAll('.net-tab');
      const cards = document.querySelectorAll('.net-card');
      const search = document.getElementById('searchInput');

      tabs.forEach(tab => {
        tab.addEventListener('click', () => {
          tabs.forEach(t => t.classList.remove('active'));
          tab.classList.add('active');
          const target = tab.dataset.target;
          cards.forEach(c => {
            c.classList.toggle('hidden', target !== 'all' && c.id !== target);
          });
        });
      });

      if (search) {
        search.addEventListener('input', () => {
          const q = search.value.trim().toLowerCase();
          document.querySelectorAll('.host-row').forEach(row => {
            const hay = (row.dataset.search || '').includes(q);
            row.classList.toggle('hidden', q !== '' && !hay);
          });
        });
      }
    })();
  </script>
</body>
</html>
EOF

  mv "$tmp_html" "$HTML_FILE"
}

ejecutar_ciclo() {
  local raw_json hora_actual data_json
  hora_actual="$(date -u +"%H:%M:%S")"

  if [[ -n "$DESDE_ARCHIVO" ]]; then
    if [[ ! -f "$DESDE_ARCHIVO" ]]; then
      echo "[ERROR] No existe el fichero: $DESDE_ARCHIVO" >&2
      return 1
    fi
    raw_json="$(cat "$DESDE_ARCHIVO")"
  else
    if ! raw_json="$(curl -sS --compressed --max-time "$TIMEOUT_CURL" "$SYNC_URL")"; then
      echo "[ERROR] No se pudo consultar $SYNC_URL (timeout=${TIMEOUT_CURL}s)" >&2
      return 1
    fi
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "$raw_json"; then
    echo "[ERROR] La respuesta de $SYNC_URL no es JSON válido." >&2
    return 1
  fi

  data_json="$(procesar_sync_json "$raw_json")"
  dibujar_panel_terminal "$data_json" "$hora_actual"

  if [[ "$MODO_HTML" == true ]]; then
    generar_panel_html "$data_json" "$hora_actual"
  fi
}

limpiar_al_salir() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  printf '\n[INFO] Panel de inventario detenido.\n'
  exit 0
}

parsear_argumentos() {
  while (( $# > 0 )); do
    case "$1" in
      -i|--intervalo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        INTERVALO="$2"
        shift 2
        ;;
      -s|--sync)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        SYNC_URL="$2"
        shift 2
        ;;
      -t|--timeout)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        TIMEOUT_CURL="$2"
        shift 2
        ;;
      -c|--canal)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        CANAL="$2"
        shift 2
        ;;
      --solo-canal)
        SOLO_CANAL=true
        shift
        ;;
      -r|--red)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        FILTRO_RED="$2"
        shift 2
        ;;
      -e|--escaner)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        FILTRO_ESCANER="$2"
        shift 2
        ;;
      --html)
        MODO_HTML=true
        if [[ $# -ge 2 && "$2" != -* ]]; then
          HTML_FILE="$2"
          shift 2
        else
          shift
        fi
        ;;
      --servir)
        MODO_HTML=true
        SERVIR_HTTP=true
        if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
          PUERTO_HTTP="$2"
          shift 2
        else
          shift
        fi
        ;;
      -1|--once)
        SOLO_UNA_VEZ=true
        shift
        ;;
      --desde-archivo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        DESDE_ARCHIVO="$2"
        shift 2
        ;;
      -h|--help)
        mostrar_uso
        exit 0
        ;;
      *)
        echo "[ERROR] Opción desconocida: $1" >&2
        mostrar_uso >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parsear_argumentos "$@"
  comprobar_dependencias

  if ! [[ "$INTERVALO" =~ ^[0-9]+$ ]] || (( INTERVALO < 1 )); then
    echo "[ERROR] El intervalo debe ser un entero >= 1." >&2
    exit 1
  fi
  if ! [[ "$TIMEOUT_CURL" =~ ^[0-9]+$ ]] || (( TIMEOUT_CURL < 1 )); then
    echo "[ERROR] El timeout debe ser un entero >= 1." >&2
    exit 1
  fi

  if [[ "$SOLO_UNA_VEZ" == true ]]; then
    ejecutar_ciclo
    exit 0
  fi

  trap limpiar_al_salir INT TERM

  if [[ "$SERVIR_HTTP" == true ]]; then
    local html_dir html_base
    html_dir="$(dirname "$HTML_FILE")"
    html_base="$(basename "$HTML_FILE")"
    mkdir -p "$html_dir"
    # Crear index.html enlazado si el fichero HTML tiene otro nombre
    if [[ "$html_base" != "index.html" && ! -e "$html_dir/index.html" ]]; then
      ln -sf "$html_base" "$html_dir/index.html"
    fi
    python3 -m http.server "$PUERTO_HTTP" --directory "$html_dir" >/dev/null 2>&1 &
    HTTP_PID=$!
    echo "[INFO] Servidor web iniciado en http://0.0.0.0:${PUERTO_HTTP}/${html_base} (PID $HTTP_PID)"
  fi

  while true; do
    ejecutar_ciclo || true
    sleep "$INTERVALO"
  done
}

main "$@"
