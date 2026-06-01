import Link from "next/link";

/**
 * Landing pública (sin sesión) — presentación de "Taxi Seguro Ecuador".
 *
 * El root layout (src/app/layout.tsx) constriñe el contenido a una tarjeta
 * angosta (`max-w-md` centrada) pensada para las pantallas de auth. Para que la
 * landing ocupe TODO el ancho usamos el truco full-bleed:
 *   `w-screen relative left-1/2 right-1/2 -mx-[50vw]`
 * que rompe el contenedor sin tocar el layout ni las rutas existentes.
 */
export default function Landing() {
  return (
    <div className="w-screen relative left-1/2 right-1/2 -mx-[50vw] -my-4 min-h-screen bg-white text-gray-900">
      {/* Header */}
      <header className="sticky top-0 z-10 bg-white/95 backdrop-blur border-b border-gray-100">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 h-16 flex items-center justify-between">
          <span className="text-lg sm:text-xl font-extrabold tracking-tight text-primary">
            🚕 Taxi Seguro Ecuador
          </span>
          <Link
            href="/login"
            className="bg-primary text-white font-semibold rounded-lg px-4 py-2 text-sm hover:bg-primary-dark transition"
          >
            Ingresar
          </Link>
        </div>
      </header>

      {/* Hero */}
      <section className="bg-accent">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 py-16 sm:py-24 text-center">
          <h1 className="text-4xl sm:text-6xl lg:text-7xl font-black tracking-tight text-gray-900 leading-tight">
            PIDE TU TAXI SEGURO
          </h1>
          <p className="mt-5 text-lg sm:text-2xl font-medium text-gray-800 max-w-2xl mx-auto">
            Taxi convencional, legal y confiable en Quito y sus valles.
          </p>
          <div className="mt-8 sm:mt-10">
            <Link
              href="/login"
              className="inline-block bg-gray-900 text-white text-lg sm:text-xl font-bold rounded-xl px-8 py-4 shadow-lg hover:bg-black transition"
            >
              🚕 Pedir taxi ahora →
            </Link>
          </div>
        </div>
      </section>

      {/* ¿Quiénes somos? */}
      <section className="mx-auto max-w-6xl px-4 sm:px-6 py-16">
        <h2 className="text-2xl sm:text-4xl font-extrabold text-primary text-center">
          ¿Quiénes somos?
        </h2>
        <p className="mt-5 text-base sm:text-lg text-gray-700 max-w-3xl mx-auto text-center leading-relaxed">
          Taxi Seguro Ecuador es una{" "}
          <strong>asociación de taxis legalmente constituida</strong> — un{" "}
          <strong>operador privado de transporte</strong> con una flota de más de{" "}
          <strong>150 taxis legales y registrados</strong>, con rutas y paradas
          asignadas en Quito y sus valles. Nacemos para apoyar y dignificar al
          taxismo convencional, modernizando al gremio con tecnología, sin
          competencia desleal: orden, seguridad y movilidad para Quito.
        </p>

        {/* Tres tarjetas */}
        <div className="mt-10 grid grid-cols-1 md:grid-cols-3 gap-6">
          <article className="card border border-gray-100">
            <div className="text-3xl">🤝</div>
            <h3 className="mt-3 text-lg font-bold text-gray-900">
              Apoyo al taxi convencional
            </h3>
            <p className="mt-2 text-gray-600">
              Tecnología al servicio del taxista legal de siempre, sin
              competencia desleal.
            </p>
          </article>

          <article className="card border border-gray-100">
            <div className="text-3xl">📍</div>
            <h3 className="mt-3 text-lg font-bold text-gray-900">
              Paradas ordenadas
            </h3>
            <p className="mt-2 text-gray-600">
              Organizamos turnos y paradas para un servicio justo y eficiente.
            </p>
          </article>

          <article className="card border border-gray-100">
            <div className="text-3xl">🛡️</div>
            <h3 className="mt-3 text-lg font-bold text-gray-900">Seguridad</h3>
            <p className="mt-2 text-gray-600">
              Conductores verificados, seguimiento en tiempo real y botón de
              emergencia.
            </p>
          </article>
        </div>
      </section>

      {/* Banda destacada */}
      <section className="bg-primary">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 py-12 text-center">
          <p className="text-lg sm:text-2xl font-semibold text-white max-w-3xl mx-auto leading-relaxed">
            🌆 Movilidad para la ciudad — Nuestra flota aporta reportes de
            cierres e incidentes viales en tiempo real para una Quito más
            ordenada, fluida y segura.
          </p>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-gray-100">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 py-8 text-center text-sm text-gray-600">
          Contacto: taxiseguroec@it-services.center · Quito, Ecuador · © Taxi
          Seguro Ecuador
        </div>
      </footer>
    </div>
  );
}
