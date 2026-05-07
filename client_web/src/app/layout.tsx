import type { Metadata } from "next";
import "./globals.css";
import { AuthProvider } from "@/lib/auth";

export const metadata: Metadata = {
  title: "Taxis App — Pide tu taxi",
  description:
    "Solicita tu taxi a tu asociación de confianza. Rápido y seguro.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="es">
      <body>
        <AuthProvider>
          <main className="min-h-screen flex items-center justify-center p-4">
            <div className="w-full max-w-md">{children}</div>
          </main>
        </AuthProvider>
      </body>
    </html>
  );
}
