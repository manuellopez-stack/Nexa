import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

class ImagingOrdersSection extends StatefulWidget {
  const ImagingOrdersSection({super.key, required this.patientId});

  final int? patientId;

  @override
  State<ImagingOrdersSection> createState() => _ImagingOrdersSectionState();
}

class _ImagingOrdersSectionState extends State<ImagingOrdersSection> {
  late Future<List<Map<String, dynamic>>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    final patientId = widget.patientId;
    if (patientId == null) return Future.value([]);
    return ApiService.getImagingOrders(patientId);
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
      builder: (_) => _CreateImagingOrderDialog(patientId: patientId),
    );

    if (created == true) _reload();
  }

  Future<void> _openOrderDetail(String orderId) async {
    final patientId = widget.patientId;
    if (patientId == null) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _ImagingOrderDetailDialog(
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
            const Icon(Icons.image_outlined, color: NexaColors.primary),
            const SizedBox(width: 9),
            const Expanded(
              child: Text(
                'Imagenología',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _openCreateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Solicitar estudio'),
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
                    : 'No fue posible cargar las órdenes de imagenología.',
                style: const TextStyle(color: Color(0xFFB91C1C)),
              );
            }

            final orders = snapshot.data ?? [];

            if (orders.isEmpty) {
              return const Text(
                'No hay estudios de imagenología solicitados.',
              );
            }

            return Column(
              children: orders.map((order) {
                final types = (order['types'] as List? ?? [])
                    .whereType<Map>()
                    .map((t) => t['name']?.toString() ?? '')
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
                                types.isEmpty
                                    ? 'Estudio de imagenología'
                                    : types,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            _ImagingStatusBadge(status: status),
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

class _CreateImagingOrderDialog extends StatefulWidget {
  const _CreateImagingOrderDialog({required this.patientId});

  final int patientId;

  @override
  State<_CreateImagingOrderDialog> createState() =>
      _CreateImagingOrderDialogState();
}

class _CreateImagingOrderDialogState extends State<_CreateImagingOrderDialog> {
  late Future<List<Map<String, dynamic>>> _typesFuture;
  final Set<String> _selectedTypeIds = {};
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _typesFuture = ApiService.getImagingTypes();
  }

  Future<void> _submit() async {
    if (_selectedTypeIds.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.createImagingOrder(
        patientId: widget.patientId,
        typeIds: _selectedTypeIds.toList(),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible crear la orden de imagenología.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Solicitar estudio de imagenología'),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _typesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              return const Text(
                'No fue posible cargar el catálogo de imagenología.',
              );
            }

            final types = snapshot.data ?? [];

            final Map<String, List<Map<String, dynamic>>> grouped = {};
            for (final type in types) {
              final category = type['category']?.toString() ?? 'Otros';
              grouped.putIfAbsent(category, () => []).add(type);
            }

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Selecciona uno o más estudios:'),
                  const SizedBox(height: 8),
                  ...grouped.entries.map((entry) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 2),
                          child: Text(
                            entry.key,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: NexaColors.primary,
                            ),
                          ),
                        ),
                        ...entry.value.map((type) {
                          final id = type['id']?.toString() ?? '';
                          final name = type['name']?.toString() ?? '';
                          final code = type['fonasaCode']?.toString() ?? '';

                          return CheckboxListTile(
                            value: _selectedTypeIds.contains(id),
                            onChanged: id.isEmpty
                                ? null
                                : (checked) {
                                    setState(() {
                                      if (checked == true) {
                                        _selectedTypeIds.add(id);
                                      } else {
                                        _selectedTypeIds.remove(id);
                                      }
                                    });
                                  },
                            title: Text(name),
                            subtitle: code.isEmpty
                                ? null
                                : Text('Código FONASA: $code'),
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                          );
                        }),
                      ],
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
              (_selectedTypeIds.isEmpty || _isSubmitting) ? null : _submit,
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

class _ImagingOrderDetailDialog extends StatefulWidget {
  const _ImagingOrderDetailDialog({
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  @override
  State<_ImagingOrderDetailDialog> createState() =>
      _ImagingOrderDetailDialogState();
}

class _ImagingOrderDetailDialogState extends State<_ImagingOrderDetailDialog> {
  late Future<Map<String, dynamic>> _detailFuture;
  late Future<List<Map<String, dynamic>>> _imagesFuture;
  bool _isMarkingPerformed = false;
  bool _isAnalyzing = false;
  bool _isIncorporating = false;
  bool _isUploadingImage = false;
  String? _error;
  String? _imageError;
  String? _analysis;
  Map<String, dynamic>? _documentData;
  String? _documentFilename;

  @override
  void initState() {
    super.initState();
    _detailFuture = _load();
    _imagesFuture = _loadImages();
  }

  Future<Map<String, dynamic>> _load() {
    return ApiService.getImagingOrderDetail(
      patientId: widget.patientId,
      orderId: widget.orderId,
    );
  }

  Future<List<Map<String, dynamic>>> _loadImages() {
    return ApiService.getImagingImages(
      patientId: widget.patientId,
      orderId: widget.orderId,
    );
  }

  void _reload() {
    setState(() {
      _detailFuture = _load();
      _imagesFuture = _loadImages();
      _analysis = null;
      _documentData = null;
      _documentFilename = null;
    });
  }

  Future<void> _markPerformed() async {
    if (_isMarkingPerformed) return;
    setState(() {
      _isMarkingPerformed = true;
      _error = null;
    });
    try {
      await ApiService.markImagingPerformed(
        patientId: widget.patientId,
        orderId: widget.orderId,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible marcar el estudio como realizado.',
        );
      }
    } finally {
      if (mounted) setState(() => _isMarkingPerformed = false);
    }
  }

  Future<void> _uploadImage() async {
    if (_isUploadingImage) return;

    final result = await FilePicker.pickFiles(withData: true);

    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;

    if (bytes == null) {
      setState(() {
        _imageError = 'No fue posible leer el archivo seleccionado.';
      });
      return;
    }

    if (bytes.length > 50 * 1024 * 1024) {
      setState(() {
        _imageError = 'El archivo supera el máximo permitido de 50 MB.';
      });
      return;
    }

    setState(() {
      _isUploadingImage = true;
      _imageError = null;
    });

    try {
      final uploadResult = await ApiService.uploadImagingImage(
        patientId: widget.patientId,
        orderId: widget.orderId,
        filename: file.name,
        base64Data: base64Encode(bytes),
      );

      final conversionError = uploadResult['conversionError']?.toString();

      setState(() {
        _imagesFuture = _loadImages();
        _imageError = (conversionError != null && conversionError.isNotEmpty)
            ? 'Se guardó el archivo, pero no fue posible generar una vista previa: $conversionError'
            : null;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _imageError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _imageError = 'No fue posible subir la imagen.');
      }
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  void _openFullImage(String pngUrl) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            SizedBox(
              width: double.infinity,
              height: 600,
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: Image.network(pngUrl, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.4),
                ),
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _analyzeReport() async {
    if (_isAnalyzing) return;

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;

    if (bytes == null) {
      setState(() => _error = 'No fue posible leer el archivo seleccionado.');
      return;
    }

    if (bytes.length > 10 * 1024 * 1024) {
      setState(() => _error = 'El PDF supera el máximo permitido de 10 MB.');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _error = null;
      _analysis = null;
      _documentData = null;
      _documentFilename = null;
    });

    try {
      final result = await ApiService.analyzePatientPdf(
        patientId: widget.patientId,
        filename: file.name,
        base64Data: base64Encode(bytes),
      );

      if (!mounted) return;

      setState(() {
        _analysis = result['analysis']?.toString();
        final data = result['documentData'];
        _documentData = data is Map<String, dynamic> ? data : null;
        _documentFilename = file.name;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Ocurrió un error al analizar el PDF.');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _incorporateReport() async {
    if (_isIncorporating || _documentData == null || _documentFilename == null) {
      return;
    }

    setState(() {
      _isIncorporating = true;
      _error = null;
    });

    try {
      await ApiService.incorporateDocumentData(
        patientId: widget.patientId,
        documentData: _documentData!,
        filename: _documentFilename!,
        imagingOrderId: widget.orderId,
      );
      _reload();
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No fue posible incorporar el informe a la orden.',
        );
      }
    } finally {
      if (mounted) setState(() => _isIncorporating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Detalle de la orden de imagenología'),
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
            final types = (data['types'] as List? ?? [])
                .whereType<Map>()
                .map((t) => Map<String, dynamic>.from(t))
                .toList();
            final documents = (data['documents'] as List? ?? [])
                .whereType<Map>()
                .map((d) => Map<String, dynamic>.from(d))
                .toList();

            final status = order['status']?.toString() ?? 'ordenado';

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
                      _ImagingStatusBadge(status: status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Estudios solicitados',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: types.map((type) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: NexaColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: NexaColors.border),
                        ),
                        child: Text(type['name']?.toString() ?? ''),
                      );
                    }).toList(),
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Imagen del estudio',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isUploadingImage ? null : _uploadImage,
                        icon: _isUploadingImage
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.image_outlined, size: 18),
                        label: Text(
                          _isUploadingImage
                              ? 'Subiendo...'
                              : 'Subir imagen DICOM',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _imagesFuture,
                    builder: (context, imagesSnapshot) {
                      if (imagesSnapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }

                      if (imagesSnapshot.hasError) {
                        return const Text(
                          'No fue posible cargar las imágenes de esta orden.',
                        );
                      }

                      final images = imagesSnapshot.data ?? [];

                      if (images.isEmpty) {
                        return const Text(
                          'No hay imágenes subidas para este estudio.',
                        );
                      }

                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: images.map((imageFile) {
                          final pngUrl = imageFile['pngUrl']?.toString();

                          if (pngUrl == null || pngUrl.isEmpty) {
                            return Container(
                              width: 140,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                'Sin vista previa disponible',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFB91C1C),
                                ),
                              ),
                            );
                          }

                          return GestureDetector(
                            onTap: () => _openFullImage(pngUrl),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(
                                pngUrl,
                                width: 140,
                                height: 140,
                                fit: BoxFit.cover,
                                loadingBuilder: (context, child, progress) {
                                  if (progress == null) return child;
                                  return const SizedBox(
                                    width: 140,
                                    height: 140,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                },
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                  width: 140,
                                  height: 140,
                                  color: NexaColors.background,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                  if (_imageError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _imageError!,
                      style: const TextStyle(color: Color(0xFFB91C1C)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (status == 'ordenado')
                    OutlinedButton.icon(
                      onPressed: _isMarkingPerformed ? null : _markPerformed,
                      icon: _isMarkingPerformed
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.event_available_outlined, size: 18),
                      label: const Text('Marcar estudio realizado'),
                    ),
                  if (status == 'realizado' ||
                      status == 'informado' ||
                      status == 'validado') ...[
                    const Divider(height: 28),
                    const Text(
                      'Informe',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    if (documents.isEmpty)
                      const Text(
                        'Todavía no se ha subido un informe para esta orden.',
                      )
                    else
                      ...documents.map(
                        (doc) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: NexaColors.background,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: NexaColors.border),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.picture_as_pdf_outlined,
                                size: 18,
                                color: NexaColors.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(doc['filename']?.toString() ?? ''),
                              ),
                              Text(
                                doc['validationStatus']?.toString() ??
                                    'pendiente',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: NexaColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    if (status != 'validado')
                      OutlinedButton.icon(
                        onPressed: _isAnalyzing ? null : _analyzeReport,
                        icon: _isAnalyzing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.upload_file_outlined, size: 18),
                        label: Text(
                          _isAnalyzing
                              ? 'Analizando PDF...'
                              : 'Subir y analizar informe PDF',
                        ),
                      ),
                    if (_analysis != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FDFA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF99F6E4)),
                        ),
                        child: Text(
                          _analysis!,
                          style: const TextStyle(height: 1.45),
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _isIncorporating ? null : _incorporateReport,
                        icon: _isIncorporating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.download_done_outlined, size: 18),
                        label: Text(
                          _isIncorporating
                              ? 'Incorporando...'
                              : 'Incorporar informe a la orden',
                        ),
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

class _ImagingStatusBadge extends StatelessWidget {
  const _ImagingStatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    String label;

    switch (status) {
      case 'realizado':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        label = 'Realizado';
        break;
      case 'informado':
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        label = 'Informado';
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
