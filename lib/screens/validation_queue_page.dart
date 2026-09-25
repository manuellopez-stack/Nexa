import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/imagenda_shell.dart';
import '../widgets/today_patients_section.dart';

/// Pantalla "Por validar": todo lo que un profesional todavía tiene que
/// revisar (documentos leídos por IA, laboratorio con resultados,
/// imagenología informada y dental realizado), en una sola lista y lo más
/// antiguo primero. Ver GET /validation-queue en server.mjs.
///
/// "Revisar" abre la ficha del paciente en la sección correspondiente y el
/// mismo diálogo donde ya se valida ese ítem; al volver, la lista se recarga.
class ValidationQueuePage extends StatefulWidget {
  const ValidationQueuePage({super.key, @visibleForTesting this.loadQueue});

  /// Solo para tests: reemplaza a [ApiService.getValidationQueue].
  final Future<Map<String, dynamic>> Function()? loadQueue;

  @override
  State<ValidationQueuePage> createState() => _ValidationQueuePageState();
}

/// Filtros de la fila de chips, en orden. `null` = Todos.
const List<({String? tipo, String label})> _kFilters = [
  (tipo: null, label: 'Todos'),
  (tipo: 'documento', label: 'Documentos IA'),
  (tipo: 'imagenologia', label: 'Imagenología'),
  (tipo: 'laboratorio', label: 'Laboratorio'),
  (tipo: 'dental', label: 'Dental'),
];

class _ValidationQueuePageState extends State<ValidationQueuePage> {
  late Future<Map<String, dynamic>> _queueFuture;
  String? _filter; // null = Todos

  @override
  void initState() {
    super.initState();
    _queueFuture = _load();
  }

  Future<Map<String, dynamic>> _load() =>
      (widget.loadQueue ?? ApiService.getValidationQueue)();

  void _reload() {
    setState(() => _queueFuture = _load());
    ImagendaShell.refreshPendingValidationCount();
  }

  Future<void> _review(Map<String, dynamic> item) async {
    final patientId = item['patientId'];
    if (patientId is! int) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El informe no tiene un paciente válido.')),
      );
      return;
    }

    final tipo = item['tipo']?.toString();
    final focus = switch (tipo) {
      'documento' => PatientFileFocus.documents,
      'laboratorio' => PatientFileFocus.lab,
      'imagenologia' => PatientFileFocus.imaging,
      'dental' => PatientFileFocus.dental,
      _ => null,
    };

    await openPatientFile(
      context,
      patientId,
      focus: focus,
      documentFilename: tipo == 'documento' ? item['archivo']?.toString() : null,
      orderId: tipo == 'documento' ? null : item['id']?.toString(),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final padding = width < 600 ? 16.0 : 28.0;

    return ImagendaShell(
      selected: ShellSection.validation,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(padding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1250),
            child: !ApiService.canValidate
                ? const _Message(
                    icon: Icons.lock_outline,
                    text: 'Solo un médico o un administrador puede validar informes.',
                  )
                : FutureBuilder<Map<String, dynamic>>(
                    future: _queueFuture,
                    builder: (context, snapshot) {
                      final data = snapshot.data;
                      final items = _itemsOf(data);
                      final counts = _countsOf(data);
                      final total = counts['total'];

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ImagendaPageHeader(
                            title: 'Por validar',
                            subtitle: total == null
                                ? 'Informes que esperan revisión de un profesional'
                                : total == 1
                                ? '1 informe espera revisión de un profesional · los más antiguos primero'
                                : '$total informes esperan revisión de un profesional · los más antiguos primero',
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final filter in _kFilters)
                                _FilterChip(
                                  label: filter.label,
                                  count: counts[filter.tipo ?? 'total'],
                                  selected: _filter == filter.tipo,
                                  onTap: () =>
                                      setState(() => _filter = filter.tipo),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildListCard(snapshot, items),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildListCard(
    AsyncSnapshot<Map<String, dynamic>> snapshot,
    List<Map<String, dynamic>> items,
  ) {
    Widget body;
    if (snapshot.connectionState == ConnectionState.waiting) {
      body = const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (snapshot.hasError) {
      final error = snapshot.error;
      body = _Message(
        icon: Icons.error_outline,
        color: NexaColors.error,
        text: error is ApiException
            ? error.message
            : 'No fue posible cargar los informes por validar.',
        action: TextButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Reintentar'),
        ),
      );
    } else {
      final visible = _filter == null
          ? items
          : items.where((item) => item['tipo'] == _filter).toList();
      if (items.isEmpty) {
        body = const _Message(
          icon: Icons.check_circle_outline,
          color: Color(0xFF15803D),
          text: 'Todo al día: no hay informes por validar.',
        );
      } else if (visible.isEmpty) {
        body = const _Message(
          icon: Icons.check_circle_outline,
          color: Color(0xFF15803D),
          text: 'No hay informes de este tipo por validar.',
        );
      } else {
        body = LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) const _TableHeader(),
                for (var i = 0; i < visible.length; i++) ...[
                  if (i > 0 || wide)
                    const Divider(height: 1, color: NexaColors.border),
                  _QueueRow(
                    item: visible[i],
                    wide: wide,
                    onReview: () => _review(visible[i]),
                  ),
                ],
              ],
            );
          },
        );
      }
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexaColors.border),
      ),
      child: body,
    );
  }
}

