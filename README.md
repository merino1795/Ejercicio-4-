# Ejercicio 4: Inventario de red y detección de cambios (`inventario.sh`)

**Grupo:** Grupo 7  
**Canal:** `inventario`  
**Escáner por defecto:** `kali-g7`

> **Aviso legal:** Escanead únicamente la red del laboratorio indicada por el profesor. Escanear redes ajenas sin autorización es ilegal.

---

## 1. Estructura del proyecto

```text
inventario-red/
├── inventario.sh       # Script principal de escaneo, comparación, alertas e informe
├── autorizados.json    # Lista de IPs permitidas en la red del laboratorio
├── informe.md          # Informe legible en Markdown generado automáticamente con jq -r
├── inventarios/        # Histórico de inventarios JSON (inv_AAAAMMDD_HHMMSS.json)
├── README.md           # Documentación de uso, contratos JSON y guion de demo
└── prompts.md          # Registro de prompts usados con Claude y correcciones aplicadas
```

---

## 2. Requisitos previos

Herramientas necesarias en Kali Linux: `bash`, `curl`, `jq`, `shellcheck` y `nmap`.

```bash
sudo apt update && sudo apt install -y jq shellcheck curl nmap
```

Dar permisos de ejecución y comprobar buenas prácticas con `shellcheck`:

```bash
chmod +x inventario.sh
shellcheck inventario.sh
```

---

## 3. Configuración de endpoints

Los endpoints se cargan automáticamente desde `.env` (copia `.env.example` a `.env`), mediante variables de entorno (`WEBHOOK_URL`, `SYNC_URL`) o con `-w`:

- **Enviar (POST con JSON):** `WEBHOOK_URL` (ejemplo: `http://SERVIDOR_AULA:9007/webhook/TU_TOKEN` → responde `{ "ok": true, ... }`)
- **Recuperar (GET):** `SYNC_URL` (ejemplo: `http://SERVIDOR_AULA:8087/sync`)

Al enviar al webhook, el script añade automáticamente `"canal": "inventario"` al JSON y la cabecera `X-Canal: inventario`, validando tanto el código HTTP `2xx` como el campo `"ok": true` de la respuesta.

---

## 4. Instrucciones de ejecución

### Escaneo básico (Fase 1)
```bash
./inventario.sh 192.168.1.0/24
```
El script ejecuta y muestra trazas paso a paso (`[PASO 1/6]` a `[PASO 6/6]`):
1. Comprueba dependencias (`nmap`, `jq`, `curl`).
2. Valida el parámetro CIDR (octetos `0–255` y prefijo `0–32`).
3. Localiza el último inventario en `inventarios/` y ejecuta `nmap -F --open -oG - <red>`.
4. Convierte la salida a JSON, valida la estructura con `jq -e` y guarda `inventarios/inv_AAAAMMDD_HHMMSS.json`.
5. Genera el informe legible `informe.md` con `jq -r`.
6. Compara contra el inventario anterior:
   - Si hay cambios, envía el JSON `cambios_red` al webhook y evalúa `autorizados.json` y puertos de riesgo.
   - Si no hay cambios, muestra `Sin cambios` y **no envía nada**.

### Opciones disponibles

| Opción | Descripción | Valor por defecto |
| --- | --- | --- |
| `-w, --webhook URL` | Cambia la URL destino del webhook (`POST`). | Endpoint Grupo 7 |
| `-e, --escaner NOMBRE` | Cambia el campo `"escaner"` del JSON. | `kali-g7` |
| `-a, --autorizados FICHERO` | Fichero JSON de IPs permitidas. Cualquier IP nueva fuera de lista genera una alerta con `"severidad": "alta"`. | `./autorizados.json` |
| `-d, --directorio DIR` | Carpeta donde guardar los ficheros `inv_*.json`. | `./inventarios` |
| `-v, --vigilancia [SEG]` | Repite el escaneo cada `SEG` segundos y solo envía cuando hay cambios (cierre limpio con `Ctrl+C`). | `120` s |
| `-i, --informe FICHERO` | Ruta del informe legible en Markdown generado con `jq -r`. | `./informe.md` |
| `--sin-informe` | Omite la generación de `informe.md`. | Informe activo |
| `--enviar-inventario` | Envía también el JSON `inventario` completo en el primer escaneo (línea base). | Desactivado |
| `--auditar` | Envía alertas de IPs no autorizadas y puertos de riesgo presentes en el inventario actual aunque ya existieran antes. | Desactivado |
| `--prueba` | Envía un evento JSON `tipo: "prueba"` al webhook para comprobar conectividad. | — |
| `--dry-run` | Muestra por pantalla los JSON que se enviarían sin realizar peticiones `POST`. | Desactivado |
| `--desde-archivo FICHERO` | Lee una salida `nmap -oG` desde un fichero local (pruebas/depuración sin escanear). | — |
| `--ver-sync` | Consulta con `GET` los eventos recibidos en `SYNC_URL` (`/sync`). | — |
| `-h, --help` | Muestra la ayuda completa del script. | — |

