import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../screens/imaging_report_editor_page.dart';
import '../services/api_service.dart';
import 'document_pdf.dart';

/// Informe radiológico escrito en Imagenda, dentro del detalle de una orden de
/// imagenología. El médico ve "Escribir informe" / "Continuar borrador" /
/// "Ver informe firmado" + "Nueva versión" según el estado; los demás roles,
/// solo "Ver informe firmado". [onChanged] se llama si se guardó o firmó algo
/// (la orden puede haber cambiado de estado).
class ImagingReportActions extends StatefulWidget {
  const ImagingReportActions({
    super.key,
    required this.patientId,
    required this.orderId,
    required this.onChanged,
  });

  final int patientId;
  final String orderId;
  final VoidCallback onChanged;

  @override
  State<ImagingReportActions> createState() => _ImagingReportActionsState();
}

class _ImagingReportActionsState extends State<ImagingReportActions> {
  late Future<Map<String, dynamic>> _future;
  bool _creatingVersion = false;

  bool get _isDoctor => ApiService.role == 'medico';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() => ApiService.getImagingReport(
    patientId: widget.patientId,
    orderId: widget.orderId,
  );

  void _reload() => setState(() => _future = _load());

  Future<void> _openEditor() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ImagingReportEditorPage(
          patientId: widget.patientId,
          orderId: widget.orderId,
        ),
      ),
    );
    if (!mounted) return;
    _reload();
    if (changed == true) widget.onChanged();
  }

  Future<void> _newVersion() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nueva versión del informe'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Se creará un borrador con el texto del informe firmado para que '
            'lo corrijas. El informe firmado sigue vigente hasta que firmes la '
            'nueva versión; en ese momento quedará reemplazado.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Crear nueva versión'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _creatingVersion = true);
    try {
      await ApiService.createImagingReportVersion(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      if (mounted) await _openEditor();
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _creatingVersion = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        // Si falla (p. ej. la migración todavía no está aplicada) no se
        // muestra nada: el flujo de informe subido sigue igual.
        final data = snapshot.data;
        if (snapshot.hasError || data == null) return const SizedBox.shrink();

        final report = data['report'] is Map
            ? Map<String, dynamic>.from(data['report'] as Map)
            : null;
        final permissions = data['permissions'] is Map
            ? Map<String, dynamic>.from(data['permissions'] as Map)
            : const <String, dynamic>{};
        final status = report?['status']?.toString();
        final signedFilename = status == 'firmado'
            ? (report?['documentFilename'])?.toString()
            : null;

        final buttons = <Widget>[
          if (_isDoctor && report == null && permissions['canDraft'] == true)
            FilledButton.icon(
              onPressed: _openEditor,
              style: FilledButton.styleFrom(
                backgroundColor: NexaColors.primary,
              ),
              icon: const Icon(Icons.edit_note, size: 18),
              label: const Text('Escribir informe'),
            ),
          if (_isDoctor && status == 'borrador')
            FilledButton.icon(
              onPressed: _openEditor,
              style: FilledButton.styleFrom(
                backgroundColor: NexaColors.primary,
              ),
              icon: const Icon(Icons.edit_note, size: 18),
              label: Text(
                (report?['version'] is int && (report!['version'] as int) > 1)
                    ? 'Continuar borrador (versión ${report['version']})'
                    : 'Continuar borrador',
              ),
            ),
          if (signedFilename != null && signedFilename.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => openDocumentPdf(
                context,
                patientId: widget.patientId,
                filename: signedFilename,
              ),
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text('Ver informe firmado'),
            ),
          if (_isDoctor && permissions['canCreateNewVersion'] == true)
            OutlinedButton.icon(
              onPressed: _creatingVersion ? null : _newVersion,
              icon: const Icon(Icons.history_edu_outlined, size: 18),
              label: const Text('Nueva versión'),
            ),
        ];
        if (buttons.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (status == 'firmado')
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Firmado por ${report?['signerName'] ?? '—'}'
                    '${report?['signerSpecialty'] != null ? ' (${report!['signerSpecialty']})' : ''}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                ),
              Wrap(spacing: 8, runSpacing: 8, children: buttons),
            ],
          ),
        );
      },
    );
  }
}
