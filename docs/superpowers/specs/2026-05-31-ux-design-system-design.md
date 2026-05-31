# Design System + Temas Curados + Pulido UX — Plan

**Fecha:** 2026-05-31
**Proyecto:** taxi_jipijapa
**Estado:** Aprobado (alcance A+B+C "pro" + temas curados). Ejecución por olas.

## Contexto (auditoría 2026-05-31)
31 pantallas. Problemas: contraste roto (texto blanco sobre AppBar amarillo en 8 pantallas), ~400 colores hardcodeados, sin estados error/vacío (~29 StreamBuilder en spinner pelado), tipografía sin escala (17 tamaños sueltos, uno de `fontSize:7`), emojis en UI, AppBars inconsistentes. Buenos ejemplos a replicar: `home_page`, `login_page`, `my_payments_page`.

## Requisito clave de theming
El theming por asociación se **conserva** pero el admin elige **TEMAS CURADOS (presets profesionales)**, no colores sueltos → nunca una combinación fea. Hoy `AssociationThemeService` guarda `theme.{primaryColor,secondaryColor,accentColor,logoUrl}` y los aplica al `ColorScheme` en runtime. Cambia a guardar `theme.presetId` (+ logoUrl). Backward-compat: si existe `primaryColor` viejo, seguir aplicándolo hasta que el admin elija un preset.

## Regla arquitectónica (crítica para que los presets funcionen)
- **Colores de MARCA** (primary/secondary/accent): usar SIEMPRE `Theme.of(context).colorScheme.primary/secondary/tertiary` (runtime) — así el preset por asociación se refleja. NO usar `AppTheme.primaryColor` const para marca.
- **Colores SEMÁNTICOS** (success/warning/error/info y estados `statusFree/Busy/Returning/Offline`): constantes en `AppTheme` (no cambian por asociación). `error` también vive en colorScheme.
- **Paleta categórica** (tiles del home, categorías de caja): set fijo de 6–8 colores en `AppTheme.categorical` en vez de `Colors.deepPurple/teal...` ad-hoc.

## Presets curados (Fase B) — `lib/core/theme/theme_presets.dart`
Cada preset = { id, nombre, primary (+onPrimary legible), secondary, accent }. Propuesta inicial (ajustable):
1. **Amarillo Clásico** (default): primary `#FFD600` (on=negro), secondary `#1A237E`, accent `#00BFA5`.
2. **Azul Corporativo**: primary `#1565C0` (on=blanco), secondary `#0D47A1`, accent `#FFB300`.
3. **Verde Esmeralda**: primary `#2E7D32` (on=blanco), secondary `#1B5E20`, accent `#FFC107`.
4. **Rojo Taxi**: primary `#C62828` (on=blanco), secondary `#1A237E`, accent `#FFC107`.
5. **Naranja Energía**: primary `#EF6C00` (on=blanco), secondary `#263238`, accent `#00ACC1`.
6. **Grafito Premium**: primary `#263238` (on=blanco), secondary `#FFC107`, accent `#26A69A`.
Todos validados para contraste de texto sobre primary.

## Fundación (Fase B) — componentes/tokens
- `AppTheme`: añadir `textTheme` (escala M3: headlineMedium/titleMedium/bodyMedium/labelSmall…), `AppSpacing` (4/8/12/16/24), tokens `infoColor`, `neutralBg`, `categorical[]`. Mantener status tokens existentes.
- Widgets reutilizables: `AppScaffold`/`AppAppBar` (theme-correct, back-button `canPop()?pop():go('/home')` integrado), `EmptyState(icon,title,subtitle,action)`, `LoadingState`, `ErrorState(message,onRetry)` — modelado sobre `my_payments_page._errorState` (detecta índices faltantes).

## Fases
- **Ola 1 = Fase B (fundación + presets) + Fase A (quick wins):** tokens+textTheme+spacing+categorical, AppScaffold+state widgets, theme_presets + refactor AssociationThemeService a presetId + rehacer `theme_settings_page` a galería de temas. Quick wins: quitar overrides de AppBar rotos (8), `fontSize:7`, emojis→Icon, color de marca en perfil. Build APK, review.
- **Ola 2+ = Fase C:** migrar las 31 pantallas a `colorScheme`/`textTheme`/`AppSpacing` y añadir `EmptyState/LoadingState/ErrorState` en todos los StreamBuilder/FutureBuilder. En lotes por módulo (admin, payments, trips, map, etc.). Referencia: home/login/my_payments.

## Restricciones
No tocar lógica de negocio ni backend. `flutter analyze` limpio. No auto-commit (specs/docs en rama docs/*). Build de APK lo hace el orquestador (Claude), no los agentes.
