import 'dart:async';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../models/chat_message.dart';
import '../services/api_service.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_composer.dart';
import '../widgets/thinking_bubble.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.initialPrompt,
  });

  final String initialPrompt;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  final messages = <ChatMessage>[];

  bool isThinking = false;

  @override
  void initState() {
    super.initState();
    _sendMessage(widget.initialPrompt);
  }

  @override
  void dispose() {
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String text) async {
    final cleaned = text.trim();

    if (cleaned.isEmpty || isThinking) {
      return;
    }

    setState(() {
      messages.add(
        ChatMessage(
          text: cleaned,
          isUser: true,
        ),
      );

      isThinking = true;
    });

    controller.clear();
    _scrollToBottom();

    try {
      final answer = await ApiService.sendMessage(cleaned);

      if (!mounted) return;

      setState(() {
        messages.add(
          ChatMessage(
            text: answer,
            isUser: false,
          ),
        );

        isThinking = false;
      });
    } on TimeoutException {
      if (!mounted) return;

      setState(() {
        messages.add(
          const ChatMessage(
            text:
                'La respuesta está tardando demasiado. Comprueba que el backend siga funcionando e inténtalo nuevamente.',
            isUser: false,
          ),
        );

        isThinking = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;

      setState(() {
        messages.add(
          ChatMessage(
            text: 'No pude responder: ${error.message}',
            isUser: false,
          ),
        );

        isThinking = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        messages.add(
          ChatMessage(
            text:
                'No pude conectarme con el backend de Nexa.\n\nDetalle: $error',
            isUser: false,
          ),
        );

        isThinking = false;
      });
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;

      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: AppBar(
        backgroundColor: NexaColors.surface,
        title: const Row(
          children: [
            Icon(
              Icons.auto_awesome,
              color: NexaColors.primary,
            ),
            SizedBox(width: 10),
            Text(
              'Conversación con Nexa',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: NexaColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              itemCount: messages.length + (isThinking ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == messages.length && isThinking) {
                  return const ThinkingBubble();
                }

                return ChatBubble(
                  message: messages[index],
                );
              },
            ),
          ),
          ChatComposer(
            controller: controller,
            enabled: !isThinking,
            onSend: () => _sendMessage(controller.text),
          ),
        ],
      ),
    );
  }
}