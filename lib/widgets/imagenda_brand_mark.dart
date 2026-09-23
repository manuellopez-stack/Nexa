import 'package:flutter/material.dart';

/// Logo de Imagenda dimensionado para caber en un AppBar.
class ImagendaBrandMark extends StatelessWidget {
  const ImagendaBrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/imagenda_logo.png',
      height: 28,
    );
  }
}
