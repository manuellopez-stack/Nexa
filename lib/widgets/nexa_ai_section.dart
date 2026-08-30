import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../screens/chat_page.dart';
import '../services/api_service.dart';

class NexaAiSection extends StatelessWidget {
  const NexaAiSection({super.key});

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
                      Color(0xFF06B6D4),
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
                  'Nexa AI',
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
          const Text(
            'He detectado tres situaciones relevantes para la operación de hoy:',
            style: TextStyle(
              height: 1.5,
              color: NexaColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          const _InsightRow(
            color: Color(0xFFEF4444),
            icon: Icons.build_circle_outlined,
            text: 'El mamógrafo permanece fuera de servicio.',
          ),
          const SizedBox(height: 14),
          const _InsightRow(
            color: Color(0xFFF59E0B),
            icon: Icons.schedule,
            text: 'Seis pacientes superan los 20 minutos de espera.',
          ),
          const SizedBox(height: 14),
          const _InsightRow(
            color: Color(0xFF06B6D4),
            icon: Icons.lightbulb_outline,
            text: 'La Sala 2 podría atender 8 pacientes adicionales.',
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDFA),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.trending_up,
                  color: Color(0xFF0F766E),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Impacto estimado: recuperar hasta \$180.000 durante la jornada.',
                    style: TextStyle(
                      color: Color(0xFF115E59),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openChat(context),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Preguntar a Nexa'),
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