import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_xlsio/xlsio.dart' as xlsio;

import '../../features/admin/data/models/cashflow_model.dart';

/// Servicio para generar archivos Excel (.xlsx) reales con `syncfusion_flutter_xlsio`.
///
/// Cumple el requerimiento del Dominio E del PROMPT_MAESTRO:
/// "Excel: una hoja por período, formato ec-ES."
///
/// Este servicio genera un .xlsx con:
/// - Hoja "Resumen": KPIs (ingresos, egresos, balance) + breakdown por categoría.
/// - Hoja "Movimientos": tabla detallada de cada movimiento del período.
/// - Hoja "Categorías": agregación por categoría con totales.
class ExcelExportService {
  ExcelExportService._();
  static final ExcelExportService instance = ExcelExportService._();

  /// Genera el archivo Excel del reporte de cashflow y lo retorna como bytes.
  Uint8List buildCashflowReport({
    required String associationName,
    required List<CashflowMovement> movements,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String periodLabel,
  }) {
    final workbook = xlsio.Workbook();
    try {
      _buildResumenSheet(
        workbook,
        associationName: associationName,
        movements: movements,
        periodStart: periodStart,
        periodEnd: periodEnd,
        periodLabel: periodLabel,
      );
      _buildMovimientosSheet(workbook, movements);
      _buildCategoriasSheet(workbook, movements);

      // La hoja default 'Sheet1' queda como primera del workbook; las
      // que agregamos vienen después. Reordenar/borrar Sheet1 no es
      // crítico (Excel la abre en cualquier orden); la dejamos para no
      // depender de APIs específicas de versión de syncfusion.

      final bytes = workbook.saveAsStream();
      return Uint8List.fromList(bytes);
    } finally {
      workbook.dispose();
    }
  }

  void _buildResumenSheet(
    xlsio.Workbook wb, {
    required String associationName,
    required List<CashflowMovement> movements,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String periodLabel,
  }) {
    final sheet = wb.worksheets.addWithName('Resumen');
    sheet.getRangeByName('A1:D1').merge();
    final title = sheet.getRangeByName('A1');
    title.setText(associationName);
    title.cellStyle.fontSize = 16;
    title.cellStyle.bold = true;
    title.cellStyle.hAlign = xlsio.HAlignType.left;

    sheet.getRangeByName('A2:D2').merge();
    final subtitle = sheet.getRangeByName('A2');
    subtitle.setText('Reporte de Caja · $periodLabel');
    subtitle.cellStyle.fontSize = 12;
    subtitle.cellStyle.italic = true;

    sheet.getRangeByName('A3').setText('Período');
    sheet.getRangeByName('B3').setText(
        '${DateFormat('dd MMM yyyy').format(periodStart)} – ${DateFormat('dd MMM yyyy').format(periodEnd)}');

    sheet.getRangeByName('A4').setText('Generado');
    sheet.getRangeByName('B4').setText(
        DateFormat('dd MMM yyyy · HH:mm').format(DateTime.now()));

    final ingresos =
        movements.where((m) => m.isIngreso).fold<double>(0, (s, m) => s + m.monto);
    final egresos =
        movements.where((m) => m.isEgreso).fold<double>(0, (s, m) => s + m.monto);
    final balance = ingresos - egresos;

    // KPIs
    final kpiHeader = sheet.getRangeByName('A6');
    kpiHeader.setText('KPIs del período');
    kpiHeader.cellStyle.bold = true;
    kpiHeader.cellStyle.fontSize = 13;

    sheet.getRangeByName('A7').setText('Ingresos');
    sheet.getRangeByName('B7').setNumber(ingresos);
    sheet.getRangeByName('B7').numberFormat = '"\$"#,##0.00';

    sheet.getRangeByName('A8').setText('Egresos');
    sheet.getRangeByName('B8').setNumber(egresos);
    sheet.getRangeByName('B8').numberFormat = '"\$"#,##0.00';

    sheet.getRangeByName('A9').setText('Balance');
    sheet.getRangeByName('B9').setNumber(balance);
    sheet.getRangeByName('B9').numberFormat = '"\$"#,##0.00';
    sheet.getRangeByName('B9').cellStyle.bold = true;

    // Categorías
    final byCat = <String, ({double ingresos, double egresos})>{};
    for (final m in movements) {
      final cur = byCat[m.categoria] ?? (ingresos: 0.0, egresos: 0.0);
      byCat[m.categoria] = (
        ingresos: cur.ingresos + (m.isIngreso ? m.monto : 0),
        egresos: cur.egresos + (m.isEgreso ? m.monto : 0),
      );
    }

    final catHeader = sheet.getRangeByName('A11');
    catHeader.setText('Resumen por categoría');
    catHeader.cellStyle.bold = true;
    catHeader.cellStyle.fontSize = 13;

    sheet.getRangeByName('A12').setText('Categoría');
    sheet.getRangeByName('B12').setText('Ingresos');
    sheet.getRangeByName('C12').setText('Egresos');
    sheet.getRangeByName('D12').setText('Neto');
    sheet.getRangeByName('A12:D12').cellStyle.bold = true;
    sheet.getRangeByName('A12:D12').cellStyle.backColor = '#1565C0';
    sheet.getRangeByName('A12:D12').cellStyle.fontColor = '#FFFFFF';

    var row = 13;
    for (final entry in byCat.entries) {
      sheet.getRangeByIndex(row, 1).setText(entry.key);
      sheet.getRangeByIndex(row, 2).setNumber(entry.value.ingresos);
      sheet.getRangeByIndex(row, 2).numberFormat = '"\$"#,##0.00';
      sheet.getRangeByIndex(row, 3).setNumber(entry.value.egresos);
      sheet.getRangeByIndex(row, 3).numberFormat = '"\$"#,##0.00';
      sheet.getRangeByIndex(row, 4)
          .setNumber(entry.value.ingresos - entry.value.egresos);
      sheet.getRangeByIndex(row, 4).numberFormat = '"\$"#,##0.00';
      row++;
    }

    sheet.autoFitColumn(1);
    sheet.autoFitColumn(2);
    sheet.autoFitColumn(3);
    sheet.autoFitColumn(4);
  }

