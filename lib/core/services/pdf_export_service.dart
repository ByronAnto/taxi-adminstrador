import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;

import '../../features/admin/data/models/cashflow_model.dart';
import '../../features/reports/data/weekly_closing_service.dart';

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

  // ─── Reporte semanal estilo Excel manual del admin ───
  //
  // Replica el formato que la administración maneja en hojas de cálculo:
  //   - Tabla izquierda: lista de unidades con su VALOR ($) o color
  //     rojo (NO PAGO) / azul (PERMISO).
  //   - Tabla derecha arriba: pagos a operadoras separados por
  //     Miércoles / Domingos / Extras + Total.
  //   - Tabla GASTOS VARIOS (recargas, mantenimiento puntual, etc.).
  //   - Tabla SOBRANTE SEMANA: Ingresos vs Egresos = balance.
  //   - Caja NOVEDADES con texto libre del admin.
  Future<Uint8List> buildWeeklyClosingPdf({
    required WeeklyClosingReport report,
    String? logoUrl,
    PdfColor? primaryColor,
  }) async {
    final theme = await _theme();
    final logoImage = await _loadLogo(logoUrl);
    final primary = primaryColor ?? PdfColors.blue800;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final dateFmt = DateFormat('dd MMM yyyy', 'es');

    // Colores de estado (igual que el Excel del admin).
    const cellPaid = PdfColor.fromInt(0xFFFFF59D); // amarillo
    const cellUnpaid = PdfColor.fromInt(0xFFE57373); // rojo
    const cellPermission = PdfColor.fromInt(0xFF64B5F6); // azul
    const headerYellow = PdfColor.fromInt(0xFFFFF59D);
    const greenTotal = PdfColor.fromInt(0xFFC8E6C9);
    const blueTotal = PdfColor.fromInt(0xFFBBDEFB);

    final doc = pw.Document(theme: theme);
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: _marginCm,
          marginRight: _marginCm,
          marginTop: _marginCm,
          marginBottom: _marginCm,
        ),
        header: (ctx) => _buildHeader(
          report.associationName,
          'Cierre semanal · ${dateFmt.format(report.weekStart)} al ${dateFmt.format(report.weekEnd)}',
          logoImage,
          primary,
        ),
        build: (ctx) => [
          // Banda superior con título de la semana.
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey200,
              border: pw.Border.all(color: PdfColors.grey400),
            ),
            alignment: pw.Alignment.center,
            child: pw.Text(
              'SEMANA DEL ${dateFmt.format(report.weekStart).toUpperCase()} AL ${dateFmt.format(report.weekEnd).toUpperCase()}',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          pw.SizedBox(height: 10),
          // Layout 2 columnas: Tabla unidades a la izquierda + Resumen a la derecha.
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ─── Columna izquierda: unidades ───
              pw.Expanded(
                flex: 4,
                child: _buildUnitsTable(report, fmt, headerYellow,
                    cellPaid, cellUnpaid, cellPermission, blueTotal),
              ),
              pw.SizedBox(width: 12),
              // ─── Columna derecha: operadoras + gastos + sobrante ───
              pw.Expanded(
                flex: 6,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    _buildOperatorsTable(
                        report, fmt, headerYellow, greenTotal, blueTotal),
                    pw.SizedBox(height: 14),
                    _buildMiscExpensesTable(
                        report, fmt, headerYellow, blueTotal),
                    pw.SizedBox(height: 14),
                    _buildBalanceTable(
                        report, fmt, headerYellow, blueTotal),
                    pw.SizedBox(height: 14),
                    _buildLegend(cellUnpaid, cellPermission),
                  ],
                ),
              ),
            ],
          ),
          if (report.novedades != null && report.novedades!.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            _buildNovedadesBox(report.novedades!),
          ],
        ],
      ),
    );
    return doc.save();
  }

  pw.Widget _buildUnitsTable(
    WeeklyClosingReport r,
    NumberFormat fmt,
    PdfColor headerYellow,
    PdfColor cellPaid,
    PdfColor cellUnpaid,
    PdfColor cellPermission,
    PdfColor blueTotal,
  ) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(28),
        1: pw.FlexColumnWidth(2.5),
        2: pw.FlexColumnWidth(1),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            _hCell('N°'),
            _hCell('Número de Unidad'),
            _hCellColored('VALOR', headerYellow),
          ],
        ),
        for (var i = 0; i < r.units.length; i++)
          pw.TableRow(children: [
            _cell('${i + 1}'),
            _cell('unidad ${r.units[i].unitNumber.padLeft(2, '0')}'),
            _valorCell(r.units[i], fmt, cellPaid, cellUnpaid, cellPermission),
          ]),
        pw.TableRow(
          decoration: pw.BoxDecoration(color: blueTotal),
          children: [
            _hCell(''),
            _hCell('total'),
            _hCell(fmt.format(r.totalUnits)),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildOperatorsTable(
    WeeklyClosingReport r,
    NumberFormat fmt,
    PdfColor headerYellow,
    PdfColor greenTotal,
    PdfColor blueTotal,
  ) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            _hCell('PAGOS DE OPERADORA'),
            _hCell('MIÉRCOLES'),
            _hCell('DOMINGOS'),
            _hCell('EXTRAS'),
            _hCell('Total'),
          ],
        ),
        for (final op in r.operatorPayments)
          pw.TableRow(children: [
            _cell(op.operatorName),
            _cell(fmt.format(op.miercoles)),
            _cell(fmt.format(op.domingos)),
            _cell(fmt.format(op.extras)),
            _cellColored(fmt.format(op.total), greenTotal),
          ]),
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            _hCell('total'),
            _hCell(fmt.format(r.operatorPayments
                .fold(0.0, (a, b) => a + b.miercoles))),
            _hCell(fmt.format(r.operatorPayments
                .fold(0.0, (a, b) => a + b.domingos))),
            _hCell(fmt.format(r.operatorPayments
                .fold(0.0, (a, b) => a + b.extras))),
            _hCellColored(fmt.format(r.totalOperators), blueTotal),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildMiscExpensesTable(
    WeeklyClosingReport r,
    NumberFormat fmt,
    PdfColor headerYellow,
    PdfColor blueTotal,
  ) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(1),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            _hCell('GASTOS VARIOS'),
            _hCell('Valor'),
          ],
        ),
        if (r.miscExpenses.isEmpty)
          pw.TableRow(children: [_cell(''), _cell('')])
        else
          for (final e in r.miscExpenses)
            pw.TableRow(children: [
              _cell(e.description),
              _cell(fmt.format(e.value)),
            ]),
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            _hCell('TOTAL'),
            _hCellColored(fmt.format(r.totalMisc), blueTotal),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildBalanceTable(
    WeeklyClosingReport r,
    NumberFormat fmt,
    PdfColor headerYellow,
    PdfColor blueTotal,
  ) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: [
            _hCell('SOBRANTE SEMANA'),
            _hCell('INGRESOS'),
            _hCell('EGRESOS'),
          ],
        ),
        pw.TableRow(children: [
          _cell('INGRESO DE UNIDADES'),
          _cell(fmt.format(r.totalUnits)),
          _cell(''),
        ]),
        pw.TableRow(children: [
          _cell('PAGO DE OPERADORAS'),
          _cell(''),
          _cell(fmt.format(r.totalOperators)),
        ]),
        pw.TableRow(children: [
          _cell('GASTOS VARIOS'),
          _cell(''),
          _cell(fmt.format(r.totalMisc)),
        ]),
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            _hCell('TOTAL SOBRANTE SEMANA'),
            pw.Container(
              padding: const pw.EdgeInsets.all(4),
              decoration: pw.BoxDecoration(color: blueTotal),
              alignment: pw.Alignment.center,
              child: pw.Text(
                fmt.format(r.balance),
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            ),
            _cell(''),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildLegend(PdfColor cellUnpaid, PdfColor cellPermission) {
    return pw.Row(children: [
      _legendChip(cellUnpaid, 'NO PAGO'),
      pw.SizedBox(width: 12),
      _legendChip(cellPermission, 'PERMISO'),
    ]);
  }

  pw.Widget _legendChip(PdfColor color, String label) {
    return pw.Row(children: [
      pw.Container(width: 16, height: 16, color: color),
      pw.SizedBox(width: 4),
      pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
    ]);
  }

  pw.Widget _buildNovedadesBox(String text) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey600, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(4),
            color: PdfColors.grey300,
            alignment: pw.Alignment.center,
            child: pw.Text('NOVEDADES',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 6),
          pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
    );
  }

  // ─── Helpers de celdas ───
  pw.Widget _hCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(
          text,
          style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold, fontSize: 9),
          textAlign: pw.TextAlign.center,
        ),
      );

  pw.Widget _hCellColored(String text, PdfColor color) => pw.Container(
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(color: color),
        alignment: pw.Alignment.center,
        child: pw.Text(text,
            style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold, fontSize: 9)),
      );

  pw.Widget _cell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Text(text,
            style: const pw.TextStyle(fontSize: 9),
            textAlign: pw.TextAlign.center),
      );

  pw.Widget _cellColored(String text, PdfColor color) => pw.Container(
        padding: const pw.EdgeInsets.all(4),
        decoration: pw.BoxDecoration(color: color),
        alignment: pw.Alignment.center,
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
      );

  pw.Widget _valorCell(
    WeeklyUnitRow u,
    NumberFormat fmt,
    PdfColor cellPaid,
    PdfColor cellUnpaid,
    PdfColor cellPermission,
  ) {
    switch (u.status) {
      case WeeklyUnitPaymentStatus.paid:
        return _cellColored(fmt.format(u.amount), cellPaid);
      case WeeklyUnitPaymentStatus.unpaid:
        return pw.Container(
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(color: cellUnpaid),
            alignment: pw.Alignment.center,
            child: pw.Text(''));
      case WeeklyUnitPaymentStatus.permission:
        return _cellColored('PERMISO', cellPermission);
    }
  }

  pw.Widget _buildHeader(String name, String subtitle,
      pw.MemoryImage? logo, PdfColor primary) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 8),
      decoration: pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: primary, width: 1.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          if (logo != null)
            pw.Container(
                width: 36, height: 36, child: pw.Image(logo)),
          if (logo != null) pw.SizedBox(width: 10),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(name,
                    style: pw.TextStyle(
                        color: primary,
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 14)),
                pw.Text(subtitle,
                    style: const pw.TextStyle(
                        fontSize: 9, color: PdfColors.grey700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Cierre mensual estilo Excel admin "MES X" ───
  //
  // Tabla con cabecera del mes + lista de semanas con su sobrante +
  // total del mes. Si hay saldo del mes anterior, se incluye como
  // primera fila (igual que en el Excel del admin).
  Future<Uint8List> buildMonthlyClosingPdf({
    required MonthlyClosingReport report,
    String? logoUrl,
    PdfColor? primaryColor,
  }) async {
    final theme = await _theme();
    final logoImage = await _loadLogo(logoUrl);
    final primary = primaryColor ?? PdfColors.blue800;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final dateFmt = DateFormat('dd MMM', 'es');

    const headerYellow = PdfColor.fromInt(0xFFFFF59D);
    const blueTotal = PdfColor.fromInt(0xFFBBDEFB);
    const greenWeek = PdfColor.fromInt(0xFFC8E6C9);

    final doc = pw.Document(theme: theme);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: _marginCm,
        marginRight: _marginCm,
        marginTop: _marginCm,
        marginBottom: _marginCm,
      ),
      header: (ctx) => _buildHeader(
        report.associationName,
        'Cierre mensual · ${report.monthLabel}',
        logoImage,
        primary,
      ),
      build: (ctx) => [
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: PdfColors.purple50,
            border: pw.Border.all(color: PdfColors.purple200),
          ),
          alignment: pw.Alignment.center,
          child: pw.Text(
            'SOBRANTE DE LAS UNIDADES SEMANALES ${report.monthLabel}',
            style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 12,
                color: PdfColors.purple800),
          ),
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(3),
            1: pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(
              decoration: pw.BoxDecoration(color: blueTotal),
              children: [
                _hCell('SOBRANTE MES ANTERIOR'),
                _hCellColored(
                    fmt.format(report.previousMonthBalance), headerYellow),
              ],
            ),
            for (final w in report.weeks)
              pw.TableRow(
                decoration: pw.BoxDecoration(color: greenWeek),
                children: [
                  _cell(
                      'Semana del ${dateFmt.format(w.weekStart)} al ${dateFmt.format(w.weekEnd)}'),
                  _cell(fmt.format(w.balance)),
                ],
              ),
            pw.TableRow(
              decoration: pw.BoxDecoration(color: blueTotal),
              children: [
                _hCell('SOBRANTE TOTAL DEL MES DE ${report.monthLabel.split(' ').first}'),
                _hCellColored(fmt.format(report.monthTotal), headerYellow),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Text(
          'Suma del mes (sin saldo previo): ${fmt.format(report.weeksTotal)}',
          style: const pw.TextStyle(
              fontSize: 9, color: PdfColors.grey700),
        ),
      ],
    ));
    return doc.save();
  }

  /// Cierre anual: tabla de 12 meses con sobrante de cada uno y total.
  Future<Uint8List> buildAnnualClosingPdf({
    required AnnualClosingReport report,
    String? logoUrl,
    PdfColor? primaryColor,
  }) async {
    final theme = await _theme();
    final logoImage = await _loadLogo(logoUrl);
    final primary = primaryColor ?? PdfColors.blue800;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    const headerYellow = PdfColor.fromInt(0xFFFFF59D);
    const blueTotal = PdfColor.fromInt(0xFFBBDEFB);

    final doc = pw.Document(theme: theme);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: _marginCm,
        marginRight: _marginCm,
        marginTop: _marginCm,
        marginBottom: _marginCm,
      ),
      header: (ctx) => _buildHeader(
        report.associationName,
        'Cierre anual · ${report.year}',
        logoImage,
        primary,
      ),
      build: (ctx) => [
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(3),
            1: pw.FlexColumnWidth(1),
            2: pw.FlexColumnWidth(1),
            3: pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [
                _hCell('Mes'),
                _hCell('Saldo previo'),
                _hCell('Sobrante mes'),
                _hCell('Total acumulado'),
              ],
            ),
            for (final m in report.months)
              pw.TableRow(children: [
                _cell(m.monthLabel),
                _cell(fmt.format(m.previousMonthBalance)),
                _cell(fmt.format(m.weeksTotal)),
                _cellColored(fmt.format(m.monthTotal), headerYellow),
              ]),
            pw.TableRow(
              decoration: pw.BoxDecoration(color: blueTotal),
              children: [
                _hCell('TOTAL ${report.year}'),
                _hCell(''),
                _hCell(fmt.format(
                    report.months.fold<double>(0, (a, m) => a + m.weeksTotal))),
                _hCellColored(fmt.format(report.yearTotal), headerYellow),
              ],
            ),
          ],
        ),
      ],
    ));
    return doc.save();
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
