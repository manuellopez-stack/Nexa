import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
  });

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: message.isUser
              ? NexaColors.primary
              : NexaColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: message.isUser
              ? null
              : Border.all(color: NexaColors.border),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            height: 1.5,
            color: message.isUser
                ? Colors.white
                : NexaColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
