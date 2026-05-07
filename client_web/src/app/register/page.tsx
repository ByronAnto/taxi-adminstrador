"use client";

import { createUserWithEmailAndPassword } from "firebase/auth";
import {
  collection,
  doc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  where,
} from "firebase/firestore";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useState } from "react";
import { getFirebase } from "@/lib/firebase";

interface AssociationOption {
  id: string;
  name: string;
  city: string;
}

export default function RegisterPage() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [associationId, setAssociationId] = useState("");
  const [associations, setAssociations] = useState<AssociationOption[]>([]);
  const [loadingAssoc, setLoadingAssoc] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    async function load() {
      try {
        const { db } = getFirebase();
        // Solo asociaciones activas (no expiradas/canceladas).
        const q = query(
          collection(db, "associations"),
          where("status", "in", ["active", "trial"]),
        );
        const snap = await getDocs(q);
        const list: AssociationOption[] = snap.docs.map((d) => ({
          id: d.id,
          name: (d.data().name as string) ?? d.id,
          city: (d.data().city as string) ?? "",
        }));
        list.sort((a, b) => a.name.localeCompare(b.name));
        setAssociations(list);
      } catch (e) {
        // Si fallan las reglas / no hay datos, dejamos lista vacía.
        setAssociations([]);
      } finally {
        setLoadingAssoc(false);
      }
    }
    load();
  }, []);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (!associationId) {
      setError("Selecciona tu grupo de confianza.");
      return;
    }
    setLoading(true);
    try {
      const { auth, db } = getFirebase();
      const cred = await createUserWithEmailAndPassword(
        auth,
        email.trim(),
        password,
      );
      // Crear doc clients/{uid} con datos del cliente.
      await setDoc(doc(db, "clients", cred.user.uid), {
        name: name.trim(),
        phone: phone.trim(),
        email: email.trim(),
        associationId,
        createdAt: serverTimestamp(),
      });
      router.replace("/home");
    } catch (e: any) {
      setError(traduce(e?.code ?? e?.message ?? "Error al registrarse"));
      setLoading(false);
    }
  }

  return (
    <div className="card">
      <div className="text-center mb-6">
        <div className="text-3xl mb-1">🚕</div>
        <h1 className="text-xl font-bold text-primary">Crear cuenta</h1>
        <p className="text-sm text-gray-600">
          Únete a tu cooperativa de taxi de confianza.
        </p>
      </div>
      <form onSubmit={onSubmit} className="space-y-3">
        <div>
          <label className="block text-sm font-medium mb-1">Nombre completo *</label>
          <input
            type="text"
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="input"
            autoComplete="name"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Teléfono *</label>
          <input
            type="tel"
            required
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            className="input"
            autoComplete="tel"
            placeholder="09XXXXXXXX"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">
            Tu grupo de confianza *
          </label>
          <select
            required
            value={associationId}
            onChange={(e) => setAssociationId(e.target.value)}
            className="input bg-white"
            disabled={loadingAssoc}
          >
            <option value="">
              {loadingAssoc ? "Cargando…" : "Selecciona una cooperativa"}
            </option>
            {associations.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name}
                {a.city ? ` · ${a.city}` : ""}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Correo *</label>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="input"
            autoComplete="email"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">
            Contraseña * <span className="text-gray-500">(mínimo 6)</span>
          </label>
          <input
            type="password"
            required
            minLength={6}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="input"
            autoComplete="new-password"
          />
        </div>
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-800 text-sm rounded p-2">
            {error}
          </div>
        )}
        <button type="submit" disabled={loading} className="btn-primary">
          {loading ? "Creando…" : "Crear cuenta"}
        </button>
      </form>
      <div className="mt-4 text-center text-sm">
        ¿Ya tienes cuenta?{" "}
        <Link href="/login" className="text-primary hover:underline font-medium">
          Inicia sesión
        </Link>
      </div>
    </div>
  );
}

function traduce(code: string): string {
  if (code.includes("email-already-in-use")) {
    return "Ese correo ya está registrado.";
  }
  if (code.includes("invalid-email")) return "Correo no válido.";
  if (code.includes("weak-password")) {
    return "La contraseña debe tener al menos 6 caracteres.";
  }
  if (code.includes("network")) return "Sin conexión a internet.";
  return code;
}
