import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';

class DashboardKpiSection extends StatelessWidget {
  const DashboardKpiSection({super.key});

  @override
  Widget build(BuildContext context) {
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
          children: const [
            KpiCard(
              title: 'Pacientes hoy',
              value: '126',
              variation: '+14%',
              detail: 'Meta: 120',
              icon: Icons.people_outline,
              accentColor: NexaColors.primary,
              progress: 1,
            ),
            KpiCard(
              title: 'Estudios',
              value: '148',
              variation: '+8%',
              detail: 'Meta: 150',
              icon: Icons.monitor_heart_outlined,
              accentColor: Color(0xFF06B6D4),
              progress: 0.98,
            ),
            KpiCard(
              title: 'Ingresos',
              value: '\$4.320.000',
              variation: '+18%',
              detail: 'Proyección diaria',
              icon: Icons.payments_outlined,
              accentColor: Color(0xFF10B981),
              progress: 0.92,
            ),
            KpiCard(
              title: 'Alertas',
              value: '2',
              variation: '1 crítica',
              detail: 'Requieren atención',
              icon: Icons.warning_amber_rounded,
              accentColor: Color(0xFFF59E0B),
              progress: 0.38,
            ),
          ]
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