**Variables de entorno soportadas:** `WEBHOOK_URL`, `SYNC_URL`, `ESCANER`, `CANAL`, `INV_DIR`, `AUTORIZADOS_FILE`, `INFORME_FILE`, `PUERTOS_RIESGO`.

### Ejemplos de uso

```bash
# 0. Verificar conectividad con el webhook antes de escanear
./inventario.sh --prueba

# 1. Primer escaneo (línea base) enviando también el inventario inicial
./inventario.sh 192.168.1.0/24 --enviar-inventario

# 2. Segundo escaneo sin cambios (muestra "Sin cambios" y no envía nada)
./inventario.sh 192.168.1.0/24

# 3. Modo vigilancia cada 2 minutos (120s)
./inventario.sh 192.168.1.0/24 -v 120

# 4. Modo vigilancia rápido para la demo (cada 15 segundos)
./inventario.sh 192.168.1.0/24 -v 15

# 5. Auditar el inventario actual completo en modo prueba (sin POST)
./inventario.sh 192.168.1.0/24 --auditar --dry-run

# 6. Verificar los eventos recibidos en el servidor del profesor (GET)
./inventario.sh --ver-sync
```

---

## 5. Ampliaciones implementadas (Fase 2)

1. **Puertos abiertos y cerrados por equipo:** Se calculan diferencias de pares `{ip, puerto}` entre escaneos consecutivos y se envían en `puertos_abiertos` y `puertos_cerrados`.
2. **Control de equipos autorizados (`autorizados.json`):** Cualquier IP nueva no incluida en [autorizados.json](./autorizados.json) genera automáticamente un evento `alerta_no_autorizado` con `"severidad": "alta"`. Admite tanto una lista de objetos `{"autorizados": [{"ip": "..."}]}` como un array simple de IPs.
3. **Puertos de riesgo:** Se vigilan por defecto los puertos `21, 23, 445, 1433, 3306, 3389, 5900, 6379` (configurable con `PUERTOS_RIESGO`). Si se abre alguno de ellos —incluso en un equipo autorizado— se envía `alerta_puertos_riesgo` con `"severidad": "alta"`.
4. **Modo vigilancia (`-v`):** Bucle periódico con cierre limpio mediante `trap ... INT TERM` al pulsar `Ctrl+C`.
5. **Informe legible (`informe.md`):** Generado automáticamente a partir del último inventario mediante `jq -r`, indicando estado de autorización y puertos de riesgo por equipo.

---

## 6. Configuración y ejemplos de JSON

### 6.1 Lista de equipos autorizados (`autorizados.json`)
```json
{
  "descripcion": "Equipos autorizados en la red del laboratorio - Grupo 7",
  "autorizados": [
    { "ip": "192.168.1.1", "nombre": "gateway-lab" },
    { "ip": "192.168.1.143", "nombre": "kali-g7" }
  ]
}
```

### 6.2 Inventario guardado (`inventarios/inv_AAAAMMDD_HHMMSS.json`)
> Nota: El fichero local sigue exactamente el contrato siguiente; si se envía con `--enviar-inventario`, `enviar_webhook` añade automáticamente `"canal": "inventario"` al payload HTTP.

