import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/report_data.dart';
import '../bloc/reports_bloc.dart';

/// Pagina de reportes y analiticas con graficos fl_chart
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ReportsBloc, ReportsState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Reportes'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Actualizar',
                onPressed: () {
                  final period = state is ReportsLoaded
                      ? state.reportData.period
                      : 'Hoy';
                  context
                      .read<ReportsBloc>()
                      .add(ReportsLoadRequested(period: period));
                },
              ),
            ],
          ),
          body: _buildBody(context, state),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ReportsState state) {
    if (state is ReportsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state is ReportsError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 12),
            Text(state.message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => context
                  .read<ReportsBloc>()
                  .add(ReportsLoadRequested()),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (state is ReportsLoaded) {
      return _ReportsContent(data: state.reportData);
    }
    // Initial state
    return const Center(child: CircularProgressIndicator());
  }
}

// ================ CONTENIDO DEL REPORTE ================

class _ReportsContent extends StatelessWidget {
  final ReportData data;
  const _ReportsContent({required this.data});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PeriodSelector(currentPeriod: data.period),
          const SizedBox(height: 16),
          _KPISection(data: data),
          const SizedBox(height: 24),
          _TripsByHourChart(tripsByHour: data.tripsByHour),
          const SizedBox(height: 24),
          _DailyRevenueChart(dailyRevenue: data.dailyRevenue),
          const SizedBox(height: 24),
          _TopDriversSection(drivers: data.topDrivers),
          const SizedBox(height: 24),
          _PaymentMethodSection(distribution: data.paymentMethodDistribution),
          const SizedBox(height: 24),
          _FrequentDestinations(destinations: data.frequentDestinations),
          const SizedBox(height: 24),
          _HeatmapSection(tripsByDayAndHour: data.tripsByDayAndHour),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ================ SELECTOR DE PERIODO ================

class _PeriodSelector extends StatelessWidget {
  final String currentPeriod;
  const _PeriodSelector({required this.currentPeriod});

