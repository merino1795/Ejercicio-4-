# Inventario de red y detección de cambios

Grupo: Grupo 7

Canal: inventario

Escáner por defecto: kali-g7

Escanea una red con `nmap`, guarda el resultado como inventario JSON, lo compara con el escaneo anterior y notifica por webhook los cambios: equipos nuevos o desaparecidos, puertos que se abren o se cierran, equipos no autorizados y puertos de riesgo. Incluye un panel web local con un histórico filtrable de los eventos del canal.

Proyecto de laboratorio de ciberseguridad (ejercicio «Inventario de red y detección de cambios»).

> \*\*Aviso legal.\*\* Escanea únicamente redes propias o aquellas para las que tengas autorización expresa. Escanear redes ajenas sin permiso es ilegal en la mayoría de jurisdicciones. El autor no se hace responsable del uso que se haga de esta herramienta.

## Características

* Validación del parámetro de red (CIDR) antes de escanear.
* Inventario con fecha en `inventarios/inv\_AAAAMMDD\_HHMMSS.json`, validado con `jq -e`.
* Detección de equipos nuevos y desaparecidos, y de puertos abiertos y cerrados por equipo.
* **Equipos no autorizados** (`autorizados.json`) y **puertos de riesgo** (23, 445, 3389, 5900) con severidad `alta`, `media` o `baja`.
* Solo envía al webhook cuando hay cambios; si no, imprime `Sin cambios`.
* **Modo vigilancia** (`--vigilar`) y informe legible en `informe.md`.
* **Panel web local** con estado, equipos, cambios recientes y un histórico acumulado del canal con filtros (tipo, escáner, severidad, IP pública o privada, puertos, evento, periodo).

## Requisitos

* Linux o macOS con `bash`, `nmap`, `jq`, `curl` y `awk`.
* Python 3.8 o superior para el panel (solo biblioteca estándar, sin dependencias).

```bash
sudo apt install nmap jq curl
```

## Instalación

```bash
git clone https://github.com/<usuario>/inventario-red.git
cd inventario-red
cp .env.example .env                              # y edítalo
cp autorizados.example.json autorizados.json      # opcional: tus IPs permitidas
```

## Configuración

Todo se define en `.env` (no se sube a git) o como variables de entorno:

|Variable|Descripción|Por defecto|
|-|-|-|
|`WEBHOOK\_URL`|URL a la que se hace POST con los cambios. Vacía = modo local, no se envía nada|vacía|
|`SYNC\_URL`|URL de lectura (GET) del canal para el histórico del panel|vacía|
|`ESCANER`|Nombre que identifica a este escáner en los mensajes|`hostname`|
|`INTERVALO`|Segundos entre escaneos (panel y `--vigilar`)|300 en el panel, 120 en `--vigilar`|
|`PUERTO\_WEB`|Puerto del panel local|`8080`|
|`SYNC\_INTERVALO`|Segundos entre lecturas del canal|`30`|

**La URL del webhook suele contener un token: trátala como una contraseña.**

## Uso

### Línea de comandos

```bash
./inventario.sh 192.168.1.0/24            # un escaneo
./inventario.sh 192.168.1.0/24 --vigilar  # repetir cada INTERVALO segundos
```

El primer escaneo crea la línea base y no envía nada. Dos escaneos consecutivos sin cambios tampoco envían nada.

### Panel web

```bash
python3 servidor.py 192.168.1.0/24
```

Abre `http://127.0.0.1:8080`. El servidor ejecuta `inventario.sh` periódicamente y escucha **solo en `127.0.0.1`**. En `docs/panel\_demo.html` hay una vista previa con datos de ejemplo.

## Formato de los mensajes

Inventario:

```json
{
  "tipo": "inventario",
  "escaner": "mi-equipo",
  "red": "192.168.1.0/24",
  "ts": "2026-11-17T11:20:00Z",
  "hosts": \[
    { "ip": "192.168.1.10", "nombre": "portatil",
      "puertos": \[ { "puerto": 22, "proto": "tcp", "servicio": "ssh" } ] }
  ]
}
```

Cambios (los campos `puertos\_riesgo`, `no\_autorizados` y `severidad` son extensiones sobre el contrato básico):

```json
{
  "tipo": "cambios\_red",
  "escaner": "mi-equipo",
  "ts": "2026-11-17T11:22:00Z",
  "nuevos": \["192.168.1.57"],
  "desaparecidos": \[],
  "puertos\_abiertos": \[ { "ip": "192.168.1.10", "puerto": 80 } ],
  "puertos\_cerrados": \[],
  "puertos\_riesgo": \[],
  "no\_autorizados": \["192.168.1.57"],
  "severidad": "alta"
}
```

## Estructura

```
inventario.sh              escaneo, inventario, comparación y envío
servidor.py                panel web local + histórico del canal
tests/run.sh               pruebas sin red (nmap simulado)
docs/panel\_demo.html       vista previa del panel con datos de ejemplo
.env.example               plantilla de configuración
autorizados.example.json   plantilla de IPs autorizadas
.github/workflows/ci.yml   ShellCheck, sintaxis de Python y pruebas
```

## Pruebas

```bash
bash tests/run.sh
```

Cubren la validación CIDR, el parseo de `nmap -oG` y la comparación de inventarios (nuevos, desaparecidos, puertos, riesgo, no autorizados, severidad). No requieren red ni ejecutan nmap real.

## Limitaciones conocidas

* **La identidad de un equipo es su IP.** Si el DHCP la reasigna, se verá como un equipo nuevo y otro desaparecido. Usar la MAC lo resolvería, pero requiere privilegios de root y estar en la misma subred.
* **`nmap -F` solo mira los 100 puertos más comunes.** Un servicio en otro puerto no se detecta.
* **`--open` puede ocultar equipos sin puertos abiertos.** El script procesa también las líneas `Status: Up`; verifica el comportamiento en tu versión de nmap.
* **Sin reintentos.** Si el POST al webhook falla, ese evento no se reenvía (queda en `cambios.log`).
* **Un único escaneo perdido puede producir un falso «desaparecido».** No hay confirmación en dos pasadas.
* **Sin sudo, nmap hace escaneo por conexión TCP:** es más lento y no obtiene MACs.
* **El histórico del canal es genérico.** Se asume que cada elemento sigue el formato de mensajes de arriba; con otro formato, los filtros por tipo, escáner o evento no encontrarán coincidencias.
* **`sync\_historial.jsonl` crece sin límite.**

## Seguridad

* No subas `.env`, `inventarios/`, `cambios.log`, `sync\_historial.jsonl` ni `autorizados.json`: contienen datos de tu red. Ya están en `.gitignore`.
* Los nombres de equipo los controla cualquiera de la red escaneada: el panel los muestra como texto, nunca como HTML. No lo cambies a `innerHTML`.
* No cambies el panel para escuchar en `0.0.0.0`: expone la topología de tu red.
* Si un token del webhook llega a un repositorio público, considéralo comprometido y regénéralo.

## Licencia

[MIT](LICENSE)

