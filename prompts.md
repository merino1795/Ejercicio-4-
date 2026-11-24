# Registro de prompts y correcciones (`prompts.md`)

**Grupo:** Grupo 7  
**Ejercicio:** Ejercicio 4 — Inventario de red y detección de cambios (`inventario.sh`)

---

## Prompt 1 — Formato `-oG` de `nmap` y conversión a JSON

**Prompt usado:**
> Explícame el formato `-oG` de `nmap` y cómo extraer la IP, el nombre de host y la lista de puertos abiertos de cada línea `Host:` para generar un JSON con el esquema `{tipo, escaner, red, ts, hosts: [{ip, nombre, puertos: [{puerto, proto, servicio}]}]}`.

**Qué generó inicialmente y qué se corrigió:**
1. **Duplicación de hosts:** La primera versión procesaba cada línea `Host:` de forma independiente. Como `nmap -oG` imprime normalmente dos líneas por equipo (`Status: Up` y `Ports: ...`), cada IP aparecía duplicada en el array `hosts`.
   - *Corrección:* Agrupar los registros por IP con `group_by(.ip)` en `jq`, combinar los puertos con `unique_by([.puerto, .proto])` y conservar el primer nombre de host no vacío.
2. **Columnas extra tras `Ports:`:** `nmap` añade a veces `\tIgnored State: closed (...)` al final de la línea `Ports:`.
   - *Corrección:* Limitar la captura de puertos hasta el siguiente tabulador (`\tPorts: (?<ports>[^\t]+)`) para no corromper el último servicio.
3. **Servicios vacíos y tipo numérico del puerto:** Algunos puertos aparecen sin nombre de servicio (`//`).
   - *Corrección:* Convertir el puerto explícitamente a entero con `tonumber` y usar `"desconocido"` como valor por defecto si el campo de servicio viene vacío.
4. **Equipos activos sin puertos abiertos descartados por `capture` en `jq`:** Usar `try (capture("\tPorts: (?<ports>[^\t]+)").ports) catch ""` hacía que, cuando una línea `Host: ... Status: Up` no contenía `Ports:`, `capture` devolviera `empty` (en lugar de lanzar un error), eliminando silenciosamente del array a los equipos activos sin puertos abiertos.
   - *Corrección:* Comprobar primero con `if test("\tPorts: ") then capture(...).ports else "" end` para conservar todos los equipos `Up` aunque tengan `puertos: []`.
5. **Líneas `Status: Down` y orden de IPs:** Se añadió `contains("Status: Down") | not` para evitar falsos positivos y `sort_by(try (.ip | split(".") | map(tonumber)) catch [.ip])` para ordenar las IPs numéricamente (`.1`, `.129`, `.141`, `.143`) en lugar de lexicográficamente.

---

## Prompt 2 — Comparación de inventarios y diferencias de puertos con `jq`

**Prompt usado:**
> ¿Cómo comparo dos ficheros JSON de inventario con `jq` para sacar equipos nuevos, desaparecidos, puertos abiertos y puertos cerrados, devolviendo exactamente el contrato `cambios_red`?

**Qué generó inicialmente y qué se corrigió:**
1. **Fallos cuando un inventario no tiene hosts (`hosts: []`):** En `jq`, `map(...) | add` devuelve `null` sobre un array vacío, lo que hacía fallar la resta de arrays (`$pn - $pv`).
   - *Corrección:* Añadir el fallback `| add // [] | unique` al aplanar los pares `{ip, puerto}`.
2. **Envío innecesario cuando no hay cambios:** La condición inicial solo comprobaba `nuevos` y `desaparecidos`, ignorando si se había abierto o cerrado un puerto en un host ya existente.
   - *Corrección:* Evaluar la suma de longitudes de las 4 listas (`nuevos`, `desaparecidos`, `puertos_abiertos`, `puertos_cerrados`). Solo si es mayor que `0` se envía el webhook; en caso contrario se imprime `Sin cambios`.

---

## Prompt 3 — Validación de CIDR y endurecimiento del script Bash

**Prompt usado:**
> Dame una expresión regular en Bash para validar redes CIDR IPv4 y revisa el script para que pase `shellcheck` sin avisos y gestione bien errores de `curl` y `jq`.

**Qué generó inicialmente y qué se corrigió:**
1. **Regex CIDR demasiado permisiva:** La primera propuesta usaba `[0-9]{1,3}`, lo que aceptaba IPs inválidas como `999.300.1.1/99`.
   - *Corrección:* Sustituir por rangos exactos de octeto (`25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]`) y prefijo (`3[0-2]|[12]?[0-9]`).
