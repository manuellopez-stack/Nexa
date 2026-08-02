import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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

  Future<List<Map<String, dynamic>>> _loadPatients() async {
    final response = await http.get(
      Uri.parse('http://localhost:3000/patients/today'),
    );

    if (response.statusCode != 200) {
      throw Exception('No fue posible cargar los pacientes.');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final patients = data['patients'] as List<dynamic>;

    return patients
        .map((patient) => Map<String, dynamic>.from(patient as Map))
        .toList();
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
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
                color: Color(0xFF2563EB),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Pacientes del día',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
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
            style: TextStyle(color: Color(0xFF64748B)),
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
                return _ErrorMessage(onRetry: _reloadPatients);
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
                    Color(0xFFF8FAFC),
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

  String _patientContext() {
    final patient = widget.patient;
    final history = _mapList(patient['history']);

    final historyText = history.isEmpty
        ? 'Sin historial registrado.'
        : history
            .map(
              (item) =>
                  '- ${item['date'] ?? ''}: ${item['exam'] ?? ''}',
            )
            .join('\n');

    return '''
Responde exclusivamente usando la ficha clínica proporcionada.
No inventes diagnósticos ni datos.
Aclara cuando la información no sea suficiente.
No reemplaces la evaluación de un profesional de salud.

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

HISTORIAL
$historyText
'''.trim();
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
                color: Color(0xFF2563EB),
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
                    color: Color(0xFF64748B),
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
                  children: documents
                      .map((document) => _DocumentChip(name: document))
                      .toList(),
                ),
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

class _PatientChatPanel extends StatelessWidget {
  const _PatientChatPanel({
    required this.controller,
    required this.isLoading,
    required this.answer,
    required this.error,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool isLoading;
  final String? answer;
  final String? error;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.chat_bubble_outline, color: Color(0xFF2563EB)),
              SizedBox(width: 9),
              Text(
                'Preguntar a Nexa sobre este paciente',
                style: TextStyle(
                  color: Color(0xFF0F172A),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
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
                        color: Colors.white,
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
                color: Colors.white,
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
  const _DocumentChip({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.description_outlined,
            size: 18,
            color: Color(0xFF2563EB),
          ),
          const SizedBox(width: 7),
          Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
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
  const _HistoryItem({required this.date, required this.exam});

  final String date;
  final String exam;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, size: 19, color: Color(0xFF2563EB)),
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
              color: Color(0xFF64748B),
              fontSize: 13,
            ),
          ),
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
  const _ErrorMessage({required this.onRetry});

  final VoidCallback onRetry;

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
          const Text(
            'No fue posible conectar con Nexa Backend.',
            style: TextStyle(
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
