import 'dart:async';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../services/browser_download.dart';
import '../widgets/ohif_viewer_button.dart';

/// Campos del informe, en el orden en que se muestran: (clave del backend,
/// título).
const List<(String, String)> _kReportSections = [
  ('clinicalHistory', 'Antecedentes clínicos'),
  ('technique', 'Técnica'),
  ('findings', 'Hallazgos'),
  ('impression', 'Impresión diagnóstica'),
];

/// Editor del informe radiológico de una orden de imagenología (rol médico).
/// Trabaja sobre el borrador: lo crea con la plantilla si todavía no hay
/// informe, lo guarda solo cada 30 segundos si hubo cambios y lo firma.
/// Devuelve true al cerrarse si se guardó o firmó algo.
class ImagingReportEditorPage extends StatefulWidget {
  const ImagingReportEditorPage({
    super.key,
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  @override
  State<ImagingReportEditorPage> createState() =>
      _ImagingReportEditorPageState();
}

class _ImagingReportEditorPageState extends State<ImagingReportEditorPage> {
  static const Duration _autosaveEvery = Duration(seconds: 30);

  final Map<String, TextEditingController> _controllers = {
    for (final (key, _) in _kReportSections) key: TextEditingController(),
  };
  Map<String, String> _hints = const {};
  Map<String, dynamic>? _data;
  String? _loadError;
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  bool _signing = false;
  bool _changedSomething = false;
  DateTime? _savedAt;
  Timer? _autosave;

  Map<String, dynamic>? get _report => _data?['report'] is Map
      ? Map<String, dynamic>.from(_data!['report'] as Map)
      : null;

  bool get _isDraftEditable {
    final report = _report;
    if (report != null) return report['status'] == 'borrador';
    final permissions = _data?['permissions'];
    return permissions is Map && permissions['canDraft'] == true;
  }

  Map<String, String> get _fields => {
    for (final (key, _) in _kReportSections) key: _controllers[key]!.text,
  };

  @override
  void initState() {
    super.initState();
    for (final controller in _controllers.values) {
      controller.addListener(_markDirty);
    }
    _load();
    _autosave = Timer.periodic(_autosaveEvery, (_) {
      if (_dirty && !_saving && !_signing) _save(quiet: true);
    });
  }

  @override
  void dispose() {
    _autosave?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty && !_loading) setState(() => _dirty = true);
  }

  // Llena los campos sin marcar cambios.
  void _fill(Map<String, String> values) {
    for (final (key, _) in _kReportSections) {
      _controllers[key]!.text = values[key] ?? '';
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final data = await ApiService.getImagingReport(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      if (!mounted) return;
      _data = data;
      final report = _report;
      final template = data['template'] is Map
          ? Map<String, dynamic>.from(data['template'] as Map)
          : null;
      if (report != null) {
        _fill({
          for (final (key, _) in _kReportSections)
            key: report[key]?.toString() ?? '',
        });
        _hints = const {};
      } else {
        // Sin informe: técnica y antecedentes parten con el texto base; en
        // Hallazgos e Impresión la plantilla es solo una guía (hint).
        _fill({
          'clinicalHistory': template?['clinicalHistory']?.toString() ?? '',
          'technique': template?['technique']?.toString() ?? '',
        });
        _hints = {
          'findings': template?['findings']?.toString() ?? '',
          'impression': template?['impression']?.toString() ?? '',
        };
      }
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'No fue posible cargar el informe.';
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  /// Guarda el borrador. true si quedó guardado.
  Future<bool> _save({bool quiet = false}) async {
    if (_saving) return false;
    setState(() => _saving = true);
    try {
      final data = await ApiService.saveImagingReportDraft(
        patientId: widget.patientId,
        orderId: widget.orderId,
        fields: _fields,
      );
      if (!mounted) return true;
      setState(() {
        _data = data;
        _dirty = false;
        _savedAt = DateTime.now();
        _changedSomething = true;
      });
      if (!quiet) _showMessage('Borrador guardado.');
      return true;
    } on ApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('No fue posible guardar el borrador.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return false;
  }

  /// Vista previa en una pestaña nueva. La pestaña se abre dentro del clic
  /// (antes de cualquier await) para que el navegador no la bloquee.
  Future<void> _preview() async {
    final tab = openPendingBrowserTab();
    if (_dirty || _report == null) {
      final saved = await _save(quiet: true);
      if (!saved) {
        tab?.close();
        return;
      }
    }
    try {
      final bytes = await ApiService.getImagingReportPreview(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      if (tab != null) {
        tab.showBytes(bytes, 'application/pdf');
      } else if (!saveBytesAsFile(
        bytes,
        'borrador-informe.pdf',
        'application/pdf',
      )) {
        _showMessage(
          'La vista previa solo está disponible en la versión web de Imagenda.',
        );
      }
    } on ApiException catch (error) {
      tab?.close();
      if (mounted) _showMessage(error.message);
    } catch (_) {
      tab?.close();
      if (mounted) _showMessage('No fue posible generar la vista previa.');
    }
  }

  Map<String, dynamic> get _mySignature => _data?['mySignature'] is Map
      ? Map<String, dynamic>.from(_data!['mySignature'] as Map)
      : const {};

  /// Pide los datos de firma. true si quedaron completos.
  Future<bool> _askSignature() async {
    final signature = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SignatureDataDialog(initial: _mySignature),
    );
    if (signature == null || !mounted) return false;
    setState(() {
      _data = {...?_data, 'mySignature': signature};
    });
    return signature['complete'] == true;
  }

  Future<void> _sign() async {
    final fields = _fields;
    if (fields['findings']!.trim().isEmpty ||
        fields['impression']!.trim().isEmpty) {
      _showMessage(
        'Completa Hallazgos e Impresión diagnóstica antes de firmar.',
      );
      return;
    }
    if (_mySignature['complete'] != true && !await _askSignature()) return;
    if (!mounted) return;

    // Aviso si quedaron guías de la plantilla entre corchetes.
    final hasTemplateGuides = fields.values.any(
      (text) => RegExp(r'\[[^\]]+\]').hasMatch(text),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Firmar informe'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Al firmar, el informe quedará aprobado con tu nombre, RUT y '
                'especialidad, y ya no podrás editarlo. ¿Firmar?',
              ),
              if (hasTemplateGuides) ...[
                const SizedBox(height: 12),
                const Text(
                  'Atención: todavía hay textos de la plantilla entre corchetes '
                  '[ ].',
                  style: TextStyle(
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Firmar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _signing = true);
    try {
      await _signOnce(fields);
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  Future<void> _signOnce(
    Map<String, String> fields, {
    bool retried = false,
  }) async {
    try {
      await ApiService.signImagingReport(
        patientId: widget.patientId,
        orderId: widget.orderId,
        fields: fields,
      );
      if (!mounted) return;
      _dirty = false;
      _changedSomething = true;
      _showMessage('Informe firmado. Ya está aprobado y adjunto a la orden.');
      Navigator.pop(context, true);
    } on SignatureIncompleteException {
      // Los datos de firma cambiaron en otro lado: se piden y se reintenta.
      if (!retried && mounted && await _askSignature()) {
        await _signOnce(fields, retried: true);
      }
    } on ApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('No fue posible firmar el informe.');
    }
  }

  // Al salir con cambios sin guardar, se guardan antes.
  Future<void> _leave() async {
    if (_dirty && _isDraftEditable) await _save(quiet: true);
    if (mounted) Navigator.pop(context, _changedSomething);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: NexaColors.background,
        appBar: AppBar(
          backgroundColor: NexaColors.surface,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            tooltip: 'Volver',
            icon: const Icon(Icons.arrow_back),
            onPressed: _leave,
          ),
          title: const Text('Informe radiológico'),
          actions: [
            if (!_loading && _isDraftEditable)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: _SaveStatus(
                    saving: _saving,
                    dirty: _dirty,
                    savedAt: _savedAt,
                  ),
                ),
              ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    final data = _data ?? const {};
    final patient = data['patient'] is Map
        ? Map<String, dynamic>.from(data['patient'] as Map)
        : const <String, dynamic>{};
    final exam = data['exam'] is Map
        ? Map<String, dynamic>.from(data['exam'] as Map)
        : const <String, dynamic>{};
    final order = data['order'] is Map
        ? Map<String, dynamic>.from(data['order'] as Map)
        : const <String, dynamic>{};
    final report = _report;
    final editable = _isDraftEditable;
    final busy = _saving || _signing;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReportHeader(
                patient: patient,
                examTitle: exam['title']?.toString() ?? '',
                accessionNumber: order['accessionNumber']?.toString(),
                version: report?['version'],
                trailing: OhifViewerButton(
                  patientId: widget.patientId,
                  orderId: widget.orderId,
                ),
              ),
              const SizedBox(height: 16),
              if (!editable)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    report?['status'] == 'firmado'
                        ? 'Este informe ya está firmado y no se puede editar. '
                              'Para corregirlo, crea una nueva versión desde la orden.'
                        : 'Este estudio todavía no se puede informar (debe estar realizado).',
                  ),
                ),
              for (final (key, title) in _kReportSections) ...[
                _SectionField(
                  title: title,
                  controller: _controllers[key]!,
                  hint: _hints[key],
                  enabled: editable && !_signing,
                  large: key == 'findings',
                ),
                const SizedBox(height: 16),
              ],
              if (editable)
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _save(),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Guardar borrador'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _preview,
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('Vista previa'),
                    ),
                    FilledButton.icon(
                      onPressed: busy ? null : _sign,
                      style: FilledButton.styleFrom(
                        backgroundColor: NexaColors.primary,
                      ),
                      icon: _signing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.draw_outlined, size: 18),
                      label: Text(_signing ? 'Firmando...' : 'Firmar informe'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveStatus extends StatelessWidget {
  const _SaveStatus({
    required this.saving,
    required this.dirty,
    required this.savedAt,
  });

  final bool saving;
  final bool dirty;
  final DateTime? savedAt;

  @override
  Widget build(BuildContext context) {
    final String text;
    if (saving) {
      text = 'Guardando...';
    } else if (dirty) {
      text = 'Cambios sin guardar';
    } else if (savedAt != null) {
      final time = TimeOfDay.fromDateTime(savedAt!);
      text =
          'Guardado a las ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else {
      text = '';
    }
    return Text(
      text,
      style: const TextStyle(fontSize: 12.5, color: NexaColors.textSecondary),
    );
  }
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({
    required this.patient,
    required this.examTitle,
    required this.accessionNumber,
    required this.version,
    required this.trailing,
  });

  final Map<String, dynamic> patient;
  final String examTitle;
  final String? accessionNumber;
  final Object? version;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final age = patient['age'];
    final details = [
      if ((patient['rut']?.toString() ?? '').isNotEmpty)
        'RUT ${patient['rut']}',
      if (age != null) '$age años',
      if (accessionNumber != null && accessionNumber!.isNotEmpty)
        'N° de acceso $accessionNumber',
      if (version is int && (version as int) > 1) 'Versión $version',
    ];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NexaColors.border),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                patient['name']?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: NexaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                examTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: NexaColors.primaryDark,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                details.join(' · '),
                style: const TextStyle(color: NexaColors.textSecondary),
              ),
            ],
          ),
          trailing,
        ],
      ),
    );
  }
}

