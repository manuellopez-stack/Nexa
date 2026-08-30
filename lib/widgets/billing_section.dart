import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// Etiquetas legibles para los métodos de pago que acepta el backend.
const Map<String, String> _kPaymentMethods = {
  'efectivo': 'Efectivo',
  'tarjeta': 'Tarjeta',
  'transferencia': 'Transferencia',
  'bono_isapre': 'Bono Isapre',
  'bono_fonasa': 'Bono Fonasa',
  'convenio': 'Convenio',
};

String _sourceLabel(String? sourceType) {
  switch (sourceType) {
    case 'lab_order':
      return 'Laboratorio';
    case 'imaging_order':
      return 'Imagenología';
    default:
      return 'Cobro';
  }
}

/// Formatea un monto en pesos chilenos: 12340 -> "$12.340".
String _formatClp(num? value) {
  final amount = (value ?? 0).round();
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}\$${buffer.toString()}';
}

/// Sección "Cobros" de la ficha del paciente. Muestra la lista de cobros
/// (billing_orders) con sus pagos y permite registrar pagos y editar el
/// folio del bono. Se monta solo para administrador y recepción.
class BillingSection extends StatefulWidget {
  const BillingSection({super.key, required this.patientId});

  final int? patientId;

  @override
  State<BillingSection> createState() => _BillingSectionState();
}

class _BillingSectionState extends State<BillingSection> {
  late Future<List<Map<String, dynamic>>> _billingFuture;

  @override
  void initState() {
    super.initState();
    _billingFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    final patientId = widget.patientId;
    if (patientId == null) return Future.value([]);
    return ApiService.getPatientBilling(patientId);
  }

  void _reload() {
    setState(() {
      _billingFuture = _load();
    });
  }

  Future<void> _openRegisterPayment(Map<String, dynamic> order) async {
    final registered = await showDialog<bool>(
      context: context,
      builder: (_) => _RegisterPaymentDialog(
        billingOrderId: order['id']?.toString() ?? '',
        suggestedAmount: order['balance'] is num
            ? (order['balance'] as num)
            : null,
      ),
    );

    if (registered == true) _reload();
  }

