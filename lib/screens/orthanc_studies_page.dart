import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/milmed_brand_mark.dart';
import '../widgets/patient_picker_dialog.dart';

/// Pantalla "Estudios sin vincular": estudios DICOM recibidos en Orthanc que
/// no se pudieron casar automáticamente por accession_number (ver
/// GET /orthanc-studies?status=unlinked en server.mjs). Permite vincularlos
/// a mano eligiendo paciente y orden.
class OrthancStudiesPage extends StatefulWidget {
  const OrthancStudiesPage({super.key});

  @override
  State<OrthancStudiesPage> createState() => _OrthancStudiesPageState();
}

class _OrthancStudiesPageState extends State<OrthancStudiesPage> {
  late Future<List<Map<String, dynamic>>> _studiesFuture;
  String? _linkingStudyId;

  @override
  void initState() {
    super.initState();
    _studiesFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    return ApiService.getUnlinkedOrthancStudies();
  }

  void _reload() {
    setState(() {
      _studiesFuture = _load();
    });
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _linkStudy(Map<String, dynamic> study) async {
    final orthancStudyId = study['orthancStudyId']?.toString();
    if (orthancStudyId == null || orthancStudyId.isEmpty) return;

    final patient = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const PatientPickerDialog(),
    );
    if (patient == null || !mounted) return;

    final patientId = patient['id'];
    if (patientId is! int) {
      _notify('El paciente elegido no tiene un identificador válido.');
      return;
    }

    final order = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _OrderPickerDialog(
        patientId: patientId,
        patientName: patient['name']?.toString() ?? 'paciente',
      ),
    );
    if (order == null || !mounted) return;

    final orderId = order['id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      _notify('La orden elegida no tiene un identificador válido.');
      return;
    }

    setState(() => _linkingStudyId = orthancStudyId);

    try {
      await ApiService.linkOrthancStudy(
        orthancStudyId: orthancStudyId,
        orderId: orderId,
      );
      if (!mounted) return;
      _notify('Estudio vinculado correctamente.');
      _reload();
    } on ApiException catch (error) {
      if (mounted) _notify(error.message);
    } catch (_) {
      if (mounted) _notify('No fue posible vincular el estudio.');
    } finally {
      if (mounted) setState(() => _linkingStudyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: AppBar(
        backgroundColor: NexaColors.surface,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MilmedBrandMark(),
            SizedBox(width: 12),
            Text(
              'Estudios sin vincular',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: NexaColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Container(
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
                      const Icon(Icons.link_off, color: NexaColors.primary),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Estudios DICOM sin vincular',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: NexaColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Actualizar',
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Estudios recibidos desde el equipo de imagenología que no '
                    'se pudieron casar automáticamente con una orden. Vincúlalos '
                    'a mano eligiendo el paciente y la orden correspondiente.',
                    style: TextStyle(color: NexaColors.textSecondary),
                  ),
                  const SizedBox(height: 22),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _studiesFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }

                      if (snapshot.hasError) {
                        final error = snapshot.error;
                        return _ErrorMessage(
                          message: error is ApiException
                              ? error.message
                              : 'No fue posible cargar los estudios de Orthanc.',
                          onRetry: _reload,
                        );
                      }

                      final studies = snapshot.data ?? [];

                      if (studies.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('No hay estudios pendientes de vincular.'),
                        );
                      }

                      return Column(
                        children: studies.map((study) {
                          final orthancStudyId =
                              study['orthancStudyId']?.toString() ?? '';
                          return _UnlinkedStudyTile(
                            study: study,
                            isLinking: _linkingStudyId == orthancStudyId,
                            onLink: () => _linkStudy(study),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UnlinkedStudyTile extends StatelessWidget {
  const _UnlinkedStudyTile({
    required this.study,
    required this.isLinking,
    required this.onLink,
  });

  final Map<String, dynamic> study;
  final bool isLinking;
  final VoidCallback onLink;

  String _formatDicomDate(String? raw) {
    if (raw == null) return '';
    final value = raw.trim();
    if (RegExp(r'^\d{8}$').hasMatch(value)) {
      return '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}';
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final accessionNumber = study['accessionNumberReceived']?.toString().trim();
    final patientName = study['patientNameReceived']?.toString().trim();
    final patientIdReceived = study['patientIdReceived']?.toString().trim();
    final studyDate = _formatDicomDate(study['studyDate']?.toString());

    final subtitleParts = [
      if (patientName != null && patientName.isNotEmpty) patientName,
      if (patientIdReceived != null && patientIdReceived.isNotEmpty)
        'ID DICOM: $patientIdReceived',
      if (studyDate.isNotEmpty) 'Fecha: $studyDate',
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexaColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (accessionNumber != null && accessionNumber.isNotEmpty)
                      ? 'Accession number: $accessionNumber'
                      : 'Sin accession number',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.join(' · '),
                    style: const TextStyle(
                      color: NexaColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: isLinking ? null : onLink,
            icon: isLinking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link, size: 18),
            label: Text(isLinking ? 'Vinculando...' : 'Vincular a una orden'),
          ),
        ],
      ),
    );
  }
}

/// Diálogo para elegir a qué orden de imagenología de un paciente ya
/// seleccionado se vincula el estudio.
class _OrderPickerDialog extends StatefulWidget {
  const _OrderPickerDialog({required this.patientId, required this.patientName});

  final int patientId;
  final String patientName;

  @override
  State<_OrderPickerDialog> createState() => _OrderPickerDialogState();
}

class _OrderPickerDialogState extends State<_OrderPickerDialog> {
  late Future<List<Map<String, dynamic>>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = ApiService.getImagingOrders(widget.patientId);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Elegir orden — ${widget.patientName}'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _ordersFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return const Center(
                child: Text('No fue posible cargar las órdenes de este paciente.'),
              );
            }

            final orders = snapshot.data ?? [];

            if (orders.isEmpty) {
              return const Center(
                child: Text('Este paciente no tiene órdenes de imagenología.'),
              );
            }

            return ListView.builder(
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                final types = (order['types'] as List? ?? [])
                    .whereType<Map>()
                    .map((t) => t['name']?.toString() ?? '')
                    .where((name) => name.isNotEmpty)
                    .join(', ');
                final status = order['status']?.toString() ?? 'ordenado';
                final accessionNumber = order['accessionNumber']?.toString();

                return ListTile(
                  dense: true,
                  title: Text(types.isEmpty ? 'Estudio de imagenología' : types),
                  subtitle: Text(
                    [
                      if (accessionNumber != null && accessionNumber.trim().isNotEmpty)
                        accessionNumber.trim(),
                      status,
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.pop(context, order),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
      ],
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
          const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
          const SizedBox(height: 10),
          Text(
            message ?? 'No fue posible conectar con Imagenda Backend.',
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
