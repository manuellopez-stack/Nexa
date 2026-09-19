import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';

/// Logo de MILMED junto al ícono de Imagenda, mismo patrón visual que
/// WelcomePage, dimensionado para caber en un AppBar.
class MilmedBrandMark extends StatelessWidget {
  const MilmedBrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            'assets/images/milmed_logo.png',
            height: 28,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: NexaColors.primary,
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(
            Icons.auto_awesome,
            color: Colors.white,
            size: 18,
          ),
        ),
      ],
    );
  }
}
