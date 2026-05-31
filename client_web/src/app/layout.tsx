import type { Metadata } from "next";
import "./globals.css";
import { AuthProvider } from "@/lib/auth";

export const metadata: Metadata = {
  title: "Taxi Seguro Ecuador — taxi seguro en Quito",
  description:
    "Pide tu taxi seguro: taxi convencional, legal y confiable en Quito y sus valles. Conductores verificados, seguimiento en tiempo real y botón de emergencia.",
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
