import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';

class OperationalStatusSection extends StatelessWidget {
  const OperationalStatusSection({super.key});

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
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Estado operacional',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: NexaColors.textPrimary,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Situación actual de las áreas principales',
            style: TextStyle(
              color: NexaColors.textSecondary,
            ),
          ),
          SizedBox(height: 28),

          StatusBar(
            title: 'Equipos',
            value: 0.82,
            label: '4 de 5 disponibles',
            color: Color(0xFF06B6D4),
          ),

          SizedBox(height: 18),

          StatusBar(
            title: 'Agenda',
            value: 0.92,
            label: '92 % ocupación',
            color: NexaColors.primary,
          ),

          SizedBox(height: 18),

          StatusBar(
            title: 'Personal',
            value: 1.0,
            label: 'Equipo completo',
            color: Color(0xFF10B981),
          ),

          SizedBox(height: 18),

          StatusBar(
            title: 'Conectividad',
            value: 0.98,
            label: 'Servicios operativos',
            color: Color(0xFF10B981),
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