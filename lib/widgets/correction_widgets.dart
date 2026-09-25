import 'package:flutter/material.dart';

/// Piezas comunes de "Pedir corrección" (ver sql/correction_requests.sql):
/// el cuadro para escribir el motivo, el aviso rojo suave y el chip
/// "Devuelto". Un documento u orden está devuelto mientras traiga
/// `correctionReason`.

const int kCorrectionReasonMinLength = 5;

const Color _kReturnedBackground = Color(0xFFFEF2F2);
const Color _kReturnedBorder = Color(0xFFFECACA);
const Color _kReturnedText = Color(0xFFB91C1C);

/// true si el documento u orden tiene una corrección pendiente.
bool hasPendingCorrection(Map<String, dynamic>? item) {
  final reason = item?['correctionReason']?.toString().trim() ?? '';
  return reason.isNotEmpty;
}

/// Pide el motivo de la corrección (obligatorio, mínimo 5 caracteres).
/// Devuelve el motivo o null si se cancela.
Future<String?> showCorrectionReasonDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _CorrectionReasonDialog(),
  );
}

class _CorrectionReasonDialog extends StatefulWidget {
  const _CorrectionReasonDialog();

  @override
  State<_CorrectionReasonDialog> createState() =>
      _CorrectionReasonDialogState();
}

class _CorrectionReasonDialogState extends State<_CorrectionReasonDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.length < kCorrectionReasonMinLength) {
      setState(
        () => _error =
            'Escribe el motivo (mínimo $kCorrectionReasonMinLength caracteres).',
      );
      return;
    }
    Navigator.pop(context, reason);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pedir corrección'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'El informe vuelve a quien lo cargó para que lo corrija. '
              'Explica qué hay que corregir.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: 'Motivo *',
                hintText: 'Ej: falta el valor de hemoglobina',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: _kReturnedText),
          child: const Text('Pedir corrección'),
        ),
      ],
    );
  }
}

/// Aviso rojo suave: `Devuelto para corrección: <motivo> — <quien> · <fecha>`.
/// No muestra nada si el ítem no tiene corrección pendiente.
class CorrectionNotice extends StatelessWidget {
  const CorrectionNotice({super.key, required this.item});

  final Map<String, dynamic>? item;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String? _formatDate(dynamic value) {
    final date = value == null ? null : DateTime.tryParse('$value')?.toLocal();
    if (date == null) return null;
    return '${_two(date.day)}/${_two(date.month)}/${date.year} '
        '${_two(date.hour)}:${_two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPendingCorrection(item)) return const SizedBox.shrink();

    final reason = item!['correctionReason'].toString().trim();
    final by = item!['correctionRequestedBy']?.toString().trim();
    final at = _formatDate(item!['correctionRequestedAt']);
    final meta = [
      if (by != null && by.isNotEmpty) by,
      ?at,
    ].join(' · ');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kReturnedBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kReturnedBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.undo_rounded, size: 18, color: _kReturnedText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              meta.isEmpty
                  ? 'Devuelto para corrección: $reason'
                  : 'Devuelto para corrección: $reason — $meta',
              style: const TextStyle(color: _kReturnedText, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Chip rojo 'Devuelto' para listas de la ficha del paciente.
class ReturnedChip extends StatelessWidget {
  const ReturnedChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _kReturnedBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _kReturnedBorder),
      ),
      child: const Text(
        'Devuelto',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: _kReturnedText,
        ),
      ),
    );
  }
}
