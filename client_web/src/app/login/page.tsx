"use client";

import { signInWithEmailAndPassword } from "firebase/auth";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { getFirebase } from "@/lib/firebase";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const { auth } = getFirebase();
      await signInWithEmailAndPassword(auth, email.trim(), password);
      router.replace("/home");
    } catch (e: any) {
      setError(traduce(e?.code ?? e?.message ?? "Error al iniciar sesión"));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="card">
      <div className="text-center mb-6">
        <div className="text-4xl mb-2">🚕</div>
        <h1 className="text-2xl font-bold text-primary">Taxis App</h1>
        <p className="text-sm text-gray-600">Pide tu taxi en segundos</p>
      </div>
      <form onSubmit={onSubmit} className="space-y-4">
        <div>
          <label className="block text-sm font-medium mb-1">Correo</label>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="input"
            placeholder="tu@correo.com"
            autoComplete="email"
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Contraseña</label>
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="input"
            placeholder="••••••••"
            autoComplete="current-password"
          />
        </div>
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-800 text-sm rounded p-2">
            {error}
          </div>
        )}
        <button type="submit" disabled={loading} className="btn-primary">
          {loading ? "Entrando…" : "Iniciar sesión"}
        </button>
      </form>
      <div className="mt-6 flex justify-between text-sm">
        <Link href="/recover" className="text-primary hover:underline">
          Olvidé mi contraseña
        </Link>
        <Link href="/register" className="text-primary hover:underline">
          Crear cuenta
        </Link>
      </div>
    </div>
  );
}

function traduce(code: string): string {
  if (code.includes("user-not-found") || code.includes("wrong-password") ||
      code.includes("invalid-credential")) {
    return "Correo o contraseña incorrectos.";
  }
  if (code.includes("too-many-requests")) {
    return "Demasiados intentos. Espera un momento.";
  }
  if (code.includes("network")) {
    return "Sin conexión a internet.";
  }
  return code;
}
