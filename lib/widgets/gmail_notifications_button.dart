import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// Campanita de notificaciones para el AppBar del dashboard.
///
/// Solo se muestra al rol administrador (el control real está en el backend).
/// Consulta los correos no leídos de Gmail y, al tocarla, abre un diálogo con
/// la lista (asunto, remitente y fecha). Muestra un contador si hay no leídos.
class GmailNotificationsButton extends StatefulWidget {
  const GmailNotificationsButton({super.key});

  @override
  State<GmailNotificationsButton> createState() =>
      _GmailNotificationsButtonState();
}

class _GmailNotificationsButtonState extends State<GmailNotificationsButton> {
  List<Map<String, dynamic>>? _correos;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final correos = await ApiService.getGmailUnread();
      if (!mounted) return;
      setState(() => _correos = correos);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No fue posible cargar los correos.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _GmailNotificationsDialog(
        correos: _correos ?? const [],
        isLoading: _isLoading,
        error: _error,
        onRefresh: () async {
          await _load();
          return (
            correos: _correos ?? const <Map<String, dynamic>>[],
            error: _error,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _correos?.length ?? 0;

    return IconButton(
      tooltip: 'Correos no leídos',
      onPressed: _openDialog,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(
            Icons.notifications_outlined,
            color: NexaColors.textSecondary,
          ),
          if (count > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: NexaColors.error,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: NexaColors.surface, width: 1.5),
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GmailNotificationsDialog extends StatefulWidget {
  const _GmailNotificationsDialog({
    required this.correos,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
  });

  final List<Map<String, dynamic>> correos;
  final bool isLoading;
  final String? error;
  final Future<({List<Map<String, dynamic>> correos, String? error})> Function()
      onRefresh;

  @override
  State<_GmailNotificationsDialog> createState() =>
      _GmailNotificationsDialogState();
}

class _GmailNotificationsDialogState extends State<_GmailNotificationsDialog> {
  late List<Map<String, dynamic>> _correos;
  late bool _isLoading;
  String? _error;

  @override
  void initState() {
    super.initState();
    _correos = widget.correos;
    _isLoading = widget.isLoading;
    _error = widget.error;
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await widget.onRefresh();
      if (mounted) {
        setState(() {
          _correos = result.correos;
          _error = result.error;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible cargar los correos.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NexaColors.surface,
      title: Row(
        children: [
          const Icon(Icons.mark_email_unread_outlined,
              color: NexaColors.primary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Correos no leídos',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: NexaColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _isLoading ? null : _refresh,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: _buildBody(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading && _correos.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _correos.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF991B1B),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_correos.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            'No tienes correos sin leer.',
            style: TextStyle(color: NexaColors.textSecondary),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _correos
              .map((correo) => _CorreoTile(
                    correo: correo,
                    onTap: () => _openDetail(correo),
                  ))
              .toList(),
        ),
      ),
    );
  }

  Future<void> _openDetail(Map<String, dynamic> correo) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _GmailMessageDetailDialog(correoResumen: correo),
    );
  }
}

class _CorreoTile extends StatelessWidget {
  const _CorreoTile({required this.correo, required this.onTap});

  final Map<String, dynamic> correo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final asunto = (correo['asunto']?.toString().trim().isNotEmpty ?? false)
        ? correo['asunto'].toString().trim()
        : '(sin asunto)';
    final remitente = correo['remitente']?.toString().trim() ?? '';
    final extracto = correo['extracto']?.toString().trim() ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NexaColors.background,
            border: Border.all(color: NexaColors.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      asunto,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: NexaColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatFecha(correo['fecha']),
                    style: const TextStyle(
                      fontSize: 11,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: NexaColors.textSecondary,
                  ),
                ],
              ),
              if (remitente.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  remitente,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ],
              if (extracto.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  extracto,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: NexaColors.textPrimary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatFecha(dynamic value) {
    if (value == null) return '';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    final local = parsed.toLocal();
    final now = DateTime.now();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    final hora = '${twoDigits(local.hour)}:${twoDigits(local.minute)}';

    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return hora;
    }
    return '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} $hora';
  }
}

/// Diálogo grande con el contenido completo de un correo (remitente, asunto,
/// fecha y cuerpo). Se abre al tocar un correo en la lista de no leídos.
class _GmailMessageDetailDialog extends StatefulWidget {
  const _GmailMessageDetailDialog({required this.correoResumen});

  /// Datos ya conocidos (id, asunto, remitente, fecha, extracto) para poder
  /// mostrar un encabezado inmediato mientras se carga el cuerpo completo.
  final Map<String, dynamic> correoResumen;

  @override
  State<_GmailMessageDetailDialog> createState() =>
      _GmailMessageDetailDialogState();
}

class _GmailMessageDetailDialogState extends State<_GmailMessageDetailDialog> {
  Map<String, dynamic>? _correo;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final id = widget.correoResumen['id']?.toString() ?? '';
    try {
      final correo = await ApiService.getGmailMessage(id);
      if (!mounted) return;
      setState(() => _correo = correo);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No fue posible cargar el correo.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatFecha(dynamic value) {
    if (value == null) return '';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    final local = parsed.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  /// Convierte el HTML del correo a texto plano legible cuando no hay una
  /// versión en texto disponible (la app no incluye un renderizador HTML).
  String _cuerpoLegible() {
    final cuerpoTexto = _correo?['cuerpoTexto']?.toString().trim() ?? '';
    if (cuerpoTexto.isNotEmpty) return cuerpoTexto;

    final cuerpoHtml = _correo?['cuerpoHtml']?.toString() ?? '';
    if (cuerpoHtml.isEmpty) {
      return widget.correoResumen['extracto']?.toString().trim() ?? '';
    }

    final sinEtiquetas = cuerpoHtml
        .replaceAll(RegExp(r'<(br|/p|/div)[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    return sinEtiquetas
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final asunto = (_correo?['asunto'] ?? widget.correoResumen['asunto'])
            ?.toString()
            .trim() ??
        '(sin asunto)';
    final remitente = (_correo?['remitente'] ?? widget.correoResumen['remitente'])
            ?.toString()
            .trim() ??
        '';
    final fecha = _correo?['fecha'] ?? widget.correoResumen['fecha'];

    return AlertDialog(
      backgroundColor: NexaColors.surface,
      title: Row(
        children: [
          IconButton(
            tooltip: 'Volver',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.mail_outline, color: NexaColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              asunto.isEmpty ? '(sin asunto)' : asunto,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: NexaColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (remitente.isNotEmpty)
                  _DetalleFila(etiqueta: 'De', valor: remitente),
                if (fecha != null)
                  _DetalleFila(etiqueta: 'Fecha', valor: _formatFecha(fecha)),
                const SizedBox(height: 12),
                const Divider(color: NexaColors.border),
                const SizedBox(height: 12),
                _buildCuerpo(),
              ],
            ),
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

  Widget _buildCuerpo() {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF991B1B),
              ),
            ),
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

    final cuerpo = _cuerpoLegible();
    if (cuerpo.isEmpty) {
      return const Text(
        'Este correo no tiene contenido para mostrar.',
        style: TextStyle(color: NexaColors.textSecondary),
      );
    }

    return SelectableText(
      cuerpo,
      style: const TextStyle(
        fontSize: 13.5,
        color: NexaColors.textPrimary,
        height: 1.5,
      ),
    );
  }
}

class _DetalleFila extends StatelessWidget {
  const _DetalleFila({required this.etiqueta, required this.valor});

  final String etiqueta;
  final String valor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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
              style: const TextStyle(
                fontSize: 12.5,
                color: NexaColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