2. **Obtención del inventario anterior con `ls`:** `ls -1 inventarios/inv_*.json | tail -n 1` genera advertencia `SC2012` en `shellcheck` y falla con `set -euo pipefail` cuando la carpeta está vacía.
   - *Corrección:* Usar un array con `shopt -s nullglob` (`archivos=("$INV_DIR"/inv_*.json)`), que es seguro y ya queda ordenado cronológicamente por el formato `AAAAMMDD_HHMMSS`. Se añadió también protección de colisión (`_$$.json`) si se lanzan dos escaneos en el mismo segundo.
3. **Comprobación de códigos HTTP en `curl`:** Usar solo `curl -s -X POST` no detectaba errores HTTP `4xx`/`5xx`.
   - *Corrección:* Capturar `%{http_code}` con `curl -sS --max-time 15 -w $'\n%{http_code}'` y comprobar explícitamente el rango `2xx`.

---

## Prompt 4 — Ampliaciones de Fase 2 (`autorizados.json`, puertos de riesgo, vigilancia e `informe.md`)

**Prompt usado:**
> Añade al script: comprobación contra `autorizados.json` con `"severidad": "alta"`, detección de puertos de riesgo (`21, 23, 445, 3389, 5900...`), modo vigilancia cada 2 minutos y generación de `informe.md` con `jq -r`.

**Qué generó inicialmente y qué se corrigió:**
1. **Spam de alertas en escaneos sin cambios:** Inicialmente, las alertas de `autorizados.json` y puertos de riesgo se disparaban en cada ejecución incluso si la red no había cambiado, rompiendo el requisito de que dos escaneos consecutivos sin cambios no envíen nada.
   - *Corrección:* En el flujo normal solo se notifican por webhook IPs no autorizadas que aparezcan en `nuevos` y puertos de riesgo que aparezcan en `puertos_abiertos`. Se añadió además la opción `--auditar` para forzar la notificación del estado completo cuando se desee auditar bajo demanda.
2. **Salida limpia en modo vigilancia:** Se añadió `trap ... INT TERM` para terminar el bucle `while true; do ... sleep ...; done` de forma limpia al pulsar `Ctrl+C`.
3. **Flexibilidad en `autorizados.json`:** Se ajustó el filtro de `jq` para aceptar tanto una lista de objetos `{"autorizados": [{"ip": "..."}]}` como un array simple de strings `["192.168.1.1"]`.

---

## Prompt 5 — Integración con el servidor del aula, depuración y pruebas reales

**Prompt usado:**
> Adapta `inventario.sh` al servidor del profesor (POST con respuesta `{"ok": true}` y GET `/sync`), añade un modo `--prueba` para verificar el webhook, `--desde-archivo` para probar sin escanear y mensajes paso a paso para poder depurar y explicar el flujo en la demo.

**Qué generó inicialmente y qué se corrigió:**
1. **Validación incompleta de la respuesta del webhook:** Si el servidor devolvía HTTP `200` con `{"ok": false}`, el script lo daba por bueno.
   - *Corrección:* Comprobar explícitamente con `jq -e '.ok == true'` y rechazar `has("ok") and .ok != true`, enviando además el campo `"canal"` en el JSON y la cabecera `X-Canal`.
2. **Falta de visibilidad durante escaneos reales y pruebas:** En la red del laboratorio (`192.168.1.0/24`) costaba saber en qué fase estaba el script y si había enviado o no el payload.
   - *Corrección:* Añadir trazas claras `[PASO 1/6]`–`[PASO 6/6]` y `[DEBUG]`, junto a los modos `--prueba`, `--dry-run`, `--desde-archivo` y `--ver-sync`. Con pruebas reales sobre `192.168.1.0/24` se validó la detección en directo del puerto `8000` (`python3 -m http.server 8000`) y la clasificación de equipos autorizados (`192.168.1.1`, `192.168.1.143`) frente a no autorizados en `informe.md`.
3. **Pruebas integrales de Fase 2 (orden de ficheros, `--auditar` y `trap` en vigilancia):** Al validar todos los casos de Fase 2 con escaneos rápidos y señales se detectaron tres fallos sutiles:
   - *Ordenación por locale:* En locales UTF-8, `inv_..._60.json` podía ordenarse antes que `inv_....json` al compararse dentro del mismo segundo. Se fijó `local LC_ALL=C` en `obtener_ultimo_inventario` y sufijos secuenciales `_01`, `_02`…
   - *Modo `--auditar` con cambios simultáneos:* Antes solo auditaba el inventario completo cuando no había cambios. Se unificó la lógica para que `--auditar` revise siempre todo el inventario sin duplicar alertas.
   - *Respuesta inmediata a `SIGTERM` durante `sleep`:* En modo vigilancia (`-v 120`), Bash esperaba a que terminara `sleep` antes de ejecutar el `trap`. Se cambió a `sleep "$INTERVALO_VIGILANCIA" & SLEEP_PID=$!; wait "$SLEEP_PID"` con cierre de `$SLEEP_PID` en `detener_vigilancia`.
