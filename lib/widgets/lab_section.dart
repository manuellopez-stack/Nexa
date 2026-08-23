import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

class LabOrdersSection extends StatefulWidget {
  const LabOrdersSection({super.key, required this.patientId});

  final int? patientId;

  @override
  State<LabOrdersSection> createState() => _LabOrdersSectionState();
}

class _LabOrdersSectionState extends State<LabOrdersSection> {
  late Future<List<Map<String, dynamic>>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    final patientId = widget.patientId;
    if (patientId == null) return Future.value([]);
    return ApiService.getLabOrders(patientId);
  }

  void _reload() {
    setState(() {
      _ordersFuture = _load();
    });
  }

  Future<void> _openCreateDialog() async {
    final patientId = widget.patientId;
    if (patientId == null) return;

    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _CreateLabOrderDialog(patientId: patientId),
    );

    if (created == true) _reload();
  }

  Future<void> _openOrderDetail(String orderId) async {
    final patientId = widget.patientId;
    if (patientId == null) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _LabOrderDetailDialog(
        patientId: patientId,
        orderId: orderId,
      ),
    );

    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.biotech_outlined, color: NexaColors.primary),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Laboratorio',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Solicitar examen'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _ordersFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              final error = snapshot.error;
              return Text(
                error is ApiException
                    ? error.message
                    : 'No fue posible cargar las órdenes de laboratorio.',
                style: const TextStyle(color: Color(0xFFB91C1C)),
              );
            }

            final orders = snapshot.data ?? [];

            if (orders.isEmpty) {
              return const Text('No hay exámenes de laboratorio solicitados.');
            }

            return Column(
              children: orders.map((order) {
                final panels = (order['panels'] as List? ?? [])
                    .whereType<Map>()
                    .map((p) => p['name']?.toString() ?? '')
                    .where((name) => name.isNotEmpty)
                    .join(', ');
                final status = order['status']?.toString() ?? 'ordenado';
                final orderId = order['id']?.toString() ?? '';

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: NexaColors.background,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: orderId.isEmpty
                          ? null
                          : () => _openOrderDetail(orderId),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: NexaColors.border),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                panels.isEmpty
                                    ? 'Examen de laboratorio'
                                    : panels,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            _LabStatusBadge(status: status),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

class _CreateLabOrderDialog extends StatefulWidget {
  const _CreateLabOrderDialog({required this.patientId});

  final int patientId;

  @override
  State<_CreateLabOrderDialog> createState() => _CreateLabOrderDialogState();
}

class _CreateLabOrderDialogState extends State<_CreateLabOrderDialog> {
  late Future<List<Map<String, dynamic>>> _panelsFuture;
  final Set<String> _selectedPanelIds = {};
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _panelsFuture = ApiService.getLabPanels();
  }

  Future<void> _submit() async {
    if (_selectedPanelIds.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.createLabOrder(
        patientId: widget.patientId,
        panelIds: _selectedPanelIds.toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible crear la orden de laboratorio.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Solicitar examen de laboratorio'),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _panelsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              return const Text(
                'No fue posible cargar el catálogo de exámenes.',
              );
            }

            final panels = snapshot.data ?? [];

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Selecciona uno o más exámenes:'),
                  const SizedBox(height: 8),
                  ...panels.map((panel) {
                    final id = panel['id']?.toString() ?? '';
                    final name = panel['name']?.toString() ?? '';
                    final code = panel['fonasaCode']?.toString() ?? '';

                    return CheckboxListTile(
                      value: _selectedPanelIds.contains(id),
                      onChanged: id.isEmpty
                          ? null
                          : (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedPanelIds.add(id);
                                } else {
                                  _selectedPanelIds.remove(id);
                                }
                              });
                            },
                      title: Text(name),
                      subtitle:
                          code.isEmpty ? null : Text('Código FONASA: $code'),
                      controlAffinity: ListTileControlAffinity.leading,
                    );
                  }),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFB91C1C)),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed:
              (_selectedPanelIds.isEmpty || _isSubmitting) ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Crear orden'),
        ),
      ],
    );
  }
}

