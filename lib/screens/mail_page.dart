import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/email_html_renderer.dart';

/// Extensiones que Gmail suele bloquear como adjunto (mismo criterio que
/// aplica el propio Gmail al enviar). Evita un rechazo silencioso del envío.
const Set<String> _extensionesBloqueadas = {
  'exe', 'bat', 'cmd', 'com', 'cpl', 'msi', 'msp', 'scr', 'js', 'jar', 'vbs',
};

const Map<String, String> _mimePorExtension = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'zip': 'application/zip',
};

String _mimeTypeDesdeNombre(String nombre) {
  final ext = nombre.contains('.') ? nombre.split('.').last.toLowerCase() : '';
  return _mimePorExtension[ext] ?? 'application/octet-stream';
}

String _formatTamano(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Sección "Correo" del menú principal: lista de correos de la bandeja,
/// panel de lectura y compositor de respuesta con adjuntos. A diferencia de
/// la campanita de notificaciones (solo administrador, solo no leídos),
/// aquí administrador y recepcion pueden navegar toda la bandeja y responder.
class MailPage extends StatefulWidget {
  const MailPage({super.key});

  @override
  State<MailPage> createState() => _MailPageState();
}

class _MailPageState extends State<MailPage> {
  final TextEditingController _searchController =
      TextEditingController(text: 'in:inbox');
  String _query = 'in:inbox';

  List<Map<String, dynamic>> _correos = [];
  String? _siguientePagina;
  bool _isLoadingList = false;
  bool _isLoadingMore = false;
  String? _listError;

  String? _selectedId;
  Map<String, dynamic>? _detalle;
  bool _isLoadingDetail = false;
  String? _detailError;

  final TextEditingController _replyController = TextEditingController();
  final List<PlatformFile> _adjuntos = [];
  bool _isSending = false;
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _loadList() async {
    setState(() {
      _isLoadingList = true;
      _listError = null;
    });

    try {
      final data = await ApiService.getMailMessages(q: _query);
      final correos = data['correos'];
      if (!mounted) return;
      setState(() {
        _correos = correos is List
            ? correos
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
            : [];
        _siguientePagina = data['siguientePagina'] as String?;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _listError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _listError = 'No fue posible cargar los correos.');
      }
    } finally {
      if (mounted) setState(() => _isLoadingList = false);
    }
  }

  Future<void> _loadMore() async {
    if (_siguientePagina == null || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final data =
          await ApiService.getMailMessages(q: _query, pageToken: _siguientePagina);
      final correos = data['correos'];
      if (!mounted) return;
      setState(() {
        if (correos is List) {
          _correos.addAll(
            correos.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
          );
        }
        _siguientePagina = data['siguientePagina'] as String?;
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _listError = error.message);
    } catch (_) {
      // Silencioso: la lista ya cargada sigue siendo válida.
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _selectMessage(String id) async {
    setState(() {
      _selectedId = id;
      _detalle = null;
      _detailError = null;
      _isLoadingDetail = true;
      _replyController.clear();
      _adjuntos.clear();
      _sendError = null;
    });

    try {
      final correo = await ApiService.getMailMessage(id);
      if (!mounted) return;
      setState(() => _detalle = correo);
    } on ApiException catch (error) {
      if (mounted) setState(() => _detailError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _detailError = 'No fue posible cargar el correo.');
      }
    } finally {
      if (mounted) setState(() => _isLoadingDetail = false);
    }
  }

  Future<void> _pickAttachments() async {
    final result = await FilePicker.pickFiles(withData: true, allowMultiple: true);
    if (result == null) return;

    final rechazados = <String>[];
    final aceptados = <PlatformFile>[];
    var tamanoAcumulado =
        _adjuntos.fold<int>(0, (total, file) => total + (file.bytes?.length ?? 0));

    for (final file in result.files) {
      final ext = file.extension?.toLowerCase() ?? '';
      if (_extensionesBloqueadas.contains(ext)) {
        rechazados.add('${file.name} (tipo no permitido)');
        continue;
      }
      final bytes = file.bytes;
      if (bytes == null) {
        rechazados.add('${file.name} (no se pudo leer)');
        continue;
      }
      tamanoAcumulado += bytes.length;
      if (tamanoAcumulado > 20 * 1024 * 1024) {
        rechazados.add('${file.name} (supera el máximo de 20 MB en total)');
        continue;
      }
      aceptados.add(file);
    }

    if (!mounted) return;
    setState(() => _adjuntos.addAll(aceptados));

    if (rechazados.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se agregaron: ${rechazados.join(', ')}')),
      );
    }
  }

  void _removeAttachment(int index) {
    setState(() => _adjuntos.removeAt(index));
  }

  Future<void> _sendReply() async {
    final id = _selectedId;
    final cuerpo = _replyController.text.trim();
    if (id == null || cuerpo.isEmpty || _isSending) return;

    setState(() {
      _isSending = true;
      _sendError = null;
    });

    try {
      final adjuntosPayload = _adjuntos
          .map((file) => {
                'nombre': file.name,
                'mimeType': _mimeTypeDesdeNombre(file.name),
                'base64Data': base64Encode(file.bytes!),
              })
          .toList();

      await ApiService.sendMailReply(
        messageId: id,
        cuerpoTexto: cuerpo,
        adjuntos: adjuntosPayload,
      );

      if (!mounted) return;
      setState(() {
        _replyController.clear();
        _adjuntos.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Respuesta enviada.')),
      );
    } on ApiException catch (error) {
      if (mounted) setState(() => _sendError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _sendError = 'No fue posible enviar la respuesta.');
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: AppBar(
        title: const Text(
          'Correo',
          style: TextStyle(fontWeight: FontWeight.w700, color: NexaColors.textPrimary),
        ),
        backgroundColor: NexaColors.surface,
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 380, child: _buildListPane()),
          const VerticalDivider(width: 1, color: NexaColors.border),
          Expanded(child: _buildDetailPane()),
        ],
      ),
    );
  }

  Widget _buildListPane() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Buscar (ej: in:inbox, from:...)',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: IconButton(
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _isLoadingList
                    ? null
                    : () {
                        _query = _searchController.text.trim().isEmpty
                            ? 'in:inbox'
                            : _searchController.text.trim();
                        _loadList();
                      },
              ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onSubmitted: (value) {
              _query = value.trim().isEmpty ? 'in:inbox' : value.trim();
              _loadList();
            },
          ),
        ),
        Expanded(child: _buildListBody()),
      ],
    );
  }

  Widget _buildListBody() {
    if (_isLoadingList && _correos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_listError != null && _correos.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(_listError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loadList,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_correos.isEmpty) {
      return const Center(
        child: Text('No hay correos.', style: TextStyle(color: NexaColors.textSecondary)),
      );
    }

    return ListView.builder(
      itemCount: _correos.length + (_siguientePagina != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _correos.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: _isLoadingMore
                  ? const CircularProgressIndicator()
                  : OutlinedButton(
                      onPressed: _loadMore,
                      child: const Text('Cargar más'),
                    ),
            ),
          );
        }
        final correo = _correos[index];
        final id = correo['id']?.toString() ?? '';
        final seleccionado = id == _selectedId;
        final noLeido = correo['noLeido'] == true;

        return Material(
          color: seleccionado ? NexaColors.primary.withValues(alpha: 0.08) : Colors.transparent,
          child: InkWell(
            onTap: id.isEmpty ? null : () => _selectMessage(id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: NexaColors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          (correo['asunto']?.toString().trim().isNotEmpty ?? false)
                              ? correo['asunto'].toString().trim()
                              : '(sin asunto)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: noLeido ? FontWeight.w800 : FontWeight.w600,
                            color: NexaColors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        _formatFechaCorta(correo['fecha']),
                        style: const TextStyle(fontSize: 11, color: NexaColors.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    correo['remitente']?.toString().trim() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: NexaColors.textSecondary),
                  ),
                  if ((correo['extracto']?.toString().trim() ?? '').isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      correo['extracto'].toString().trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: NexaColors.textPrimary),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailPane() {
    if (_selectedId == null) {
      return const Center(
        child: Text(
          'Selecciona un correo para leerlo.',
          style: TextStyle(color: NexaColors.textSecondary),
        ),
      );
    }

    if (_isLoadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_detailError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(_detailError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _selectMessage(_selectedId!),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    final correo = _detalle;
    if (correo == null) return const SizedBox.shrink();

    final adjuntosOriginales = correo['adjuntos'];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (correo['asunto']?.toString().trim().isNotEmpty ?? false)
                ? correo['asunto'].toString().trim()
                : '(sin asunto)',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: NexaColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          if ((correo['remitente']?.toString().trim() ?? '').isNotEmpty)
            _DetalleFila(etiqueta: 'De', valor: correo['remitente'].toString().trim()),
          if ((correo['destinatarios']?.toString().trim() ?? '').isNotEmpty)
            _DetalleFila(etiqueta: 'Para', valor: correo['destinatarios'].toString().trim()),
          if (correo['fecha'] != null)
            _DetalleFila(etiqueta: 'Fecha', valor: _formatFechaLarga(correo['fecha'])),
          if (adjuntosOriginales is List && adjuntosOriginales.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: adjuntosOriginales.whereType<Map>().map((adjunto) {
                final nombre = adjunto['nombre']?.toString() ?? 'adjunto';
                final tamano = adjunto['tamano'];
                final etiqueta = tamano is int
                    ? '$nombre (${_formatTamano(tamano)})'
                    : nombre;
                return Chip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(color: NexaColors.border),
          const SizedBox(height: 16),
          EmailBodyView(
            cuerpoHtml: correo['cuerpoHtml']?.toString() ?? '',
            cuerpoTexto: correo['cuerpoTexto']?.toString() ?? '',
          ),
          const SizedBox(height: 28),
          const Divider(color: NexaColors.border),
          const SizedBox(height: 16),
          _buildComposer(correo),
        ],
      ),
    );
  }

  Widget _buildComposer(Map<String, dynamic> correo) {
    final destinatario = correo['remitente']?.toString().trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          destinatario.isEmpty ? 'Responder' : 'Responder a $destinatario',
          style: const TextStyle(fontWeight: FontWeight.w700, color: NexaColors.textPrimary),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _replyController,
          minLines: 5,
          maxLines: 12,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Escribe tu respuesta...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        const SizedBox(height: 10),
        if (_adjuntos.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: List.generate(_adjuntos.length, (index) {
              final file = _adjuntos[index];
              return InputChip(
                avatar: const Icon(Icons.attach_file, size: 16),
                label: Text(
                  '${file.name} (${_formatTamano(file.bytes?.length ?? 0)})',
                  style: const TextStyle(fontSize: 12),
                ),
                onDeleted: () => _removeAttachment(index),
              );
            }),
          ),
        const SizedBox(height: 10),
        if (_sendError != null) ...[
          Text(_sendError!, style: const TextStyle(color: Color(0xFF991B1B))),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _isSending ? null : _pickAttachments,
              icon: const Icon(Icons.attach_file),
              label: const Text('Adjuntar archivo'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _isSending || _replyController.text.trim().isEmpty
                  ? null
                  : _sendReply,
              icon: _isSending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send),
              label: const Text('Enviar respuesta'),
            ),
          ],
        ),
      ],
    );
  }

  String _formatFechaCorta(dynamic value) {
    if (value == null) return '';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final now = DateTime.now();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    final hora = '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return hora;
    }
    return '${twoDigits(local.day)}/${twoDigits(local.month)}';
  }

  String _formatFechaLarga(dynamic value) {
    if (value == null) return '';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    final local = parsed.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }
}

class _DetalleFila extends StatelessWidget {
  const _DetalleFila({required this.etiqueta, required this.valor});

  final String etiqueta;
  final String valor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              etiqueta,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: NexaColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: const TextStyle(fontSize: 12.5, color: NexaColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
