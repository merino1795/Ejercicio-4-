#!/usr/bin/env bash
# inventario.sh - Inventario de red y detección de cambios
# Uso: sudo ./inventario.sh <red CIDR> [--vigilar]
set -euo pipefail

# Configuración local opcional (.env, nunca versionado)
DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$DIR_SCRIPT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIR_SCRIPT/.env"
  set +a
fi

WEBHOOK_URL="${WEBHOOK_URL:-}"   # definir en .env (ver .env.example)
ESCANER="${ESCANER:-$(hostname)}"
DIR="inventarios"
AUTORIZADOS="autorizados.json"      # array JSON de IPs: ["192.168.56.1", ...]
PUERTOS_RIESGO='[23,445,3389,5900]'
INTERVALO="${INTERVALO:-120}"      # segundos en modo vigilancia

uso() { echo "Uso: $0 <red CIDR> [--vigilar]" >&2; exit 1; }

# 1. Validación CIDR: formato + octetos <= 255
validar_cidr() {
  local re='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'
  [[ $1 =~ $re ]] || return 1
  local ip=${1%/*} o
  local -a oct
  IFS=. read -ra oct <<< "$ip"
  for o in "${oct[@]}"; do (( 10#$o <= 255 )) || return 1; done
}

# 2-3. Escaneo -> JSON -> validación con jq -e
escanear() {
  local red=$1 salida=$2
  nmap -F --open -oG - "$red" \
  | awk -F'\t' '/^Host:/ {
      split($1, a, " "); ip=a[2]; nom=a[3]; gsub(/[()]/, "", nom);
      puertos="";
      for (i=2; i<=NF; i++) if ($i ~ /^Ports:/) puertos=substr($i, 8);
      print ip "\t" nom "\t" puertos
    }' \
  | jq -R -s --arg escaner "$ESCANER" --arg red "$red" --arg ts "$(date -u +%FT%TZ)" '
      split("\n")
      | map(select(length > 0) | split("\t"))
      | map({
          ip: .[0],
          nombre: (.[1] // ""),
          puertos: ((.[2] // "") | split(", ") | map(select(length > 0) | split("/")
                    | {puerto: (.[0] | tonumber), proto: .[2], servicio: .[4]}))
        })
      | group_by(.ip)
      | map({ip: .[0].ip, nombre: .[0].nombre, puertos: (map(.puertos) | add // [])})
      | {tipo: "inventario", escaner: $escaner, red: $red, ts: $ts, hosts: .}' > "$salida"
  jq -e '.tipo == "inventario" and (.hosts | type == "array")' "$salida" >/dev/null
}

# 4. Comparación: equipos nuevos/desaparecidos, puertos, autorizados y riesgo
comparar() {
  local viejo=$1 nuevo=$2 autz='[]'
  [[ -f $AUTORIZADOS ]] && autz=$(cat "$AUTORIZADOS")
  jq -n --slurpfile a "$viejo" --slurpfile b "$nuevo" \
        --argjson autz "$autz" --argjson riesgo "$PUERTOS_RIESGO" \
        --arg ts "$(date -u +%FT%TZ)" '
    def mapa: map({key: .ip, value: (.puertos | map(.puerto))}) | from_entries;
    ($a[0].hosts | mapa) as $ma
    | ($b[0].hosts | mapa) as $mb
    | ($a[0].hosts | map(.ip)) as $v
    | ($b[0].hosts | map(.ip)) as $n
    | ($n - ($n - $v)) as $comunes
    | {
        tipo: "cambios_red",
        escaner: $b[0].escaner,
        ts: $ts,
        nuevos: ($n - $v),
        desaparecidos: ($v - $n),
        puertos_abiertos: [ $comunes[] as $ip | (($mb[$ip]) - ($ma[$ip]))[] | {ip: $ip, puerto: .} ],
        puertos_cerrados: [ $comunes[] as $ip | (($ma[$ip]) - ($mb[$ip]))[] | {ip: $ip, puerto: .} ],
        puertos_riesgo:   [ $n[] as $ip | (($mb[$ip]) - ($ma[$ip] // []))[]
                            | select(IN($riesgo[])) | {ip: $ip, puerto: .} ],
        no_autorizados:   (if ($autz | length) == 0 then [] else ($n - $autz) end)
      }
    | . + {severidad: (if (.no_autorizados | length) > 0 then "alta"
                       elif (.puertos_riesgo | length) > 0 then "media"
                       else "baja" end)}'
}

hay_cambios() {
  jq -e '(.nuevos + .desaparecidos + .puertos_abiertos + .puertos_cerrados
          + .puertos_riesgo + .no_autorizados) | length > 0' <<< "$1" >/dev/null
}

enviar() {
  if [[ -z $WEBHOOK_URL ]]; then
    echo "[i] WEBHOOK_URL no definida: modo local, no se envía nada"
    return 0
  fi
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "$1" "$WEBHOOK_URL" >/dev/null
}

# Informe legible a partir del último inventario
generar_informe() {
  jq -r '"# Inventario de red \(.red)\n\nEscáner: \(.escaner) · \(.ts)\n\n| IP | Nombre | Puertos |\n|---|---|---|",
    (.hosts[] | "| \(.ip) | \(.nombre) | \(.puertos | map("\(.puerto)/\(.servicio)") | join(", ")) |")' "$1" > informe.md
}

ciclo() {
  mkdir -p "$DIR"
  local previo nuevo cambios
  previo=$(find "$DIR" -maxdepth 1 -name 'inv_*.json' 2>/dev/null | sort | tail -n1 || true)
  nuevo="$DIR/inv_$(date +%Y%m%d_%H%M%S).json"

  escanear "$RED" "$nuevo"
  echo "[+] $(date +%T) Inventario guardado: $nuevo ($(jq '.hosts | length' "$nuevo") equipos)"
  generar_informe "$nuevo"

  if [[ -z $previo ]]; then
    echo "[i] Primer escaneo: línea base creada."
    return
  fi

  cambios=$(comparar "$previo" "$nuevo")
  if hay_cambios "$cambios"; then
    echo "[!] Cambios detectados (severidad: $(jq -r .severidad <<< "$cambios"))"
    jq . <<< "$cambios"
    jq -c . <<< "$cambios" >> cambios.log
    enviar "$cambios" || echo "[x] Error enviando al webhook" >&2
  else
    echo "Sin cambios"
  fi
}

# --- Main ---
main() {
  RED=${1:-}
  local modo=${2:-}
  [[ -n $RED ]] || uso
  validar_cidr "$RED" || { echo "Red no válida: $RED (ej. 192.168.56.0/24)" >&2; exit 1; }
  local cmd
  for cmd in nmap jq curl awk; do
    command -v "$cmd" >/dev/null || { echo "Falta $cmd" >&2; exit 1; }
  done

  if [[ $modo == "--vigilar" ]]; then
    echo "[*] Modo vigilancia sobre $RED cada ${INTERVALO}s (Ctrl+C para salir)"
    trap 'echo; echo "Vigilancia detenida."; exit 0' INT TERM
    while true; do ciclo; sleep "$INTERVALO"; done
  else
    ciclo
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
