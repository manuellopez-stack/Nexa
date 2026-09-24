import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// Logo de Imagenda dimensionado para caber en un AppBar. Si la clínica de
/// quien está conectado tiene logo, se muestra a la izquierda, separado por
/// una línea vertical fina.
class ImagendaBrandMark extends StatelessWidget {
  const ImagendaBrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    final imagendaLogo = Image.asset(
      'assets/images/imagenda_logo.png',
      height: 28,
    );

    return ValueListenableBuilder<Uint8List?>(
      valueListenable: ApiService.clinicLogo,
      builder: (context, logo, _) {
        if (logo == null) return imagendaLogo;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(logo, height: 28),
            const SizedBox(width: 12),
            Container(width: 1, height: 24, color: NexaColors.border),
            const SizedBox(width: 12),
            imagendaLogo,
          ],
        );
      },
    );
  }
}