List<Map<String, dynamic>> _itemsOf(Map<String, dynamic>? data) {
  final raw = data?['items'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

/// Conteos por tipo ('total', 'documento', ...). Vacío mientras carga.
Map<String, int> _countsOf(Map<String, dynamic>? data) {
  final raw = data?['conteos'];
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (entry.value is num) entry.key.toString(): (entry.value as num).toInt(),
  };
}

// ======================================================================
// Filtros
// ======================================================================

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : NexaColors.textPrimary;

    return Material(
      color: selected ? NexaColors.primary : NexaColors.surface,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? NexaColors.primary : NexaColors.border,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 22),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.22)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count?.toString() ?? '—',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : NexaColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Lista
// ======================================================================

const double _kIconColumn = 52;
const double _kButtonColumn = 112;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  static const _style = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: NexaColors.textSecondary,
  );

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          SizedBox(width: _kIconColumn),
          Expanded(flex: 3, child: Text('PACIENTE', style: _style)),
          SizedBox(width: 16),
          Expanded(flex: 4, child: Text('INFORME', style: _style)),
          SizedBox(width: 16),
          Expanded(flex: 3, child: Text('ESPERANDO DESDE', style: _style)),
          SizedBox(width: _kButtonColumn),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.item,
    required this.wide,
    required this.onReview,
  });

  final Map<String, dynamic> item;
  final bool wide;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final tipo = item['tipo']?.toString() ?? '';
    final patient = _TwoLines(
      title: _text(item['patientName'], 'Paciente sin nombre'),
      subtitle: item['patientRut'] == null
          ? 'Sin RUT'
          : 'RUT ${item['patientRut']}',
    );
    final report = _TwoLines(
      title: _text(item['titulo'], 'Informe'),
      subtitle: _text(item['detalle'], ''),
      showAiTag: item['esIA'] == true,
    );
    final since = _WaitingSince(value: item['desde']?.toString());
    final button = FilledButton(
      onPressed: onReview,
      style: FilledButton.styleFrom(
        backgroundColor: NexaColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
      child: const Text('Revisar'),
    );

    if (wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: _kIconColumn,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _TypeIcon(tipo: tipo),
              ),
            ),
            Expanded(flex: 3, child: patient),
            const SizedBox(width: 16),
            Expanded(flex: 4, child: report),
            const SizedBox(width: 16),
            Expanded(flex: 3, child: since),
            SizedBox(
              width: _kButtonColumn,
              child: Align(alignment: Alignment.centerRight, child: button),
            ),
          ],
        ),
      );
    }

    // Angosto: todo apilado, con el botón abajo a la derecha.
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TypeIcon(tipo: tipo),
              const SizedBox(width: 12),
              Expanded(child: patient),
            ],
          ),
          const SizedBox(height: 10),
          report,
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [since, button],
          ),
        ],
      ),
    );
  }
}

String _text(dynamic value, String fallback) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

class _TypeIcon extends StatelessWidget {
  const _TypeIcon({required this.tipo});

  final String tipo;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (tipo) {
      'documento' => (Icons.description_outlined, const Color(0xFF6366F1)),
      'imagenologia' => (Icons.image_search_outlined, const Color(0xFF0284C7)),
      'laboratorio' => (Icons.biotech_outlined, NexaColors.primary),
      'dental' => (Icons.medical_services_outlined, const Color(0xFFDB2777)),
      _ => (Icons.fact_check_outlined, NexaColors.textSecondary),
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

class _TwoLines extends StatelessWidget {
  const _TwoLines({
    required this.title,
    required this.subtitle,
    this.showAiTag = false,
  });

  final String title;
  final String subtitle;
  final bool showAiTag;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: NexaColors.textPrimary,
          ),
        ),
        if (subtitle.isNotEmpty || showAiTag) ...[
          const SizedBox(height: 3),
          Row(
            children: [
              if (showAiTag) ...[
                const _AiTag(),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AiTag extends StatelessWidget {
  const _AiTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'IA',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF4F46E5),
        ),
      ),
    );
  }
}

/// "hoy HH:MM", "ayer HH:MM" o la fecha; en ámbar y con " · hace más de 2 h"
/// si lleva más de 2 horas esperando.
class _WaitingSince extends StatelessWidget {
  const _WaitingSince({required this.value});

  final String? value;

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final since = value == null ? null : DateTime.tryParse(value!)?.toLocal();
    if (since == null) {
      return const Text(
        'Sin fecha',
        style: TextStyle(fontSize: 13.5, color: NexaColors.textSecondary),
      );
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(since.year, since.month, since.day);
    final clock = '${_two(since.hour)}:${_two(since.minute)}';
    final daysAgo = today.difference(day).inDays;
    var label = daysAgo == 0
        ? 'hoy $clock'
        : daysAgo == 1
        ? 'ayer $clock'
        : '${_two(since.day)}/${_two(since.month)}/${since.year}';

    final overdue = now.difference(since) > const Duration(hours: 2);
    if (overdue) label += ' · hace más de 2 h';

    return Text(
      label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: overdue ? FontWeight.w600 : FontWeight.w500,
        color: overdue ? const Color(0xFFB45309) : NexaColors.textPrimary,
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.color = NexaColors.textSecondary,
    this.action,
  });

  final IconData icon;
  final String text;
  final Color color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w600, color: color),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
