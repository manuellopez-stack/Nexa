import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import 'billing_section.dart';

const _kWeekdays = [
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];

const _kMonths = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

String _two(int n) => n.toString().padLeft(2, '0');

String _dayLabel(DateTime d) =>
    '${_kWeekdays[d.weekday - 1]} ${d.day} de ${_kMonths[d.month - 1]} de ${d.year}';

String _paymentsCount(int count) => count == 1 ? '1 pago' : '$count pagos';

String _methodLabel(String? method) =>
    kPaymentMethodLabels[method] ?? method ?? 'Sin método';

// Hora "HH:mm" de un pago. paid_at viene en UTC; se muestra en la hora del
// equipo, que en la clínica es la de Chile.
String _clock(Object? paidAt) {
  final parsed = DateTime.tryParse(paidAt?.toString() ?? '');
  if (parsed == null) return '';
  final local = parsed.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

List<Map<String, dynamic>> _mapList(Object? value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

int _asInt(Object? value) => value is num ? value.toInt() : 0;

/// Diálogo "Cierre de caja" del Centro de Control: pagos de un día (hoy por
/// defecto, sin permitir días futuros) con totales, desglose por método y,
/// para administrador, por recepcionista. Recepción ve solo sus propios
/// pagos (el backend ya filtra; ver GET /billing/daily-summary).
class CashCloseDialog extends StatefulWidget {
  const CashCloseDialog({super.key});

  @override
  State<CashCloseDialog> createState() => _CashCloseDialogState();
}

class _CashCloseDialogState extends State<CashCloseDialog> {
  late DateTime _day = _today();
  late Future<Map<String, dynamic>> _future = _load();

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool get _isToday => _day == _today();

  Future<Map<String, dynamic>> _load() =>
      ApiService.getDailyCashSummary(date: _day);

  void _goTo(DateTime day) {
    final today = _today();
    setState(() {
      _day = day.isAfter(today) ? today : day;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mine = ApiService.isReception;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Cierre de caja'),
          if (mine) ...[
            const SizedBox(height: 4),
            const Text(
              'Solo los pagos que registraste tú',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w400,
                color: NexaColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDaySelector(),
            const SizedBox(height: 16),
            Flexible(
              child: FutureBuilder<Map<String, dynamic>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    final error = snapshot.error;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        error is ApiException
                            ? error.message
                            : 'No fue posible obtener el cierre de caja.',
                        style: const TextStyle(color: Color(0xFFB91C1C)),
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    child: _buildSummary(snapshot.data!, showUser: !mine),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _buildDaySelector() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Día anterior',
          onPressed: () => _goTo(_day.subtract(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            _dayLabel(_day),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: NexaColors.textPrimary,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Día siguiente',
          onPressed: _isToday
              ? null
              : () => _goTo(_day.add(const Duration(days: 1))),
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 4),
        OutlinedButton(
          onPressed: _isToday ? null : () => _goTo(_today()),
          child: const Text('Hoy'),
        ),
      ],
    );
  }

  Widget _buildSummary(Map<String, dynamic> data, {required bool showUser}) {
    final count = _asInt(data['count']);
    if (count == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No hay pagos registrados este día.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NexaColors.textSecondary),
        ),
      );
    }

    final byMethod = _mapList(data['byMethod']);
    final byUser = _mapList(data['byUser']);
    final payments = _mapList(data['payments']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _TotalBox(
                label: 'Total recaudado',
                value: formatClp(data['total'] as num?),
                detail: _paymentsCount(count),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _TotalBox(
                label: 'En efectivo',
                value: formatClp(data['cashTotal'] as num?),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const _SectionTitle('Por método de pago'),
        for (final row in byMethod)
          _SummaryRow(
            label: _methodLabel(row['method']?.toString()),
            count: _asInt(row['count']),
            amount: row['total'] as num?,
          ),
        if (showUser && byUser.isNotEmpty) ...[
          const SizedBox(height: 20),
          const _SectionTitle('Por recepcionista'),
          for (final row in byUser)
            _SummaryRow(
              label: row['name']?.toString() ?? 'Sin registrar',
              count: _asInt(row['count']),
              amount: row['total'] as num?,
            ),
        ],
        const SizedBox(height: 20),
        const _SectionTitle('Pagos del día'),
        for (final payment in payments)
          _PaymentRow(payment: payment, showUser: showUser),
      ],
    );
  }
}

class _TotalBox extends StatelessWidget {
  const _TotalBox({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexaColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: NexaColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: NexaColors.textPrimary,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(
              detail!,
              style: const TextStyle(
                fontSize: 12.5,
                color: NexaColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: NexaColors.textPrimary,
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.count,
    required this.amount,
  });

  final String label;
  final int count;
  final num? amount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: NexaColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 80,
            child: Text(
              _paymentsCount(count),
              textAlign: TextAlign.right,
              style: const TextStyle(color: NexaColors.textSecondary),
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              formatClp(amount),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment, required this.showUser});

  final Map<String, dynamic> payment;
  final bool showUser;

  @override
  Widget build(BuildContext context) {
    final reference = payment['reference']?.toString().trim() ?? '';
    final details = [
      _methodLabel(payment['method']?.toString()),
      if (reference.isNotEmpty) 'Ref. $reference',
      if (showUser) 'Registró: ${payment['registeredByName'] ?? 'Sin registrar'}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: NexaColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              _clock(payment['paidAt']),
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: NexaColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  payment['patientName']?.toString() ?? 'Paciente sin nombre',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            formatClp(payment['amount'] as num?),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
