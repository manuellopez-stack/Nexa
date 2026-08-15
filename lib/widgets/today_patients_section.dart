import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

class TodayPatientsSection extends StatefulWidget {
  const TodayPatientsSection({super.key});

  @override
  State<TodayPatientsSection> createState() => _TodayPatientsSectionState();
}

class _TodayPatientsSectionState extends State<TodayPatientsSection> {
  late Future<List<Map<String, dynamic>>> _patientsFuture;

  @override
  void initState() {
    super.initState();
    _patientsFuture = _loadPatients();
  }

  Future<List<Map<String, dynamic>>> _loadPatients() {
    return ApiService.getTodayPatients();
  }

  void _reloadPatients() {
    setState(() {
      _patientsFuture = _loadPatients();
    });
  }

  Future<void> _showPatientDialog(Map<String, dynamic> preview) async {
    final id = preview['id'];

    if (id is! int) {
      _showError('El paciente no tiene un identificador válido.');
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          width: 280,
          child: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 18),
              Expanded(child: Text('Cargando ficha del paciente...')),
            ],
          ),
        ),
      ),
    );

    try {
      final patient = await ApiService.getPatient(id);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return _PatientDialog(patient: patient);
        },
      );

      if (mounted) _reloadPatients();
    } on ApiException catch (error) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showError(error.message);
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showError('Ocurrió un error inesperado al cargar la ficha.');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NexaColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D0F172A),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.people_alt_outlined,
                color: NexaColors.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Pacientes del día',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: NexaColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Actualizar',
                onPressed: _reloadPatients,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Próximas atenciones obtenidas desde Nexa Backend',
            style: TextStyle(color: NexaColors.textSecondary),
          ),
          const SizedBox(height: 22),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _patientsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              if (snapshot.hasError) {
                final error = snapshot.error;
                return _ErrorMessage(
                  message: error is ApiException ? error.message : null,
                  onRetry: _reloadPatients,
                );
              }

              final patients = snapshot.data ?? [];

              if (patients.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No hay pacientes programados.'),
                );
              }

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  headingRowColor: const WidgetStatePropertyAll(
                    NexaColors.background,
                  ),
                  columns: const [
                    DataColumn(label: Text('Hora')),
                    DataColumn(label: Text('Paciente')),
                    DataColumn(label: Text('Examen')),
                    DataColumn(label: Text('Sala')),
                    DataColumn(label: Text('Estado')),
                  ],
                  rows: patients.map((patient) {
                    return DataRow(
                      onSelectChanged: (_) => _showPatientDialog(patient),
                      cells: [
                        DataCell(Text(patient['time']?.toString() ?? '')),
                        DataCell(
                          Text(
                            patient['name']?.toString() ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        DataCell(Text(patient['exam']?.toString() ?? '')),
                        DataCell(Text(patient['room']?.toString() ?? '')),
                        DataCell(
                          _StatusBadge(
                            status: patient['status']?.toString() ?? '',
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PatientDialog extends StatefulWidget {
  const _PatientDialog({required this.patient});

  final Map<String, dynamic> patient;

  @override
  State<_PatientDialog> createState() => _PatientDialogState();
}

class _PatientDialogState extends State<_PatientDialog> {
  final TextEditingController _questionController = TextEditingController();

  String? _answer;
  String? _error;
  bool _isLoading = false;
  bool _isAnalyzingDocument = false;
  bool _isIncorporatingDocument = false;
  String? _documentAnalysis;
  Map<String, dynamic>? _documentData;
  String? _documentError;
  String? _incorporationMessage;
  Map<String, dynamic>? _existingPatientMatch;
  String? _documentFilename;
  String? _deletingFilename;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _mapList(dynamic value) {
    if (value is! List) return [];

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  List<String> _stringList(dynamic value) {
    if (value is! List) return [];

    return value
        .whereType<String>()
        .where((item) => item.trim().isNotEmpty)
        .toList();
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.isEmpty) return 'P';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }

    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }

  String _normalizeDocumentName(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\.pdf$'), '')
        .replaceAll(RegExp(r'[^a-z0-9áéíóúüñ]+'), '');
  }

  Map<String, dynamic>? _documentRecordFor(String filename) {
    final records = _mapList(widget.patient['documentRecords']);
    final target = _normalizeDocumentName(filename);

    for (final record in records) {
      final recordFilename = record['filename']?.toString() ?? '';
      if (_normalizeDocumentName(recordFilename) == target) return record;
    }

    return null;
  }

  String _patientContext() {
    final patient = widget.patient;
    final history = _mapList(patient['history']);
    final documentRecords = _mapList(patient['documentRecords']);

    final historyText = history.isEmpty
        ? 'Sin historial registrado.'
        : history
            .map((item) {
              final date = item['date'] ?? 'Sin fecha';
              final exam = item['exam'] ?? 'Sin examen';
              final summary = item['summary']?.toString().trim();
              final summaryPart =
                  (summary != null && summary.isNotEmpty) ? ' — $summary' : '';
              return '- $date: $exam$summaryPart';
            })
            .join('\n');

    final documentsText = documentRecords.isEmpty
        ? 'Sin documentos incorporados todavía.'
        : documentRecords
            .map((doc) {
              final date = doc['date'] ?? 'Sin fecha';
              final type = doc['documentType'] ?? doc['exam'] ?? 'Documento';
              final summary = doc['summary']?.toString().trim();
              final summaryPart =
                  (summary != null && summary.isNotEmpty) ? '\n  $summary' : '';
              return '- [$date] $type$summaryPart';
            })
            .join('\n');

    return '''
Responde exclusivamente usando la ficha clínica proporcionada.
No inventes diagnósticos ni datos.
Aclara cuando la información no sea suficiente.
No reemplaces la evaluación de un profesional de salud.
Si la pregunta pide comparar exámenes, describir cambios o evolución en el
tiempo, usa las fechas del historial y de los documentos incorporados para
identificar cuál es el examen más reciente y cuál el anterior, y compara
explícitamente los hallazgos de cada uno. Si solo existe un examen o
documento, indícalo claramente y aclara que no hay un estudio anterior con
el cual comparar.

FICHA DEL PACIENTE
Nombre: ${patient['name'] ?? 'Sin información'}
RUT: ${patient['rut'] ?? 'Sin información'}
Edad: ${patient['age'] ?? 'Sin información'}
Médico: ${patient['doctor'] ?? 'Sin información'}
Teléfono: ${patient['phone'] ?? 'Sin información'}
Examen: ${patient['exam'] ?? 'Sin información'}
Sala: ${patient['room'] ?? 'Sin información'}
Estado: ${patient['status'] ?? 'Sin información'}
Observaciones: ${patient['observations'] ?? 'Sin observaciones'}
Riesgo registrado: ${patient['risk'] ?? 'Sin evaluar'}

HISTORIAL (ordenado como está registrado)
$historyText

DOCUMENTOS INCORPORADOS (con su resumen clínico)
$documentsText
'''.trim();
  }


  Future<void> _showSavedDocument(String filename) async {
    final patientId = widget.patient['id'];
    if (patientId is! int) {
      setState(() => _documentError = 'El paciente no tiene un identificador válido.');
      return;
    }

    try {
      final result = await ApiService.getPatientDocument(
        patientId: patientId,
        filename: filename,
      );
      if (!mounted) return;
      final raw = result['document'];
      if (raw is! Map) {
        throw const ApiException('Nexa no encontró información guardada para este documento.');
      }
      final document = Map<String, dynamic>.from(raw);

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _SavedDocumentDialog(
          patientId: patientId,
          filename: filename,
          document: document,
        ),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _documentError = error.message);
    } catch (_) {
      if (mounted) setState(() => _documentError = 'No fue posible abrir la información del documento.');
    }
  }

  Future<void> _deleteDocument(String filename) async {
    final patientId = widget.patient['id'];

    if (patientId is! int) {
      setState(() => _documentError = 'El paciente no tiene un identificador válido.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar documento'),
        content: Text(
          '¿Quitar "$filename" de la ficha de este paciente? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _deletingFilename = filename;
      _documentError = null;
    });

    try {
      final result = await ApiService.deleteDocument(
        patientId: patientId,
        filename: filename,
      );

      if (!mounted) return;

      setState(() {
        final updatedPatient = result['patient'];

        if (updatedPatient is Map<String, dynamic>) {
          widget.patient
            ..clear()
            ..addAll(updatedPatient);
        }

        if (_documentFilename == filename) {
          _documentAnalysis = null;
          _documentData = null;
          _documentFilename = null;
          _incorporationMessage = null;
          _existingPatientMatch = null;
        }
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _documentError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _documentError = 'No fue posible eliminar el documento.');
      }
    } finally {
      if (mounted) setState(() => _deletingFilename = null);
    }
  }

  Future<void> _analyzePdfDocument() async {
    if (_isAnalyzingDocument) return;

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;

    if (bytes == null) {
      setState(() {
        _documentError = 'No fue posible leer el archivo seleccionado.';
      });
      return;
    }

    if (bytes.length > 10 * 1024 * 1024) {
      setState(() {
        _documentError = 'El PDF supera el máximo permitido de 10 MB.';
      });
      return;
    }

    final patientId = widget.patient['id'];

    if (patientId is! int) {
      setState(() {
        _documentError = 'El paciente no tiene un identificador válido.';
      });
      return;
    }

    setState(() {
      _isAnalyzingDocument = true;
      _documentAnalysis = null;
      _documentData = null;
      _documentError = null;
      _incorporationMessage = null;
      _existingPatientMatch = null;
      _documentFilename = null;
    });

    try {
      final result = await ApiService.analyzePatientPdf(
        patientId: patientId,
        filename: file.name,
        base64Data: base64Encode(bytes),
      );

      if (!mounted) return;

      setState(() {
        _documentAnalysis = result['analysis']?.toString();
        final data = result['documentData'];
        _documentData = data is Map<String, dynamic> ? data : null;
        final existing = result['existingPatient'];
        _existingPatientMatch =
            existing is Map<String, dynamic> ? existing : null;
        _documentFilename =
            result['filename']?.toString().trim().isNotEmpty == true
                ? result['filename'].toString().trim()
                : file.name;
      });
    } on ApiException catch (error) {
      if (!mounted) return;

      setState(() {
        _documentError = error.message;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _documentError = 'Ocurrió un error al analizar el PDF.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzingDocument = false;
        });
      }
    }
  }

  Future<void> _incorporateDocumentIntoPatient() async {
    if (_isIncorporatingDocument || _documentData == null) return;

    final filename = _documentFilename;
    if (filename == null || filename.trim().isEmpty) {
      setState(() {
        _documentError =
            'Nexa no pudo identificar el nombre del PDF analizado. Vuelve a analizar el documento.';
      });
      return;
    }

    final patientId = widget.patient['id'];
    if (patientId is! int) { setState(() => _documentError = 'El paciente no tiene un identificador válido.'); return; }
    if (_documentData!['isClinical'] != true) { setState(() => _documentError = 'Este documento no fue clasificado como clínico y no se incorporará a la ficha.'); return; }
    String normalizedRut(dynamic value) => value?.toString().toUpperCase().replaceAll(RegExp(r'[^0-9K]'), '') ?? '';
    final currentRut = normalizedRut(widget.patient['rut']);
    final incomingRut = normalizedRut(_documentData!['patientRut']);
    final identityDiffers = incomingRut.isNotEmpty && currentRut.isNotEmpty && incomingRut != currentRut;
    int? targetPatientId;
    if (identityDiffers) {
      final existing = _existingPatientMatch;
      if (existing == null || existing['id'] is! int) { setState(() => _documentError = 'El documento corresponde a otro RUT, pero Nexa no encontró una ficha existente. No se modificó la ficha actual.'); return; }
      final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
        title: const Text('Este paciente ya existe'),
        content: Text('El documento corresponde a ${existing['name'] ?? 'otro paciente'} (RUT ${existing['rut'] ?? 'sin información'}).\n\n¿Desea incorporar el documento a su ficha existente?\n\nLa ficha actual de ${widget.patient['name'] ?? 'este paciente'} no será modificada.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Incorporar a ficha existente'))],
      ));
      if (confirmed != true) return;
      targetPatientId = existing['id'] as int;
    }
    setState(() { _isIncorporatingDocument = true; _documentError = null; _incorporationMessage = null; });
    try {
      final result = await ApiService.incorporateDocumentData(
        patientId: patientId,
        documentData: _documentData!,
        filename: filename,
        targetPatientId: targetPatientId,
      );
      if (!mounted) return;
      final updatedPatient = result['patient']; final routed = result['routedToExistingPatient'] == true; final message = result['message']?.toString();
      setState(() { if (!routed && updatedPatient is Map<String, dynamic>) { widget.patient..clear()..addAll(updatedPatient); } _incorporationMessage = message?.trim().isNotEmpty == true ? message!.trim() : (routed ? 'Documento incorporado a la ficha existente. La ficha actual no fue modificada.' : 'Información incorporada y guardada correctamente en la ficha.'); });
    } on ApiException catch (error) { if (mounted) setState(() => _documentError = error.message); }
    catch (_) { if (mounted) setState(() => _documentError = 'Ocurrió un error al incorporar la información a la ficha.'); }
    finally { if (mounted) setState(() => _isIncorporatingDocument = false); }
  }

  void _askQuickQuestion(String question) {
    _questionController.text = question;
    _askNexa();
  }

  Future<void> _askNexa() async {
    final question = _questionController.text.trim();

    if (question.isEmpty || _isLoading) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _answer = null;
    });

    try {
      final answer = await ApiService.sendMessage(
        '${_patientContext()}\n\nPREGUNTA DEL USUARIO:\n$question',
      );

      if (!mounted) return;

      setState(() {
        _answer = answer;
      });
    } on ApiException catch (error) {
      if (!mounted) return;

      setState(() {
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _error = 'No fue posible obtener una respuesta de Nexa AI.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final patient = widget.patient;
    final history = _mapList(patient['history']);
    final documents = _stringList(patient['documents']);
    final risk = patient['risk']?.toString().trim().toUpperCase() ?? '';
    final summary = patient['aiSummary']?.toString().trim() ?? '';

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 27,
            backgroundColor: const Color(0xFFEFF6FF),
            child: Text(
              _initials(patient['name']?.toString() ?? ''),
              style: const TextStyle(
                color: NexaColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  patient['name']?.toString() ?? '',
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'RUT: ${patient['rut']?.toString() ?? 'Sin información'}',
                  style: const TextStyle(
                    color: NexaColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (risk.isNotEmpty) _RiskBadge(risk: risk),
        ],
      ),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Edad',
                      value: patient['age'] == null
                          ? 'Sin información'
                          : '${patient['age']} años',
                    ),
                  ),
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Hora',
                      value: patient['time']?.toString() ?? '',
                    ),
                  ),
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Médico',
                      value:
                          patient['doctor']?.toString() ?? 'Sin información',
                    ),
                  ),
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Teléfono',
                      value:
                          patient['phone']?.toString() ?? 'Sin información',
                    ),
                  ),
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Examen',
                      value: patient['exam']?.toString() ?? '',
                    ),
                  ),
                  SizedBox(
                    width: 290,
                    child: _InfoRow(
                      label: 'Sala',
                      value: patient['room']?.toString() ?? '',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StatusBadge(status: patient['status']?.toString() ?? ''),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'Observaciones',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 7),
              Text(
                patient['observations']?.toString() ?? 'Sin observaciones',
                style: const TextStyle(height: 1.45),
              ),
              const SizedBox(height: 20),
              _AiPanel(
                risk: risk.isEmpty ? 'SIN EVALUAR' : risk,
                summary: summary.isEmpty
                    ? 'No existe todavía un resumen generado por Nexa AI.'
                    : summary,
              ),
              const SizedBox(height: 18),
              _PatientChatPanel(
                controller: _questionController,
                isLoading: _isLoading,
                answer: _answer,
                error: _error,
                onSend: _askNexa,
                onQuickQuestion: _askQuickQuestion,
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'Documentos disponibles',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              if (documents.isEmpty)
                const Text('No hay documentos registrados.')
              else
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: documents.map((document) {
                    final record = _documentRecordFor(document);

                    return _DocumentChip(
                      name: document,
                      documentType: record?['documentType']?.toString(),
                      date: record?['date']?.toString(),
                      onTap: () => _showSavedDocument(document),
                      onDelete: () => _deleteDocument(document),
                      isDeleting: _deletingFilename == document,
                    );
                  }).toList(),
                ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed:
                    _isAnalyzingDocument ? null : _analyzePdfDocument,
                icon: _isAnalyzingDocument
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file_outlined),
                label: Text(
                  _isAnalyzingDocument
                      ? 'Analizando PDF...'
                      : 'Adjuntar y analizar PDF',
                ),
              ),
              if (_documentError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _documentError!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_documentData != null) ...[
                const SizedBox(height: 14),
                _DocumentDataCard(
                  data: _documentData!,
                  isIncorporating: _isIncorporatingDocument,
                  incorporationMessage: _incorporationMessage,
                  onIncorporate: _incorporateDocumentIntoPatient,
                ),
              ],
              if (_documentAnalysis != null) ...[
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: ExpansionTile(
                    leading: const Icon(
                      Icons.document_scanner_outlined,
                      color: Color(0xFFB45309),
                    ),
                    title: const Text(
                      'Ver análisis completo del documento',
                      style: TextStyle(
                        color: Color(0xFF92400E),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _documentAnalysis!,
                          style: const TextStyle(height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'Historial del paciente',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              if (history.isEmpty)
                const Text('No hay atenciones anteriores registradas.')
              else
                ...history.map(
                  (item) => _HistoryItem(
                    date: item['date']?.toString() ?? '',
                    exam: item['exam']?.toString() ?? '',
                    summary: item['summary']?.toString(),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _DocumentDataCard extends StatelessWidget {
  const _DocumentDataCard({
    required this.data,
    required this.isIncorporating,
    required this.incorporationMessage,
    required this.onIncorporate,
  });

  final Map<String, dynamic> data;
  final bool isIncorporating;
  final String? incorporationMessage;
  final VoidCallback onIncorporate;

  String value(String key) {
    final result = data[key]?.toString().trim();
    if (result == null || result.isEmpty || result == 'null') {
      return 'Sin información';
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final isClinical = data['isClinical'] == true;

    final fields = <({String label, String key, IconData icon})>[
      (label: 'Tipo de documento', key: 'documentType', icon: Icons.description_outlined),
      (label: 'Paciente', key: 'patientName', icon: Icons.person_outline),
      (label: 'RUT', key: 'patientRut', icon: Icons.badge_outlined),
      (label: 'Edad', key: 'patientAge', icon: Icons.cake_outlined),
      (label: 'Examen', key: 'exam', icon: Icons.biotech_outlined),
      (label: 'Médico', key: 'doctor', icon: Icons.medical_services_outlined),
      (label: 'Prioridad', key: 'priority', icon: Icons.flag_outlined),
      (label: 'Fecha', key: 'date', icon: Icons.calendar_today_outlined),
      (label: 'Motivo', key: 'reason', icon: Icons.notes_outlined),
      (label: 'Equipo', key: 'equipment', icon: Icons.monitor_heart_outlined),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexaColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A0F172A),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: isClinical
                      ? const Color(0xFFDCFCE7)
                      : const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isClinical
                      ? Icons.medical_information_outlined
                      : Icons.description_outlined,
                  color: isClinical
                      ? const Color(0xFF15803D)
                      : const Color(0xFFB45309),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isClinical
                          ? 'Documento clínico detectado'
                          : 'Documento no clínico detectado',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        color: NexaColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value('documentType'),
                      style: const TextStyle(color: NexaColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: fields
                .map(
                  (item) => SizedBox(
                    width: 290,
                    child: Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: NexaColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: NexaColors.border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            item.icon,
                            size: 19,
                            color: const Color(0xFF475569),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.label,
                                  style: const TextStyle(
                                    color: NexaColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  value(item.key),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: NexaColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF0FDFA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF99F6E4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Resumen extraído',
                  style: TextStyle(
                    color: Color(0xFF115E59),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  value('summary'),
                  style: const TextStyle(
                    color: Color(0xFF134E4A),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (isClinical)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isIncorporating ? null : onIncorporate,
                icon: isIncorporating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: NexaColors.surface,
                        ),
                      )
                    : const Icon(Icons.download_done_outlined),
                label: Text(
                  isIncorporating
                      ? 'Incorporando información...'
                      : 'Incorporar datos a la ficha',
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Este documento no es clínico. Nexa no modificará la ficha del paciente.',
                style: TextStyle(
                  color: Color(0xFF9A3412),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (incorporationMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: Color(0xFF15803D),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      incorporationMessage!,
                      style: const TextStyle(
                        color: Color(0xFF166534),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PatientChatPanel extends StatelessWidget {
  const _PatientChatPanel({
    required this.controller,
    required this.isLoading,
    required this.answer,
    required this.error,
    required this.onSend,
    required this.onQuickQuestion,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? answer;
  final String? error;
  final VoidCallback onSend;
  final ValueChanged<String> onQuickQuestion;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexaColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.chat_bubble_outline, color: NexaColors.primary),
              SizedBox(width: 9),
              Text(
                'Preguntar a Nexa sobre este paciente',
                style: TextStyle(
                  color: NexaColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.compare_arrows, size: 16),
                label: const Text('¿Qué cambió respecto al examen anterior?'),
                onPressed: isLoading
                    ? null
                    : () => onQuickQuestion(
                          '¿Qué cambió respecto al examen o documento anterior de este paciente?',
                        ),
              ),
              ActionChip(
                avatar: const Icon(Icons.timeline, size: 16),
                label: const Text('Resume la evolución del paciente'),
                onPressed: isLoading
                    ? null
                    : () => onQuickQuestion(
                          'Resume la evolución de este paciente a lo largo del tiempo, según el historial y los documentos disponibles.',
                        ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            enabled: !isLoading,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText:
                  'Ej.: Resume los antecedentes relevantes para este examen.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: isLoading ? null : onSend,
              icon: isLoading
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: NexaColors.surface,
                      ),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(isLoading ? 'Consultando...' : 'Consultar'),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 14),
            Text(
              error!,
              style: const TextStyle(
                color: Color(0xFFB91C1C),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (answer != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: NexaColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Text(
                answer!,
                style: const TextStyle(height: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AiPanel extends StatelessWidget {
  const _AiPanel({required this.risk, required this.summary});

  final String risk;
  final String summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDFA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF99F6E4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFF0F766E)),
              SizedBox(width: 9),
              Text(
                'Nexa AI',
                style: TextStyle(
                  color: Color(0xFF115E59),
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Nivel de riesgo: $risk',
            style: const TextStyle(
              color: Color(0xFF115E59),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            summary,
            style: const TextStyle(
              color: Color(0xFF134E4A),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _DocumentChip extends StatelessWidget {
  const _DocumentChip({
    required this.name,
    this.documentType,
    this.date,
    this.onTap,
    this.onDelete,
    this.isDeleting = false,
  });

  final String name;
  final String? documentType;
  final String? date;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final metaParts = [
      if (documentType != null && documentType!.trim().isNotEmpty)
        documentType!.trim(),
      if (date != null && date!.trim().isNotEmpty) date!.trim(),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexaColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 18,
                  color: NexaColors.primary,
                ),
                const SizedBox(width: 7),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (metaParts.isNotEmpty)
                      Text(
                        metaParts.join(' · '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: NexaColors.textSecondary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 26,
              height: 26,
              child: isDeleting
                  ? const Padding(
                      padding: EdgeInsets.all(5),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      tooltip: 'Eliminar documento',
                      onPressed: onDelete,
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RiskBadge extends StatelessWidget {
  const _RiskBadge({required this.risk});

  final String risk;

  @override
  Widget build(BuildContext context) {
    final isLow = risk == 'BAJO';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: isLow
            ? const Color(0xFFDCFCE7)
            : const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        risk,
        style: TextStyle(
          color: isLow
              ? const Color(0xFF15803D)
              : const Color(0xFFC2410C),
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({required this.date, required this.exam, this.summary});

  final String date;
  final String exam;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final hasSummary = summary != null && summary!.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexaColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, size: 19, color: NexaColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  exam,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                date,
                style: const TextStyle(
                  color: NexaColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          if (hasSummary) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 29),
              child: Text(
                summary!.trim(),
                style: const TextStyle(
                  color: NexaColors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.onRetry, this.message});

  final VoidCallback onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            color: Color(0xFFDC2626),
          ),
          const SizedBox(height: 10),
          Text(
            message ?? 'No fue posible conectar con Nexa Backend.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF991B1B),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }
}

class _SavedDocumentDialog extends StatefulWidget {
  const _SavedDocumentDialog({
    required this.patientId,
    required this.filename,
    required this.document,
  });

  final int patientId;
  final String filename;
  final Map<String, dynamic> document;

  @override
  State<_SavedDocumentDialog> createState() => _SavedDocumentDialogState();
}

class _SavedDocumentDialogState extends State<_SavedDocumentDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  String? _answer;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _value(String key) {
    final text = widget.document[key]?.toString().trim() ?? '';
    return text.isEmpty ? 'Sin información' : text;
  }

  Future<void> _ask() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _loading) return;
    setState(() { _loading = true; _answer = null; _error = null; });
    try {
      final answer = await ApiService.askPatientDocument(
        patientId: widget.patientId,
        filename: widget.filename,
        question: question,
      );
      if (!mounted) return;
      setState(() => _answer = answer);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No fue posible obtener una respuesta de Nexa.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.picture_as_pdf_outlined),
        const SizedBox(width: 10),
        Expanded(child: Text(widget.filename, overflow: TextOverflow.ellipsis)),
      ]),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _DocumentDetailRow(label: 'Tipo', value: _value('documentType')),
            _DocumentDetailRow(label: 'Paciente', value: _value('patientName')),
            _DocumentDetailRow(label: 'RUT', value: _value('patientRut')),
            _DocumentDetailRow(label: 'Edad', value: _value('patientAge')),
            _DocumentDetailRow(label: 'Examen', value: _value('exam')),
            _DocumentDetailRow(label: 'Médico', value: _value('doctor')),
            _DocumentDetailRow(label: 'Fecha', value: _value('date')),
            _DocumentDetailRow(label: 'Prioridad', value: _value('priority')),
            const Divider(height: 28),
            const Text('Resumen guardado', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            SelectableText(_value('summary')),
            const SizedBox(height: 18),
            const Text('Equipo / técnica', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            SelectableText(_value('equipment')),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            const Row(children: [
              Icon(Icons.auto_awesome, size: 20, color: Color(0xFF4F64A3)),
              SizedBox(width: 8),
              Text('Preguntar a Nexa sobre este documento', style: TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Ej.: ¿Cuáles son los hallazgos principales de este informe?',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _ask(),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _loading ? null : _ask,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(_loading ? 'Consultando...' : 'Consultar'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
            ],
            if (_answer != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDFA),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF99F6E4)),
                ),
                child: SelectableText(_answer!, style: const TextStyle(height: 1.45)),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ],
    );
  }
}

class _DocumentDetailRow extends StatelessWidget {
  const _DocumentDetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 105,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF475569))),
        ),
        Expanded(child: SelectableText(value)),
      ]),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (status) {
      case 'En atención':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        icon = Icons.check_circle_outline;
        break;
      case 'Esperando':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        icon = Icons.schedule;
        break;
      default:
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        icon = Icons.event_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: textColor),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