```json
{
  "tipo": "inventario",
  "escaner": "kali-g7",
  "red": "192.168.1.0/24",
  "ts": "2026-11-23T19:31:46Z",
  "hosts": [
    {
      "ip": "192.168.1.1",
      "nombre": "",
      "puertos": [
        { "puerto": 53, "proto": "tcp", "servicio": "domain" },
        { "puerto": 80, "proto": "tcp", "servicio": "http" },
        { "puerto": 443, "proto": "tcp", "servicio": "https" }
      ]
    },
    {
      "ip": "192.168.1.143",
      "nombre": "",
      "puertos": [
        { "puerto": 8000, "proto": "tcp", "servicio": "http-alt" }
      ]
    }
  ]
}
```

### 6.3 Cambios de red (`tipo: "cambios_red"`)
```json
{
  "canal": "inventario",
  "tipo": "cambios_red",
  "escaner": "kali-g7",
  "ts": "2026-11-23T19:32:10Z",
  "nuevos": ["192.168.1.150"],
  "desaparecidos": [],
  "puertos_abiertos": [
    { "ip": "192.168.1.143", "puerto": 8000 }
  ],
  "puertos_cerrados": []
}
```

### 6.4 Alerta de equipo no autorizado (`autorizados.json`)
```json
{
  "canal": "inventario",
  "tipo": "alerta_no_autorizado",
  "severidad": "alta",
  "escaner": "kali-g7",
  "ts": "2026-11-23T19:32:10Z",
  "ips_no_autorizadas": ["192.168.1.150"]
}
```

### 6.5 Alerta de puertos de riesgo
```json
{
  "canal": "inventario",
  "tipo": "alerta_puertos_riesgo",
  "severidad": "alta",
  "escaner": "kali-g7",
  "ts": "2026-11-23T19:32:10Z",
  "puertos_riesgo": [
    { "ip": "192.168.1.143", "puerto": 23, "servicio": "telnet" }
  ]
}
```

### 6.6 Mensaje de prueba de conectividad (`--prueba`)
```json
{
  "canal": "inventario",
  "tipo": "prueba",
  "escaner": "kali-g7",
  "ts": "2026-11-23T19:30:00Z",
  "detalle": "Mensaje de prueba de conectividad - Grupo 7"
}
```

### 6.7 Ejemplo de informe legible generado (`informe.md`)
```markdown
# Informe de Inventario de Red

- **Escáner:** `kali-g7`
- **Red escaneada:** `192.168.1.0/24`
- **Fecha (UTC):** `2026-11-23T19:31:46Z`
- **Equipos activos detectados:** 4
- **Total de puertos abiertos:** 8

## Equipos detectados

| IP | Nombre | Autorizado | Puertos abiertos | Puertos de riesgo |
| --- | --- | --- | --- | --- |
| `192.168.1.1` | - | Sí | 53/tcp (domain), 80/tcp (http), 443/tcp (https) | - |
| `192.168.1.129` | - | NO (severidad alta) | 5000/tcp (upnp), 49152/tcp (desconocido), 49153/tcp (desconocido) | - |
| `192.168.1.141` | - | NO (severidad alta) | 49152/tcp (desconocido) | - |
| `192.168.1.143` | - | Sí | 8000/tcp (http-alt) | - |
```

---

## 7. Guion sugerido para la demo en vivo (3–4 min)

1. **Validación y conectividad (30 s):** Mostrar `shellcheck inventario.sh` sin avisos, probar un CIDR inválido (`./inventario.sh 999.1.1.1/24`) y verificar el webhook con `./inventario.sh --prueba`.
2. **Línea base y estabilidad (1 min):** Ejecutar `./inventario.sh 192.168.1.0/24` dos veces seguidas. En la segunda se muestra `Sin cambios` y no se envía nada al webhook.
3. **Detección de cambio en directo (1 min 30 s):** En una máquina del laboratorio (o en local), arrancar `python3 -m http.server 8000`. Volver a ejecutar `./inventario.sh 192.168.1.0/24`: se detecta el puerto `8000` en `puertos_abiertos` y se envía el JSON `cambios_red`.
4. **Verificación y ampliaciones (1 min):** Consultar `./inventario.sh --ver-sync` para enseñar el evento recibido en el servidor del profesor y mostrar el informe generado en [informe.md](./informe.md) junto a [autorizados.json](./autorizados.json).
