# Taxis App — Portal del cliente

Web simple para que un pasajero pida un taxi a la **cooperativa de su
confianza** (asociación). La operadora ve el pedido en la app móvil
(Flutter) y le asigna una unidad.

## ¿Cómo se conecta con la app móvil de la operadora/admin?

Comparten **el mismo proyecto Firebase** (`taxis-f0f51`). Las bases de
datos son las mismas: misma `Auth`, misma `Firestore`, mismo `Storage`.

Cuando un cliente envía un pedido desde esta web:

1. Se crea un doc en `tripRequests/{}` con:
   - `clienteId`, `clienteNombre`, `clienteTelefono`, `associationId`
   - `origen { lat, lng, address }` ← punto exacto del mapa
   - `destinoTexto` ← solo referencia textual (no requiere coordenadas)
   - `paraCuando` (timestamp; si vacío, ahora)
   - `estado: 'pendiente'`
2. La operadora abre la app Flutter → **Solicitudes de carrera** →
   ve el pedido → tap **Asignar** → elige una unidad de su asociación.
3. El estado pasa a `asignada` y el cliente lo ve en tiempo real en
   "Mis carreras".

## Stack

- **Next.js 14** (App Router) + TypeScript
- **Tailwind CSS** (mobile-first, responsive)
- **Firebase Web SDK 10** (Auth + Firestore)
- **react-leaflet** + OpenStreetMap (mapa libre, sin API key)
- **Docker** multi-stage para deploy
- **GitHub Actions** para build + push a `ghcr.io`

## Páginas

| Ruta | Descripción |
|---|---|
| `/login` | Email + contraseña |
| `/register` | Registro: nombre, teléfono, **selector de cooperativa**, email, contraseña |
| `/recover` | Reset de contraseña por email |
| `/home` | Formulario de pedido + mapa de recogida |
| `/mis-carreras` | Historial en tiempo real, opción de cancelar pendientes |

## Configuración

1. Copia `.env.local.example` a `.env.local`.
2. Rellena los valores desde Firebase Console → Configuración del
   proyecto → "Tus apps" → SDK web. Son los mismos valores que usa la
   app Flutter (proyecto `taxis-f0f51`).

```bash
NEXT_PUBLIC_FIREBASE_API_KEY=AIza...
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=taxis-f0f51.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=taxis-f0f51
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=taxis-f0f51.appspot.com
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=1043852093355
NEXT_PUBLIC_FIREBASE_APP_ID=1:...:web:...
```

## Desarrollo local

```bash
cd client_web
npm install
npm run dev      # http://localhost:3000
```

## Build local

```bash
npm run build
npm run start
```

## Docker

```bash
# Build (las vars NEXT_PUBLIC_* se inyectan al build)
docker build -t taxis-client-web \
  --build-arg NEXT_PUBLIC_FIREBASE_API_KEY="..." \
  --build-arg NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN="taxis-f0f51.firebaseapp.com" \
  --build-arg NEXT_PUBLIC_FIREBASE_PROJECT_ID="taxis-f0f51" \
  --build-arg NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET="taxis-f0f51.appspot.com" \
  --build-arg NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID="..." \
  --build-arg NEXT_PUBLIC_FIREBASE_APP_ID="..." .

# Run
docker run -p 3000:3000 taxis-client-web
```

## CI/CD (GitHub Actions)

El workflow `.github/workflows/deploy-client-web.yml`:

1. Se dispara con cada `push a main` que toque `client_web/**`.
2. Hace `npm ci` y verifica lint.
3. Construye la imagen Docker con los secrets como build-args.
4. Publica en **GitHub Container Registry** (`ghcr.io/<owner>/<repo>/client-web:latest`).

### Secrets que tienes que configurar

GitHub → Repo → **Settings → Secrets and variables → Actions**:

| Secret | De dónde sacarlo |
|---|---|
| `FIREBASE_API_KEY` | Firebase Console → SDK web |
| `FIREBASE_AUTH_DOMAIN` | `taxis-f0f51.firebaseapp.com` |
| `FIREBASE_PROJECT_ID` | `taxis-f0f51` |
| `FIREBASE_STORAGE_BUCKET` | `taxis-f0f51.appspot.com` |
| `FIREBASE_MESSAGING_SENDER_ID` | Firebase Console |
| `FIREBASE_APP_ID` | Firebase Console |

## Deploy de la imagen Docker

Una vez en `ghcr.io`, puedes correrla en:

- **Cloud Run** (Google Cloud, mismo proyecto Firebase, scale-to-zero):
  ```bash
  gcloud run deploy taxis-client-web \
    --image ghcr.io/byronanto/taxi-adminstrador/client-web:latest \
    --region us-central1 \
    --allow-unauthenticated --port 3000
  ```
- **Render**, **Fly.io**, **Railway**: pull de la imagen pública.
- **VPS propio**: `docker pull` + `docker run` con un proxy nginx delante.

## Reglas Firestore necesarias (ya desplegadas)

```
match /tripRequests/{reqId} {
  allow create: if isAuthenticated()
    && request.resource.data.clienteId == request.auth.uid
    && request.resource.data.estado == 'pendiente';
  allow read, update: if isClienteOf(resource.data) || isOperatorOrAdmin();
}
match /clients/{uid} {
  allow read, write: if isOwner(uid) || isOperatorOrAdmin();
}
```

## Notas de diseño

- **Mobile-first**: Tailwind con `max-w-md` centrado. Funciona perfecto
  en celular y se ve bien en escritorio.
- **OpenStreetMap** en lugar de Google Maps: cero costo, cero API key
  adicional. Si en el futuro quieres geocoding de calles, se cambia a
  `@react-google-maps/api` con la misma API key Android.
- **Solo punto de recogida tiene mapa**: el destino es libre por texto
  porque el cliente sabe el lugar y la operadora coordina al chofer
  por radio. Esto simplifica mucho el UX vs Uber/InDriver.
- **No hay precio**: se acuerda con la operadora/conductor por canal
  habitual. La web es solicitud, no marketplace.
