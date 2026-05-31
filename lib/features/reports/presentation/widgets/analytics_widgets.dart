import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/stats_aggregator.dart';

/// Etiquetas de días de semana indexadas por `dayOfWeek` 0=Dom..6=Sáb,
/// igual que el campo del backend.
const List<String> kDowLabels = ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'];

/// Texto del comparativo WoW/MoM/YoY para una cadencia. Devuelve `null` para
/// [ReportCadence.day] (no se compara "ayer" en esta vista) y para cualquier
/// caso sin comparativo significativo.
String? comparisonLabelFor(ReportCadence cadence) {
  switch (cadence) {
    case ReportCadence.week:
      return 'vs semana anterior';
    case ReportCadence.month:
      return 'vs mes anterior';
    case ReportCadence.year:
      return 'vs año anterior';
    case ReportCadence.day:
      return null;
  }
}

// ============================================================================
// Selector de cadencia (Día / Semana / Mes / Año)
// ============================================================================

class CadenceSelector extends StatelessWidget {
  final ReportCadence value;
  final ValueChanged<ReportCadence> onChanged;

  /// Si `false`, oculta la opción "Año" (p.ej. reporte de conductor D/S/M).
  final bool includeYear;

  const CadenceSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.includeYear = true,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ReportCadence>(
      segments: [
        const ButtonSegment(value: ReportCadence.day, label: Text('Hoy')),
        const ButtonSegment(value: ReportCadence.week, label: Text('Semana')),
        const ButtonSegment(value: ReportCadence.month, label: Text('Mes')),
        if (includeYear)
          const ButtonSegment(value: ReportCadence.year, label: Text('Año')),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

// ============================================================================
// Tarjeta KPI
// ============================================================================

class AnalyticsKpiCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  /// % de cambio vs periodo anterior. `null` ⇒ no se muestra badge.
  final double? changePct;

  /// Texto del comparativo ("vs semana anterior"). Solo se usa si [changePct]
  /// no es null; se muestra como pie de la tarjeta para dar contexto al badge.
  final String? changeLabel;

  const AnalyticsKpiCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.changePct,
    this.changeLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const Spacer(),
                if (changePct != null) TrendBadge(pct: changePct!),
              ],
            ),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 22, color: color)),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
            if (changePct != null && changeLabel != null) ...[
              const SizedBox(height: 2),
              Text(changeLabel!,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 10)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Badge ↑/↓ con color según el signo del cambio.
class TrendBadge extends StatelessWidget {
  final double pct;
  const TrendBadge({super.key, required this.pct});

  @override
  Widget build(BuildContext context) {
    final isNeutral = pct == 0;
    final isPositive = pct > 0;
    final color = isNeutral
        ? Colors.grey
        : isPositive
            ? AppTheme.statusFree
            : AppTheme.errorColor;
    final arrow = isNeutral
        ? ''
        : isPositive
            ? '↑ '
            : '↓ ';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$arrow${pct.abs().toStringAsFixed(0)}%',
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

// ============================================================================
// Aviso "datos insuficientes"
// ============================================================================

class InsufficientDataNotice extends StatelessWidget {
  final int daysWithTrips;
  const InsufficientDataNotice({super.key, required this.daysWithTrips});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warningColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warningColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline,
              size: 18, color: AppTheme.warningColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Pocos días con datos ($daysWithTrips). Las cifras se muestran, '
              'pero las comparativas y la tendencia aún no son confiables.',
              style: TextStyle(
                  fontSize: 11, color: AppTheme.warningColor.withValues(alpha: 0.95)),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Encabezado de sección
// ============================================================================

class SectionTitle extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const SectionTitle(
      {super.key, required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Text(text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }
}

// ============================================================================
// HEATMAP día-de-semana × hora (vista estrella)
// ============================================================================

/// Grilla 7×24 (dayOfWeek 0=Dom..6=Sáb × hora 0..23) coloreada por intensidad.
/// Se construye con un GridView propio (`Container`s) porque fl_chart no tiene
/// heatmap nativo. La escala de color va de gris claro → amarillo de marca →
/// rojo, derivada del AppTheme.
class DowHourHeatmap extends StatelessWidget {
  /// Matriz [dow 0..6][hora 0..23].
  final List<List<int>> heatmap;
  const DowHourHeatmap({super.key, required this.heatmap});

  static Color heatColor(double intensity) {
    if (intensity <= 0) return Colors.grey.shade100;
    if (intensity < 0.5) {
      // gris → amarillo taxi
      return Color.lerp(
          Colors.grey.shade200, AppTheme.primaryColor, intensity * 2)!;
    }
    // amarillo → naranja → rojo (alta demanda)
    return Color.lerp(
        AppTheme.primaryColor, AppTheme.errorColor, (intensity - 0.5) * 2)!;
  }

  @override
  Widget build(BuildContext context) {
    int maxVal = 0;
    for (final row in heatmap) {
      for (final v in row) {
        if (v > maxVal) maxVal = v;
      }
    }
    if (maxVal == 0) {
      return _emptyCard('Sin datos para el mapa de calor');
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header de horas (cada 3h).
          Row(
            children: [
              const SizedBox(width: 36),
              ...List.generate(
                24,
                (h) => _cell(
                  16,
                  Colors.transparent,
                  child: Text(
                    h % 3 == 0 ? '$h' : '',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
          // 7 filas de día (Lun primero para lectura operativa).
          ...List.generate(7, (i) {
            // Mostramos Lun..Dom; dow 1..6 luego 0 (domingo).
            final dow = (i + 1) % 7; // 1,2,3,4,5,6,0
            final row = heatmap[dow];
            return Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    kDowLabels[dow],
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 2),
                ...List.generate(24, (h) {
                  final count = row[h];
                  final intensity = count / maxVal;
                  return Tooltip(
                    message: count > 0
                        ? '${kDowLabels[dow]} ${h}h: $count carreras'
                        : '',
                    child: _cell(16, heatColor(intensity)),
                  );
                }),
              ],
            );
          }),
          const SizedBox(height: 6),
          // Leyenda 0 → máx.
          Row(
            children: [
              const SizedBox(width: 38),
              const Text('0',
                  style: TextStyle(fontSize: 9, color: Colors.grey)),
              const SizedBox(width: 4),
              ...List.generate(5, (i) => _cell(12, heatColor(i / 4))),
              const SizedBox(width: 4),
              Text('máx ($maxVal)',
                  style: const TextStyle(fontSize: 9, color: Colors.grey)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cell(double size, Color color, {Widget? child}) {
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
      child: child,
    );
  }
}

// ============================================================================
// Barras de carreras por hora (0-23)
// ============================================================================

class TripsByHourBars extends StatelessWidget {
  final Map<int, int> tripsByHour;
  final Color color;
  const TripsByHourBars({
    super.key,
    required this.tripsByHour,
    this.color = AppTheme.secondaryColor,
  });

  @override
  Widget build(BuildContext context) {
    if (tripsByHour.values.every((v) => v == 0) || tripsByHour.isEmpty) {
      return _emptyCard('Sin datos de carreras por hora');
    }
    final maxV = tripsByHour.values.fold<int>(1, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 200,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxV * 1.2,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, gIndex, rod, rIndex) => BarTooltipItem(
                '${group.x}:00\n${rod.toY.toInt()} carreras',
                const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
          titlesData: FlTitlesData(
            show: true,
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, m) => Text(v.toInt().toString(),
                    style: const TextStyle(fontSize: 10)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, m) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${v.toInt()}h',
                      style: const TextStyle(fontSize: 9)),
                ),
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          barGroups: (tripsByHour.keys.toList()..sort())
              .map((h) => BarChartGroupData(
                    x: h,
                    barRods: [
                      BarChartRodData(
                        toY: tripsByHour[h]!.toDouble(),
                        color: color,
                        width: 8,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(4),
                          topRight: Radius.circular(4),
                        ),
                      ),
                    ],
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ============================================================================
// Línea de tendencia (serie diaria)
// ============================================================================

class DailyTrendLine extends StatelessWidget {
  final List<DailyPoint> series;

  /// Si `true`, grafica `estimatedRevenue`; si `false`, `totalTrips`.
  final bool revenue;
  final Color color;
  const DailyTrendLine({
    super.key,
    required this.series,
    this.revenue = false,
    this.color = AppTheme.statusFree,
  });

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) {
      return _emptyCard('Se necesita más de un día para la tendencia');
    }
    double valueOf(DailyPoint p) =>
        revenue ? p.estimatedRevenue : p.totalTrips.toDouble();

    final spots = List.generate(
        series.length, (i) => FlSpot(i.toDouble(), valueOf(series[i])));

    String shortDate(String iso) {
      // "YYYY-MM-DD" → "DD/MM"
      final parts = iso.split('-');
      return parts.length == 3 ? '${parts[2]}/${parts[1]}' : iso;
    }

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => touched.map((spot) {
                final idx = spot.x.toInt();
                final label =
                    idx >= 0 && idx < series.length ? shortDate(series[idx].date) : '';
                final val = revenue
                    ? '\$${spot.y.toStringAsFixed(2)}'
                    : '${spot.y.toInt()}';
                return LineTooltipItem(
                  '$label\n$val',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              }).toList(),
            ),
          ),
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          titlesData: FlTitlesData(
            show: true,
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, m) => Text(
                  revenue ? '\$${v.toInt()}' : '${v.toInt()}',
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (series.length / 6).clamp(1, 31).toDouble(),
                getTitlesWidget: (v, m) {
                  final idx = v.toInt();
                  if (idx >= 0 && idx < series.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(shortDate(series[idx].date),
                          style: const TextStyle(fontSize: 8)),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: color,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(show: series.length <= 14),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Horas pico (chips)
// ============================================================================

class PeakHoursChips extends StatelessWidget {
  final List<PeakHour> peaks;
  const PeakHoursChips({super.key, required this.peaks});

  @override
  Widget build(BuildContext context) {
    if (peaks.isEmpty) {
      return _emptyCard('Sin horas pico en este periodo');
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: peaks.map((p) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.warningColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: AppTheme.warningColor.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.schedule,
                  size: 14, color: AppTheme.warningColor),
              const SizedBox(width: 6),
              Text(
                '${p.hour.toString().padLeft(2, '0')}:00',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.warningColor),
              ),
              const SizedBox(width: 6),
              Text('${p.trips}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.warningColor)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ============================================================================
// Comparativa por día de semana (mismo-día vs mismo-día)
// ============================================================================

class DayOfWeekComparison extends StatelessWidget {
  final List<int> current; // por dow 0..6
  final List<int> previous;
  const DayOfWeekComparison(
      {super.key, required this.current, required this.previous});

  @override
  Widget build(BuildContext context) {
    final maxV = [
      ...current,
      ...previous,
      1,
    ].reduce((a, b) => a > b ? a : b);

    // Orden de lectura: Lun..Dom (1..6, luego 0).
    final order = [1, 2, 3, 4, 5, 6, 0];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _legend(AppTheme.secondaryColor, 'Esta semana'),
            const SizedBox(width: 12),
            _legend(Colors.grey.shade400, 'Semana anterior'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: order.map((dow) {
              final cur = current[dow];
              final prev = previous[dow];
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _bar(prev / maxV, Colors.grey.shade400),
                          const SizedBox(width: 2),
                          _bar(cur / maxV, AppTheme.secondaryColor),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(kDowLabels[dow],
                          style: const TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _bar(double ratio, Color color) {
    return Container(
      width: 9,
      height: (90 * ratio).clamp(2, 90).toDouble(),
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
      ),
    );
  }

  Widget _legend(Color c, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 12,
            height: 12,
            decoration:
                BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}

// ============================================================================
// Embudo de solicitudes web (Recibidas → Asignadas → Finalizadas + Canceladas)
// ============================================================================

/// Embudo/escalera de solicitudes web del rango: las tres etapas del flujo
/// (Recibidas → Asignadas → Finalizadas) como barras de ancho decreciente
/// proporcional al volumen, Canceladas aparte, y las tasas (% cumplimiento /
/// % cancelación / % asignación) como badges. Estado vacío explícito.
class RequestFunnelSection extends StatelessWidget {
  final FunnelStats funnel;
  const RequestFunnelSection({super.key, required this.funnel});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    if (funnel.isEmpty) {
      return _emptyCard('Sin solicitudes web en este período');
    }

    // Base para los anchos: la primera etapa (recibidas) o el máximo, lo que
    // sea mayor, para que ninguna barra exceda el contenedor.
    final base = [
      funnel.recibidas,
      funnel.asignadas,
      funnel.finalizadas,
    ].reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FunnelStage(
              label: 'Recibidas',
              value: funnel.recibidas,
              ratio: funnel.recibidas / base,
              color: AppTheme.infoColor,
              icon: Icons.call_received,
            ),
            const SizedBox(height: AppSpacing.sm),
            _FunnelStage(
              label: 'Asignadas',
              value: funnel.asignadas,
              ratio: funnel.asignadas / base,
              color: AppTheme.secondaryColor,
              icon: Icons.assignment_ind_outlined,
            ),
            const SizedBox(height: AppSpacing.sm),
            _FunnelStage(
              label: 'Finalizadas',
              value: funnel.finalizadas,
              ratio: funnel.finalizadas / base,
              color: AppTheme.successColor,
              icon: Icons.check_circle_outline,
            ),
            const Divider(height: AppSpacing.xl),
            // Canceladas aparte (no es una etapa del flujo de cumplimiento).
            Row(
              children: [
                const Icon(Icons.cancel_outlined,
                    size: 18, color: AppTheme.errorColor),
                const SizedBox(width: AppSpacing.sm),
                Text('Canceladas',
                    style: textTheme.bodyMedium
                        ?.copyWith(color: AppTheme.textSecondary)),
                const Spacer(),
                Text('${funnel.canceladas}',
                    style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.errorColor)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // Tasas como badges.
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _RateBadge(
                  label: 'Cumplimiento',
                  rate: funnel.fulfillmentRate,
                  color: AppTheme.successColor,
                ),
                _RateBadge(
                  label: 'Cancelación',
                  rate: funnel.cancellationRate,
                  color: AppTheme.errorColor,
                ),
                _RateBadge(
                  label: 'Asignación',
                  rate: funnel.assignmentRate,
                  color: AppTheme.infoColor,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Una etapa del embudo: etiqueta + barra proporcional + conteo.
class _FunnelStage extends StatelessWidget {
  final String label;
  final int value;
  final double ratio; // 0..1
  final Color color;
  final IconData icon;
  const _FunnelStage({
    required this.label,
    required this.value,
    required this.ratio,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppTheme.textSecondary)),
            const Spacer(),
            Text('$value',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold, color: color)),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            // Ancho mínimo visible para que las etapas con valor 0 < ratio
            // sigan siendo perceptibles, pero 0 real queda casi invisible.
            final w = value == 0
                ? 0.0
                : (constraints.maxWidth * ratio).clamp(6.0, constraints.maxWidth);
            return Stack(
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                Container(
                  height: 10,
                  width: w,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Badge de una tasa porcentual. `rate` null ⇒ muestra "—" (sin base).
class _RateBadge extends StatelessWidget {
  final String label;
  final double? rate;
  final Color color;
  const _RateBadge({
    required this.label,
    required this.rate,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final value = rate == null ? '—' : '${rate!.toStringAsFixed(0)}%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w900, color: color)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color.withValues(alpha: 0.95))),
        ],
      ),
    );
  }
}

// ============================================================================
// Helpers
// ============================================================================

Widget _emptyCard(String msg) {
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_chart_outlined, size: 36, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ],
        ),
      ),
    ),
  );
}
