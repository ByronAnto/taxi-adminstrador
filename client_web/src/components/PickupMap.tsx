"use client";

import "leaflet/dist/leaflet.css";
import L from "leaflet";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  MapContainer,
  Marker,
  TileLayer,
  useMap,
  useMapEvents,
} from "react-leaflet";

const icon = L.icon({
  iconUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
  iconRetinaUrl:
    "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
  shadowUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
  iconSize: [25, 41],
  iconAnchor: [12, 41],
  popupAnchor: [1, -34],
  shadowSize: [41, 41],
});

interface Props {
  initialLat?: number;
  initialLng?: number;
  onChange: (lat: number, lng: number) => void;
}

const QUITO_CENTER: [number, number] = [-0.1807, -78.4678];

type GeoStatus = "idle" | "locating" | "ok" | "denied" | "unavailable";

export default function PickupMap({
  initialLat,
  initialLng,
  onChange,
}: Props) {
  const [pos, setPos] = useState<[number, number] | null>(
    initialLat != null && initialLng != null ? [initialLat, initialLng] : null,
  );
  const [status, setStatus] = useState<GeoStatus>("idle");
  // onChange puede no ser estable; usamos ref para evitar re-disparos del effect.
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  const requestLocation = useCallback((animate = false) => {
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
        const point: [number, number] = [
          p.coords.latitude,
          p.coords.longitude,
        ];
        setPos(point);
        onChangeRef.current(point[0], point[1]);
        setStatus("ok");
        if (animate && (window as any).__pickupMap) {
          (window as any).__pickupMap.flyTo(point, 17, { duration: 0.8 });
        }
      },
      (err) => {
        if (err.code === err.PERMISSION_DENIED) {
          setStatus("denied");
        } else {
          setStatus("unavailable");
        }
        if (!pos) {
          setPos(QUITO_CENTER);
          onChangeRef.current(QUITO_CENTER[0], QUITO_CENTER[1]);
        }
      },
      {
        enableHighAccuracy: true,
        timeout: 10000,
        maximumAge: 0,
      },
    );
  }, [pos]);

  useEffect(() => {
    // Pedimos geo al montar SOLO si no hay pos inicial.
    if (pos) return;
    requestLocation(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const center = pos ?? QUITO_CENTER;

  return (
    <div className="rounded-lg overflow-hidden border border-gray-300 relative">
      <MapContainer
        center={center}
        zoom={16}
        style={{ height: "260px", width: "100%" }}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{y}/{x}.png"
        />
        <Recenter center={center} />
        <ClickHandler
          onClick={(lat, lng) => {
            setPos([lat, lng]);
            onChangeRef.current(lat, lng);
          }}
        />
        {pos && <Marker position={pos} icon={icon} />}
      </MapContainer>

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

      <div
        className={`px-3 py-2 text-xs border-t ${statusBg(status)}`}
      >
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
      return "Toca el mapa si quieres ajustar el punto exacto donde te vamos a recoger.";
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

function Recenter({ center }: { center: [number, number] }) {
  const map = useMap();
  useEffect(() => {
    map.setView(center);
    // Exponemos referencia para flyTo desde el botón externo.
    (window as any).__pickupMap = map;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [center[0], center[1]]);
  return null;
}

function ClickHandler({
  onClick,
}: {
  onClick: (lat: number, lng: number) => void;
}) {
  useMapEvents({
    click(e) {
      onClick(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}
