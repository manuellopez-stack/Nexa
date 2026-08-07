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

  static Future<Map<String, dynamic>> _decodeMap(
    http.Response response,
  ) async {
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

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decodedBody['error'];

      throw ApiException(
        error is String && error.trim().isNotEmpty
            ? error.trim()
            : 'El servidor respondió con el error ${response.statusCode}.',
      );
    }

    return decodedBody;
  }

  static Future<String> sendMessage(String message) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/chat'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'message': message}),
        )
        .timeout(const Duration(seconds: 60));

    final decodedBody = await _decodeMap(response);
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
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<Map<String, dynamic>> analyzePatientPdf({
    required int patientId,
    required String filename,
    required String base64Data,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse(
              '$_baseUrl/patients/$patientId/documents/analyze',
            ),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'filename': filename,
              'base64Data': base64Data,
            }),
          )
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const ApiException(
        'No fue posible enviar el PDF al backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final analysis = decodedBody['analysis'];
    final documentData = decodedBody['documentData'];

    if (analysis is! String || analysis.trim().isEmpty) {
      throw const ApiException(
        'El backend no entregó un análisis válido.',
      );
    }

    if (documentData is! Map) {
      throw const ApiException(
        'El backend no entregó los datos estructurados del documento.',
      );
    }

    return {
      'analysis': analysis.trim(),
      'documentData': Map<String, dynamic>.from(documentData),
    };
  }
}