  @override
  Widget build(BuildContext context) {
    final periods = ['Hoy', 'Semana', 'Mes', 'Ano'];
    return Row(
      children: periods.map((period) {
        final isSelected = period == currentPeriod;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(period),
              selected: isSelected,
              selectedColor: AppTheme.primaryColor,
              onSelected: (s) {
                if (s) {
                  context
                      .read<ReportsBloc>()
                      .add(ReportsLoadRequested(period: period));
                }
              },
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ================ KPI CARDS ================

class _KPISection extends StatelessWidget {
  final ReportData data;
  const _KPISection({required this.data});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _KPICard(
                label: 'Total Carreras',
                value: '${data.totalTrips}',
                icon: Icons.local_taxi,
                color: AppTheme.secondaryColor,
                trend: data.tripsTrend,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KPICard(
                label: 'Ingresos',
                value: '\$${data.totalRevenue.toStringAsFixed(2)}',
                icon: Icons.attach_money,
                color: AppTheme.statusFree,
                trend: data.revenueTrend,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _KPICard(
                label: 'Conductores',
                value: '${data.activeDriversCount}',
                icon: Icons.people,
                color: Colors.blue,
                trend: 0,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KPICard(
                label: 'Canceladas',
                value: '${data.cancelledTrips}',
                icon: Icons.cancel,
                color: AppTheme.errorColor,
                trend: data.cancelledTrend,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _KPICard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final double trend;

  const _KPICard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.trend,
  });

  @override
  Widget build(BuildContext context) {
    final isPositive = trend > 0;
    final isNeutral = trend == 0;
    final trendStr = isNeutral
        ? '0%'
        : '${isPositive ? '+' : ''}${trend.toStringAsFixed(0)}%';

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
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isNeutral
                        ? Colors.grey.withValues(alpha: 0.15)
                        : isPositive
                            ? AppTheme.statusFree.withValues(alpha: 0.15)
                            : AppTheme.errorColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    trendStr,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isNeutral
                          ? Colors.grey
                          : isPositive
                              ? AppTheme.statusFree
                              : AppTheme.errorColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 22, color: color)),
            Text(label,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ================ GRAFICO: CARRERAS POR HORA ================

class _TripsByHourChart extends StatelessWidget {
  final Map<int, int> tripsByHour;
  const _TripsByHourChart({required this.tripsByHour});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.show_chart, size: 20, color: AppTheme.secondaryColor),
            SizedBox(width: 8),
            Text('Carreras por hora',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: tripsByHour.isEmpty
              ? _emptyChart('Sin datos de carreras')
              : BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: (tripsByHour.values.isEmpty
                            ? 1
                            : tripsByHour.values
                                .reduce((a, b) => a > b ? a : b))
                        .toDouble() *
                        1.2,
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, gIndex, rod, rIndex) {
                          return BarTooltipItem(
                            '${group.x}:00\n${rod.toY.toInt()} carreras',
                            const TextStyle(
                                color: Colors.white, fontSize: 12),
                          );
                        },
                      ),
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 28,
                          getTitlesWidget: (value, meta) => Text(
                            value.toInt().toString(),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '${value.toInt()}h',
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    gridData: const FlGridData(
                      show: true,
                      drawVerticalLine: false,
                    ),
                    barGroups: _buildBarGroups(),
                  ),
                ),
        ),
      ],
    );
  }

  List<BarChartGroupData> _buildBarGroups() {
    final sortedKeys = tripsByHour.keys.toList()..sort();
    return sortedKeys.map((hour) {
      return BarChartGroupData(
        x: hour,
        barRods: [
          BarChartRodData(
            toY: tripsByHour[hour]!.toDouble(),
            color: AppTheme.secondaryColor,
            width: 12,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(4),
            ),
          ),
        ],
      );
    }).toList();
  }
}

// ================ GRAFICO: INGRESOS DIARIOS ================

class _DailyRevenueChart extends StatelessWidget {
  final Map<String, double> dailyRevenue;
  const _DailyRevenueChart({required this.dailyRevenue});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bar_chart, size: 20, color: AppTheme.statusFree),
            SizedBox(width: 8),
            Text('Ingresos diarios',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: dailyRevenue.isEmpty
              ? _emptyChart('Sin datos de ingresos')
              : LineChart(
                  LineChartData(
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipItems: (spots) {
                          final keys = dailyRevenue.keys.toList();
                          return spots.map((spot) {
                            final label = spot.x.toInt() < keys.length
                                ? keys[spot.x.toInt()]
                                : '';
                            return LineTooltipItem(
                              '$label\n\$${spot.y.toStringAsFixed(2)}',
                              const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            );
                          }).toList();
                        },
                      ),
                    ),
                    gridData: const FlGridData(
                      show: true,
                      drawVerticalLine: false,
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 40,
                          getTitlesWidget: (value, meta) => Text(
                            '\$${value.toInt()}',
                            style: const TextStyle(fontSize: 9),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 1,
                          getTitlesWidget: (value, meta) {
                            final keys = dailyRevenue.keys.toList();
                            final idx = value.toInt();
                            if (idx >= 0 && idx < keys.length) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(keys[idx],
                                    style: const TextStyle(fontSize: 9)),
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
                        spots: _buildSpots(),
                        isCurved: true,
                        color: AppTheme.statusFree,
                        barWidth: 3,
                        isStrokeCapRound: true,
                        dotData: FlDotData(
                          show: dailyRevenue.length <= 7,
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          color: AppTheme.statusFree.withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  List<FlSpot> _buildSpots() {
    final values = dailyRevenue.values.toList();
    return List.generate(values.length, (i) {
      return FlSpot(i.toDouble(), values[i]);
    });
  }
}

// ================ TOP CONDUCTORES ================

class _TopDriversSection extends StatelessWidget {
  final List<DriverReportItem> drivers;
  const _TopDriversSection({required this.drivers});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.emoji_events, size: 20, color: AppTheme.primaryDark),
            SizedBox(width: 8),
            Text('Top Conductores',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        if (drivers.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('Sin datos de conductores',
                    style: TextStyle(color: Colors.grey[500])),
              ),
            ),
          )
        else
          ...List.generate(drivers.length, (index) {
            final driver = drivers[index];
            final medalColors = [
              AppTheme.primaryColor,
              Colors.grey[400]!,
              Colors.brown[300]!,
            ];

            // Calcular los 2 sources con más carreras
            final sortedSources = driver.bySource.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
            final top2 = sortedSources.take(2).toList();

            String sourceLabel(String src) {
              switch (src) {
                case 'standQueue': return 'Cola';
                case 'street': return 'Calle';
                case 'manual': return '+1';
                case 'apkOperadora': return 'Op';
                case 'walkieTalkie': return 'Radio';
                case 'webCliente': return 'Web';
                default: return src;
              }
            }

            final sourceSummary = top2
                .map((e) => '${sourceLabel(e.key)}: ${e.value}')
                .join(' · ');

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          index < 3 ? medalColors[index] : Colors.grey[200],
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: index < 3 ? Colors.white : Colors.grey[600],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(driver.name,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Row(
                            children: [
                              Text('${driver.tripCount} carreras',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              if (driver.peakHourCount > 0) ...[
                                const SizedBox(width: 8),
                                Text(
                                  'Pico: ${driver.peakHour}h (${driver.peakHourCount})',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade700,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ],
                          ),
                          if (sourceSummary.isNotEmpty)
                            Text(sourceSummary,
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey[500])),
                        ],
                      ),
                    ),
                    Text(
                      '\$${driver.income.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

// ================ METODOS DE PAGO (PIE CHART) ================

class _PaymentMethodSection extends StatelessWidget {
  final Map<String, double> distribution;
  const _PaymentMethodSection({required this.distribution});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.payment, size: 20, color: AppTheme.secondaryColor),
            SizedBox(width: 8),
            Text('Metodos de Pago',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: distribution.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Sin datos de pagos',
                          style: TextStyle(color: Colors.grey[500])),
                    ),
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 100,
                        height: 100,
                        child: PieChart(
                          PieChartData(
                            sectionsSpace: 2,
                            centerSpaceRadius: 20,
                            sections: _buildSections(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: distribution.entries.map((e) {
                            final color = _methodColor(e.key);
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(e.key,
                                        style:
                                            const TextStyle(fontSize: 13)),
                                  ),
                                  Text(
                                    '${(e.value * 100).toInt()}%',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: color,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  List<PieChartSectionData> _buildSections() {
    return distribution.entries.map((e) {
      return PieChartSectionData(
        color: _methodColor(e.key),
        value: e.value * 100,
        radius: 25,
        showTitle: false,
      );
    }).toList();
  }

  Color _methodColor(String method) {
    switch (method) {
      case 'Efectivo':
        return AppTheme.statusFree;
      case 'Transferencia':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }
}

// ================ DESTINOS FRECUENTES ================

class _FrequentDestinations extends StatelessWidget {
  final List<DestinationReportItem> destinations;
  const _FrequentDestinations({required this.destinations});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.place, size: 20, color: AppTheme.errorColor),
            SizedBox(width: 8),
            Text('Destinos Frecuentes',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 12),
        if (destinations.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('Sin datos de destinos',
                    style: TextStyle(color: Colors.grey[500])),
              ),
            ),
          )
        else
          ...destinations.map((dest) => Card(
                margin: const EdgeInsets.only(bottom: 4),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_on,
                      color: AppTheme.errorColor, size: 20),
                  title: Text(dest.address),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.secondaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${dest.count} viajes',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.secondaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              )),
      ],
    );
  }
}

// ================ HEATMAP DÍAS × HORAS ================

class _HeatmapSection extends StatelessWidget {
  final Map<int, Map<int, int>> tripsByDayAndHour;
  const _HeatmapSection({required this.tripsByDayAndHour});

  static const _dayLabels = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

  @override
  Widget build(BuildContext context) {
    // Calcular máximo global para escalar colores
    int maxVal = 1;
    for (final hourMap in tripsByDayAndHour.values) {
      for (final v in hourMap.values) {
        if (v > maxVal) maxVal = v;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.grid_on, size: 20, color: Colors.deepOrange),
            SizedBox(width: 8),
            Text('Mapa de calor (días × horas)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        const SizedBox(height: 8),
        if (tripsByDayAndHour.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text('Sin datos para el mapa de calor',
                    style: TextStyle(color: Colors.grey[500])),
              ),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header de horas
                Row(
                  children: [
                    const SizedBox(width: 36), // espacio para labels de días
                    ...List.generate(24, (h) => _HeatCell(
                      size: 16,
                      color: Colors.transparent,
                      child: Text(
                        h % 3 == 0 ? '$h' : '',
                        style: const TextStyle(fontSize: 7, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    )),
                  ],
                ),
                // Filas por día de la semana (1=Lun..7=Dom)
                ...List.generate(7, (di) {
                  final dow = di + 1;
                  final hourMap = tripsByDayAndHour[dow] ?? {};
                  return Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          _dayLabels[di],
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.right,
                        ),
                      ),
                      const SizedBox(width: 2),
                      ...List.generate(24, (h) {
                        final count = hourMap[h] ?? 0;
                        final intensity = maxVal > 0 ? count / maxVal : 0.0;
                        final color = _heatColor(intensity);
                        return Tooltip(
                          message: count > 0
                              ? '${_dayLabels[di]} ${h}h: $count carreras'
                              : '',
                          child: _HeatCell(size: 16, color: color),
                        );
                      }),
                    ],
                  );
                }),
                // Leyenda
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(width: 38),
                    const Text('0', style: TextStyle(fontSize: 9, color: Colors.grey)),
                    const SizedBox(width: 4),
                    ...List.generate(5, (i) {
                      return _HeatCell(size: 12, color: _heatColor(i / 4));
                    }),
                    const SizedBox(width: 4),
                    const Text('máx', style: TextStyle(fontSize: 9, color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  static Color _heatColor(double intensity) {
    if (intensity <= 0) return Colors.grey.shade100;
    // Gradiente: gris claro → naranja → rojo
    if (intensity < 0.5) {
      return Color.lerp(Colors.grey.shade200, Colors.orange.shade400,
          intensity * 2)!;
    }
    return Color.lerp(
        Colors.orange.shade400, Colors.red.shade700, (intensity - 0.5) * 2)!;
  }
}

class _HeatCell extends StatelessWidget {
  final double size;
  final Color color;
  final Widget? child;

  const _HeatCell({required this.size, required this.color, this.child});

  @override
  Widget build(BuildContext context) {
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

// ================ HELPERS ================

Widget _emptyChart(String msg) {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.insert_chart_outlined, size: 40, color: Colors.grey[400]),
        const SizedBox(height: 8),
        Text(msg,
            style: TextStyle(color: Colors.grey[500], fontSize: 13)),
      ],
    ),
  );
}
