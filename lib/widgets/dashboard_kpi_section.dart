import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

class DashboardKpiSection extends StatefulWidget {
  const DashboardKpiSection({super.key});

  @override
  State<DashboardKpiSection> createState() => _DashboardKpiSectionState();
}

class _DashboardKpiSectionState extends State<DashboardKpiSection> {
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
    return FutureBuilder<Map<String, dynamic>>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 188,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          final message = snapshot.error is ApiException
              ? (snapshot.error as ApiException).message
              : 'No fue posible cargar el resumen del día.';

          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
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
                const SizedBox(height: 10),
                TextButton(onPressed: _reload, child: const Text('Reintentar')),
              ],
            ),
          );
        }

        final summary = snapshot.data!;
        final patientsToday = _asInt(summary['patientsToday']);
        final waiting = _asInt(summary['waiting']);
        final inAttention = _asInt(summary['inAttention']);
        final scheduled = _asInt(summary['scheduled']);
        final pendingValidation = _asInt(summary['pendingValidation']);
        final totalUploaded = _asInt(summary['totalUploadedDocuments']);
        final totalAnalyzed = _asInt(summary['totalAnalyzedDocuments']);

        final cards = [
          KpiCard(
            title: 'Pacientes hoy',
            value: '$patientsToday',
            variation: '$inAttention en atención',
            detail: '$waiting esperando · $scheduled programados',
            icon: Icons.people_outline,
            accentColor: NexaColors.primary,
            progress: patientsToday > 0 ? inAttention / patientsToday : 0,
          ),
          KpiCard(
            title: 'Documentos analizados por IA',
            value: '$totalAnalyzed',
            variation: 'de $totalUploaded cargados',
            detail: '${(totalUploaded - totalAnalyzed).clamp(0, totalUploaded)} por procesar',
            icon: Icons.description_outlined,
            accentColor: const Color(0xFF06B6D4),
            progress: totalUploaded > 0 ? totalAnalyzed / totalUploaded : 0,
          ),
          KpiCard(
            title: 'Pendientes de validación',
            value: '$pendingValidation',
            variation: pendingValidation > 0 ? 'Requiere revisión' : 'Al día',
            detail: 'de $patientsToday pacientes registrados',
            icon: Icons.fact_check_outlined,
            accentColor: const Color(0xFFF59E0B),
            progress: patientsToday > 0 ? pendingValidation / patientsToday : 0,
          ),
          const KpiCard(
            title: 'Backend Nexa',
            value: 'Operativo',
            variation: 'En línea',
            detail: 'Conectividad en tiempo real',
            icon: Icons.cloud_done_outlined,
            accentColor: Color(0xFF10B981),
            progress: 1,
          ),
        ];

        return LayoutBuilder(
          builder: (context, constraints) {
            int columns;

            if (constraints.maxWidth >= 1050) {
              columns = 4;
            } else if (constraints.maxWidth >= 620) {
              columns = 2;
            } else {
              columns = 1;
            }

            const spacing = 16.0;

            final cardWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: cards
                  .map(
                    (card) => SizedBox(
                      width: cardWidth,
                      child: card,
                    ),
                  )
                  .toList(),
            );
          },
        );
      },
    );
  }
}

class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.title,
    required this.value,
    required this.variation,
    required this.detail,
    required this.icon,
    required this.accentColor,
    required this.progress,
  });

  final String title;
  final String value;
  final String variation;
  final String detail;
  final IconData icon;
  final Color accentColor;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 188,
      padding: const EdgeInsets.all(20),
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
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  icon,
                  color: accentColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 29,
              fontWeight: FontWeight.w800,
              color: NexaColors.textPrimary,
              letterSpacing: -0.7,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                variation,
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: const Color(0xFFE8EEF5),
              valueColor: AlwaysStoppedAnimation<Color>(accentColor),
            ),
          ),
        ],
      ),
    );
  }
}