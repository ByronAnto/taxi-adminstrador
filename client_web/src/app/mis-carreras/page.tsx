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
  notas: string | null;
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
          notas: (x.notas as string) ?? null,
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
              {t.estado === "pendiente" && (
                <button
                  onClick={() => cancel(t.id)}
                  className="mt-2 text-xs text-red-600 hover:underline"
                >
                  Cancelar
                </button>
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
    case "cumplida":
      return base + "bg-green-100 text-green-900";
    case "rechazada":
    case "cancelada":
      return base + "bg-gray-200 text-gray-700";
    default:
      return base + "bg-gray-100 text-gray-700";
  }
}
