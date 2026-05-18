"use client";

import { httpsCallable } from "firebase/functions";
import Link from "next/link";
import { FormEvent, useState } from "react";
import { getFirebase } from "@/lib/firebase";

export default function RecoverPage() {
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const { functions } = getFirebase();
      // Llamamos a la Cloud Function que envía el correo desde Gmail
      // SMTP propio (mejor entrega que el remitente por defecto de
      // Firebase, que termina en spam).
      const fn = httpsCallable<{ email: string }, { ok: boolean }>(
        functions,
        "sendPasswordResetEmail",
      );
      await fn({ email: email.trim().toLowerCase() });
      setSent(true);
    } catch (e: any) {
      setError(
        e?.message ||
          "Error al enviar el correo. Intenta de nuevo.",
      );
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card">
      <div className="text-center mb-6">
        <div className="text-3xl mb-1">🔑</div>
        <h1 className="text-xl font-bold text-primary">
          Recuperar contraseña
        </h1>
        <p className="text-sm text-gray-600">
          Te enviaremos un enlace al correo registrado.
        </p>
      </div>
      {sent ? (
        <div className="text-center space-y-4">
          <div className="bg-green-50 border border-green-200 text-green-800 rounded p-3">
            Listo. Revisa tu correo (incluso la carpeta de spam).
          </div>
          <Link href="/login" className="btn-primary inline-block">
            Volver a iniciar sesión
          </Link>
        </div>
      ) : (
        <form onSubmit={onSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium mb-1">Correo</label>
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="input"
              autoComplete="email"
            />
          </div>
          {error && (
            <div className="bg-red-50 border border-red-200 text-red-800 text-sm rounded p-2">
              {error}
            </div>
          )}
          <button type="submit" disabled={loading} className="btn-primary">
            {loading ? "Enviando…" : "Enviar enlace"}
          </button>
          <div className="text-center text-sm">
            <Link href="/login" className="text-primary hover:underline">
              Volver
            </Link>
          </div>
        </form>
      )}
    </div>
  );
}
