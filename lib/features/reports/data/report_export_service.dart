import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'analytics_report_service.dart';
import 'drivers_summary_service.dart';
import 'stats_aggregator.dart';

/// Exporta un [AnalyticsReport] ya cargado a PDF o CSV, sin re-consultar
/// Firestore. Usa los datos en memoria (KPIs, horas pico, embudo, serie
/// diaria). Comparte el archivo con la hoja nativa (`Printing.sharePdf` /
/// `SharePlus`).
///
/// Color de marca: amarillo taxi (#FFD600) para encabezados del PDF, alineado
/// con `colorScheme.primary` de la app.
class ReportExportService {
  const ReportExportService();

  static const ReportExportService instance = ReportExportService();

  /// Amarillo taxi de marca (= AppTheme.primaryColor).
  static const PdfColor _brand = PdfColor.fromInt(0xFFFFD600);
  static const PdfColor _ink = PdfColor.fromInt(0xFF212121);
  static const PdfColor _muted = PdfColor.fromInt(0xFF757575);

  NumberFormat get _money => NumberFormat.currency(symbol: '\$', decimalDigits: 2);

  /// Etiqueta del archivo a partir del rango/cadencia ("reporte-base-2026-05-31").
  String _fileStem(AnalyticsReport report, {required bool isDriver}) {
    final stamp = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final who = isDriver ? 'conductor' : 'base';
    return 'reporte-$who-$stamp';
  }

  String _rangeText(AnalyticsReport report) {
    final df = DateFormat('dd MMM yyyy', 'es');
    DateTime ec(DateTime ts) => ts.toUtc().subtract(const Duration(hours: 5));
    return '${report.range.label} · '
        '${df.format(ec(report.range.fromTs))} – ${df.format(ec(report.range.toTs))}';
  }

  // ==========================================================================
  // PDF
  // ==========================================================================

