"use client";

import "leaflet/dist/leaflet.css";
import L from "leaflet";
import { useEffect, useState } from "react";
import {
  MapContainer,
  Marker,
  TileLayer,
  useMap,
  useMapEvents,
} from "react-leaflet";

// Fix iconos Leaflet en Next (los assets default no resuelven bien con Webpack).
const icon = L.icon({
  iconUrl:
    "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
  iconRetinaUrl:
    "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
  shadowUrl:
    "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
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

export default function PickupMap({
  initialLat,
  initialLng,
  onChange,
}: Props) {
  const [pos, setPos] = useState<[number, number] | null>(
    initialLat != null && initialLng != null ? [initialLat, initialLng] : null,
  );

  // Pedir geolocalización al montar para centrar en el usuario.
  useEffect(() => {
    if (pos) return;
    if (typeof navigator === "undefined" || !navigator.geolocation) return;
    navigator.geolocation.getCurrentPosition(
      (p) => {
        const point: [number, number] = [p.coords.latitude, p.coords.longitude];
        setPos(point);
        onChange(point[0], point[1]);
      },
      () => {
        // Si el usuario niega la geolocalización, dejamos el centro de Quito.
        setPos(QUITO_CENTER);
        onChange(QUITO_CENTER[0], QUITO_CENTER[1]);
      },
      { timeout: 5000 },
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const center = pos ?? QUITO_CENTER;

  return (
    <div className="rounded-lg overflow-hidden border border-gray-300">
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
            onChange(lat, lng);
          }}
        />
        {pos && <Marker position={pos} icon={icon} />}
      </MapContainer>
      <div className="bg-amber-50 px-3 py-2 text-xs text-amber-900 border-t border-amber-200">
        Toca el mapa para mover el punto exacto donde te vamos a recoger.
      </div>
    </div>
  );
}

function Recenter({ center }: { center: [number, number] }) {
  const map = useMap();
  useEffect(() => {
    map.setView(center);
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
