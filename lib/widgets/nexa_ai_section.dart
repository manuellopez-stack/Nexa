import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../screens/chat_page.dart';
import '../services/api_service.dart';

class NexaAiSection extends StatefulWidget {
  const NexaAiSection({super.key});

  @override
  State<NexaAiSection> createState() => _NexaAiSectionState();
}

class _NexaAiSectionState extends State<NexaAiSection> {
  late Future<Map<String, dynamic>> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = ApiService.getDashboardSummary();
  }

  void _reload() {
    setState(() {
      _summaryFuture = ApiService.getDashboardSummary();
    });
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  void _openChat(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const ChatPage(
          initialPrompt:
              'Analiza la operación actual del centro y dime qué requiere mi atención.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // El backend solo permite usar la IA (/chat) a administrador y medico.
    // Para el resto de roles no mostramos esta sección.
    if (!ApiService.canUseAi) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NexaColors.border),
        boxShadow: const [
          BoxShadow(
            blurRadius: 24,
            offset: Offset(0, 10),
            color: Color(0x0D0F172A),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      NexaColors.primary,
                      Color(0xFF5FB39A),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Text(
                  'Imagenda AI',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: NexaColors.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFEFF),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Text(
                  'En línea',
                  style: TextStyle(
                    color: Color(0xFF0891B2),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            'Buenos días, Manuel.',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: NexaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<Map<String, dynamic>>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                );
              }

              if (snapshot.hasError || !snapshot.hasData) {
                final message = snapshot.error is ApiException
                    ? (snapshot.error as ApiException).message
                    : 'No fue posible cargar el resumen del día.';

                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF991B1B),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _reload,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                );
              }

              final summary = snapshot.data!;
              final patientsToday = _asInt(summary['patientsToday']);
              final waiting = _asInt(summary['waiting']);
              final pendingValidation = _asInt(summary['pendingValidation']);
              final roomsInUse = _asInt(summary['roomsInUse']);
              final totalKnownRooms = _asInt(summary['totalKnownRooms']);

              final insights = <_InsightRow>[
                if (waiting > 0)
                  _InsightRow(
                    color: const Color(0xFFF59E0B),
                    icon: Icons.schedule,
                    text: waiting == 1
                        ? '1 paciente en espera en este momento.'
                        : '$waiting pacientes en espera en este momento.',
                  ),
                if (pendingValidation > 0)
                  _InsightRow(
                    color: const Color(0xFFEF4444),
                    icon: Icons.fact_check_outlined,
                    text: pendingValidation == 1
                        ? '1 documento u orden pendiente de validar.'
                        : '$pendingValidation documentos/órdenes pendientes de validar.',
                  ),
                if (roomsInUse > 0)
                  _InsightRow(
                    color: const Color(0xFF5FB39A),
                    icon: Icons.meeting_room_outlined,
                    text: '$roomsInUse de $totalKnownRooms salas en uso.',
                  ),
                if (patientsToday > 0)
                  _InsightRow(
                    color: NexaColors.primary,
                    icon: Icons.people_outline,
                    text: patientsToday == 1
                        ? 'Hoy hay 1 paciente en la agenda.'
                        : 'Hoy hay $patientsToday pacientes en la agenda.',
                  ),
              ].take(3).toList();

              if (insights.isEmpty) {
                return const _InsightRow(
                  color: Color(0xFF10B981),
                  icon: Icons.check_circle_outline,
                  text: 'Sin novedades para hoy.',
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Esto es lo que encontré para la operación de hoy:',
                    style: TextStyle(
                      height: 1.5,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (var i = 0; i < insights.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    insights[i],
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openChat(context),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Preguntar a Imagenda'),
              style: FilledButton.styleFrom(
                backgroundColor: NexaColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({
    required this.color,
    required this.icon,
    required this.text,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 18,
            color: color,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              text,
              style: const TextStyle(
                height: 1.4,
                color: NexaColors.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
