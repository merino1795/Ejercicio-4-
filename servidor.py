#!/usr/bin/env python3
"""Panel local para inventario.sh.
Uso: python3 servidor.py 192.168.1.0/24
Variables opcionales: INTERVALO (s, def. 300), PUERTO_WEB (def. 8080), SYNC_URL.
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))


def cargar_env():
    """Lee KEY=valor de .env (si existe) sin pisar variables ya definidas."""
    try:
        with open(os.path.join(BASE, ".env"), encoding="utf-8") as f:
            for linea in f:
                linea = linea.strip()
                if linea and not linea.startswith("#") and "=" in linea:
                    k, v = linea.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    except OSError:
        pass


cargar_env()
INTERVALO = int(os.environ.get("INTERVALO", 300))
PUERTO_WEB = int(os.environ.get("PUERTO_WEB", 8080))
SYNC_URL = os.environ.get("SYNC_URL", "")
RED = sys.argv[1] if len(sys.argv) > 1 else ""

if not re.fullmatch(r"(\d{1,3}\.){3}\d{1,3}/(\d|[12]\d|3[0-2])", RED):
    sys.exit("Uso: python3 servidor.py <red CIDR>  (ej. 192.168.1.0/24)")

LOCK = threading.Lock()
ESTADO = {"escaneando": False, "ultimo": None, "proximo": None, "rc": None, "salida": ""}
_sync = {"t": 0.0, "v": None}
SYNC_INTERVALO = int(os.environ.get("SYNC_INTERVALO", 30))
HISTORIAL = os.path.join(BASE, "sync_historial.jsonl")
HIST_LOCK = threading.Lock()
_vistos = set()


def bucle_escaneo():
    while True:
        with LOCK:
            ESTADO["escaneando"] = True
        try:
            p = subprocess.run(["bash", os.path.join(BASE, "inventario.sh"), RED],
                               cwd=BASE, capture_output=True, text=True,
                               timeout=max(INTERVALO, 60))
            rc, salida = p.returncode, (p.stdout + p.stderr)[-2000:]
        except subprocess.TimeoutExpired:
            rc, salida = -1, "Escaneo cancelado por tiempo excesivo"
        with LOCK:
            ESTADO.update(escaneando=False, ultimo=time.time(), rc=rc, salida=salida,
                          proximo=time.time() + INTERVALO)
        time.sleep(INTERVALO)


def ultimo_inventario():
    ficheros = sorted(glob.glob(os.path.join(BASE, "inventarios", "inv_*.json")))
    if not ficheros:
        return None
    try:
        with open(ficheros[-1]) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def leer_json(nombre, defecto):
    try:
        with open(os.path.join(BASE, nombre)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return defecto


def ultimos_cambios(n=15):
    try:
        with open(os.path.join(BASE, "cambios.log")) as f:
            lineas = f.readlines()[-n:]
    except OSError:
        return []
    salida = []
    for linea in lineas:
        try:
            salida.append(json.loads(linea))
        except ValueError:
            pass
    return salida[::-1]


def consultar_sync():
    """GET al /sync desde el servidor (sin CORS)."""
    if not SYNC_URL:
        return {"ok": False, "error": "SYNC_URL no configurada (ver .env.example)"}
    try:
        with urllib.request.urlopen(SYNC_URL, timeout=5) as r:
            cuerpo = r.read(2_000_000).decode("utf-8", "replace")
        try:
            val = {"ok": True, "json": json.loads(cuerpo)}
        except ValueError:
            val = {"ok": True, "texto": cuerpo[:5000]}
    except Exception as e:  # red caida, timeout, etc.
        val = {"ok": False, "error": str(e)}
    return val


def leer_sync():
    return _sync["v"] or {"ok": False, "error": "Aún sin lectura"}


def extraer_items(val):
    """Convierte la respuesta del /sync en una lista de elementos."""
    if not val.get("ok"):
        return []
    if "json" in val:
        d = val["json"]
        if isinstance(d, dict):
            for v in d.values():  # p. ej. {"eventos": [ ... ]}
                if isinstance(v, list) and v and all(isinstance(i, dict) for i in v):
                    return v
        return d if isinstance(d, list) else [d]
    return [{"texto": l} for l in val.get("texto", "").splitlines() if l.strip()]


def _hash(item):
    return hashlib.sha1(json.dumps(item, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def acumular(items):
    """Guarda en sync_historial.jsonl solo lo que no se había visto."""
    with HIST_LOCK, open(HISTORIAL, "a", encoding="utf-8") as f:
        for it in items:
            h = _hash(it)
            if h in _vistos:
                continue
            _vistos.add(h)
            f.write(json.dumps({"visto": time.time(), "hash": h, "dato": it},
                               ensure_ascii=False) + "\n")


def leer_historial(n=2000):
    try:
        with open(HISTORIAL, encoding="utf-8") as f:
            lineas = f.readlines()
    except OSError:
        return {"total": 0, "items": []}
    items = []
    for l in lineas[-n:]:
        try:
            items.append(json.loads(l))
        except ValueError:
            pass
    return {"total": len(lineas), "items": items[::-1]}


def bucle_sync():
    try:  # recuperar lo ya guardado para no duplicar tras reiniciar
        with open(HISTORIAL, encoding="utf-8") as f:
            for l in f:
                try:
                    _vistos.add(json.loads(l)["hash"])
                except (ValueError, KeyError):
                    pass
    except OSError:
        pass
    while True:
        val = consultar_sync()
        _sync.update(t=time.time(), v=val)
        acumular(extraer_items(val))
        time.sleep(SYNC_INTERVALO)


PAGINA = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inventario de red</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--tx:#1d2330;--mut:#6b7385;--bd:#e2e5ec;--ok:#1a9d5c;--alta:#d92d3a;--media:#e08a00;--baja:#3b82f6}
@media (prefers-color-scheme:dark){:root{--bg:#0f131a;--card:#171c26;--tx:#e6e9f0;--mut:#8b93a7;--bd:#262d3b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.5 system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px}
header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;margin-bottom:20px}
h1{font-size:22px;margin:0}
.pill{padding:4px 12px;border-radius:999px;font-size:13px;font-weight:600;color:#fff;background:var(--ok)}
.pill.scan{background:var(--media)}.pill.err{background:var(--alta)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:16px;margin-bottom:16px}
.grid .card{margin:0}
.num{font-size:30px;font-weight:700}.mut{color:var(--mut);font-size:13px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--bd)}
th{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
tr.alta td:first-child{border-left:4px solid var(--alta)}tr.media td:first-child{border-left:4px solid var(--media)}
.tag{display:inline-block;padding:1px 8px;margin:1px 4px 1px 0;border-radius:6px;background:var(--bd);font-size:12px}
.tag.riesgo{background:var(--alta);color:#fff}
.sev{font-weight:700;text-transform:uppercase;font-size:12px}
.sev.alta{color:var(--alta)}.sev.media{color:var(--media)}.sev.baja{color:var(--baja)}
pre{margin:8px 0 0;padding:12px;background:var(--bg);border-radius:8px;max-height:260px;overflow:auto;font-size:12px}
.badge{background:var(--baja);color:#fff;border-radius:6px;padding:2px 8px;font-size:12px;margin-left:8px}
.wrap{overflow-x:auto}
.fgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px}.fgrid label{display:block;font-size:12px;color:var(--mut);margin-bottom:2px}.fgrid select,.fgrid input{width:100%;padding:7px 9px;border:1px solid var(--bd);border-radius:8px;background:var(--bg);color:var(--tx)}.chk{display:flex;align-items:center;gap:6px;font-size:14px}.chk input{width:auto}.btn{padding:7px 14px;border:1px solid var(--bd);border-radius:8px;background:var(--bg);color:var(--tx);cursor:pointer}.tag.click{cursor:pointer}
</style></head><body><main>
<header><h1>Inventario de red <span class="mut" id="red"></span></h1><span class="pill" id="estado">Cargando…</span></header>
<div class="grid">
 <div class="card"><div class="mut">Equipos detectados</div><div class="num" id="nhosts">–</div></div>
 <div class="card"><div class="mut">Próximo escaneo en</div><div class="num" id="cuenta">–</div></div>
 <div class="card"><div class="mut">Último escaneo</div><div class="num" id="ultimo" style="font-size:20px">–</div></div>
 <div class="card"><div class="mut">Cambios registrados</div><div class="num" id="ncambios">–</div></div>
</div>
<div class="card"><h2 style="margin-top:0;font-size:16px">Equipos</h2><div class="wrap"><table>
 <thead><tr><th>IP</th><th>Nombre</th><th>Puertos</th></tr></thead><tbody id="hosts"></tbody></table></div></div>
<div class="card"><h2 style="margin-top:0;font-size:16px">Cambios recientes</h2><div id="cambios" class="mut">Sin cambios registrados</div></div>
<div class="card"><h2 style="margin-top:0;font-size:16px">Respuesta del /sync<span class="badge" id="syncbadge" hidden>Actualizado</span></h2>
 <div class="mut" id="syncinfo"></div><pre id="sync"></pre></div>
<div class="card"><h2 style="margin-top:0;font-size:16px">Histórico acumulado del /sync <span class="mut">(<span id="hshown">0</span> de <span id="hnum">0</span>)</span></h2>
 <div class="fgrid">
  <div><label>Buscar texto</label><input id="filtro" type="search" placeholder="Cualquier texto…"></div>
  <div><label>Tipo</label><select id="f-tipo"></select></div>
  <div><label>Escáner (grupo)</label><select id="f-esc"></select></div>
  <div><label>Severidad</label><select id="f-sev"><option value="">Todas</option><option value="alta">alta</option><option value="media">media</option><option value="baja">baja</option></select></div>
  <div><label>Direcciones IP</label><select id="f-ip"><option value="">Todas</option><option value="publica">Con alguna IP pública</option><option value="privada">Solo IPs privadas</option></select></div>
  <div><label>Puertos (separados por coma)</label><input id="f-pto" type="search" placeholder="22, 80, 8000"></div>
  <div><label>Evento</label><select id="f-ev"><option value="">Todos</option><option value="nuevos">Equipos nuevos</option><option value="desaparecidos">Equipos desaparecidos</option><option value="puertos_abiertos">Puertos abiertos</option><option value="puertos_cerrados">Puertos cerrados</option></select></div>
  <div><label>Visto hace menos de</label><select id="f-t"><option value="0">Sin límite</option><option value="300">5 minutos</option><option value="3600">1 hora</option><option value="86400">24 horas</option></select></div>
 </div>
 <div style="display:flex;gap:16px;flex-wrap:wrap;align-items:center;margin:10px 0">
  <label class="chk"><input type="checkbox" id="f-riesgo"> Solo puertos de riesgo</label>
  <label class="chk"><input type="checkbox" id="f-noaut"> Solo con IP no autorizada</label>
  <button class="btn" id="f-lim" type="button">Limpiar filtros</button>
 </div>
 <div class="mut">Puertos más frecuentes (clic para filtrar)</div><div id="toppuertos" style="margin:4px 0 10px"></div>
 <div class="wrap" style="max-height:420px;overflow:auto"><table><thead><tr><th>Visto</th><th>Tipo</th><th>Escáner</th><th>Sev.</th><th>Contenido</th></tr></thead><tbody id="historial"></tbody></table></div>
 <div class="mut" id="hnota"></div></div>
</main>
<script>
const RIESGO = [23,445,3389,5900];
const $ = id => document.getElementById(id);
function el(tag, texto, cls){const e=document.createElement(tag); if(texto!==undefined) e.textContent=texto; if(cls) e.className=cls; return e;}
let proximo=null, syncPrevio=null;

function pintarHosts(inv, autz){
  const tb=$('hosts'); tb.replaceChildren();
  if(!inv){tb.append(Object.assign(el('td','Esperando el primer escaneo…'),{colSpan:3}));return;}
  $('red').textContent=inv.red; $('nhosts').textContent=inv.hosts.length;
  for(const h of inv.hosts){
    const riesgo=h.puertos.some(p=>RIESGO.includes(p.puerto));
    const noAut=autz.length>0 && !autz.includes(h.ip);
    const tr=el('tr',undefined,noAut?'alta':(riesgo?'media':''));
    tr.append(el('td',h.ip), el('td',h.nombre||'—'));
    const td=el('td');
    if(!h.puertos.length) td.append(el('span','ninguno','mut'));
    for(const p of h.puertos) td.append(el('span',p.puerto+'/'+(p.servicio||'?'),'tag'+(RIESGO.includes(p.puerto)?' riesgo':'')));
    tr.append(td); tb.append(tr);
  }
}
function lista(titulo, arr){ return arr.length? titulo+': '+arr.join(', ') : null; }
function pintarCambios(cs){
  const c=$('cambios'); c.replaceChildren(); $('ncambios').textContent=cs.length;
  if(!cs.length){c.textContent='Sin cambios registrados';return;}
  for(const x of cs){
    const caja=el('div'); caja.style.cssText='padding:8px 0;border-bottom:1px solid var(--bd)';
    const cab=el('div'); cab.append(el('span',x.severidad||'baja','sev '+(x.severidad||'baja')), el('span','  '+x.ts,'mut'));
    caja.append(cab);
    const pts=a=>a.map(p=>p.ip+':'+p.puerto);
    for(const t of [lista('Nuevos',x.nuevos||[]),lista('Desaparecidos',x.desaparecidos||[]),
        lista('Puertos abiertos',pts(x.puertos_abiertos||[])),lista('Puertos cerrados',pts(x.puertos_cerrados||[])),
        lista('Puertos de riesgo',pts(x.puertos_riesgo||[])),lista('No autorizados',x.no_autorizados||[])])
      if(t) caja.append(el('div',t));
    c.append(caja);
  }
}
function pintarSync(s){
  const cuerpo = !s.ok ? '' : (s.json!==undefined ? JSON.stringify(s.json,null,2) : s.texto);
  $('syncinfo').textContent = s.ok ? 'Lectura correcta' : 'No se pudo leer: '+s.error;
  $('sync').textContent = cuerpo;
  if(syncPrevio!==null && cuerpo!==syncPrevio){ const b=$('syncbadge'); b.hidden=false; setTimeout(()=>b.hidden=true,15000); }
  if(s.ok) syncPrevio=cuerpo;
}
const AN=new Map(); let AUTZ=[], ultimoH=null;
function esPublica(ip){
  const p=ip.split('.').map(Number);
  if(p.length!==4||p.some(n=>n>255)) return false;
  const a=p[0], b=p[1];
  return !(a===0||a===10||a===127||a>=224||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&b===168));
}
function recorrer(v,clave,acc){
  if(Array.isArray(v)){ v.forEach(x=>recorrer(x,clave,acc)); return; }
  if(v && typeof v==='object'){ for(const k in v) recorrer(v[k],k,acc); return; }
  if(typeof v==='string'){ const m=v.match(/[0-9]{1,3}(?:[.][0-9]{1,3}){3}/g); if(m) m.forEach(i=>acc.ips.add(i)); }
  if(/^(puertos?|ports?)$/i.test(clave||'')){ const n=Number(v); if(Number.isInteger(n)&&n>0&&n<65536) acc.puertos.add(n); }
}
function analizar(x){
  let r=AN.get(x.hash); if(r) return r;
  const acc={ips:new Set(),puertos:new Set()}; recorrer(x.dato,'',acc);
  const o=(x.dato && typeof x.dato==='object' && !Array.isArray(x.dato))?x.dato:{};
  const hay=k=>Array.isArray(o[k]) && o[k].length>0;
  r={ips:[...acc.ips], puertos:[...acc.puertos], tipo:String(o.tipo||'otro'), escaner:String(o.escaner||'—'), sev:String(o.severidad||''),
     ev:{nuevos:hay('nuevos'),desaparecidos:hay('desaparecidos'),puertos_abiertos:hay('puertos_abiertos'),puertos_cerrados:hay('puertos_cerrados')}};
  AN.set(x.hash,r); return r;
}
function llenar(sel,vals,todos){
  const k=vals.join('|'); if(sel.dataset.k===k) return;
  const actual=sel.value; sel.dataset.k=k; sel.replaceChildren(new Option(todos,''));
  for(const v of vals) sel.append(new Option(v,v));
  sel.value=vals.includes(actual)?actual:'';
}
function filtros(){
  return {q:$('filtro').value.toLowerCase(), tipo:$('f-tipo').value, esc:$('f-esc').value, sev:$('f-sev').value, ip:$('f-ip').value,
    ptos:$('f-pto').value.split(',').map(s=>Number(s.trim())).filter(n=>n>0), ev:$('f-ev').value, t:Number($('f-t').value),
    riesgo:$('f-riesgo').checked, noaut:$('f-noaut').checked};
}
function pasa(x,a,f,ahora,txt){
  if(f.q && !txt.toLowerCase().includes(f.q)) return false;
  if(f.tipo && a.tipo!==f.tipo) return false;
  if(f.esc && a.escaner!==f.esc) return false;
  if(f.sev && a.sev!==f.sev) return false;
  if(f.ip==='publica' && !a.ips.some(esPublica)) return false;
  if(f.ip==='privada' && (!a.ips.length || a.ips.some(esPublica))) return false;
  if(f.ptos.length && !f.ptos.some(p=>a.puertos.includes(p))) return false;
  if(f.ev && !a.ev[f.ev]) return false;
  if(f.t && ahora-x.visto>f.t) return false;
  if(f.riesgo && !a.puertos.some(p=>RIESGO.includes(p))) return false;
  if(f.noaut && !(AUTZ.length && a.ips.some(i=>!AUTZ.includes(i)))) return false;
  return true;
}
function pintarHistorial(h){
  ultimoH=h; $('hnum').textContent=h.total;
  llenar($('f-tipo'),[...new Set(h.items.map(x=>analizar(x).tipo))].sort(),'Todos');
  llenar($('f-esc'),[...new Set(h.items.map(x=>analizar(x).escaner))].sort(),'Todos');
  const f=filtros(), ahora=Date.now()/1000, tb=$('historial'), cont=new Map(); let n=0;
  tb.replaceChildren();
  for(const x of h.items){
    const a=analizar(x), txt=JSON.stringify(x.dato);
    if(!pasa(x,a,f,ahora,txt)) continue;
    n++; a.puertos.forEach(p=>cont.set(p,(cont.get(p)||0)+1));
    if(n>300) continue;
    const c=el('td',txt.length>400?txt.slice(0,400)+'…':txt); c.style.cssText='font-size:12px;word-break:break-all';
    const tr=el('tr'); tr.append(el('td',new Date(x.visto*1000).toLocaleString()), el('td',a.tipo), el('td',a.escaner), el('td',a.sev||'—','sev '+a.sev), c);
    tb.append(tr);
  }
  $('hshown').textContent=n;
  $('hnota').textContent = (n>300?'Mostrando las 300 primeras coincidencias. ':'') + (h.total>h.items.length?'Se analizan solo los '+h.items.length+' elementos más recientes de '+h.total+'.':'');
  const top=$('toppuertos'); top.replaceChildren();
  if(!cont.size) top.append(el('span','sin puertos en los resultados','mut'));
  for(const [p,c] of [...cont].sort((a,b)=>b[1]-a[1]).slice(0,8)){
    const t=el('span',p+' ×'+c,'tag click'+(RIESGO.includes(p)?' riesgo':''));
    t.onclick=()=>{ $('f-pto').value=String(p); pintarHistorial(ultimoH); };
    top.append(t);
  }
}
for(const id of ['filtro','f-tipo','f-esc','f-sev','f-ip','f-pto','f-ev','f-t','f-riesgo','f-noaut'])
  for(const ev of ['input','change']) $(id).addEventListener(ev,()=>{ if(ultimoH) pintarHistorial(ultimoH); });
$('f-lim').onclick=()=>{
  for(const id of ['filtro','f-tipo','f-esc','f-sev','f-ip','f-pto','f-ev']) $(id).value='';
  $('f-t').value='0'; $('f-riesgo').checked=false; $('f-noaut').checked=false;
  if(ultimoH) pintarHistorial(ultimoH);
};
async function refrescar(){
  let d;
  try{ d=await (await fetch('/api/estado')).json(); }
  catch(e){ const p=$('estado'); p.textContent='Servidor local sin respuesta'; p.className='pill err'; return; }
  const p=$('estado');
  if(d.escaneando){p.textContent='Escaneando…';p.className='pill scan';}
  else if(d.rc!==null && d.rc!==0){p.textContent='Error en el último escaneo';p.className='pill err';}
  else {p.textContent='Todo en orden';p.className='pill';}
  proximo=d.proximo;
  $('ultimo').textContent = d.ultimo? new Date(d.ultimo*1000).toLocaleTimeString() : '–';
  AUTZ=d.autorizados; pintarHosts(d.inventario, d.autorizados); pintarCambios(d.cambios); pintarSync(d.sync); pintarHistorial(d.historial);
}
setInterval(()=>{ if(proximo){const s=Math.max(0,Math.round(proximo-Date.now()/1000));
  $('cuenta').textContent=Math.floor(s/60)+':'+String(s%60).padStart(2,'0');}},1000);
refrescar(); setInterval(refrescar,10000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _enviar(self, codigo, tipo, cuerpo):
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        if self.path == "/":
            self._enviar(200, "text/html; charset=utf-8", PAGINA.encode())
        elif self.path == "/api/estado":
            with LOCK:
                estado = dict(ESTADO)
            estado.update(inventario=ultimo_inventario(), cambios=ultimos_cambios(),
                          autorizados=leer_json("autorizados.json", []), sync=leer_sync(),
                          historial=leer_historial())
            self._enviar(200, "application/json", json.dumps(estado).encode())
        else:
            self._enviar(404, "text/plain", b"No encontrado")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=bucle_escaneo, daemon=True).start()
    threading.Thread(target=bucle_sync, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PUERTO_WEB), Handler)  # solo local
    print(f"Panel en http://127.0.0.1:{PUERTO_WEB}  (escaneo de {RED} cada {INTERVALO}s)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nDetenido.")
