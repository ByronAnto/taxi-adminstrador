# Runbook: LiveKit en Oracle Cloud Free Tier + nginx ingress

> **Contexto:** complemento operativo del spec [`2026-05-19-livekit-hybrid-migration.md`](2026-05-19-livekit-hybrid-migration.md). Acá viven los comandos exactos para la VM Oracle Ampere A1 (24 GB / 4 vCPU ARM) con `livekit.tu-dominio.com` apuntando vía nginx.

## Topología

```
                                  ┌──────────────────────────────────┐
   Cliente Flutter                │  Oracle Cloud A1 ARM (24GB/4CPU) │
   (Jipijapa, etc.)               │                                  │
                                  │  ┌──────────┐    ┌────────────┐  │
   wss://livekit.tu-dominio.com   │  │  nginx   │───▶│  livekit    │  │
   ─────────signaling────────────▶│  │  :443    │    │  :7880 (ws) │  │
                                  │  │  TLS     │    │  :7881 (tcp)│  │
                                  │  └──────────┘    └────────────┘  │
                                  │                        ▲          │
   UDP 50000-60000                │                        │          │
   ───────media (audio)──────────────────────────────────  ┘          │
   (NO pasa por nginx)            │                                  │
                                  └──────────────────────────────────┘
                                       Security List + iptables
```

**Por qué nginx:** terminar TLS con cert renovable + un único punto de entrada en :443 que es el único puerto "amigable" con redes corporativas y carriers móviles que filtran puertos exóticos.

**Por qué NO va nginx en el media:** WebRTC UDP no se proxiá por HTTP. Cada paquete tiene que llegar lo más rápido posible al server — agregar un hop nginx sumaría 5-10 ms y latencia variable. LiveKit sabe descubrir su IP externa y publicarla al cliente (`use_external_ip: true`).

---

## Paso 1: Configurar Oracle Cloud (Security List)

Esto se hace en la consola web de Oracle, **antes** de tocar la VM. Sin esto, los pasos siguientes "funcionan" pero el tráfico nunca llega desde internet.

### 1.1. Ir a la Security List del VCN

`Networking → Virtual Cloud Networks → tu-vcn → Security Lists → Default Security List for tu-vcn`

### 1.2. Agregar Ingress Rules (todas con source `0.0.0.0/0`)

| Stateless | Source CIDR | IP Protocol | Source Port | Destination Port | Descripción |
|---|---|---|---|---|---|
| No | 0.0.0.0/0 | TCP | All | 22 | SSH (ya debería estar) |
| No | 0.0.0.0/0 | TCP | All | 80 | HTTP (certbot challenge + redirect) |
| No | 0.0.0.0/0 | TCP | All | 443 | HTTPS (nginx ingress) |
| No | 0.0.0.0/0 | TCP | All | 7881 | LiveKit TCP fallback |
| No | 0.0.0.0/0 | UDP | All | 50000-60000 | WebRTC media (UDP range) |

**Importante:** "Stateless" debe quedar en **No** (stateful). Stateless te obliga a abrir también el rango de egreso y duplica reglas.

---

## Paso 2: Configurar la VM (iptables / firewall del SO)

Oracle Ubuntu 22.04+ trae iptables con políticas restrictivas por default (Oracle agrega un `DROP` para todo lo no-SSH). Hay que abrir lo mismo que en la Security List, pero a nivel SO.

### 2.1. Conectarse y ver el estado actual

```bash
ssh ubuntu@livekit.tu-dominio.com
sudo iptables -L INPUT -n --line-numbers
```

Vas a ver algo como:

```
Chain INPUT (policy ACCEPT)
num  target     prot opt source               destination
1    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            state RELATED,ESTABLISHED
2    ACCEPT     icmp --  0.0.0.0/0            0.0.0.0/0
3    ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0
4    ACCEPT     udp  --  0.0.0.0/0            0.0.0.0/0            udp spt:123
5    ACCEPT     tcp  --  0.0.0.0/0            0.0.0.0/0            state NEW tcp dpt:22
6    REJECT     all  --  0.0.0.0/0            0.0.0.0/0            reject-with icmp-host-prohibited
```

La regla 6 (REJECT) es el problema — bloquea todo lo nuevo después del SSH.

### 2.2. Insertar las reglas ANTES del REJECT

```bash
# Insertar como regla 6 (empujando el REJECT hacia abajo)
sudo iptables -I INPUT 6 -p tcp --dport 80   -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 443  -j ACCEPT
sudo iptables -I INPUT 6 -p tcp --dport 7881 -j ACCEPT
sudo iptables -I INPUT 6 -p udp --dport 50000:60000 -j ACCEPT

# Confirmar el orden
sudo iptables -L INPUT -n --line-numbers
```

### 2.3. Persistir los cambios

```bash
sudo apt update
sudo apt install -y iptables-persistent
# Te va a preguntar si guardar las reglas actuales — decí YES a IPv4 y a IPv6
sudo netfilter-persistent save
```

### 2.4. Verificar desde tu laptop