  void _buildMovimientosSheet(
      xlsio.Workbook wb, List<CashflowMovement> movements) {
    final sheet = wb.worksheets.addWithName('Movimientos');

    // Encabezados
    final headers = [
      'Fecha',
      'Tipo',
      'Categoría',
      'Subcategoría',
      'Monto',
      'Método',
      'Beneficiario',
      'Descripción',
    ];
    for (var i = 0; i < headers.length; i++) {
      final cell = sheet.getRangeByIndex(1, i + 1);
      cell.setText(headers[i]);
      cell.cellStyle.bold = true;
      cell.cellStyle.backColor = '#1565C0';
      cell.cellStyle.fontColor = '#FFFFFF';
    }

    // Ordenar por fecha desc
    final sorted = [...movements]..sort((a, b) => b.fecha.compareTo(a.fecha));

    for (var i = 0; i < sorted.length; i++) {
      final m = sorted[i];
      final row = i + 2;
      sheet
          .getRangeByIndex(row, 1)
          .setText(DateFormat('yyyy-MM-dd').format(m.fecha));
      sheet
          .getRangeByIndex(row, 2)
          .setText(m.isIngreso ? 'Ingreso' : 'Egreso');
      sheet.getRangeByIndex(row, 3).setText(m.categoria);
      sheet.getRangeByIndex(row, 4).setText(m.subcategoria ?? '');
      // Monto con signo según tipo
      sheet.getRangeByIndex(row, 5)
          .setNumber(m.isIngreso ? m.monto : -m.monto);
      sheet.getRangeByIndex(row, 5).numberFormat = '"\$"#,##0.00';
      sheet.getRangeByIndex(row, 6).setText(m.metodoPago ?? '');
      sheet.getRangeByIndex(row, 7).setText(m.beneficiario ?? '');
      sheet.getRangeByIndex(row, 8).setText(m.descripcion ?? '');
    }

    for (var i = 1; i <= headers.length; i++) {
      sheet.autoFitColumn(i);
    }
  }

  void _buildCategoriasSheet(
      xlsio.Workbook wb, List<CashflowMovement> movements) {
    final sheet = wb.worksheets.addWithName('Categorías');

    sheet.getRangeByName('A1').setText('Categoría');
    sheet.getRangeByName('B1').setText('Tipo');
    sheet.getRangeByName('C1').setText('Total');
    sheet.getRangeByName('D1').setText('Cantidad');
    sheet.getRangeByName('A1:D1').cellStyle.bold = true;
    sheet.getRangeByName('A1:D1').cellStyle.backColor = '#1565C0';
    sheet.getRangeByName('A1:D1').cellStyle.fontColor = '#FFFFFF';

    final ingresos = <String, ({double total, int count})>{};
    final egresos = <String, ({double total, int count})>{};
    for (final m in movements) {
      final map = m.isIngreso ? ingresos : egresos;
      final cur = map[m.categoria] ?? (total: 0.0, count: 0);
      map[m.categoria] =
          (total: cur.total + m.monto, count: cur.count + 1);
    }

    var row = 2;
    for (final e in ingresos.entries) {
      sheet.getRangeByIndex(row, 1).setText(e.key);
      sheet.getRangeByIndex(row, 2).setText('Ingreso');
      sheet.getRangeByIndex(row, 3).setNumber(e.value.total);
      sheet.getRangeByIndex(row, 3).numberFormat = '"\$"#,##0.00';
      sheet.getRangeByIndex(row, 4).setNumber(e.value.count.toDouble());
      row++;
    }
    for (final e in egresos.entries) {
      sheet.getRangeByIndex(row, 1).setText(e.key);
      sheet.getRangeByIndex(row, 2).setText('Egreso');
      sheet.getRangeByIndex(row, 3).setNumber(e.value.total);
      sheet.getRangeByIndex(row, 3).numberFormat = '"\$"#,##0.00';
      sheet.getRangeByIndex(row, 4).setNumber(e.value.count.toDouble());
      row++;
    }

    for (var i = 1; i <= 4; i++) {
      sheet.autoFitColumn(i);
    }
  }

  /// Guarda los bytes en un archivo temporal y dispara el share nativo.
  Future<void> share(Uint8List bytes,
      {String fileName = 'reporte.xlsx'}) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$fileName';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles(
      [
        XFile(
          path,
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          name: fileName,
        ),
      ],
      subject: fileName,
    );
  }

  /// Carga datos básicos de la asociación (nombre, etc.) desde Firestore.
  Future<String> loadAssociationName(String aid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('associations')
          .doc(aid)
          .get();
      if (!doc.exists) return aid;
      return (doc.data()?['name'] as String?) ?? aid;
    } catch (_) {
      return aid;
    }
  }
}
