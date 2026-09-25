import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  //
  // Se le quita cualquier "/" final: si el valor pasado por --dart-define
  // trae barra al final (fácil de escribir sin querer), concatenar rutas más
  // abajo como '$_baseUrl/auth/login' generaba '//auth/login' -- Express no
  // lo reconoce como '/auth/login' y responde 404 en HTML, lo que el cliente
  // no puede interpretar como JSON ("El servidor entregó una respuesta que
  // Imagenda no pudo interpretar").
  static final String _baseUrl = const String.fromEnvironment(
    'NEXA_BACKEND_URL',
    defaultValue: 'https://nexa-backend-v2.onrender.com',
  ).replaceFirst(RegExp(r'/+$'), '');

  // Token de sesión guardado en memoria luego de iniciar sesión. Se agrega
  // automáticamente a todas las llamadas al backend que lo necesiten.
  static String? _accessToken;
  static Map<String, dynamic>? _currentUser;
    static String? _role;
  static String? _fullName;

  // Logo de la clínica de quien está conectado (null si no tiene). Lo lee
  // ImagendaShell para mostrarlo en la credencial del menú lateral.
  static final ValueNotifier<Uint8List?> clinicLogo = ValueNotifier(null);

  static bool get isLoggedIn => _accessToken != null;
  static Map<String, dynamic>? get currentUser => _currentUser;
    static String? get role => _role;
  static String? get fullName => _fullName;

  // Permisos derivados del rol. Deben reflejar exactamente lo que permite el
  // backend (middleware requireRole en server.mjs).
  //   - canValidate  -> VALIDATORS  = administrador, medico
  //   - canUseAi      -> AI_STAFF     = administrador, medico, tecnico, recepcion (rutas /chat y /ask)
  //   - canAccessClinical -> CLINICAL_STAFF = administrador, medico, tecnico
  //   - canManageBilling -> BILLING_STAFF = administrador, recepcion
  //   - isReception   -> recepcion (vista reducida, sin datos clínicos)
  static bool get canValidate => _role == 'administrador' || _role == 'medico';
  static bool get canUseAi =>
      _role == 'administrador' ||
      _role == 'medico' ||
      _role == 'tecnico' ||
      _role == 'recepcion';
  static bool get canAccessClinical =>
      _role == 'administrador' || _role == 'medico' || _role == 'tecnico';
  static bool get canManageBilling =>
      _role == 'administrador' || _role == 'recepcion';
  static bool get isReception => _role == 'recepcion';
  //   - canDownloadDvd -> DVD_ROLES = CLINICAL_STAFF + recepcion
  //     ("Descargar para DVD" de un estudio de imagenología)
  static bool get canDownloadDvd => canAccessClinical || isReception;
  //   - isPlatformAdmin -> staff_profiles.is_platform_admin: gestiona clínicas
  //     y el personal de todas ellas (invitar a cualquier clínica, etc.).
  static bool get isPlatformAdmin => _currentUser?['isPlatformAdmin'] == true;
  static String? get clinicId => _currentUser?['clinicId'] as String?;
  static String? get clinicName => _currentUser?['clinicName'] as String?;
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

  /// Solo para tests de widgets: fija el rol sin iniciar sesión.
  @visibleForTesting
  static void debugSetRole(String? role) => _role = role;

  static void logout() {
    _accessToken = null;
    _currentUser = null;
    _role = null;
    _fullName = null;
    clinicLogo.value = null;
  }

  /// True si `url` apunta al propio backend de Imagenda (mismo esquema, host y
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
        'El servidor entregó una respuesta que Imagenda no pudo interpretar.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
    // El logo se carga en segundo plano: no retrasa el ingreso.
    unawaited(loadMyClinicLogo());
  }

  /// Completa el flujo de invitación: fija la contraseña de una cuenta recién
  /// invitada usando el access_token que Supabase entrega en el link del
  /// correo de invitación (no la sesión de este cliente, que aún no existe).
  static Future<void> acceptInvite({
    required String accessToken,
    required String password,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/staff/accept-invite'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'access_token': accessToken,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    await _decodeMap(response);
  }

  static Future<Map<String, dynamic>> getDashboardSummary() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/dashboard/summary'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    return _decodeMap(response);
  }

  /// Pantalla "Por validar": `{ items: [...], conteos: { total, documento,
  /// laboratorio, imagenologia, dental } }`, lo más antiguo primero.
  static Future<Map<String, dynamic>> getValidationQueue() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/validation-queue'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    return _decodeMap(response);
  }

  // Lista de documentos del paciente sin la ficha clínica completa
  // (GET /patients/:id/documents). Es la que usa Recepción.
  static Future<List<Map<String, dynamic>>> getPatientDocuments(
    int patientId,
  ) async {
    final http.Response response;
    try {
      response = await http.get(
        Uri.parse('$_baseUrl/patients/$patientId/documents'),
        headers: _headers(extra: const {'Accept': 'application/json'}),
      ).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible consultar los documentos del paciente.');
    }
    final decodedBody = await _decodeMap(response);
    final documents = decodedBody['documents'];
    if (documents is! List) {
      throw const ApiException('El backend no entregó una lista de documentos válida.');
    }
    return documents
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
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
      throw const ApiException('No fue posible consultar este documento con Imagenda.');
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
        'No fue posible enviar el PDF al backend de Imagenda.',
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
    final savedPatient = decodedBody['patient'];

    return {
      'analysis': analysis.trim(),
      'documentData': Map<String, dynamic>.from(documentData),
      'existingPatient': existingPatient is Map ? Map<String, dynamic>.from(existingPatient) : null,
      // true si el backend ya guardó el documento en la ficha (documento
      // clínico sin conflicto de RUT). En ese caso `patient` trae la ficha
      // ya actualizada, lista para refrescar "Documentos disponibles".
      'documentSaved': decodedBody['documentSaved'] == true,
      'patient': savedPatient is Map ? Map<String, dynamic>.from(savedPatient) : null,
    };
  }

  /// [status] 'rechazado' es "Pedir corrección" y exige [reason]
  /// (mínimo 5 caracteres; lo vuelve a validar el backend).
  static Future<Map<String, dynamic>> validateDocument({
    required int patientId,
    required String filename,
    required String status,
    String? reason,
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
            body: jsonEncode({'status': status, 'reason': ?reason}),
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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

  /// "Pedir corrección" de una orden de laboratorio, con motivo obligatorio.
  static Future<Map<String, dynamic>> requestLabCorrection({
    required int patientId,
    required String orderId,
    required String reason,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/lab-orders/$orderId/request-correction',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'reason': reason}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible pedir la corrección.');
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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

  /// "Pedir corrección" de una orden de dental, con motivo obligatorio.
  static Future<Map<String, dynamic>> requestDentalCorrection({
    required int patientId,
    required String orderId,
    required String reason,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse(
              '$_baseUrl/patients/$patientId/dental-orders/$orderId/request-correction',
            ),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'reason': reason}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible pedir la corrección.');
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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

  /// Órdenes del paciente con imágenes DICOM que se pueden bajar para DVD
  /// (GET /patients/:id/dvd-studies). Cada fila trae orderId,
  /// accessionNumber, examDate, examTypes e imageCount.
  static Future<List<Map<String, dynamic>>> getDvdStudies(int patientId) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/patients/$patientId/dvd-studies'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final studies = decodedBody['studies'];

    if (studies is! List) {
      throw const ApiException(
        'El backend no entregó los estudios del paciente.',
      );
    }

    return studies
        .whereType<Map>()
        .map((study) => Map<String, dynamic>.from(study))
        .toList();
  }

  /// Prepara la descarga "para DVD" de una orden (POST .../dvd-link) y
  /// devuelve { url, filename, viewerIncluded, viewerVersion }, con `url` ya
  /// absoluta: un enlace firmado que vence en 10 minutos y que el navegador
  /// puede bajar sin el header de sesión. La primera vez el servidor
  /// descarga el visor Weasis, por eso el timeout largo.
  static Future<Map<String, dynamic>> prepareDvdDownload({
    required int patientId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse(
              '$_baseUrl/patients/$patientId/imaging-orders/$orderId/dvd-link',
            ),
            headers: _headers(),
          )
          .timeout(const Duration(minutes: 5));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final url = decodedBody['url'];

    if (url is! String || url.isEmpty) {
      throw const ApiException(
        'El backend no entregó el enlace de descarga.',
      );
    }

    return {...decodedBody, 'url': '$_baseUrl$url'};
  }

  /// Estudios recibidos en Orthanc que todavía no se pudieron casar
  /// automáticamente con una orden por accession_number (pantalla "Estudios
  /// sin vincular"). Cada fila trae accessionNumberReceived,
  /// patientNameReceived, patientIdReceived, studyDate, orthancStudyId y
  /// createdAt.
  static Future<List<Map<String, dynamic>>> getUnlinkedOrthancStudies() async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/orthanc-studies?status=unlinked'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final studies = decodedBody['studies'];

    if (studies is! List) {
      throw const ApiException(
        'El backend no entregó los estudios de Orthanc.',
      );
    }

    return studies
        .whereType<Map>()
        .map((study) => Map<String, dynamic>.from(study))
        .toList();
  }

  /// Vincula manualmente un estudio de Orthanc (por su orthancStudyId) a una
  /// orden de imagenología elegida a mano, sin depender de que el
  /// accession_number haya coincidido. Copia las imágenes a la orden y borra
  /// el estudio en Orthanc.
  static Future<void> linkOrthancStudy({
    required String orthancStudyId,
    required String orderId,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/orthanc-studies/$orthancStudyId/link'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({'orderId': orderId}),
          )
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const ApiException('No fue posible vincular el estudio de Orthanc.');
    }

    await _decodeMap(response);
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
        'No fue posible conectar con el backend de Imagenda.',
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
    required String clinicId,
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
              'clinicId': clinicId,
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
  // GESTIÓN DE CLÍNICAS (solo Administrador)
  // ============================================

  static Future<List<Map<String, dynamic>>> getClinics() async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/clinics'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final clinics = decodedBody['clinics'];

    if (clinics is! List) {
      throw const ApiException('El backend no entregó la lista de clínicas.');
    }

    return clinics
        .whereType<Map>()
        .map((clinic) => Map<String, dynamic>.from(clinic))
        .toList();
  }

  /// Crea una clínica nueva. El backend calcula y asigna automáticamente
  /// `dicomAeTitle`/`dicomPort` (plugin MultitenantDicom de Orthanc, Etapa 4
  /// del plan DICOM/PACS) y devuelve en `orthancSetup` el bloque de
  /// configuración listo para aplicar a mano en el droplet.
  static Future<Map<String, dynamic>> createClinic({
    required String name,
    String? address,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/clinics'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'name': name,
              'address': ?address,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible crear la clínica.');
    }

    final decodedBody = await _decodeMap(response);
    final clinic = decodedBody['clinic'];
    final orthancSetup = decodedBody['orthancSetup'];

    if (clinic is! Map || orthancSetup is! Map) {
      throw const ApiException(
        'El backend no entregó la clínica creada ni su configuración de Orthanc.',
      );
    }

    return {
      'clinic': Map<String, dynamic>.from(clinic),
      'orthancSetup': Map<String, dynamic>.from(orthancSetup),
    };
  }

  /// Carga el logo de la clínica de quien está conectado en [clinicLogo]
  /// (null si no tiene, si falla o si es la cuenta de administración de
  /// plataforma, que no muestra logo de clínica). Nunca lanza.
  static Future<void> loadMyClinicLogo() async {
    final token = _accessToken;
    if (token == null || isPlatformAdmin) {
      clinicLogo.value = null;
      return;
    }

    Uint8List? bytes;
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/my-clinic/logo'), headers: _headers())
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        bytes = response.bodyBytes;
      }
    } catch (_) {
      bytes = null;
    }

    // Si la sesión cambió mientras se cargaba (logout u otro login), no
    // pisar el valor de la sesión nueva.
    if (_accessToken == token) clinicLogo.value = bytes;
  }

  static Future<Map<String, dynamic>> uploadClinicLogo(
    String clinicId,
    Uint8List bytes,
    String contentType,
  ) async {
    final http.Response response;

    try {
      response = await http
          .put(
            Uri.parse('$_baseUrl/clinics/$clinicId/logo'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'base64Data': base64Encode(bytes),
              'contentType': contentType,
            }),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      throw const ApiException('No fue posible subir el logo.');
    }

    final decodedBody = await _decodeMap(response);
    final clinic = decodedBody['clinic'];
    if (clinic is! Map) {
      throw const ApiException('El backend no entregó la clínica actualizada.');
    }
    return Map<String, dynamic>.from(clinic);
  }

  static Future<Map<String, dynamic>> deleteClinicLogo(String clinicId) async {
    final http.Response response;

    try {
      response = await http
          .delete(
            Uri.parse('$_baseUrl/clinics/$clinicId/logo'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible quitar el logo.');
    }

    final decodedBody = await _decodeMap(response);
    final clinic = decodedBody['clinic'];
    if (clinic is! Map) {
      throw const ApiException('El backend no entregó la clínica actualizada.');
    }
    return Map<String, dynamic>.from(clinic);
  }

  /// Bytes del logo de una clínica, o null si no tiene.
  static Future<Uint8List?> getClinicLogo(String clinicId) async {
    final http.Response response;

    try {
      response = await http
          .get(
            Uri.parse('$_baseUrl/clinics/$clinicId/logo'),
            headers: _headers(),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible cargar el logo.');
    }

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) await _decodeMap(response);
    return response.bodyBytes;
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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
        'No fue posible conectar con el backend de Imagenda.',
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

  /// Registra un paciente nuevo (solo identidad: nombre, rut, edad, sexo,
  /// teléfono, observaciones). Devuelve `{id, name, rut, phone}`. Lanza
  /// [ApiException] con el mensaje del backend si el RUT ya existe (409) o no
  /// es válido.
  static Future<Map<String, dynamic>> createPatient({
    required String name,
    required String rut,
    int? age,
    String? sexo,
    String? phone,
    String? observations,
  }) async {
    final http.Response response;

    try {
      response = await http
          .post(
            Uri.parse('$_baseUrl/patients'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'name': name,
              'rut': rut,
              'age': ?age,
              'sexo': ?sexo,
              'phone': ?phone,
              'observations': ?observations,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible crear el paciente.');
    }

    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];

    if (patient is! Map) {
      throw const ApiException('El backend no entregó el paciente creado.');
    }

    return Map<String, dynamic>.from(patient);
  }

  /// Ficha de identidad de un paciente para precargar la edición
  /// (`{id, name, rut, age, sexo, phone, observations}`). A diferencia de
  /// [getPatient], no trae datos clínicos ni dispara la generación del
  /// resumen IA.
  static Future<Map<String, dynamic>> getPatientIdentity(int id) async {
    final http.Response response;

    try {
      response = await http
          .get(Uri.parse('$_baseUrl/patients/$id/identity'), headers: _headers())
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException(
        'No fue posible conectar con el backend de Imagenda.',
      );
    }

    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];

    if (patient is! Map) {
      throw const ApiException('El backend no entregó la ficha del paciente.');
    }

    return Map<String, dynamic>.from(patient);
  }

  /// Actualiza la identidad de un paciente existente (nombre, rut, edad,
  /// sexo, teléfono, observaciones). A diferencia de [createPatient], acá
  /// `age`/`sexo`/`phone`/`observations` en `null` explícito BORRA el campo
  /// (se envían siempre, a diferencia del alta). Lanza [ApiException] con el
  /// mensaje del backend si el RUT ya pertenece a otra ficha (409) o no es
  /// válido.
  static Future<Map<String, dynamic>> updatePatient({
    required int id,
    required String name,
    required String rut,
    int? age,
    String? sexo,
    String? phone,
    String? observations,
  }) async {
    final http.Response response;

    try {
      response = await http
          .patch(
            Uri.parse('$_baseUrl/patients/$id'),
            headers: _headers(extra: const {'Content-Type': 'application/json'}),
            body: jsonEncode({
              'name': name,
              'rut': rut,
              'age': age,
              'sexo': sexo,
              'phone': phone,
              'observations': observations,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('No fue posible actualizar el paciente.');
    }

    final decodedBody = await _decodeMap(response);
    final patient = decodedBody['patient'];

    if (patient is! Map) {
      throw const ApiException('El backend no entregó el paciente actualizado.');
    }

    return Map<String, dynamic>.from(patient);
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
        'No fue posible conectar con el backend de Imagenda.',
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
