import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;

import '../../features/admin/data/models/cashflow_model.dart';

/// Servicio para generar PDFs A4 con márgenes 2.5cm y branding por asociación.
///
/// Encabezado: logo + nombre asociación + fecha de generación.
/// Cumple los requerimientos del Dominio E del PROMPT_MAESTRO:
/// "PDF: A4, márgenes 2.5 cm, encabezado con logo + nombre asociación"
class PdfExportService {
  PdfExportService._();
  static final PdfExportService instance = PdfExportService._();

  /// Margen estándar 2.5 cm = 70.866 puntos PDF (1 cm = ~28.346 pt).
  static const double _marginCm = 2.5 * PdfPageFormat.cm;

  /// Reporte de cashflow para una asociación en un período.
  Future<Uint8List> buildCashflowReport({
    required String associationName,
    String? logoUrl,
    PdfColor? primaryColor,
    required List<CashflowMovement> movements,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String periodLabel,
  }) async {
    final theme = await _theme();
    final logoImage = await _loadLogo(logoUrl);
    final primary = primaryColor ?? PdfColors.blue800;

    final ingresos =
        movements.where((m) => m.isIngreso).fold<double>(0, (s, m) => s + m.monto);
    final egresos =
        movements.where((m) => m.isEgreso).fold<double>(0, (s, m) => s + m.monto);
    final balance = ingresos - egresos;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final dateFmt = DateFormat('dd MMM yyyy');

    final doc = pw.Document(theme: theme);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: _marginCm,
          marginRight: _marginCm,
          marginTop: _marginCm,
          marginBottom: _marginCm,
        ),
        header: (ctx) => _header(
          associationName: associationName,
          subtitle: 'Reporte de Caja · $periodLabel',
          logoImage: logoImage,
          primary: primary,
        ),
        footer: (ctx) => _footer(ctx),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Text(
            'Período: ${dateFmt.format(periodStart)} – ${dateFmt.format(periodEnd)}',
            style: const pw.TextStyle(fontSize: 11),
          ),
          pw.SizedBox(height: 16),
          _kpiBlock(
            ingresos: ingresos,
            egresos: egresos,
            balance: balance,
            fmt: fmt,
            primary: primary,
          ),
          pw.SizedBox(height: 18),
          pw.Text('Detalle de movimientos',
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: primary,
              )),
          pw.SizedBox(height: 8),
          if (movements.isEmpty)
            pw.Text('Sin movimientos en el período.',
                style: const pw.TextStyle(fontSize: 11))
          else
            _movementsTable(movements, fmt, dateFmt, primary),
          pw.SizedBox(height: 14),
          _byCategoryBlock(movements, fmt, primary),
        ],
      ),
    );

    return doc.save();
  }

  // ─── Helpers de UI del PDF ───

  pw.Widget _header({
    required String associationName,
    required String subtitle,
    pw.MemoryImage? logoImage,
    required PdfColor primary,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: primary, width: 1.4),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          if (logoImage != null)
            pw.Container(
              width: 48,
              height: 48,
              margin: const pw.EdgeInsets.only(right: 12),
              child: pw.Image(logoImage, fit: pw.BoxFit.contain),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(associationName,
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: primary,
                    )),
                pw.Text(subtitle,
                    style: const pw.TextStyle(fontSize: 11)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('Generado',
                  style: pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey700)),
              pw.Text(
                DateFormat('dd MMM yyyy · HH:mm').format(DateTime.now()),
                style: const pw.TextStyle(fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _footer(pw.Context ctx) {
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Text(
        'Página ${ctx.pageNumber} de ${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ),
    );
  }

  pw.Widget _kpiBlock({
    required double ingresos,
    required double egresos,
    required double balance,
    required NumberFormat fmt,
    required PdfColor primary,
  }) {
    return pw.Row(
      children: [
        _kpiCell('Ingresos', fmt.format(ingresos), PdfColors.green700),
        pw.SizedBox(width: 8),
        _kpiCell('Egresos', fmt.format(egresos), PdfColors.red700),
        pw.SizedBox(width: 8),
        _kpiCell('Balance', fmt.format(balance),
            balance >= 0 ? primary : PdfColors.red900),
      ],
    );
  }

  pw.Widget _kpiCell(String label, String value, PdfColor color) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: color, width: 0.8),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(label,
                style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            pw.SizedBox(height: 4),
            pw.Text(value,
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                  color: color,
                )),
          ],
        ),
      ),
    );
  }

  pw.Widget _movementsTable(List<CashflowMovement> movs, NumberFormat fmt,
      DateFormat dateFmt, PdfColor primary) {
    return pw.TableHelper.fromTextArray(
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
        fontSize: 10,
      ),
      headerDecoration: pw.BoxDecoration(color: primary),
      cellStyle: const pw.TextStyle(fontSize: 9),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.centerLeft,
        2: pw.Alignment.centerLeft,
        3: pw.Alignment.centerLeft,
        4: pw.Alignment.centerRight,
      },
      headers: ['Fecha', 'Tipo', 'Categoría', 'Beneficiario / Descripción', 'Monto'],
      data: movs.map((m) {
        return [
          dateFmt.format(m.fecha),
          m.isIngreso ? 'Ingreso' : 'Egreso',
          m.categoria,
          [m.beneficiario, m.descripcion]
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .join(' · '),
          '${m.isIngreso ? '+' : '-'}${fmt.format(m.monto)}',
        ];
      }).toList(),
    );
  }

  pw.Widget _byCategoryBlock(
      List<CashflowMovement> movs, NumberFormat fmt, PdfColor primary) {
    final ingresos = <String, double>{};
    final egresos = <String, double>{};
    for (final m in movs) {
      final map = m.isIngreso ? ingresos : egresos;
      map[m.categoria] = (map[m.categoria] ?? 0) + m.monto;
    }
    if (ingresos.isEmpty && egresos.isEmpty) return pw.SizedBox();
    pw.Widget section(String title, Map<String, double> data, PdfColor color) {
      if (data.isEmpty) return pw.SizedBox();
      final entries = data.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: 10),
          pw.Text(title,
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: color,
                fontSize: 11,
              )),
          pw.SizedBox(height: 4),
          ...entries.map((e) => pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(e.key, style: const pw.TextStyle(fontSize: 10)),
                  pw.Text(fmt.format(e.value),
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                      )),
                ],
              )),
        ],
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Resumen por categoría',
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: primary,
            )),
        section('Ingresos', ingresos, PdfColors.green800),
        section('Egresos', egresos, PdfColors.red800),
      ],
    );
  }

  // ─── Theme con fuente Roboto (soporta tildes y ñ) ───

  pw.ThemeData? _cachedTheme;
  Future<pw.ThemeData> _theme() async {
    if (_cachedTheme != null) return _cachedTheme!;
    try {
      // PdfGoogleFonts incluye Roboto.
      final regular = await PdfGoogleFonts.robotoRegular();
      final bold = await PdfGoogleFonts.robotoBold();
      _cachedTheme = pw.ThemeData.withFont(base: regular, bold: bold);
    } catch (_) {
      _cachedTheme = pw.ThemeData();
    }
    return _cachedTheme!;
  }

  Future<pw.MemoryImage?> _loadLogo(String? logoUrl) async {
    if (logoUrl == null || logoUrl.isEmpty) {
      // Logo embedded del proyecto como fallback.
      try {
        final bytes = await rootBundle.load('assets/icon/app_icon.png');
        return pw.MemoryImage(bytes.buffer.asUint8List());
      } catch (_) {
        return null;
      }
    }
    try {
      final res = await http.get(Uri.parse(logoUrl));
      if (res.statusCode == 200) {
        return pw.MemoryImage(res.bodyBytes);
      }
    } catch (_) {}
    return null;
  }

  /// Dispara el diálogo nativo de impresión / compartir / guardar.
  Future<void> share(Uint8List bytes,
      {String fileName = 'reporte.pdf'}) async {
    await Printing.sharePdf(bytes: bytes, filename: fileName);
  }

  /// Carga datos de la asociación (nombre, logoUrl, primaryColor) desde Firestore.
  Future<({String name, String? logoUrl, PdfColor? primary})> loadAssociation(
      String aid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      if (!doc.exists) return (name: aid, logoUrl: null, primary: null);
      final data = doc.data()!;
      final theme = data['theme'] as Map<String, dynamic>?;
      final hex = theme?['primaryColor'] as String?;
      PdfColor? primary;
      if (hex != null && hex.startsWith('#') && hex.length == 7) {
        try {
          final r = int.parse(hex.substring(1, 3), radix: 16);
          final g = int.parse(hex.substring(3, 5), radix: 16);
          final b = int.parse(hex.substring(5, 7), radix: 16);
          primary = PdfColor.fromInt(0xff000000 | (r << 16) | (g << 8) | b);
        } catch (_) {}
      }
      return (
        name: (data['name'] as String?) ?? aid,
        logoUrl: theme?['logoUrl'] as String?,
        primary: primary,
      );
    } catch (_) {
      return (name: aid, logoUrl: null, primary: null);
    }
  }
}
