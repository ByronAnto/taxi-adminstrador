"use client";

// =====================================================================
//  PickupMap — selector del "Punto exacto de recogida".
//
//  Proveedor de mapas: Google Maps JavaScript API (mismo que la app
//  Flutter). Se carga con @react-google-maps/api.
//
//  La API key viene de la variable de entorno pública
//  NEXT_PUBLIC_GOOGLE_MAPS_API_KEY. Por ser NEXT_PUBLIC_* se inlinea
//  en build-time; en Docker/CI se inyecta como build-arg + ENV (ver
//  Dockerfile). Sin key, el componente degrada con un mensaje claro
//  ("Mapa no disponible") en vez de romper el build/render.
//
//  Google Cloud: debe estar habilitada "Maps JavaScript API" y la key
//  debe ser de tipo "browser" restringida al dominio de producción
//  (taxiseguro.it-services.center).
// =====================================================================

import { useCallback, useEffect, useRef, useState } from "react";
import { GoogleMap, MarkerF, useJsApiLoader } from "@react-google-maps/api";

interface Props {
  initialLat?: number;
  initialLng?: number;
  onChange: (lat: number, lng: number) => void;
}

// Quito, Ecuador — fallback idéntico al de la app Flutter.
const QUITO_CENTER = { lat: -0.1807, lng: -78.4678 };

const MAP_API_KEY = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY ?? "";

const CONTAINER_STYLE = { height: "260px", width: "100%" };

type GeoStatus = "idle" | "locating" | "ok" | "denied" | "unavailable";

type LatLng = { lat: number; lng: number };

export default function PickupMap({ initialLat, initialLng, onChange }: Props) {
  const { isLoaded, loadError } = useJsApiLoader({
    id: "taxiseguro-google-maps",
    googleMapsApiKey: MAP_API_KEY,
  });

  const [pos, setPos] = useState<LatLng | null>(
    initialLat != null && initialLng != null
      ? { lat: initialLat, lng: initialLng }
      : null,
  );
  const [status, setStatus] = useState<GeoStatus>("idle");

  // onChange puede no ser estable; usamos ref para evitar re-disparos.
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  // Referencia al mapa para poder centrar/animar desde el botón 📍.
  const mapRef = useRef<google.maps.Map | null>(null);

  const setPoint = useCallback((p: LatLng, pan = false) => {
    setPos(p);
    onChangeRef.current(p.lat, p.lng);
    if (pan && mapRef.current) {
      mapRef.current.panTo(p);
      mapRef.current.setZoom(17);
    }
  }, []);

  const requestLocation = useCallback(
    (animate = false) => {
      if (typeof window === "undefined") return;
      if (!("geolocation" in navigator)) {
        setStatus("unavailable");
        return;
      }
      if (!window.isSecureContext) {
        // HTTPS o localhost requerido por todos los navegadores.
        setStatus("unavailable");
        return;
      }
      setStatus("locating");
      navigator.geolocation.getCurrentPosition(
        (p) => {
          setPoint(
            { lat: p.coords.latitude, lng: p.coords.longitude },
            animate,
          );
          setStatus("ok");
        },
        (err) => {
          if (err.code === err.PERMISSION_DENIED) {
            setStatus("denied");
          } else {
            setStatus("unavailable");
          }
          setPos((prev) => {
            if (prev) return prev;
            onChangeRef.current(QUITO_CENTER.lat, QUITO_CENTER.lng);
            return QUITO_CENTER;
          });
        },
        { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 },
      );
    },
    [setPoint],
  );

  useEffect(() => {
    // Pedimos geo al montar SOLO si no hay pos inicial.
    if (pos) return;
    requestLocation(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const center = pos ?? QUITO_CENTER;

  // ---- Degradación: sin key o error al cargar Google Maps ----------
  if (!MAP_API_KEY || loadError) {
    return (
      <div className="rounded-lg overflow-hidden border border-gray-300">
        <div className="h-[260px] flex flex-col items-center justify-center bg-gray-100 text-center px-4 gap-1">
          <span className="text-2xl">🗺️</span>
          <p className="text-sm font-medium text-gray-700">
            Mapa no disponible
          </p>
          <p className="text-xs text-gray-500">
            {loadError
              ? "No se pudo cargar Google Maps."
              : "Falta configurar la clave de Google Maps."}{" "}
            Escribe abajo la referencia del lugar de recogida.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="rounded-lg overflow-hidden border border-gray-300 relative">
      {isLoaded ? (
        <GoogleMap
          mapContainerStyle={CONTAINER_STYLE}
          center={center}
          zoom={16}
          onLoad={(map) => {
            mapRef.current = map;
          }}
          onUnmount={() => {
            mapRef.current = null;
          }}
          onClick={(e) => {
            if (e.latLng) {
              setPoint({ lat: e.latLng.lat(), lng: e.latLng.lng() });
            }
          }}
          options={{
            disableDefaultUI: true,
            zoomControl: true,
            clickableIcons: false,
            gestureHandling: "greedy",
            streetViewControl: false,
            mapTypeControl: false,
            fullscreenControl: false,
          }}
        >
          {pos && (
            <MarkerF
              position={pos}
              draggable
              onDragEnd={(e) => {
                if (e.latLng) {
                  setPoint({ lat: e.latLng.lat(), lng: e.latLng.lng() });
                }
              }}
            />
          )}
        </GoogleMap>
      ) : (
        <div className="h-[260px] bg-gray-100 animate-pulse" />
      )}

      <button
        type="button"
        aria-label="Usar mi ubicación actual"
        onClick={() => requestLocation(true)}
        className="absolute top-2 right-2 z-[400] bg-white shadow-md rounded-full w-10 h-10 flex items-center justify-center hover:bg-gray-100 active:scale-95 transition border border-gray-200"
      >
        {status === "locating" ? (
          <svg
            className="animate-spin h-5 w-5 text-primary"
            viewBox="0 0 24 24"
            fill="none"
          >
            <circle
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              strokeWidth="3"
              opacity="0.25"
            />
            <path
              d="M22 12a10 10 0 0 1-10 10"
              stroke="currentColor"
              strokeWidth="3"
              strokeLinecap="round"
            />
          </svg>
        ) : (
          <span className="text-xl leading-none">📍</span>
        )}
      </button>

      <div className={`px-3 py-2 text-xs border-t ${statusBg(status)}`}>
        {statusMessage(status)}
      </div>
    </div>
  );
}

function statusMessage(s: GeoStatus): string {
  switch (s) {
    case "locating":
      return "📡 Buscando tu ubicación…";
    case "ok":
      return "Toca o arrastra el marcador para ajustar el punto exacto donde te vamos a recoger.";
    case "denied":
      return "No diste permiso de ubicación. Toca el botón 📍 arriba a la derecha y permite la ubicación, o toca el mapa para fijar el punto.";
    case "unavailable":
      return "Tu dispositivo o navegador no soporta ubicación. Toca el mapa donde estás para fijar el punto de recogida.";
    case "idle":
    default:
      return "Toca el mapa para fijar el punto de recogida.";
  }
}

function statusBg(s: GeoStatus): string {
  switch (s) {
    case "denied":
    case "unavailable":
      return "bg-red-50 text-red-900 border-red-200";
    case "locating":
      return "bg-blue-50 text-blue-900 border-blue-200";
    default:
      return "bg-amber-50 text-amber-900 border-amber-200";
  }
}
