#!/usr/bin/env bash
# Pruebas sin red: nmap se simula y no se envía nada a ningún webhook.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$RAIZ/inventario.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok=0
fallos=0

afirmar() {
  local descripcion=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok     $descripcion"
    ok=$((ok + 1))
  else
    echo "  FALLO  $descripcion"
    fallos=$((fallos + 1))
  fi
}
no() { ! "$@"; }

echo "Validación CIDR"
afirmar "acepta 192.168.1.0/24" validar_cidr 192.168.1.0/24
afirmar "rechaza sin máscara" no validar_cidr 192.168.1.0
afirmar "rechaza octeto 300" no validar_cidr 300.1.1.1/24
afirmar "rechaza máscara /33" no validar_cidr 10.0.0.0/33
afirmar "rechaza texto" no validar_cidr a.b.c.d/24

echo "Parseo de nmap -oG"
# shellcheck disable=SC2329
nmap() {
  printf '# Nmap scan\nHost: 192.168.1.1 (router)\tStatus: Up\n'
  printf 'Host: 192.168.1.1 (router)\tPorts: 80/open/tcp//http///, 443/open/tcp//https///\tIgnored State: closed (98)\n'
  printf 'Host: 192.168.1.40 ()\tStatus: Up\n# done\n'
}
escanear 192.168.1.0/24 "$TMP/a.json"
afirmar "detecta 2 equipos" jq -e '.hosts | length == 2' "$TMP/a.json"
afirmar "router con 2 puertos" jq -e '.hosts[] | select(.ip == "192.168.1.1") | .puertos | length == 2' "$TMP/a.json"
afirmar "equipo sin puertos se conserva" jq -e '.hosts[] | select(.ip == "192.168.1.40") | .puertos == []' "$TMP/a.json"

echo "Comparación de inventarios"
# shellcheck disable=SC2329
nmap() {
  printf 'Host: 192.168.1.1 (router)\tPorts: 80/open/tcp//http///\n'
  printf 'Host: 192.168.1.57 ()\tPorts: 3389/open/tcp//ms-wbt-server///, 8000/open/tcp//http-alt///\n'
}
escanear 192.168.1.0/24 "$TMP/b.json"
echo '["192.168.1.1","192.168.1.40"]' > "$TMP/aut.json"
# shellcheck disable=SC2034
AUTORIZADOS="$TMP/aut.json"
cambios=$(comparar "$TMP/a.json" "$TMP/b.json")
afirmar "equipo nuevo" jq -e '.nuevos == ["192.168.1.57"]' <<< "$cambios"
afirmar "equipo desaparecido" jq -e '.desaparecidos == ["192.168.1.40"]' <<< "$cambios"
afirmar "puerto cerrado en equipo conocido" jq -e '.puertos_cerrados == [{"ip":"192.168.1.1","puerto":443}]' <<< "$cambios"
afirmar "puertos de riesgo en equipo nuevo" jq -e '.puertos_riesgo == [{"ip":"192.168.1.57","puerto":3389}]' <<< "$cambios"
afirmar "IP no autorizada detectada" jq -e '.no_autorizados == ["192.168.1.57"]' <<< "$cambios"
afirmar "severidad alta" jq -e '.severidad == "alta"' <<< "$cambios"
afirmar "hay_cambios es verdadero" hay_cambios "$cambios"

sin_cambios=$(comparar "$TMP/a.json" "$TMP/a.json")
afirmar "mismo inventario: sin cambios" no hay_cambios "$sin_cambios"

echo
echo "Resultado: $ok correctas, $fallos fallidas"
[[ $fallos -eq 0 ]]