class _SectionField extends StatelessWidget {
  const _SectionField({
    required this.title,
    required this.controller,
    required this.hint,
    required this.enabled,
    required this.large,
  });

  final String title;
  final TextEditingController controller;
  final String? hint;
  final bool enabled;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: NexaColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          enabled: enabled,
          minLines: large ? 8 : 4,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: hint != null && hint!.isNotEmpty ? hint : null,
            hintMaxLines: 4,
            filled: true,
            fillColor: NexaColors.surface,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

/// Datos de firma del médico conectado (nombre, RUT y especialidad). Los
/// guarda con PATCH /me/signature y devuelve la firma actualizada, o null si
/// se cancela.
class SignatureDataDialog extends StatefulWidget {
  const SignatureDataDialog({super.key, required this.initial});

  final Map<String, dynamic> initial;

  @override
  State<SignatureDataDialog> createState() => _SignatureDataDialogState();
}

class _SignatureDataDialogState extends State<SignatureDataDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial['fullName']?.toString() ?? ApiService.fullName ?? '',
  );
  late final TextEditingController _rut = TextEditingController(
    text: widget.initial['rut']?.toString() ?? '',
  );
  late final TextEditingController _specialty = TextEditingController(
    text: widget.initial['specialty']?.toString() ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _rut.dispose();
    _specialty.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _rut.text.trim().isNotEmpty &&
      _specialty.text.trim().isNotEmpty &&
      !_saving;

  Future<void> _submit() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final signature = await ApiService.updateMySignature(
        fullName: _name.text.trim(),
        rut: _rut.text.trim(),
        specialty: _specialty.text.trim(),
      );
      if (mounted) Navigator.pop(context, signature);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible guardar tus datos de firma.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration decoration(String label) =>
        InputDecoration(labelText: label, border: const OutlineInputBorder());

    return AlertDialog(
      title: const Text('Completa tus datos de firma'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Aparecerán al pie de cada informe que firmes.',
              style: TextStyle(color: NexaColors.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: decoration('Nombre completo'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rut,
              onChanged: (_) => setState(() {}),
              decoration: decoration('RUT (ej. 12.345.678-5)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _specialty,
              onChanged: (_) => setState(() {}),
              decoration: decoration('Especialidad (ej. Radiología)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _canSave ? _submit : null,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}
