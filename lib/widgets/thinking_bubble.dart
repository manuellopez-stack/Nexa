import 'dart:async';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';

class ThinkingBubble extends StatefulWidget {
  const ThinkingBubble({super.key});

  @override
  State<ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<ThinkingBubble> {
  int dots = 1;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) {
        if (!mounted) return;
        setState(() {
          dots = dots == 3 ? 1 : dots + 1;
        });
      },
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        decoration: BoxDecoration(
          color: NexaColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: NexaColors.border),
        ),
        child: Text(
          'Nexa está pensando${'.' * dots}',
          style: const TextStyle(
            color: NexaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
