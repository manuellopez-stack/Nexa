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

  static const String _baseUrl = 'https://nexa-backend-v2.onrender.com';

  // Token de sesión guardado en memoria luego de iniciar sesión. Se agrega
  // automáticamente a todas las llamadas al backend que lo necesiten.
  static String? _accessToken;
  static Map<String, dynamic>? _currentUser;

  static bool get isLoggedIn => _accessToken != null;
  static Map<String, dynamic>? get currentUser => _currentUser;

  static void _setSession(String accessToken, Map<String, dynamic> user) {
    _accessToken = accessToken;
    _currentUser = user;
  }

  static void logout() {
    _accessToken = null;
    _currentUser = null;
  }

  static Map<String, String> _headers({Map<String, String>? extra}) {
    return {
      if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      ...?extra,
    };
  }

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

  static Future<void> login({
    required String email,
    required String password,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/auth/login'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final accessToken = decodedBody['accessToken'];
    final user = decodedBody['user'];

    if (accessToken is! String || accessToken.isEmpty || user is! Map) {
      throw const ApiException('El backend no entregó una sesión válida.');
    }

    _setSession(accessToken, Map<String, dynamic>.from(user));
  }

  static Future<Map<String, dynamic>> getDashboardSummary() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/dashboard/summary'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<List<Map<String, dynamic>>> getTodayPatients() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/patients/today'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final patients = decodedBody['patients'];

    if (patients is! List) {
      throw const ApiException(
        'El backend no entregó la lista de pacientes.',
      );
    }

    return patients
        .whereType<Map>()
        .map((patient) => Map<String, dynamic>.from(patient))
        .toList();
  }

  static Future<String> sendMessage(String message) async {
    final response = await http
        .post(
          Uri.parse('$_baseUrl/chat'),
          headers: _headers(extra: const {'Content-Type': 'application/json'}),
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
            headers: _headers(extra: const {'Accept': 'application/json'}),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<Map<String, dynamic>> getPatientDocument({
    required int patientId,
    required String filename,
  }) async {
    final encodedFilename = Uri.encodeComponent(filename);
    final http.Response response;
    try {
      response = await http.get(
        Uri.parse('$_baseUrl/patients/$patientId/documents/$encodedFilename'),
        headers: _headers(extra: const {'Accept': 'application/json'}),
      ).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible consultar el documento guardado.');
    }
    return _decodeMap(response);
  }

  static Future<String> askPatientDocument({
    required int patientId,
    required String filename,
    required String question,
  }) async {
    final encodedFilename = Uri.encodeComponent(filename);
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$_baseUrl/patients/$patientId/documents/$encodedFilename/ask'),
        headers: _headers(extra: const {'Content-Type': 'application/json'}),
        body: jsonEncode({'question': question}),
      ).timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const ApiException('No fue posible consultar este documento con Nexa.');
    }
    final decodedBody = await _decodeMap(response);
    final answer = decodedBody['respuesta'];
    if (answer is! String || answer.trim().isEmpty) {
      throw const ApiException('El backend no entregó una respuesta válida.');
    }
    return answer.trim();
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
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
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

    final existingPatient = decodedBody['existingPatient'];

    return {
      'analysis': analysis.trim(),
      'documentData': Map<String, dynamic>.from(documentData),
      'existingPatient': existingPatient is Map ? Map<String, dynamic>.from(existingPatient) : null,
    };
  }

  static Future<Map<String, dynamic>> validateDocument({
    required int patientId,
    required String filename,
    required String status,
  }) async {
    final encodedFilename = Uri.encodeComponent(filename);
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/documents/$encodedFilename/validate',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'status': status}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible actualizar la validación del documento.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];

    if (patient is! Map) {
      throw const ApiException('El backend no entregó la ficha actualizada.');
    }

    return {...decodedBody, 'patient': Map<String, dynamic>.from(patient)};
  }

  static Future<Map<String, dynamic>> deleteDocument({
    required int patientId,
    required String filename,
  }) async {
    final encodedFilename = Uri.encodeComponent(filename);
    final http.Response response;

    try {
      response = await http
          .delete(
            Uri.parse(
              '$_baseUrl/patients/$patientId/documents/$encodedFilename',
            ),
            headers: _headers(extra: const {'Accept': 'application/json'}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible eliminar el documento.');
    }

    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];

    if (patient is! Map) {
      throw const ApiException('El backend no entregó la ficha actualizada.');
    }

    return {...decodedBody, 'patient': Map<String, dynamic>.from(patient)};
  }

  static Future<Map<String, dynamic>> incorporateDocumentData({
    required int patientId,
    required Map<String, dynamic> documentData,
    required String filename,
    int? targetPatientId,
    String? imagingOrderId,
  }) async {
    final http.Response response;
    try {
      response = await http.patch(
        Uri.parse('$_baseUrl/patients/$patientId/from-document'),
        headers: _headers(extra: const {'Content-Type': 'application/json'}),
        body: jsonEncode({
          'documentData': documentData,
          'filename': filename,
          if (targetPatientId != null) 'targetPatientId': targetPatientId,
          if (imagingOrderId != null) 'imagingOrderId': imagingOrderId,
        }),
      ).timeout(const Duration(seconds: 30));
    } catch (_) { throw const ApiException('No fue posible actualizar la ficha del paciente.'); }
    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];
    if (patient is! Map) throw const ApiException('El backend no entregó la ficha actualizada.');
    return {...decodedBody, 'patient': Map<String, dynamic>.from(patient)};
  }

  // ============================================
  // MÓDULO DE LABORATORIO
  // ============================================

  static Future<List<Map<String, dynamic>>> getLabPanels() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/lab/panels'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final panels = decodedBody['panels'];

    if (panels is! List) {
      throw const ApiException(
        'El backend no entregó el catálogo de exámenes.',
      );
    }

    return panels
        .whereType<Map>()
        .map((panel) => Map<String, dynamic>.from(panel))
        .toList();
  }

  static Future<Map<String, dynamic>> createLabOrder({
    required int patientId,
    required List<String> panelIds,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/patients/$patientId/lab-orders'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'panelIds': panelIds}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible crear la orden de laboratorio.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden creada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<List<Map<String, dynamic>>> getLabOrders(
    int patientId,
  ) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/lab-orders'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final orders = decodedBody['orders'];

    if (orders is! List) {
      throw const ApiException(
        'El backend no entregó las órdenes de laboratorio.',
      );
    }

    return orders
        .whereType<Map>()
        .map((order) => Map<String, dynamic>.from(order))
        .toList();
  }

  static Future<Map<String, dynamic>> getLabOrderDetail({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/lab-orders/$orderId'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<Map<String, dynamic>> markSampleTaken({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/lab-orders/$orderId/sample-taken',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible marcar la toma de muestra.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<Map<String, dynamic>> saveLabResults({
    required int patientId,
    required String orderId,
    required List<Map<String, dynamic>> results,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/lab-orders/$orderId/results',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'results': results}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible guardar los resultados de laboratorio.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<Map<String, dynamic>> validateLabOrder({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/lab-orders/$orderId/validate',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible validar la orden de laboratorio.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  // ============================================
  // MÓDULO DE IMAGENOLOGÍA
  // ============================================

  static Future<List<Map<String, dynamic>>> getImagingTypes() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/imaging/types'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final types = decodedBody['types'];

    if (types is! List) {
      throw const ApiException(
        'El backend no entregó el catálogo de imagenología.',
      );
    }

    return types
        .whereType<Map>()
        .map((type) => Map<String, dynamic>.from(type))
        .toList();
  }

  static Future<Map<String, dynamic>> createImagingOrder({
    required int patientId,
    required List<String> typeIds,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/patients/$patientId/imaging-orders'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'typeIds': typeIds}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible crear la orden de imagenología.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden creada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<List<Map<String, dynamic>>> getImagingOrders(
    int patientId,
  ) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/imaging-orders'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final orders = decodedBody['orders'];

    if (orders is! List) {
      throw const ApiException(
        'El backend no entregó las órdenes de imagenología.',
      );
    }

    return orders
        .whereType<Map>()
        .map((order) => Map<String, dynamic>.from(order))
        .toList();
  }

  static Future<Map<String, dynamic>> getImagingOrderDetail({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/imaging-orders/$orderId'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<Map<String, dynamic>> markImagingPerformed({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/imaging-orders/$orderId/performed',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible marcar el estudio como realizado.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<Map<String, dynamic>> uploadImagingImage({
    required int patientId,
    required String orderId,
    required String filename,
    required String base64Data,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse(
              '$_baseUrl/patients/$patientId/imaging-orders/$orderId/image',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'filename': filename, 'base64Data': base64Data}),
          )
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const ApiException('No fue posible subir la imagen DICOM.');
    }

    return _decodeMap(response);
  }

  static Future<List<Map<String, dynamic>>> getImagingImages({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse(
              '$_baseUrl/patients/$patientId/imaging-orders/$orderId/images',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final files = decodedBody['files'];

    if (files is! List) {
      throw const ApiException(
        'El backend no entregó las imágenes de la orden.',
      );
    }

    return files
        .whereType<Map>()
        .map((file) => Map<String, dynamic>.from(file))
        .toList();
  }
}