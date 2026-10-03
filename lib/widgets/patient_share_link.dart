import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// "Enlace para el paciente": estado del QR que va en el informe firmado
/// (vence a los 365 días, se revoca al firmar una versión nueva), cuántas veces
/// se abrió y botón para revocarlo. Solo médico y administrador; si la orden
/// no tiene enlace (o falla la carga) no se muestra nada.
class PatientShareLinkCard extends StatefulWidget {
  const PatientShareLinkCard({
    super.key,
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  static bool get canManage =>
      ApiService.role == 'medico' || ApiService.role == 'administrador';

  @override
  State<PatientShareLinkCard> createState() => _PatientShareLinkCardState();
}

class _PatientShareLinkCardState extends State<PatientShareLinkCard> {
  late Future<Map<String, dynamic>?> _future;
  bool _revoking = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>?> _load() => ApiService.getPatientShareLink(
    patientId: widget.patientId,
    orderId: widget.orderId,
  );

  static String _formatDate(Object? value, {bool withTime = false}) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    final day = '${two(date.day)}-${two(date.month)}-${date.year}';
    return withTime ? '$day ${two(date.hour)}:${two(date.minute)}' : day;
  }

  Future<void> _revoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revocar enlace del paciente'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'El código QR del informe dejará de funcionar y el paciente ya no '
            'podrá ver sus imágenes desde el celular. Para darle un enlace '
            'nuevo hay que firmar una nueva versión del informe.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NexaColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Revocar enlace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _revoking = true);
    try {
      final link = await ApiService.revokePatientShareLink(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      if (!mounted) return;
      setState(() => _future = Future.value(link));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enlace del paciente revocado.')),
      );
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PatientShareLinkCard.canManage) return const SizedBox.shrink();
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snapshot) {
        final link = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done ||
            snapshot.hasError ||
            link == null) {
          return const SizedBox.shrink();
        }

        final status = link['status']?.toString() ?? '';
        final (label, color) = switch (status) {
          'activo' => ('Activo', NexaColors.success),
          'vencido' => ('Vencido', NexaColors.warning),
          'revocado' => ('Revocado', NexaColors.error),
          _ => (status, NexaColors.textSecondary),
        };
        final accessCount = link['accessCount'] is int
            ? link['accessCount'] as int
            : 0;
        final lastAccess = link['lastAccessAt'];

        final details = <String>[
          if (status == 'revocado')
            'Revocado el ${_formatDate(link['revokedAt'])}'
          else
            '${status == 'vencido' ? 'Venció' : 'Vence'} el '
                '${_formatDate(link['expiresAt'])}',
          accessCount == 1 ? '1 acceso' : '$accessCount accesos',
          lastAccess == null
              ? 'Sin accesos todavía'
              : 'Último acceso: ${_formatDate(lastAccess, withTime: true)}',
          if (link['locked'] == true) 'Bloqueado 15 min por claves erradas',
        ];

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NexaColors.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: NexaColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.qr_code_2,
                    size: 20,
                    color: NexaColors.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Enlace para el paciente',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Código QR del informe firmado. El paciente entra con los 4 '
                'primeros dígitos de su RUT.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: NexaColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Text(details.join('  ·  '), style: const TextStyle(fontSize: 13)),
              if (status == 'activo') ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _revoking ? null : _revoke,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: NexaColors.error,
                  ),
                  icon: _revoking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link_off, size: 18),
                  label: const Text('Revocar enlace'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