```bash
# Desde tu equipo (no desde la VM)
nc -vz livekit.tu-dominio.com 443   # debería decir "succeeded"
nc -vzu livekit.tu-dominio.com 50000 # UDP suele dar "open" o timeout; ambos OK
```

Si `443` da connection refused desde tu laptop pero la regla está en iptables, casi siempre es la Security List de Oracle.

---

## Paso 3: DNS

En tu proveedor del dominio: agregar registro **A** apuntando al IP público de la VM.

```
Tipo  | Nombre        | Valor                | TTL
A     | livekit       | <IP público VM>      | 300
```

Verificar:

```bash
dig +short livekit.tu-dominio.com
# Debería devolver el IP de la VM
```

Esperar 5-10 min para que propague antes del siguiente paso (certbot necesita resolver el dominio).

---

## Paso 4: Docker + Docker Compose

Oracle Ubuntu 22.04+ generalmente NO trae Docker preinstalado.

```bash
ssh ubuntu@livekit.tu-dominio.com

sudo apt update
sudo apt install -y docker.io docker-compose-v2

sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu

# Reabrir sesión para que el grupo docker tome efecto
exit
ssh ubuntu@livekit.tu-dominio.com

docker --version
docker compose version
```

---

## Paso 5: nginx + certificado TLS

### 5.1. Instalar

```bash
sudo apt install -y nginx certbot python3-certbot-nginx
sudo systemctl enable --now nginx

# Verificar
curl -I http://livekit.tu-dominio.com
# HTTP/1.1 200 OK ← nginx default page
```

### 5.2. Obtener el certificado Let's Encrypt

```bash
sudo certbot --nginx -d livekit.tu-dominio.com \
  --email brealpeaymara@gmail.com --agree-tos --redirect --non-interactive
```

certbot edita `/etc/nginx/sites-enabled/default` y agrega el bloque TLS automáticamente. Recargá nginx por las dudas:

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -I https://livekit.tu-dominio.com
# HTTP/2 200 ← TLS funcionando
```

### 5.3. Renovación automática

certbot instala un timer en systemd. Verificar:

```bash
sudo systemctl list-timers | grep certbot
# certbot.timer ← debería aparecer
sudo certbot renew --dry-run
# Simulates renewal — debería decir "Congratulations, all simulated renewals succeeded"
```

---

## Paso 6: Configurar nginx como reverse proxy de LiveKit

Reemplazar el bloque server por uno que hace WebSocket proxy:

```bash
sudo nano /etc/nginx/sites-available/livekit
```

Contenido:

```nginx
# WebSocket signaling proxy → LiveKit server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name livekit.tu-dominio.com;

    ssl_certificate     /etc/letsencrypt/live/livekit.tu-dominio.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/livekit.tu-dominio.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Sin esto, las conexiones WebSocket largas se cortan a los 60 s.
    # LiveKit las mantiene abiertas mientras el cliente esté en la room.
    proxy_read_timeout 7d;
    proxy_send_timeout 7d;
    keepalive_timeout 7d;

    # Tamaño suficiente para handshake + ICE candidates
    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;

        # Upgrade headers — clave para WebSocket
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Preservar info del cliente
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # No buffering — WebRTC necesita real-time
        proxy_buffering off;
    }
}

# Redirect HTTP → HTTPS (certbot ya creó un redirect, este lo refuerza)
server {
    listen 80;
    listen [::]:80;
    server_name livekit.tu-dominio.com;
    return 301 https://$host$request_uri;
}
```

Activar:

```bash
sudo ln -sf /etc/nginx/sites-available/livekit /etc/nginx/sites-enabled/livekit
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

---

## Paso 7: LiveKit con Docker Compose

### 7.1. Estructura

```bash
sudo mkdir -p /opt/livekit/config
sudo chown -R ubuntu:ubuntu /opt/livekit
cd /opt/livekit
```

### 7.2. Generar API key/secret

```bash
echo "API$(openssl rand -hex 8 | tr 'a-z' 'A-Z'): $(openssl rand -hex 32)"
```

Guardalos en Bitwarden (o sops + age, tu preferencia). Los vas a poner en `livekit.yaml` y en los secrets de Firebase.

### 7.3. `livekit.yaml`

```bash
nano /opt/livekit/config/livekit.yaml
```

```yaml
port: 7880
bind_addresses:
  - "0.0.0.0"

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true   # ← LiveKit detecta tu IP público automático

keys:
  # ← Pegar la línea generada en 7.2
  APIxxxxxxxxxxxx: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

logging:
  level: info
  json: false

# Si necesitás grabar audios server-side activá esto. Por defecto OFF —
# usamos grabación local Agora-style en el cliente Flutter.
egress:
  enabled: false

audio:
  active_level: 35
  min_score: 6
```

### 7.4. `docker-compose.yml`

```bash
nano /opt/livekit/docker-compose.yml
```

```yaml
version: "3.9"
services:
  livekit:
    image: livekit/livekit-server:latest
    container_name: livekit
    restart: unless-stopped
    # network_mode: host es CRÍTICO en Oracle: WebRTC necesita un puerto UDP
    # por cada peer y bridges Docker NAT-ean mal el rango grande.
    network_mode: host
    volumes:
      - ./config/livekit.yaml:/etc/livekit.yaml:ro
    command:
      - --config=/etc/livekit.yaml
```

