"use client";

import {
  collection,
  doc,
  onSnapshot,
  orderBy,
  query,
  serverTimestamp,
  updateDoc,
  where,
} from "firebase/firestore";
import Link from "next/link";
import { useEffect, useState } from "react";
import { useAuth, useRequireAuth } from "@/lib/auth";
import { getFirebase } from "@/lib/firebase";

interface TripRequest {
  id: string;
  estado: string;
  origen: { address?: string } | null;
  destinoTexto: string | null;
  cuandoSolicitado: Date | null;
  paraCuando: Date | null;
  asignadoA: string | null;
  conductorNombre: string | null;
  conductorVehiculo: string | null;
  notas: string | null;
  rating: number | null;
  ratingComment: string | null;
  ratedAt: Date | null;
}

export default function MyTripsPage() {
  const { user, loading } = useRequireAuth();
  useAuth();
  const [items, setItems] = useState<TripRequest[]>([]);
  const [listLoading, setListLoading] = useState(true);

  useEffect(() => {
    if (!user) return;
    const { db } = getFirebase();
    const q = query(
      collection(db, "tripRequests"),
      where("clienteId", "==", user.uid),
      orderBy("cuandoSolicitado", "desc"),
    );
    const unsub = onSnapshot(q, (snap) => {
      const list = snap.docs.map((d) => {
        const x = d.data();
        return {
          id: d.id,
          estado: (x.estado as string) ?? "pendiente",
          origen: x.origen ?? null,
          destinoTexto: (x.destinoTexto as string) ?? null,
          cuandoSolicitado: x.cuandoSolicitado?.toDate?.() ?? null,
          paraCuando: x.paraCuando?.toDate?.() ?? null,
          asignadoA: (x.asignadoA as string) ?? null,
          conductorNombre: (x.conductorNombre as string) ?? null,
          conductorVehiculo: (x.conductorVehiculo as string) ?? null,
          notas: (x.notas as string) ?? null,
          rating: typeof x.rating === "number" ? (x.rating as number) : null,
          ratingComment: (x.ratingComment as string) ?? null,
          ratedAt: x.ratedAt?.toDate?.() ?? null,
        } as TripRequest;
      });
      setItems(list);
      setListLoading(false);
    });
    return () => unsub();
  }, [user]);

  if (loading || !user) {
    return (
      <div className="card text-center">
        <p className="text-gray-600">Cargando…</p>
      </div>
    );
  }

  async function cancel(id: string) {
    if (!confirm("¿Cancelar esta solicitud?")) return;
    const { db } = getFirebase();
    await updateDoc(doc(db, "tripRequests", id), {
      estado: "cancelada",
      updatedAt: serverTimestamp(),
    });
  }

  return (
    <div className="card space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-primary">Mis carreras</h1>
        <Link href="/home" className="text-sm text-primary hover:underline">
          ← Pedir nueva
        </Link>
      </div>

      {listLoading ? (
        <p className="text-gray-500 text-center py-4">Cargando…</p>
      ) : items.length === 0 ? (
        <p className="text-gray-500 text-center py-8">
          Aún no has pedido ningún taxi.
        </p>
      ) : (
        <ul className="space-y-3">
          {items.map((t) => (
            <li
              key={t.id}
              className="border border-gray-200 rounded-lg p-3 bg-gray-50"
            >
              <div className="flex justify-between items-start gap-2 mb-1">
                <span className={badgeClass(t.estado)}>
                  {labelEstado(t.estado)}
                </span>
                <span className="text-xs text-gray-500">
                  {t.cuandoSolicitado
                    ? new Intl.DateTimeFormat("es-EC", {
                        day: "2-digit",
                        month: "short",
                        hour: "2-digit",
                        minute: "2-digit",
                      }).format(t.cuandoSolicitado)
                    : ""}
                </span>
              </div>
              <p className="text-sm">
                <span className="font-medium">📍 De:</span>{" "}
                {t.origen?.address || "(sin referencia)"}
              </p>
              <p className="text-sm">
                <span className="font-medium">🏁 A:</span>{" "}
                {t.destinoTexto || "(sin destino)"}
              </p>
              {t.notas && (
                <p className="text-sm text-gray-700 italic">
                  📝 {t.notas}
                </p>
              )}

              {/* Estado de asignación: se actualiza en vivo vía onSnapshot */}
              {t.estado === "pendiente" && (
                <div className="mt-2 bg-yellow-50 border border-yellow-200 text-yellow-900 text-sm rounded-md p-2">
                  🔎 Buscando unidad… la operadora te asignará un taxi en breve.
                </div>
              )}
              {t.estado === "asignada" && (
                <div className="mt-2 bg-green-50 border border-green-200 text-green-900 text-sm rounded-md p-2">
                  <p className="font-semibold">✅ Taxi asignado</p>
                  {(t.conductorNombre || t.conductorVehiculo) && (
                    <p className="mt-0.5">
                      {t.conductorNombre && (
                        <>
                          <span className="font-medium">Conductor:</span>{" "}
                          {t.conductorNombre}
                        </>
                      )}
                      {t.conductorNombre && t.conductorVehiculo && " · "}
                      {t.conductorVehiculo && (
                        <>
                          <span className="font-medium">Vehículo:</span>{" "}
                          {t.conductorVehiculo}
                        </>
                      )}
                    </p>
                  )}
                </div>
              )}
              {t.estado === "cancelada" && (
                <div className="mt-2 bg-gray-100 border border-gray-200 text-gray-700 text-sm rounded-md p-2">
                  Carrera cancelada
                </div>
              )}

              {t.estado === "pendiente" && (
                <button
                  onClick={() => cancel(t.id)}
                  className="mt-2 text-xs text-red-600 hover:underline"
                >
                  Cancelar
                </button>
              )}
              {t.estado === "finalizada" && (
                <RateTrip
                  id={t.id}
                  rating={t.rating}
                  ratingComment={t.ratingComment}
                />
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function labelEstado(e: string): string {
  switch (e) {
    case "pendiente":
      return "Pendiente";
    case "asignada":
      return "Asignada";
    case "rechazada":
      return "Rechazada";
    case "finalizada":
    case "cumplida":
      return "Completada";
    case "cancelada":
      return "Cancelada";
    default:
      return e;
  }
}

function badgeClass(e: string): string {
  const base =
    "inline-block px-2 py-0.5 text-xs font-semibold rounded ";
  switch (e) {
    case "pendiente":
      return base + "bg-amber-100 text-amber-900";
    case "asignada":
      return base + "bg-blue-100 text-blue-900";
    case "finalizada":
    case "cumplida":
      return base + "bg-green-100 text-green-900";
    case "rechazada":
    case "cancelada":
      return base + "bg-gray-200 text-gray-700";
    default:
      return base + "bg-gray-100 text-gray-700";
  }
}

function RateTrip({
  id,
  rating,
  ratingComment,
}: {
  id: string;
  rating: number | null;
  ratingComment: string | null;
}) {
  const [stars, setStars] = useState(0);
  const [hover, setHover] = useState(0);
  const [comment, setComment] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  // Ya calificada (desde Firestore) o recién guardada: modo lectura.
  if (rating != null || done) {
    const shown = rating ?? stars;
    const shownComment = rating != null ? ratingComment : comment.trim() || null;
    return (
      <div className="mt-2 border-t border-gray-200 pt-2">
        <p className="text-sm text-gray-700">
          <span className="font-medium">Calificaste:</span>{" "}
          <span className="text-amber-500" aria-label={`${shown} de 5 estrellas`}>
            {"★".repeat(shown)}
            <span className="text-gray-300">{"☆".repeat(5 - shown)}</span>
          </span>
        </p>
        {shownComment && (
          <p className="text-sm text-gray-700 italic">“{shownComment}”</p>
        )}
      </div>
    );
  }

  async function submit() {
    if (stars < 1 || stars > 5) {
      setError("Selecciona de 1 a 5 estrellas.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const { db } = getFirebase();
      await updateDoc(doc(db, "tripRequests", id), {
        rating: stars,
        ratingComment: comment.trim() ? comment.trim() : null,
        ratedAt: serverTimestamp(),
      });
      setDone(true);
    } catch (e) {
      setError(
        e instanceof Error
          ? `No se pudo guardar tu calificación: ${e.message}`
          : "No se pudo guardar tu calificación.",
      );
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mt-2 border-t border-gray-200 pt-2 space-y-2">
      <p className="text-sm font-medium text-gray-700">
        ¿Cómo estuvo tu carrera?
      </p>
      <div className="flex gap-1" role="radiogroup" aria-label="Calificación">
        {[1, 2, 3, 4, 5].map((n) => (
          <button
            key={n}
            type="button"
            disabled={saving}
            onClick={() => setStars(n)}
            onMouseEnter={() => setHover(n)}
            onMouseLeave={() => setHover(0)}
            aria-label={`${n} estrella${n > 1 ? "s" : ""}`}
            aria-checked={stars === n}
            role="radio"
            className={`text-2xl leading-none transition-colors ${
              (hover || stars) >= n ? "text-amber-500" : "text-gray-300"
            } hover:text-amber-500 disabled:opacity-50`}
          >
            ★
          </button>
        ))}
      </div>
      <textarea
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        disabled={saving}
        rows={2}
        placeholder="Comentario (opcional)"
        className="w-full text-sm border border-gray-300 rounded-md p-2 focus:outline-none focus:ring-1 focus:ring-primary disabled:opacity-50"
      />
      {error && (
        <div className="bg-red-50 text-red-700 text-sm rounded-md p-2">
          {error}
        </div>
      )}
      <button
        type="button"
        onClick={submit}
        disabled={saving || stars < 1}
        className="text-sm bg-primary text-white px-3 py-1.5 rounded-md hover:opacity-90 disabled:opacity-50"
      >
        {saving ? "Enviando…" : "Calificar"}
      </button>
    </div>
  );
}
