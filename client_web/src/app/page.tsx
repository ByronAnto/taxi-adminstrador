"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAuth } from "@/lib/auth";
import Landing from "@/components/Landing";

export default function RootPage() {
  const { user, loading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;
    // Con sesión → a la app. Sin sesión → se queda en la landing pública.
    if (user) router.replace("/home");
  }, [user, loading, router]);

  if (loading) {
    return (
      <div className="card text-center">
        <p className="text-gray-600">Cargando…</p>
      </div>
    );
  }

  // Mientras redirige al usuario logueado, no mostramos la landing.
  if (user) {
    return (
      <div className="card text-center">
        <p className="text-gray-600">Cargando…</p>
      </div>
    );
  }

  return <Landing />;
}