  /// Construye el PDF y abre la hoja de compartir/imprimir nativa.
  ///
  /// [title] es el título del documento (p.ej. "Reporte de la base" o
  /// "Reporte: Juan Pérez"). [rating] es opcional (solo base).
  Future<void> sharePdf({
    required AnalyticsReport report,
    required String title,
    bool isDriver = false,
    AssociationRating? rating,
  }) async {
    final bytes = await buildPdfBytes(
      report: report,
      title: title,
      isDriver: isDriver,
      rating: rating,
    );
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${_fileStem(report, isDriver: isDriver)}.pdf',
    );
  }

  /// Genera los bytes del PDF (separado para test/preview).
  Future<Uint8List> buildPdfBytes({
    required AnalyticsReport report,
    required String title,
    bool isDriver = false,
    AssociationRating? rating,
  }) async {
    final doc = pw.Document();
    final c = report.current;

    final kpis = <List<String>>[
      ['Total de carreras', '${c.totalTrips}'],
      ['Ingreso estimado', _money.format(c.estimatedRevenue)],
      ['Carreras/día (prom.)', c.averageTripsPerDay.toStringAsFixed(1)],
      ['Días con carreras', '${c.daysWithTrips}'],
      if (rating != null && rating.hasRatings)
        [
          'Rating promedio',
          '${rating.average!.toStringAsFixed(1)} / 5  (${rating.ratingCount} calif.)',
        ],
    ];

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          _pdfHeader(title, _rangeText(report)),
          pw.SizedBox(height: 16),
          _pdfSectionTitle('Indicadores'),
          pw.SizedBox(height: 6),
          _pdfKpiTable(kpis),
          pw.SizedBox(height: 6),
          pw.Text(
            'El "ingreso estimado" es un proxy de demanda (tarifa mínima), '
            'no el ingreso real.',
            style: pw.TextStyle(fontSize: 8, color: _muted, fontStyle: pw.FontStyle.italic),
          ),
          if (report.peaks.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            _pdfSectionTitle('Horas pico'),
            pw.SizedBox(height: 6),
            pw.Wrap(
              spacing: 6,
              runSpacing: 6,
              children: report.peaks
                  .map((p) => _pdfChip(
                      '${p.hour.toString().padLeft(2, '0')}:00 · ${p.trips}'))
                  .toList(),
            ),
          ],
          if (!isDriver && report.funnel != null && !report.funnel!.isEmpty) ...[
            pw.SizedBox(height: 16),
            _pdfSectionTitle('Embudo de solicitudes web'),
            pw.SizedBox(height: 6),
            _pdfFunnelTable(report.funnel!),
          ],
          pw.SizedBox(height: 16),
          _pdfSectionTitle('Serie diaria'),
          pw.SizedBox(height: 6),
          _pdfDailyTable(c.dailySeries),
        ],
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Generado ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())} · '
            'Página ${context.pageNumber}/${context.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: _muted),
          ),
        ),
      ),
    );

    return doc.save();
  }

  pw.Widget _pdfHeader(String title, String range) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: const pw.BoxDecoration(color: _brand),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(title,
              style: pw.TextStyle(
                  fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.SizedBox(height: 2),
          pw.Text(range, style: pw.TextStyle(fontSize: 10, color: _ink)),
        ],
      ),
    );
  }

  pw.Widget _pdfSectionTitle(String text) => pw.Text(
        text,
        style: pw.TextStyle(
            fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink),
      );

  pw.Widget _pdfChip(String text) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(
          color: const PdfColor.fromInt(0xFFFFF6CC),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 10)),
      );

  pw.Widget _pdfKpiTable(List<List<String>> rows) {
    return pw.Table(
      border: pw.TableBorder.all(color: const PdfColor.fromInt(0xFFE0E0E0)),
      columnWidths: const {
        0: pw.FlexColumnWidth(2),
        1: pw.FlexColumnWidth(1.4),
      },
      children: rows
          .map((r) => pw.TableRow(children: [
                _cell(r[0], bold: false),
                _cell(r[1], bold: true, align: pw.TextAlign.right),
              ]))
          .toList(),
    );
  }

  pw.Widget _pdfFunnelTable(FunnelStats f) {
    String pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(0)}%';
    return pw.Table(
      border: pw.TableBorder.all(color: const PdfColor.fromInt(0xFFE0E0E0)),
      children: [
        _funnelRow('Recibidas', '${f.recibidas}'),
        _funnelRow('Asignadas', '${f.asignadas}'),
        _funnelRow('Finalizadas', '${f.finalizadas}'),
        _funnelRow('Canceladas', '${f.canceladas}'),
        _funnelRow('Cumplimiento', pct(f.fulfillmentRate)),
        _funnelRow('Cancelación', pct(f.cancellationRate)),
        _funnelRow('Asignación', pct(f.assignmentRate)),
      ],
    );
  }

  pw.TableRow _funnelRow(String label, String value) => pw.TableRow(children: [
        _cell(label),
        _cell(value, bold: true, align: pw.TextAlign.right),
      ]);

  pw.Widget _pdfDailyTable(List<DailyPoint> series) {
    final header = pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF5F5F5)),
      children: [
        _cell('Fecha', bold: true),
        _cell('Carreras', bold: true, align: pw.TextAlign.right),
        _cell('Estimado', bold: true, align: pw.TextAlign.right),
      ],
    );
    final rows = series
        .map((p) => pw.TableRow(children: [
              _cell(p.date),
              _cell('${p.totalTrips}', align: pw.TextAlign.right),
              _cell(_money.format(p.estimatedRevenue), align: pw.TextAlign.right),
            ]))
        .toList();
    if (rows.isEmpty) {
      rows.add(pw.TableRow(children: [
        _cell('Sin datos'),
        _cell('0', align: pw.TextAlign.right),
        _cell(_money.format(0), align: pw.TextAlign.right),
      ]));
    }
    return pw.Table(
      border: pw.TableBorder.all(color: const PdfColor.fromInt(0xFFE0E0E0)),
      columnWidths: const {
        0: pw.FlexColumnWidth(1.6),
        1: pw.FlexColumnWidth(1),
        2: pw.FlexColumnWidth(1.2),
      },
      children: [header, ...rows],
    );
  }

  pw.Widget _cell(String text,
      {bool bold = false, pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
            fontSize: 10,
            color: _ink,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
      ),
    );
  }

  // ==========================================================================
  // CSV
  // ==========================================================================

  /// Genera el contenido CSV (resumen + serie diaria) y lo comparte como
  /// archivo `.csv` con la hoja nativa.
  Future<void> shareCsv({
    required AnalyticsReport report,
    required String title,
    bool isDriver = false,
    AssociationRating? rating,
  }) async {
    final csv = buildCsv(report: report, title: title, rating: rating);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${_fileStem(report, isDriver: isDriver)}.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: title,
    );
  }

  /// Arma el CSV en memoria: bloque de resumen + bloque de serie diaria.
  /// Encabezados en español; estimado rotulado como "estimado".
  String buildCsv({
    required AnalyticsReport report,
    required String title,
    AssociationRating? rating,
  }) {
    final c = report.current;
    final b = StringBuffer();

    String esc(Object? v) {
      final s = '$v';
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"${s.replaceAll('"', '""')}"';
      }
      return s;
    }

    void row(List<Object?> cells) =>
        b.writeln(cells.map(esc).join(','));

    // Resumen.
    row(['Reporte', title]);
    row(['Periodo', _rangeText(report)]);
    row([]);
    row(['Indicador', 'Valor']);
    row(['Total de carreras', c.totalTrips]);
    row(['Ingreso estimado', c.estimatedRevenue.toStringAsFixed(2)]);
    row(['Carreras por día (promedio)', c.averageTripsPerDay.toStringAsFixed(2)]);
    row(['Días con carreras', c.daysWithTrips]);
    if (rating != null && rating.hasRatings) {
      row(['Rating promedio (1-5)', rating.average!.toStringAsFixed(2)]);
      row(['Total de calificaciones', rating.ratingCount]);
    }
    if (report.funnel != null && !report.funnel!.isEmpty) {
      final f = report.funnel!;
      row([]);
      row(['Embudo de solicitudes web', '']);
      row(['Recibidas', f.recibidas]);
      row(['Asignadas', f.asignadas]);
      row(['Finalizadas', f.finalizadas]);
      row(['Canceladas', f.canceladas]);
    }

    // Serie diaria.
    b.writeln();
    row(['fecha', 'carreras', 'estimado']);
    for (final p in c.dailySeries) {
      row([p.date, p.totalTrips, p.estimatedRevenue.toStringAsFixed(2)]);
    }

    return b.toString();
  }
}
