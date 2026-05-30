# LiveKit — servidor RTC (reemplazo de Agora)

Servidor [LiveKit](https://livekit.io) open-source (Apache 2.0) para el audio en tiempo
real de la app taxis (push-to-talk despachador ↔ conductores), reemplazando a Agora.

## Dónde corre

VM en **Oracle Cloud** (región Colombia Central - Bogotá):

- Acceso SSH: alias `sshoracle` (`ubuntu@149.130.183.24`)
- Ubuntu 24.04 LTS · ARM64 (aarch64) · 4 vCPU · 23 GB RAM
- Docker Engine + Compose (plugin)
- Despliegue en la VM: `~/livekit/`

## Archivos

| Archivo | Descripción |
|---------|-------------|
| `docker-compose.yaml` | Servicios `livekit-server` + `caddy` (host networking, restart unless-stopped) |
| `livekit.yaml.example` | Plantilla de config. Copiar a `livekit.yaml` y poner las keys reales |
| `Caddyfile` | Reverse proxy TLS (termina HTTPS en :443, reenvía a LiveKit :7880) |
| `.gitignore` | Excluye `livekit.yaml` y `.livekit_keys` (contienen secretos) |

## Puesta en marcha (en la VM)

```bash
sshoracle
cd ~/livekit                 # o donde clones este deploy/
cp livekit.yaml.example livekit.yaml
# generar y pegar las keys:
echo "API_KEY=API$(openssl rand -hex 6)"
echo "API_SECRET=$(openssl rand -base64 32)"
# editar livekit.yaml con esas keys, luego:
sudo docker compose up -d
sudo docker compose logs -f
```

## Puertos

| Puerto | Proto | Uso |
|--------|-------|-----|
| 80   | TCP | ACME (Let's Encrypt) + redirección a HTTPS |
| 443  | TCP | HTTPS / **wss://** (señalización segura, via Caddy) |
| 7880 | TCP | Señalización LiveKit (interno; expuesto via Caddy) |
| 7881 | TCP | WebRTC sobre TCP (fallback) |
| 7882 | UDP | Media de audio/video (WebRTC) |

Hay **dos firewalls** que abrir:

1. **iptables local** de la VM (insertar ACCEPT antes del REJECT y persistir con
   `netfilter-persistent save`).
2. **Security List de Oracle Cloud** (consola web): ingress `0.0.0.0/0`, TCP `80`,
   `443`, `7880-7881` y UDP `7882`, con **Source Port Range vacío (= All)**.

## TLS / dominio

- DNS: `livekit.it-services.center` → A → `149.130.183.24`
- Caddy emite y renueva el certificado Let's Encrypt automáticamente (reto HTTP-01 en :80).
- Para agregar más subdominios, añadir un bloque al `Caddyfile` y recargar
  (`docker compose restart caddy`).

## Conexión desde la app Flutter

```
URL (producción): wss://livekit.it-services.center
```

Las credenciales (API key/secret) están en la VM en `~/livekit/.livekit_keys`
(no se versionan).