  Future<void> _openEditBonoFolio(Map<String, dynamic> order) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _EditBonoFolioDialog(
        billingOrderId: order['id']?.toString() ?? '',
        currentFolio: order['bonoFolio']?.toString(),
      ),
    );

    if (updated == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.receipt_long_outlined, color: NexaColors.primary),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Cobros',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Actualizar',
              onPressed: _reload,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _billingFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              final error = snapshot.error;
              return Text(
                error is ApiException
                    ? error.message
                    : 'No fue posible cargar los cobros del paciente.',
                style: const TextStyle(color: Color(0xFFB91C1C)),
              );
            }

            final orders = snapshot.data ?? [];

            if (orders.isEmpty) {
              return const Text('Este paciente no tiene cobros registrados.');
            }

            return Column(
              children: orders
                  .map((order) => _BillingOrderCard(
                        order: order,
                        onRegisterPayment: () => _openRegisterPayment(order),
                        onEditBonoFolio: () => _openEditBonoFolio(order),
                      ))
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class _BillingOrderCard extends StatelessWidget {
  const _BillingOrderCard({
    required this.order,
    required this.onRegisterPayment,
    required this.onEditBonoFolio,
  });

  final Map<String, dynamic> order;
  final VoidCallback onRegisterPayment;
  final VoidCallback onEditBonoFolio;

  @override
  Widget build(BuildContext context) {
    final status = order['status']?.toString() ?? 'pendiente';
    final totalAmount = order['totalAmount'] is num
        ? order['totalAmount'] as num
        : 0;
    final totalPaid = order['totalPaid'] is num ? order['totalPaid'] as num : 0;
    final balance = order['balance'] is num ? order['balance'] as num : 0;
    final bonoFolio = order['bonoFolio']?.toString();
    final payments = (order['payments'] as List? ?? [])
        .whereType<Map>()
        .map((p) => Map<String, dynamic>.from(p))
        .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NexaColors.background,
        border: Border.all(color: NexaColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _sourceLabel(order['sourceType']?.toString()),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              _BillingStatusBadge(status: status),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total: ${_formatClp(totalAmount)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                'Pagado: ${_formatClp(totalPaid)}',
                style: const TextStyle(color: NexaColors.textSecondary),
              ),
            ],
          ),
          if (balance > 0) ...[
            const SizedBox(height: 2),
            Text(
              'Saldo pendiente: ${_formatClp(balance)}',
              style: const TextStyle(
                color: Color(0xFFC2410C),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (payments.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Pagos registrados',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: NexaColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            ...payments.map((payment) {
              final method = payment['method']?.toString() ?? '';
              final reference = payment['reference']?.toString();
              final amount = payment['amount'] is num
                  ? payment['amount'] as num
                  : 0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• ${_kPaymentMethods[method] ?? method}: '
                  '${_formatClp(amount)}'
                  '${reference != null && reference.isNotEmpty ? '  (ref: $reference)' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              );
            }),
          ],
          if (ApiService.canManageBilling) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Folio de bono: ${bonoFolio != null && bonoFolio.isNotEmpty ? bonoFolio : '—'}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                TextButton.icon(
                  onPressed: onEditBonoFolio,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Editar folio'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            if (status == 'pendiente') ...[
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: onRegisterPayment,
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Registrar pago'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _RegisterPaymentDialog extends StatefulWidget {
  const _RegisterPaymentDialog({
    required this.billingOrderId,
    this.suggestedAmount,
  });

  final String billingOrderId;
  final num? suggestedAmount;

  @override
  State<_RegisterPaymentDialog> createState() => _RegisterPaymentDialogState();
}

class _RegisterPaymentDialogState extends State<_RegisterPaymentDialog> {
  String _method = _kPaymentMethods.keys.first;
  late final TextEditingController _amountController;
  final TextEditingController _referenceController = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final suggested = widget.suggestedAmount;
    _amountController = TextEditingController(
      text: (suggested != null && suggested > 0)
          ? suggested.round().toString()
          : '',
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final amount = num.tryParse(
      _amountController.text.trim().replaceAll('.', '').replaceAll(',', '.'),
    );
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Ingresa un monto válido mayor a cero.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.registerPayment(
        billingOrderId: widget.billingOrderId,
        method: _method,
        amount: amount,
        reference: _referenceController.text,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible registrar el pago.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar pago'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _method,
              decoration: const InputDecoration(
                labelText: 'Método de pago',
                border: OutlineInputBorder(),
              ),
              items: _kPaymentMethods.entries
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _method = value);
              },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto',
                prefixText: '\$ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _referenceController,
              decoration: const InputDecoration(
                labelText: 'Referencia / folio de bono (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB91C1C)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}

class _EditBonoFolioDialog extends StatefulWidget {
  const _EditBonoFolioDialog({
    required this.billingOrderId,
    this.currentFolio,
  });

  final String billingOrderId;
  final String? currentFolio;

  @override
  State<_EditBonoFolioDialog> createState() => _EditBonoFolioDialogState();
}

class _EditBonoFolioDialogState extends State<_EditBonoFolioDialog> {
  late final TextEditingController _controller;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentFolio ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    final text = _controller.text.trim();

    try {
      await ApiService.updateBonoFolio(
        billingOrderId: widget.billingOrderId,
        bonoFolio: text.isEmpty ? null : text,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible actualizar el folio del bono.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Folio de bono'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Folio de bono',
                hintText: 'Déjalo vacío para quitar el folio',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB91C1C)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}

class _BillingStatusBadge extends StatelessWidget {
  const _BillingStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    String label;

    switch (status) {
      case 'pagado':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        label = 'Pagado';
        break;
      case 'facturado':
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        label = 'Facturado';
        break;
      default:
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        label = 'Pendiente';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
