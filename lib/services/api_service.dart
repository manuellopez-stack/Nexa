import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiService {
  ApiService._();

  static const String _baseUrl = 'http://localhost:3000';

  static Future<String> sendMessage(String message) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/chat'),
          headers: const {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'message': message,
          }),
        )
        .timeout(const Duration(seconds: 60));

    final dynamic decodedBody;

    try {
      decodedBody = jsonDecode(response.body);
    } on FormatException {
      throw const ApiException(
        'El servidor entregó una respuesta que Nexa no pudo interpretar.',
      );
    }

    if (decodedBody is! Map<String, dynamic>) {
      throw const ApiException(
        'El servidor entregó una respuesta inesperada.',
      );
    }

    if (response.statusCode != 200) {
      final error = decodedBody['error'];

      throw ApiException(
        error is String && error.trim().isNotEmpty
            ? error.trim()
            : 'El servidor respondió con el error ${response.statusCode}.',
      );
    }

    final answer = decodedBody['respuesta'];

    if (answer is! String || answer.trim().isEmpty) {
      throw const ApiException(
        'El backend no entregó una respuesta válida.',
      );
    }

    return answer.trim();
  }

  static Future<Map<String, dynamic>> getPatient(int id) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$id'),
            headers: const {
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final dynamic decodedBody;

    try {
      decodedBody = jsonDecode(response.body);
    } on FormatException {
      throw const ApiException(
        'El servidor entregó una ficha que Nexa no pudo interpretar.',
      );
    }

    if (decodedBody is! Map<String, dynamic>) {
      throw const ApiException(
        'La ficha del paciente tiene un formato inválido.',
      );
    }

    if (response.statusCode != 200) {
      final error = decodedBody['error'];

      throw ApiException(
        error is String && error.trim().isNotEmpty
            ? error.trim()
            : 'No fue posible obtener la ficha del paciente.',
      );
    }

    return decodedBody;
  }
}