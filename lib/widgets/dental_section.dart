import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import 'correction_widgets.dart';

class DentalOrdersSection extends StatefulWidget {
  const DentalOrdersSection({
    super.key,
    required this.patientId,
    this.initialOrderId,
  });

  final int? patientId;

  /// Si viene, al cargar las órdenes la sección se desplaza a la vista y
  /// abre el detalle de esa orden (lo usa "Revisar" en la pantalla Por
  /// validar).
  final String? initialOrderId;

  @override
  State<DentalOrdersSection> createState() => _DentalOrdersSectionState();
}

class _DentalOrdersSectionState extends State<DentalOrdersSection> {
  late Future<List<Map<String, dynamic>>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _load();
    if (widget.initialOrderId != null) {
      _ordersFuture.then<void>(
        (_) => _focusInitialOrder(),
        onError: (_) => _focusInitialOrder(),
      );
    }
  }

  void _focusInitialOrder() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 300),
        alignment: 0.05,
      );
      if (mounted) _openOrderDetail(widget.initialOrderId!);
    });
  }

  Future<List<Map<String, dynamic>>> _load() {
    final patientId = widget.patientId;
    if (patientId == null) return Future.value([]);
    return ApiService.getDentalOrders(patientId);
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
      builder: (_) => _CreateDentalOrderDialog(patientId: patientId),
    );

    if (created == true) _reload();
  }

  Future<void> _openOrderDetail(String orderId) async {
    final patientId = widget.patientId;
    if (patientId == null) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _DentalOrderDetailDialog(
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
            const Icon(Icons.medical_services_outlined, color: NexaColors.primary),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Dental',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Solicitar atención'),
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
                    : 'No fue posible cargar las órdenes dentales.',
                style: const TextStyle(color: Color(0xFFB91C1C)),
              );
            }

            final orders = snapshot.data ?? [];

            if (orders.isEmpty) {
              return const Text('No hay atenciones dentales solicitadas.');
            }

            return Column(
              children: orders.map((order) {
                final procedures = (order['procedures'] as List? ?? [])
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
                                procedures.isEmpty
                                    ? 'Atención dental'
                                    : procedures,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (hasPendingCorrection(order)) ...[
                              const ReturnedChip(),
                              const SizedBox(width: 6),
                            ],
                            _DentalStatusBadge(status: status),
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

class _CreateDentalOrderDialog extends StatefulWidget {
  const _CreateDentalOrderDialog({required this.patientId});

  final int patientId;

  @override
  State<_CreateDentalOrderDialog> createState() =>
      _CreateDentalOrderDialogState();
}

class _CreateDentalOrderDialogState extends State<_CreateDentalOrderDialog> {
  late Future<List<Map<String, dynamic>>> _proceduresFuture;
  final Set<String> _selectedProcedureIds = {};
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _proceduresFuture = ApiService.getDentalProcedures();
  }

  Future<void> _submit() async {
    if (_selectedProcedureIds.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.createDentalOrder(
        patientId: widget.patientId,
        procedureIds: _selectedProcedureIds.toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible crear la orden dental.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Solicitar atención dental'),
      content: SizedBox(
        width: 460,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _proceduresFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              return const Text(
                'No fue posible cargar el catálogo de prestaciones.',
              );
            }

            final procedures = snapshot.data ?? [];

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Selecciona una o más prestaciones:'),
                  const SizedBox(height: 8),
                  ...procedures.map((procedure) {
                    final id = procedure['id']?.toString() ?? '';
                    final name = procedure['name']?.toString() ?? '';
                    final code = procedure['fonasaCode']?.toString() ?? '';

                    return CheckboxListTile(
                      value: _selectedProcedureIds.contains(id),
                      onChanged: id.isEmpty
                          ? null
                          : (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedProcedureIds.add(id);
                                } else {
                                  _selectedProcedureIds.remove(id);
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
          onPressed: (_selectedProcedureIds.isEmpty || _isSubmitting)
              ? null
              : _submit,
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

class _DentalOrderDetailDialog extends StatefulWidget {
  const _DentalOrderDetailDialog({
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  @override
  State<_DentalOrderDetailDialog> createState() =>
      _DentalOrderDetailDialogState();
}

class _DentalOrderDetailDialogState extends State<_DentalOrderDetailDialog> {
  late Future<Map<String, dynamic>> _detailFuture;
  final Map<String, TextEditingController> _toothControllers = {};
  final Map<String, TextEditingController> _diagnosisControllers = {};
  final Map<String, TextEditingController> _professionalControllers = {};
  bool _isSavingResults = false;
  bool _isMarkingPerformed = false;
  bool _isValidating = false;
  bool _isRequestingCorrection = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detailFuture = _load();
  }

  Future<Map<String, dynamic>> _load() {
    return ApiService.getDentalOrderDetail(
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
    for (final controller in _toothControllers.values) {
      controller.dispose();
    }
    for (final controller in _diagnosisControllers.values) {
      controller.dispose();
    }
    for (final controller in _professionalControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(
    Map<String, TextEditingController> store,
    String procedureId,
    String? initialValue,
  ) {
    return store.putIfAbsent(
      procedureId,
      () => TextEditingController(text: initialValue ?? ''),
    );
  }

  Future<void> _markPerformed() async {
    if (_isMarkingPerformed) return;
    setState(() {
      _isMarkingPerformed = true;
      _error = null;
    });
    try {
      await ApiService.markDentalPerformed(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible marcar la atención como realizada.',
        );
      }
    } finally {
      if (mounted) setState(() => _isMarkingPerformed = false);
    }
  }

  Future<void> _saveResults(List<Map<String, dynamic>> procedures) async {
    if (_isSavingResults) return;

    final results = <Map<String, dynamic>>[];

    for (final procedure in procedures) {
      final procedureId = procedure['id']?.toString() ?? '';
      if (procedureId.isEmpty) continue;

      final tooth = _toothControllers[procedureId]?.text.trim() ?? '';
      final diagnosis =
          _diagnosisControllers[procedureId]?.text.trim() ?? '';
      final professional =
          _professionalControllers[procedureId]?.text.trim() ?? '';

      if (tooth.isEmpty && diagnosis.isEmpty && professional.isEmpty) {
        continue;
      }

      results.add({
        'procedureId': procedureId,
        'tooth': tooth,
        'diagnosis': diagnosis,
        'professional': professional,
      });
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
      await ApiService.saveDentalResults(
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

  Future<void> _requestCorrection() async {
    if (_isRequestingCorrection) return;
    final reason = await showCorrectionReasonDialog(context);
    if (reason == null || !mounted) return;
    setState(() {
      _isRequestingCorrection = true;
      _error = null;
    });
    try {
      await ApiService.requestDentalCorrection(
        patientId: widget.patientId,
        orderId: widget.orderId,
        reason: reason,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible pedir la corrección.');
      }
    } finally {
      if (mounted) setState(() => _isRequestingCorrection = false);
    }
  }

  Future<void> _validate() async {
    if (_isValidating) return;
    setState(() {
      _isValidating = true;
      _error = null;
    });
    try {
      await ApiService.validateDentalOrder(
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Detalle de la atención dental'),
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
            final procedures = (data['procedures'] as List? ?? [])
                .whereType<Map>()
                .map((p) => Map<String, dynamic>.from(p))
                .toList();

            final status = order['status']?.toString() ?? 'ordenado';

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CorrectionNotice(item: order),
                  Row(
                    children: [
                      const Text(
                        'Estado: ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      _DentalStatusBadge(status: status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (status == 'ordenado')
                    OutlinedButton.icon(
                      onPressed: _isMarkingPerformed ? null : _markPerformed,
                      icon: _isMarkingPerformed
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline, size: 18),
                      label: Text(
                        hasPendingCorrection(order)
                            ? 'Corrección lista: marcar realizado'
                            : 'Marcar realizado',
                      ),
                    ),
                  // Con una corrección pendiente la orden vuelve a 'ordenado' y
                  // el resultado se puede editar antes de marcarla realizada.
                  if (status != 'ordenado' || hasPendingCorrection(order)) ...[
                    const Text(
                      'Resultados',
                      style:
                          TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    const SizedBox(height: 10),
                    ...procedures.map((procedure) {
                      final procedureId = procedure['id']?.toString() ?? '';
                      final result = procedure['result'] is Map
                          ? Map<String, dynamic>.from(
                              procedure['result'] as Map,
                            )
                          : null;

                      final toothController = _controllerFor(
                        _toothControllers,
                        procedureId,
                        result?['tooth']?.toString(),
                      );
                      final diagnosisController = _controllerFor(
                        _diagnosisControllers,
                        procedureId,
                        result?['diagnosis']?.toString(),
                      );
                      final professionalController = _controllerFor(
                        _professionalControllers,
                        procedureId,
                        result?['professional']?.toString(),
                      );

                      final enabled = status != 'validado';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              procedure['name']?.toString() ?? '',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: toothController,
                                    enabled: enabled,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      labelText: 'Pieza dentaria',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: diagnosisController,
                                    enabled: enabled,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      labelText: 'Diagnóstico / observación',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: professionalController,
                              enabled: enabled,
                              decoration: const InputDecoration(
                                isDense: true,
                                labelText: 'Profesional',
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (status != 'validado')
                      OutlinedButton.icon(
                        onPressed: _isSavingResults
                            ? null
                            : () => _saveResults(procedures),
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
                    if (status == 'realizado' &&
                        (ApiService.role == 'administrador' ||
                            ApiService.role == 'medico')) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
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
                          OutlinedButton.icon(
                            onPressed: _isRequestingCorrection ? null : _requestCorrection,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFB91C1C),
                              side: const BorderSide(color: Color(0xFFB91C1C)),
                            ),
                            icon: _isRequestingCorrection
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.undo_rounded, size: 18),
                            label: const Text('Pedir corrección'),
                          ),
                        ],
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

class _DentalStatusBadge extends StatelessWidget {
  const _DentalStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    String label;

    switch (status) {
      case 'realizado':
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        label = 'Realizado';
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