class _LabOrderDetailDialog extends StatefulWidget {
  const _LabOrderDetailDialog({
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  @override
  State<_LabOrderDetailDialog> createState() => _LabOrderDetailDialogState();
}

class _LabOrderDetailDialogState extends State<_LabOrderDetailDialog> {
  late Future<Map<String, dynamic>> _detailFuture;
  final Map<String, TextEditingController> _controllers = {};
  bool _isSavingResults = false;
  bool _isMarkingSample = false;
  bool _isValidating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detailFuture = _load();
  }

  Future<Map<String, dynamic>> _load() {
    return ApiService.getLabOrderDetail(
      patientId: widget.patientId,
      orderId: widget.orderId,
    );
  }

  void _reload() {
    setState(() {
      _detailFuture = _load();
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(
    String parameterId,
    String? initialValue,
  ) {
    return _controllers.putIfAbsent(
      parameterId,
      () => TextEditingController(text: initialValue ?? ''),
    );
  }

  Future<void> _markSampleTaken() async {
    if (_isMarkingSample) return;
    setState(() {
      _isMarkingSample = true;
      _error = null;
    });
    try {
      await ApiService.markSampleTaken(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible marcar la toma de muestra.');
      }
    } finally {
      if (mounted) setState(() => _isMarkingSample = false);
    }
  }

  Future<void> _saveResults(List<Map<String, dynamic>> parameters) async {
    if (_isSavingResults) return;

    final results = <Map<String, dynamic>>[];

    for (final parameter in parameters) {
      final parameterId = parameter['id']?.toString() ?? '';
      if (parameterId.isEmpty) continue;

      final controller = _controllers[parameterId];
      final text = controller?.text.trim() ?? '';
      if (text.isEmpty) continue;

      final isQualitative = parameter['refText'] != null;

      if (isQualitative) {
        results.add({'parameterId': parameterId, 'valueText': text});
      } else {
        final numericValue = double.tryParse(text.replaceAll(',', '.'));
        if (numericValue == null) continue;
        results.add({
          'parameterId': parameterId,
          'valueNumeric': numericValue,
        });
      }
    }

    if (results.isEmpty) {
      setState(() {
        _error = 'Ingresa al menos un resultado antes de guardar.';
      });
      return;
    }

    setState(() {
      _isSavingResults = true;
      _error = null;
    });

    try {
      await ApiService.saveLabResults(
        patientId: widget.patientId,
        orderId: widget.orderId,
        results: results,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible guardar los resultados.');
      }
    } finally {
      if (mounted) setState(() => _isSavingResults = false);
    }
  }

  Future<void> _validate() async {
    if (_isValidating) return;
    setState(() {
      _isValidating = true;
      _error = null;
    });
    try {
      await ApiService.validateLabOrder(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No fue posible validar la orden.');
    } finally {
      if (mounted) setState(() => _isValidating = false);
    }
  }

  String _referenceRangeText(Map<String, dynamic> parameter) {
    final refText = parameter['refText']?.toString();
    if (refText != null && refText.isNotEmpty) {
      return 'Esperado: $refText';
    }

    final unit = parameter['unit']?.toString() ?? '';
    final min = parameter['refMin'];
    final max = parameter['refMax'];
    final minMale = parameter['refMinMale'];
    final maxMale = parameter['refMaxMale'];
    final minFemale = parameter['refMinFemale'];
    final maxFemale = parameter['refMaxFemale'];

    if (minMale != null ||
        maxMale != null ||
        minFemale != null ||
        maxFemale != null) {
      final malePart = (minMale != null || maxMale != null)
          ? 'H: ${minMale ?? '-'}–${maxMale ?? '-'} $unit'
          : '';
      final femalePart = (minFemale != null || maxFemale != null)
          ? 'M: ${minFemale ?? '-'}–${maxFemale ?? '-'} $unit'
          : '';
      return [
        malePart,
        femalePart,
      ].where((p) => p.isNotEmpty).join(' · ');
    }

    if (min != null || max != null) {
      return 'Normal: ${min ?? '-'}–${max ?? '-'} $unit';
    }

    return '';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Detalle de la orden de laboratorio'),
      content: SizedBox(
        width: 620,
        child: FutureBuilder<Map<String, dynamic>>(
          future: _detailFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              return const Text(
                'No fue posible cargar el detalle de la orden.',
              );
            }

            final data = snapshot.data ?? {};
            final order = data['order'] is Map
                ? Map<String, dynamic>.from(data['order'] as Map)
                : <String, dynamic>{};
            final panels = (data['panels'] as List? ?? [])
                .whereType<Map>()
                .map((p) => Map<String, dynamic>.from(p))
                .toList();

            final status = order['status']?.toString() ?? 'ordenado';

            final allParameters = <Map<String, dynamic>>[];
            for (final panel in panels) {
              final params = (panel['parameters'] as List? ?? [])
                  .whereType<Map>()
                  .map((p) => Map<String, dynamic>.from(p));
              allParameters.addAll(params);
            }

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Estado: ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      _LabStatusBadge(status: status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (status == 'ordenado')
                    OutlinedButton.icon(
                      onPressed: _isMarkingSample ? null : _markSampleTaken,
                      icon: _isMarkingSample
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.science_outlined, size: 18),
                      label: const Text('Marcar toma de muestra'),
                    ),
                  if (status != 'ordenado') ...[
                    const Text(
                      'Resultados',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 10),
                    ...panels.map((panel) {
                      final panelName = panel['name']?.toString() ?? '';
                      final parameters = (panel['parameters'] as List? ?? [])
                          .whereType<Map>()
                          .map((p) => Map<String, dynamic>.from(p))
                          .toList();

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              panelName,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 6),
                            ...parameters.map((parameter) {
                              final parameterId =
                                  parameter['id']?.toString() ?? '';
                              final result = parameter['result'] is Map
                                  ? Map<String, dynamic>.from(
                                      parameter['result'] as Map,
                                    )
                                  : null;
                              final initialValue = result == null
                                  ? null
                                  : (result['valueNumeric']?.toString() ??
                                      result['valueText']?.toString());
                              final isOutOfRange =
                                  result?['isOutOfRange'] == true;
                              final controller = _controllerFor(
                                parameterId,
                                initialValue,
                              );
                              final unit = parameter['unit']?.toString() ?? '';

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 2,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            parameter['name']?.toString() ??
                                                '',
                                          ),
                                          Text(
                                            _referenceRangeText(parameter),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: NexaColors.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 140,
                                      child: TextField(
                                        controller: controller,
                                        enabled: status != 'validado',
                                        decoration: InputDecoration(
                                          isDense: true,
                                          suffixText: unit,
                                          border: const OutlineInputBorder(),
                                          filled: isOutOfRange,
                                          fillColor: isOutOfRange
                                              ? const Color(0xFFFEE2E2)
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                    if (status != 'validado')
                      OutlinedButton.icon(
                        onPressed: _isSavingResults
                            ? null
                            : () => _saveResults(allParameters),
                        icon: _isSavingResults
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Guardar resultados'),
                      ),
                    if (status == 'completado' &&
                        (ApiService.role == 'administrador' ||
                            ApiService.role == 'medico')) ...[
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _isValidating ? null : _validate,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF15803D),
                        ),
                        icon: _isValidating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('Validar orden'),
                      ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFB91C1C)),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _LabStatusBadge extends StatelessWidget {
  const _LabStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    String label;

    switch (status) {
      case 'muestra_tomada':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        label = 'Muestra tomada';
        break;
      case 'en_proceso':
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        label = 'En proceso';
        break;
      case 'completado':
        backgroundColor = const Color(0xFFF0FDFA);
        textColor = const Color(0xFF0F766E);
        label = 'Completado';
        break;
      case 'validado':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        label = 'Validado';
        break;
      default:
        backgroundColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF475569);
        label = 'Ordenado';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}