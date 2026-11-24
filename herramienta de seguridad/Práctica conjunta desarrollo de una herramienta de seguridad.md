## Ejercicio 4 Inventario de red y detección de cambios

**Script:** inventario.sh · **Canal:** inventario.

### Contexto

El script escanea la red del laboratorio con nmap, convierte el resultado en un inventario JSON, lo compara con el escaneo anterior y notifica por webhook los cambios: equipos nuevos, equipos que desaparecen y puertos que se abren o se cierran. Es la base de cualquier sistema de detección de dispositivos no autorizados.

> Importante: escanead **solo la red del laboratorio** que indique el profesor. Escanear redes ajenas sin autorización es ilegal.

### Contrato JSON del inventario

```json
{
  "tipo": "inventario",
  "escaner": "kali-g4",
  "red": "192.168.56.0/24",
  "ts": "2026-11-17T11:20:00Z",
  "hosts": [
    {
      "ip": "192.168.56.10",
      "nombre": "kali-g1",
      "puertos": [ { "puerto": 22, "proto": "tcp", "servicio": "ssh" } ]
    }
  ]
}
```

### Contrato JSON de los cambios

```json
{
  "tipo": "cambios_red",
  "escaner": "kali-g4",
  "ts": "2026-11-17T11:22:00Z",
  "nuevos": ["192.168.56.33"],
  "desaparecidos": [],
  "puertos_abiertos": [ { "ip": "192.168.56.10", "puerto": 80 } ],
  "puertos_cerrados": []
}
```

### Requisitos mínimos (fase 1)

1. Recibir la red como parámetro y validarla con una expresión regular de tipo CIDR.
2. Escanear con nmap -F --open -oG - <red> (salida "grepable", fácil de procesar) y convertir cada línea Host: en un objeto JSON con awk, sed o jq. 
3. Guardar cada inventario con fecha (inventarios/inv_AAAAMMDD_HHMMSS.json) y validarlo con jq -e.  
4. Comparar con el inventario anterior y calcular equipos nuevos y desaparecidos (en jq, la resta de arrays hace la diferencia).
5. Si hay cambios, enviar el JSON de cambios al canal inventario; si no, mostrar "Sin cambios".

Pista de partida para el paso 4:

```bash
jq -n --slurpfile a viejo.json --slurpfile b nuevo.json '
  ($a[0].hosts | map(.ip)) as $v | ($b[0].hosts | map(.ip)) as $n
  | {nuevos: ($n - $v), desaparecidos: ($v - $n)}'
```

### Ampliaciones (fase 2, elegid al menos dos)

- Detección de puertos abiertos y cerrados por equipo (no solo de equipos).
    
- Fichero autorizados.json: cualquier IP que no esté en él genera un evento con "severidad": "alta".
    
- Lista de puertos de riesgo (23, 445, 3389, 5900…) que generan aviso aunque el equipo sea conocido.
    
- Modo vigilancia: repetir cada 2 minutos y enviar solo cuando haya cambios.
    
- Informe legible: generar informe.md o informe.html a partir del último inventario con jq -r.
    

### Pistas y prompts sugeridos para Claude

- "Explícame el formato -oG de nmap y cómo extraer la IP y la lista de puertos de cada línea."
    
- "¿Cómo comparo dos ficheros JSON con jq para sacar los elementos nuevos y los que faltan?"
    
- Para provocar cambios en la demo: otro grupo arranca python3 -m http.server 8000 o apaga su máquina.
    

### Hecho cuando…

Dos escaneos consecutivos sin cambios no envían nada, y al encender un servicio nuevo