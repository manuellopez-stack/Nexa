import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

class OperationalStatusSection extends StatefulWidget {
  const OperationalStatusSection({super.key});

  @override
  State<OperationalStatusSection> createState() =>
      _OperationalStatusSectionState();
}

class _OperationalStatusSectionState extends State<OperationalStatusSection> {
  late Future<Map<String, dynamic>> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = ApiService.getDashboardSummary();
  }

  void _reload() {
    setState(() => _summaryFuture = ApiService.getDashboardSummary());
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
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
          const Text(
            'Estado operacional',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: NexaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Situación actual, calculada desde los pacientes registrados hoy',
            style: TextStyle(color: NexaColors.textSecondary),
          ),
          const SizedBox(height: 28),
          FutureBuilder<Map<String, dynamic>>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (snapshot.hasError || !snapshot.hasData) {
                final message = snapshot.error is ApiException
                    ? (snapshot.error as ApiException).message
                    : 'No fue posible cargar el estado operacional.';

                return Column(
                  children: [
                    Text(
                      message,
                      style: const TextStyle(color: Color(0xFF991B1B)),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _reload,
                      child: const Text('Reintentar'),
                    ),
                  ],
                );
              }

              final summary = snapshot.data!;
              final roomsInUse = _asInt(summary['roomsInUse']);
              final totalKnownRooms = _asInt(summary['totalKnownRooms']);
              final waiting = _asInt(summary['waiting']);
              final patientsToday = _asInt(summary['patientsToday']);
              final pendingValidation = _asInt(summary['pendingValidation']);
              final awaitingAnalysis =
                  _asInt(summary['documentsAwaitingAnalysis']);
              final totalUploaded =
                  _asInt(summary['totalUploadedDocuments']);

              return Column(
                children: [
                  StatusBar(
                    title: 'Salas en uso',
                    value: totalKnownRooms > 0
                        ? roomsInUse / totalKnownRooms
                        : 0,
                    label: '$roomsInUse de $totalKnownRooms en uso',
                    color: const Color(0xFF06B6D4),
                  ),
                  const SizedBox(height: 18),
                  StatusBar(
                    title: 'Pacientes esperando',
                    value: patientsToday > 0 ? waiting / patientsToday : 0,
                    label: '$waiting de $patientsToday pacientes',
                    color: NexaColors.primary,
                  ),
                  const SizedBox(height: 18),
                  StatusBar(
                    title: 'Documentos por validar',
                    value:
                        patientsToday > 0 ? pendingValidation / patientsToday : 0,
                    label: '$pendingValidation fichas pendientes',
                    color: const Color(0xFFF59E0B),
                  ),
                  const SizedBox(height: 18),
                  StatusBar(
                    title: 'Documentos sin analizar',
                    value:
                        totalUploaded > 0 ? awaitingAnalysis / totalUploaded : 0,
                    label: '$awaitingAnalysis de $totalUploaded documentos',
                    color: const Color(0xFF10B981),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.title,
    required this.value,
    required this.label,
    required this.color,
  });

  final String title;
  final double value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: NexaColors.textPrimary,
                ),
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: NexaColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 8,
            backgroundColor: Color(0xFFE8EEF5),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}