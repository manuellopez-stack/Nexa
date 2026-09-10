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

  // Dirección del backend. Por defecto apunta al backend en producción
  // (Render). Para probar contra un backend local se puede sobreescribir al
  // ejecutar la app:
  //   flutter run --dart-define=NEXA_BACKEND_URL=https://<url-del-backend>
  static const String _baseUrl = String.fromEnvironment(
    'NEXA_BACKEND_URL',
    defaultValue: 'https://nexa-backend-v2.onrender.com',
  );

  // Token de sesión guardado en memoria luego de iniciar sesión. Se agrega
  // automáticamente a todas las llamadas al backend que lo necesiten.
  static String? _accessToken;
  static Map<String, dynamic>? _currentUser;
    static String? _role;
  static String? _fullName;

  static bool get isLoggedIn => _accessToken != null;
  static Map<String, dynamic>? get currentUser => _currentUser;
    static String? get role => _role;
  static String? get fullName => _fullName;

  // Permisos derivados del rol. Deben reflejar exactamente lo que permite el
  // backend (middleware requireRole en server.mjs).
  //   - canValidate  -> VALIDATORS  = administrador, medico
  //   - canUseAi      -> VALIDATORS  = administrador, medico (rutas /chat y /ask)
  //   - canAccessClinical -> CLINICAL_STAFF = administrador, medico, tecnico
  //   - canManageBilling -> BILLING_STAFF = administrador, recepcion
  //   - canAccessMail -> MAIL_STAFF = administrador, recepcion (rutas /mail y /gmail/reply)
  //   - isReception   -> recepcion (vista reducida, sin datos clínicos)
  static bool get canValidate => _role == 'administrador' || _role == 'medico';
  static bool get canUseAi => _role == 'administrador' || _role == 'medico';
  static bool get canAccessClinical =>
      _role == 'administrador' || _role == 'medico' || _role == 'tecnico';
  static bool get canManageBilling =>
      _role == 'administrador' || _role == 'recepcion';
  static bool get canAccessMail =>
      _role == 'administrador' || _role == 'recepcion';
  static bool get isReception => _role == 'recepcion';
  //   - canAccessAgenda -> AGENDA_STAFF = administrador, medico, tecnico, recepcion
  //     (gestión de citas: pantalla nueva en el AppBar del dashboard)
  static bool get canAccessAgenda =>
      _role == 'administrador' ||
      _role == 'medico' ||
      _role == 'tecnico' ||
      _role == 'recepcion';

  static void _setSession(String accessToken, Map<String, dynamic> user, {String? role, String? fullName}) {
    _accessToken = accessToken;
    _currentUser = user;
        _role = role;
    _fullName = fullName;
  }

  static void logout() {
    _accessToken = null;
    _currentUser = null;
    _role = null;
    _fullName = null;
  }

  /// True si `url` apunta al propio backend de Nexa (mismo esquema, host y
  /// puerto). Se usa para decidir qué imágenes de un correo son seguras de
  /// cargar por red: solo las que ya pasaron por el proxy del backend.
  static bool esUrlDeBackend(String? url) {
    if (url == null || url.isEmpty) return false;
    final base = Uri.tryParse(_baseUrl);
    final destino = Uri.tryParse(url);
    if (base == null || destino == null || !destino.hasScheme) return false;
    return destino.scheme == base.scheme &&
        destino.host == base.host &&
        destino.port == base.port;
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

    final role = user['role'] as String?;
    final fullName = user['fullName'] as String?;

    _setSession(accessToken, Map<String, dynamic>.from(user), role: role, fullName: fullName);
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

  /// Chequeo real de salud del backend. Consulta el endpoint público
  /// `/health` y mide la latencia. No lanza excepción: devuelve un mapa con
  /// `ok` en false cuando no hay respuesta válida.
  static Future<Map<String, dynamic>> getBackendHealth() async {
    final stopwatch = Stopwatch()..start();

    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 10));
      stopwatch.stop();

      if (response.statusCode != 200) {
        return {'ok': false, 'latencyMs': stopwatch.elapsedMilliseconds};
      }

      Map<String, dynamic> body;
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        body = const {};
      }

      return {
        'ok': body['estado'] == 'OK' || body['estado'] == null,
        'latencyMs': stopwatch.elapsedMilliseconds,
        'model': body['modelo'],
      };
    } catch (_) {
      stopwatch.stop();
      return {'ok': false, 'latencyMs': stopwatch.elapsedMilliseconds};
    }
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
  // MÓDULO DENTAL
  // ============================================

  static Future<List<Map<String, dynamic>>> getDentalProcedures() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/dental/procedures'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final procedures = decodedBody['procedures'];

    if (procedures is! List) {
      throw const ApiException(
        'El backend no entregó el catálogo de prestaciones dentales.',
      );
    }

    return procedures
        .whereType<Map>()
        .map((procedure) => Map<String, dynamic>.from(procedure))
        .toList();
  }

  static Future<Map<String, dynamic>> createDentalOrder({
    required int patientId,
    required List<String> procedureIds,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/patients/$patientId/dental-orders'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'procedureIds': procedureIds}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible crear la orden dental.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden creada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<List<Map<String, dynamic>>> getDentalOrders(
    int patientId,
  ) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/dental-orders'),
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
        'El backend no entregó las órdenes dentales.',
      );
    }

    return orders
        .whereType<Map>()
        .map((order) => Map<String, dynamic>.from(order))
        .toList();
  }

  static Future<Map<String, dynamic>> getDentalOrderDetail({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/dental-orders/$orderId'),
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

  static Future<Map<String, dynamic>> markDentalPerformed({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/dental-orders/$orderId/performed',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible marcar la atención dental como realizada.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<Map<String, dynamic>> saveDentalResults({
    required int patientId,
    required String orderId,
    required List<Map<String, dynamic>> results,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/dental-orders/$orderId/results',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'results': results}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible guardar los resultados dentales.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó la orden actualizada.');
    }

    return Map<String, dynamic>.from(order);
  }

  static Future<Map<String, dynamic>> validateDentalOrder({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/dental-orders/$orderId/validate',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible validar la orden dental.',
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

  // ============================================
  // GESTIÓN DE EQUIPO (solo Administrador)
  // ============================================

  static Future<List<Map<String, dynamic>>> getStaff() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/staff'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final staff = decodedBody['staff'];

    if (staff is! List) {
      throw const ApiException('El backend no entregó la lista del equipo.');
    }

    return staff
        .whereType<Map>()
        .map((member) => Map<String, dynamic>.from(member))
        .toList();
  }

  static Future<Map<String, dynamic>> inviteStaff({
    required String email,
    required String fullName,
    required String role,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/staff/invite'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'email': email,
              'fullName': fullName,
              'role': role,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible invitar a esta persona.');
    }

    final decodedBody = await _decodeMap(response);
    final staff = decodedBody['staff'];

    if (staff is! Map) {
      throw const ApiException('El backend no entregó a la persona invitada.');
    }

    return Map<String, dynamic>.from(staff);
  }

  static Future<Map<String, dynamic>> updateStaffRole({
    required String staffId,
    required String role,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse('$_baseUrl/staff/$staffId/role'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'role': role}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible actualizar el rol de esta persona.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final staff = decodedBody['staff'];

    if (staff is! Map) {
      throw const ApiException('El backend no entregó la persona actualizada.');
    }

    return Map<String, dynamic>.from(staff);
  }

  static Future<void> deleteStaff(String staffId) async {
    final http.Response response;

    try {
      response = await http
          .delete(
            Uri.parse('$_baseUrl/staff/$staffId'),
            headers: _headers(extra: const {'Accept': 'application/json'}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible quitar a esta persona del equipo.',
      );
    }

    await _decodeMap(response);
  }

  // ============================================
  // MÓDULO DE CONTABILIDAD Y FACTURACIÓN
  // ============================================

  static Future<List<Map<String, dynamic>>> getPatientBilling(
    int patientId,
  ) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/billing'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final billingOrders = decodedBody['billingOrders'];

    if (billingOrders is! List) {
      throw const ApiException(
        'El backend no entregó la lista de cobros.',
      );
    }

    return billingOrders
        .whereType<Map>()
        .map((order) => Map<String, dynamic>.from(order))
        .toList();
  }

  static Future<Map<String, dynamic>> registerPayment({
    required String billingOrderId,
    required String method,
    required num amount,
    String? reference,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/billing/orders/$billingOrderId/payments'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'method': method,
              'amount': amount,
              if (reference != null && reference.trim().isNotEmpty)
                'reference': reference.trim(),
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible registrar el pago.');
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó el cobro actualizado.');
    }

    return {...decodedBody, 'order': Map<String, dynamic>.from(order)};
  }

  static Future<Map<String, dynamic>> updateBonoFolio({
    required String billingOrderId,
    required String? bonoFolio,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse('$_baseUrl/billing/orders/$billingOrderId'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'bonoFolio': bonoFolio}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible actualizar el folio del bono.');
    }

    final decodedBody = await _decodeMap(response);
    final order = decodedBody['order'];

    if (order is! Map) {
      throw const ApiException('El backend no entregó el cobro actualizado.');
    }

    return Map<String, dynamic>.from(order);
  }

  // Correos no leídos de Gmail (solo lectura). Solo el rol administrador
  // tiene permiso en el backend para consultar esta ruta.
  static Future<List<Map<String, dynamic>>> getGmailUnread() async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/notifications/gmail'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final correos = decodedBody['correos'];

    if (correos is! List) {
      throw const ApiException(
        'El backend no entregó la lista de correos.',
      );
    }

    return correos
        .whereType<Map>()
        .map((correo) => Map<String, dynamic>.from(correo))
        .toList();
  }

  static Future<Map<String, dynamic>> getGmailMessage(String messageId) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/notifications/gmail/$messageId'),
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

  /// Lista de correos de la sección "Correo" (no solo los no leídos, a
  /// diferencia de [getGmailUnread]). `q` usa la sintaxis de búsqueda de
  /// Gmail (por ejemplo `in:inbox`, `is:unread`, `from:alguien@dominio.cl`).
  static Future<Map<String, dynamic>> getMailMessages({
    String q = 'in:inbox',
    String? pageToken,
  }) async {
    final uri = Uri.parse('$_baseUrl/mail/messages').replace(
      queryParameters: {
        'q': q,
        if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
      },
    );

    final http.Response response;

    try {
      response = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  static Future<Map<String, dynamic>> getMailMessage(String messageId) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/mail/messages/$messageId'),
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

  /// Responde un correo dentro del mismo hilo (In-Reply-To/References,
  /// asunto "Re: ..."). `adjuntos` es una lista de mapas con `nombre`,
  /// `mimeType` y `base64Data`.
  static Future<Map<String, dynamic>> sendMailReply({
    required String messageId,
    required String cuerpoTexto,
    List<Map<String, dynamic>> adjuntos = const [],
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/gmail/reply'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'messageId': messageId,
              'cuerpoTexto': cuerpoTexto,
              'adjuntos': adjuntos,
            }),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    return _decodeMap(response);
  }

  // ============================================
  // AGENDA DE CITAS
  // ============================================

  /// Catálogo de salas activas (para el selector de sala de una cita).
  static Future<List<Map<String, dynamic>>> getRooms() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/rooms'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final rooms = decodedBody['rooms'];

    if (rooms is! List) {
      throw const ApiException('El backend no entregó el catálogo de salas.');
    }

    return rooms
        .whereType<Map>()
        .map((room) => Map<String, dynamic>.from(room))
        .toList();
  }

  /// Lista liviana de pacientes (id / nombre / rut / teléfono) para el
  /// selector de "nueva cita". `search` filtra por nombre o rut.
  static Future<List<Map<String, dynamic>>> getPatientsList({
    String? search,
  }) async {
    final uri = Uri.parse('$_baseUrl/patients').replace(
      queryParameters: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      },
    );

    final http.Response response;

    try {
      response = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final patients = decodedBody['patients'];

    if (patients is! List) {
      throw const ApiException('El backend no entregó la lista de pacientes.');
    }

    return patients
        .whereType<Map>()
        .map((patient) => Map<String, dynamic>.from(patient))
        .toList();
  }

  /// Agenda de citas. Sin `date` devuelve el día de hoy (día local de Chile).
  /// `statuses` filtra por uno o más estados (códigos: programada, en_espera,
  /// en_atencion, atendida, cancelada, no_asistio).
  static Future<List<Map<String, dynamic>>> getAppointments({
    String? date,
    List<String>? statuses,
    String? roomId,
    int? patientId,
  }) async {
    final uri = Uri.parse('$_baseUrl/appointments').replace(
      queryParameters: {
        if (date != null && date.isNotEmpty) 'date': date,
        if (statuses != null && statuses.isNotEmpty) 'status': statuses.join(','),
        if (roomId != null && roomId.isNotEmpty) 'roomId': roomId,
        if (patientId != null) 'patientId': '$patientId',
      },
    );

    final http.Response response;

    try {
      response = await http
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Nexa.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final appointments = decodedBody['appointments'];

    if (appointments is! List) {
      throw const ApiException('El backend no entregó la agenda de citas.');
    }

    return appointments
        .whereType<Map>()
        .map((appointment) => Map<String, dynamic>.from(appointment))
        .toList();
  }

  /// Crea una cita. `scheduledAt` es un instante ISO 8601 (UTC).
  static Future<Map<String, dynamic>> createAppointment({
    required int patientId,
    required String scheduledAt,
    String? roomId,
    int? durationMin,
    String? professional,
    String? reason,
    String? notes,
    String? status,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/appointments'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'patientId': patientId,
              'scheduledAt': scheduledAt,
              if (roomId != null && roomId.isNotEmpty) 'roomId': roomId,
              'durationMin': ?durationMin,
              'professional': ?professional,
              'reason': ?reason,
              'notes': ?notes,
              'status': ?status,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible crear la cita.');
    }

    final decodedBody = await _decodeMap(response);
    final appointment = decodedBody['appointment'];

    if (appointment is! Map) {
      throw const ApiException('El backend no entregó la cita creada.');
    }

    return Map<String, dynamic>.from(appointment);
  }

  /// Actualiza una cita: reprogramar (`scheduledAt`), cambiar sala (`roomId`,
  /// cadena vacía para quitarla), cambiar estado (`status`) o editar datos.
  /// Solo se envían los campos presentes en `changes`.
  static Future<Map<String, dynamic>> updateAppointment(
    String appointmentId,
    Map<String, dynamic> changes,
  ) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse('$_baseUrl/appointments/$appointmentId'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode(changes),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible actualizar la cita.');
    }

    final decodedBody = await _decodeMap(response);
    final appointment = decodedBody['appointment'];

    if (appointment is! Map) {
      throw const ApiException('El backend no entregó la cita actualizada.');
    }

    return Map<String, dynamic>.from(appointment);
  }
}