### 7.5. Arrancar y verificar logs

```bash
cd /opt/livekit
docker compose up -d
docker compose logs -f livekit
```

Buscás algo así:

```
{"level":"info","ts":...,"msg":"starting LiveKit server","version":"v1.x.x"}
{"level":"info","ts":...,"msg":"using external IP","ip":"<IP-público>"}
{"level":"info","ts":...,"msg":"starting RTC service","udp_port_range_start":50000,"udp_port_range_end":60000}
```

`Ctrl+C` para salir de logs (el container sigue corriendo).

### 7.6. Healthcheck final

```bash
# Desde la VM (loopback)
curl -i http://127.0.0.1:7880
# HTTP/1.1 200 OK ← server responde

# Desde tu laptop
curl -i https://livekit.tu-dominio.com
# HTTP/2 200 ← nginx + LiveKit OK

# WebSocket test con websocat (instalable con cargo o snap)
websocat wss://livekit.tu-dominio.com
# Debería conectarse y quedarse esperando un mensaje
```

---

## Paso 8: Subir credenciales a Firebase Functions

Ya con la API key/secret generadas en 7.2:

```bash
cd ~/Repositorios/taxis/functions

firebase functions:secrets:set LK_API_KEY
# pega el valor "APIxxxxxxxxxxxx"

firebase functions:secrets:set LK_API_SECRET
# pega el valor "xxxxxxxxxxxxxxxx..."

firebase functions:secrets:set LK_HOST
# pega: wss://livekit.tu-dominio.com
```

Estos secrets los consume la Cloud Function `getLiveKitToken` que se crea en Fase 3.

---

## Paso 9: Probar el server con un cliente "tonto"

Antes de tocar Flutter, verificá que el server acepta una conexión real con `livekit-cli` (el client oficial CLI):

```bash
# En tu laptop
brew install livekit/tap/livekit-cli   # macOS
# o curl -sSL https://get.livekit.io/cli | bash  # Linux

# Generar token (requiere API key/secret)
livekit-cli create-token \
  --api-key APIxxxxxxxx --api-secret xxxxxxxxxx \
  --room test-room --identity tester \
  --join

# Conectar
livekit-cli join-room \
  --url wss://livekit.tu-dominio.com \
  --api-key APIxxxxxxxx --api-secret xxxxxxxxxx \
  --identity tester --room test-room
```

Si conecta sin errores, el server está listo para Fase 3.

---

## Troubleshooting

| Síntoma | Causa probable | Fix |
|---|---|---|
| `wss://` da `connection refused` | Security List Oracle o iptables | Ver Pasos 1-2 |
| `wss://` conecta pero el audio no llega | Puerto UDP no abierto (Oracle o iptables) | Pasos 1-2, sección UDP |
| LiveKit log: `failed to detect external IP` | `use_external_ip: true` no funciona en Oracle por NAT | Agregar `rtc.node_ip: "<IP-público>"` en livekit.yaml |
| Certbot falla con `Connection refused` | Puerto 80 no abierto | Paso 1 + Paso 2 (puerto 80) |
| Cert renovación falla | nginx no reload tras renovación | Agregar `--deploy-hook "systemctl reload nginx"` al timer |
| Container muere apenas arranca | API key/secret mal formateado en yaml | Verificar que no haya espacios extra; key debe empezar con `API` |
| Audio se corta cada minuto | nginx `proxy_read_timeout` default 60s | Verificar Paso 6 (debe ser `7d`) |

---

## Costos operativos esperados

| Item | Costo |
|---|---|
| Oracle Cloud A1 24GB/4 vCPU | $0 (Free Tier) |
| Egress hasta 10 TB/mes | $0 (Free Tier — gratis) |
| Egress >10 TB/mes | $0.0085/GB ≈ $9 por TB extra |
| Dominio | (ya tenés) |
| Let's Encrypt | $0 |
| **Total para Jipijapa + 5 coops** | **$0/mes** |

Voz Opus a 32 kbps × 100 users × 12h/día × 30 días ≈ **4.2 TB/mes**. Margen amplio bajo el límite de 10 TB free.

---

## Checklist Go/No-Go

- [ ] Security List Oracle: 22, 80, 443, 7881 TCP + 50000-60000 UDP abiertos
- [ ] iptables VM: mismos puertos abiertos antes del REJECT, persistidos
- [ ] DNS A record `livekit.tu-dominio.com` → IP VM, propagado
- [ ] nginx + TLS funcionando (`curl -I https://livekit.tu-dominio.com` → 200)
- [ ] `docker compose ps` muestra livekit en estado `running` con uptime >5min
- [ ] `livekit-cli join-room` conecta exitosamente
- [ ] Secrets `LK_API_KEY`, `LK_API_SECRET`, `LK_HOST` cargados en Firebase
- [ ] Cron de `certbot renew` validado con `--dry-run`

Cuando los 8 puntos estén ✅, arrancamos Fase 3 (cliente Flutter + Cloud Function).
