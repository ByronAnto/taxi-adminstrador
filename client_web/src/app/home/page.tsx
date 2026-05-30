"use client";

import {
  addDoc,
  collection,
  serverTimestamp,
  Timestamp,
} from "firebase/firestore";
import { signOut } from "firebase/auth";
import dynamic from "next/dynamic";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { useAuth, useRequireAuth } from "@/lib/auth";
import { getFirebase } from "@/lib/firebase";

// Google Maps usa `window`, no funciona en SSR. Cargar dinámicamente sin SSR.
const PickupMap = dynamic(() => import("@/components/PickupMap"), {
  ssr: false,
  loading: () => (
    <div className="h-[260px] bg-gray-100 rounded-lg animate-pulse" />
  ),
});

export default function HomePage() {
  const { user, loading } = useRequireAuth();
  const { profile } = useAuth();
  const router = useRouter();

  const [pickupLat, setPickupLat] = useState<number | null>(null);
  const [pickupLng, setPickupLng] = useState<number | null>(null);
  const [pickupAddress, setPickupAddress] = useState("");
  const [destinoTexto, setDestinoTexto] = useState("");
  const [paraCuando, setParaCuando] = useState<string>("");
  const [notas, setNotas] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [okMsg, setOkMsg] = useState<string | null>(null);

  if (loading || !user) {
    return (
      <div className="card text-center">
        <p className="text-gray-600">Cargando…</p>
      </div>
    );
  }

  if (!profile) {
    return (
      <div className="card text-center space-y-3">
        <p>No encontramos tu perfil de cliente.</p>
        <p className="text-sm text-gray-600">
          Si recién creaste la cuenta, vuelve a iniciar sesión.
        </p>
        <button
          onClick={async () => {
            await signOut(getFirebase().auth);
            router.replace("/login");
          }}
          className="btn-primary"
        >
          Cerrar sesión
        </button>
      </div>
    );
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setOkMsg(null);
    if (pickupLat == null || pickupLng == null) {
      setError("Marca el punto de recogida en el mapa.");
      return;
    }
    if (!pickupAddress.trim()) {
      setError("Escribe la referencia del lugar de recogida.");
      return;
    }
    if (!destinoTexto.trim()) {
      setError("Escribe la referencia del destino.");
      return;
    }
    setSubmitting(true);
    try {
      const { db } = getFirebase();
      const now = new Date();
      const cuando = paraCuando ? new Date(paraCuando) : now;
      await addDoc(collection(db, "tripRequests"), {
        associationId: profile!.associationId,
        clienteId: user!.uid,
        clienteNombre: profile!.name,
        clienteTelefono: profile!.phone,
        origen: {
          lat: pickupLat,
          lng: pickupLng,
          address: pickupAddress.trim(),
        },
        destinoTexto: destinoTexto.trim(),
        cuandoSolicitado: serverTimestamp(),
        paraCuando: Timestamp.fromDate(cuando),
        estado: "pendiente",
        notas: notas.trim().length === 0 ? null : notas.trim(),
        createdAt: serverTimestamp(),
      });
      setOkMsg(
        "¡Tu pedido se envió! La operadora te asignará una unidad en breve.",
      );
      setPickupAddress("");
      setDestinoTexto("");
      setNotas("");
      setParaCuando("");
      // Redirigir a "Mis carreras" para que el cliente vea el estado en vivo.
      // Pequeño delay para que alcance a ver el mensaje verde de confirmación.
      // Mantenemos `submitting` en true hasta navegar, así no se puede reenviar.
      setTimeout(() => router.push("/mis-carreras"), 800);
    } catch (e: any) {
      setError(e?.message ?? "Error al enviar el pedido.");
      setSubmitting(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="card">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h1 className="text-xl font-bold text-primary">Pedir taxi</h1>
            <p className="text-sm text-gray-600">Hola, {profile.name}</p>
          </div>
          <button
            onClick={async () => {
              await signOut(getFirebase().auth);
              router.replace("/login");
            }}
            className="text-sm text-gray-600 hover:text-red-600"
          >
            Salir
          </button>
        </div>

        <form onSubmit={onSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1">
              Punto exacto de recogida *
            </label>
            <PickupMap
              onChange={(lat, lng) => {
                setPickupLat(lat);
                setPickupLng(lng);
              }}
            />
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">
              Referencia del lugar de recogida *
            </label>
            <input
              type="text"
              required
              value={pickupAddress}
              onChange={(e) => setPickupAddress(e.target.value)}
              className="input"
              placeholder="ej. Frente a la farmacia Cruz Azul"
            />
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">
              Destino (referencia) *
            </label>
            <input
              type="text"
              required
              value={destinoTexto}
              onChange={(e) => setDestinoTexto(e.target.value)}
              className="input"
              placeholder="ej. Centro Comercial El Recreo"
            />
            <p className="text-xs text-gray-500 mt-1">
              No necesitamos la dirección exacta, solo una referencia.
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">
              ¿Cuándo? <span className="text-gray-500">(opcional)</span>
            </label>
            <input
              type="datetime-local"
              value={paraCuando}
              onChange={(e) => setParaCuando(e.target.value)}
              className="input"
            />
            <p className="text-xs text-gray-500 mt-1">
              Si lo dejas vacío, se solicita inmediatamente.
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium mb-1">
              Notas <span className="text-gray-500">(opcional)</span>
            </label>
            <textarea
              value={notas}
              onChange={(e) => setNotas(e.target.value)}
              className="input"
              rows={2}
              placeholder="ej. Llevo equipaje grande"
            />
          </div>

          {error && (
            <div className="bg-red-50 border border-red-200 text-red-800 text-sm rounded p-2">
              {error}
            </div>
          )}
          {okMsg && (
            <div className="bg-green-50 border border-green-200 text-green-800 text-sm rounded p-2">
              {okMsg}
            </div>
          )}

          <button type="submit" disabled={submitting} className="btn-primary">
            {submitting ? "Enviando…" : "Pedir taxi"}
          </button>
        </form>
      </div>

      <div className="text-center">
        <Link
          href="/mis-carreras"
          className="inline-block text-primary hover:underline font-medium"
        >
          Ver mis carreras →
        </Link>
      </div>
    </div>
  );
}
