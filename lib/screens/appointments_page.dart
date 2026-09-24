import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/imagenda_app_bar.dart';
import '../widgets/patient_picker_dialog.dart';

// Códigos de estado de una cita (tabla appointments). Deben coincidir con
// APPOINTMENT_STATUSES en backend/server.mjs.
const List<String> _kStatusCodes = [
  'programada',
  'en_espera',
  'en_atencion',
  'atendida',
  'no_asistio',
  'cancelada',
];

const Map<String, String> _kStatusLabels = {
  'programada': 'Programado',
  'en_espera': 'Esperando',
  'en_atencion': 'En atención',
  'atendida': 'Atendido',
  'no_asistio': 'No asistió',
  'cancelada': 'Cancelada',
};

// Siguiente estado al "avanzar" una cita y la etiqueta de la acción.
const Map<String, String> _kAdvanceNext = {
  'programada': 'en_espera',
  'en_espera': 'en_atencion',
  'en_atencion': 'atendida',
};

const Map<String, String> _kAdvanceLabel = {
  'programada': 'Marcar en espera',
  'en_espera': 'Iniciar atención',
  'en_atencion': 'Finalizar atención',
};

const List<int> _kDurationOptions = [15, 30, 45, 60, 90, 120];

const List<String> _kWeekdays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const List<String> _kMonths = [
  'ene', 'feb', 'mar', 'abr', 'may', 'jun',
  'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
];

String _two(int n) => n.toString().padLeft(2, '0');

String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _friendlyDate(DateTime d) {
  final label =
      '${_kWeekdays[d.weekday - 1]} ${d.day} ${_kMonths[d.month - 1]} ${d.year}';
  if (_sameDay(d, DateTime.now())) return 'Hoy · $label';
  return label;
}

class AppointmentsPage extends StatefulWidget {
  const AppointmentsPage({super.key});

  @override
  State<AppointmentsPage> createState() => _AppointmentsPageState();
}

class _AppointmentsPageState extends State<AppointmentsPage> {
  DateTime _selectedDate = DateTime.now();
  final Set<String> _statusFilter = {};
  late Future<List<Map<String, dynamic>>> _future;

  // Se muestra un indicador en la cita mientras se le aplica un cambio.
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    return ApiService.getAppointments(
      date: _ymd(_selectedDate),
      statuses: _statusFilter.toList(),
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  void _goToDate(DateTime date) {
    setState(() {
      _selectedDate = DateTime(date.year, date.month, date.day);
      _future = _load();
    });
  }

  void _shiftDay(int days) =>
      _goToDate(_selectedDate.add(Duration(days: days)));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) _goToDate(picked);
  }

  void _toggleStatus(String code) {
    setState(() {
      if (_statusFilter.contains(code)) {
        _statusFilter.remove(code);
      } else {
        _statusFilter.add(code);
      }
      _future = _load();
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // ---- Acciones sobre una cita ------------------------------------------

  Future<void> _apply(
    Map<String, dynamic> appointment,
    Map<String, dynamic> changes,
    String okMessage,
  ) async {
    final id = appointment['id']?.toString();
    if (id == null || id.isEmpty) return;

    setState(() => _busyId = id);
    try {
      await ApiService.updateAppointment(id, changes);
      if (!mounted) return;
      _showSnack(okMessage);
      _reload();
    } on ApiException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack('No fue posible actualizar la cita.');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _advance(Map<String, dynamic> appointment) async {
    final code = appointment['status']?.toString() ?? '';
    final next = _kAdvanceNext[code];
    if (next == null) return;
    await _apply(appointment, {'status': next}, 'Estado actualizado.');
  }

  Future<void> _markNoShow(Map<String, dynamic> appointment) async {
    await _apply(
      appointment,
      {'status': 'no_asistio'},
      'Cita marcada como "No asistió".',
    );
  }

  Future<void> _reactivate(Map<String, dynamic> appointment) async {
    await _apply(appointment, {'status': 'programada'}, 'Cita reactivada.');
  }

  Future<void> _reschedule(Map<String, dynamic> appointment) async {
    final currentIso = appointment['scheduledAt']?.toString();
    final current = currentIso != null
        ? DateTime.tryParse(currentIso)?.toLocal() ?? DateTime.now()
        : DateTime.now();

    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;

    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _apply(
      appointment,
      {'scheduledAt': combined.toUtc().toIso8601String()},
      'Cita reprogramada.',
    );
  }

  Future<void> _changeRoom(Map<String, dynamic> appointment) async {
    final result = await showDialog<_RoomChoice>(
      context: context,
      builder: (_) => _ChangeRoomDialog(
        currentRoomId: appointment['roomId']?.toString(),
      ),
    );
    if (result == null) return;
    await _apply(
      appointment,
      {'roomId': result.roomId ?? ''},
      'Sala actualizada.',
    );
  }

  Future<void> _cancel(Map<String, dynamic> appointment) async {
    final name = appointment['patientName']?.toString() ?? 'la cita';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancelar cita'),
        content: Text(
          '¿Cancelar la cita de "$name"? Quedará registrada como cancelada.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Cancelar cita'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _apply(appointment, {'status': 'cancelada'}, 'Cita cancelada.');
  }

  Future<void> _openEditor({Map<String, dynamic>? appointment}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AppointmentEditorDialog(appointment: appointment),
    );
    if (saved == true) _reload();
  }

  // ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: ImagendaAppBar(
        title: 'Agendamiento',
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Nueva cita'),
              style: FilledButton.styleFrom(
                backgroundColor: NexaColors.primary,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Actualizar',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DateNavigator(
                  label: _friendlyDate(_selectedDate),
                  isToday: _sameDay(_selectedDate, DateTime.now()),
                  onPrev: () => _shiftDay(-1),
                  onNext: () => _shiftDay(1),
                  onPickDate: _pickDate,
                  onToday: () => _goToDate(DateTime.now()),
                ),
                const SizedBox(height: 14),
                _StatusFilterBar(
                  selected: _statusFilter,
                  onToggle: _toggleStatus,
                ),
                const SizedBox(height: 8),
                const Divider(height: 24),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: _future,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (snapshot.hasError) {
                        final error = snapshot.error;
                        return _ErrorMessage(
                          message: error is ApiException
                              ? error.message
                              : 'No fue posible cargar la agenda de citas.',
                          onRetry: _reload,
                        );
                      }

                      final appointments = snapshot.data ?? [];

                      if (appointments.isEmpty) {
                        return _EmptyState(
                          hasFilter: _statusFilter.isNotEmpty,
                          onNew: () => _openEditor(),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: appointments.length,
                        itemBuilder: (context, index) {
                          final appointment = appointments[index];
                          final id = appointment['id']?.toString();
                          return _AppointmentTile(
                            appointment: appointment,
                            isBusy: id != null && id == _busyId,
                            onAdvance: () => _advance(appointment),
                            onReschedule: () => _reschedule(appointment),
                            onChangeRoom: () => _changeRoom(appointment),
                            onCancel: () => _cancel(appointment),
                            onNoShow: () => _markNoShow(appointment),
                            onReactivate: () => _reactivate(appointment),
                            onEdit: () =>
                                _openEditor(appointment: appointment),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================
// Barra de navegación por fecha
// ======================================================================

class _DateNavigator extends StatelessWidget {
  const _DateNavigator({
    required this.label,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onPickDate,
    required this.onToday,
  });

  final String label;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPickDate;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: NexaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NexaColors.border),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Día anterior',
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: onPickDate,
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: NexaColors.textPrimary,
                ),
              ),
            ),
          ),
          if (!isToday)
            TextButton(
              onPressed: onToday,
              child: const Text('Hoy'),
            ),
          IconButton(
            tooltip: 'Día siguiente',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

// ======================================================================
// Filtro por estado
// ======================================================================

class _StatusFilterBar extends StatelessWidget {
  const _StatusFilterBar({required this.selected, required this.onToggle});

  final Set<String> selected;
  final void Function(String code) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _kStatusCodes.map((code) {
        final isSelected = selected.contains(code);
        return FilterChip(
          label: Text(_kStatusLabels[code] ?? code),
          selected: isSelected,
          onSelected: (_) => onToggle(code),
          showCheckmark: false,
          selectedColor: NexaColors.primary.withValues(alpha: 0.14),
          side: BorderSide(
            color: isSelected ? NexaColors.primary : NexaColors.border,
          ),
        );
      }).toList(),
    );
  }
}

// ======================================================================
// Fila de una cita
// ======================================================================

class _AppointmentTile extends StatelessWidget {
  const _AppointmentTile({
    required this.appointment,
    required this.isBusy,
    required this.onAdvance,
    required this.onReschedule,
    required this.onChangeRoom,
    required this.onCancel,
    required this.onNoShow,
    required this.onReactivate,
    required this.onEdit,
  });

  final Map<String, dynamic> appointment;
  final bool isBusy;
  final VoidCallback onAdvance;
  final VoidCallback onReschedule;
  final VoidCallback onChangeRoom;
  final VoidCallback onCancel;
  final VoidCallback onNoShow;
  final VoidCallback onReactivate;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final status = appointment['status']?.toString() ?? 'programada';
    final clock = appointment['clock']?.toString() ?? '';
    final durationMin = appointment['durationMin'];
    final patientName =
        appointment['patientName']?.toString().trim().isNotEmpty == true
            ? appointment['patientName'].toString()
            : 'Paciente sin nombre';

    final metaParts = <String>[
      if (appointment['reason']?.toString().trim().isNotEmpty == true)
        appointment['reason'].toString(),
      if (appointment['roomName']?.toString().trim().isNotEmpty == true)
        appointment['roomName'].toString(),
      if (appointment['professional']?.toString().trim().isNotEmpty == true)
        appointment['professional'].toString(),
    ];

    final canAdvance = _kAdvanceNext.containsKey(status);
    final isClosed = status == 'cancelada' || status == 'no_asistio';
    // Reservada por el paciente desde /reservar y todavía sin sala asignada
    // (ver sql/public_booking.sql): se destaca para que recepción la vea de
    // inmediato y le asigne sala antes del día de la atención.
    final isWebPending =
        appointment['origin'] == 'web' && appointment['roomId'] == null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isWebPending ? const Color(0xFFFFFBEB) : NexaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isWebPending ? NexaColors.warning : NexaColors.border,
          width: isWebPending ? 1.4 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clock,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: NexaColors.textPrimary,
                  ),
                ),
                if (durationMin != null)
                  Text(
                    '$durationMin min',
                    style: const TextStyle(
                      fontSize: 11,
                      color: NexaColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  patientName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: NexaColors.textPrimary,
                  ),
                ),
                if (isWebPending) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.public,
                              size: 13,
                              color: Color(0xFF92400E),
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Reservada por el paciente · falta asignar sala',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF92400E),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    metaParts.join('  ·  '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                ],
                if (appointment['notes']?.toString().trim().isNotEmpty ==
                    true) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.sticky_note_2_outlined,
                        size: 13,
                        color: NexaColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          appointment['notes'].toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: NexaColors.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _StatusBadge(status: status),
              const SizedBox(height: 4),
              if (isBusy)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: 'Acciones',
                  icon: const Icon(Icons.more_vert, size: 20),
                  onSelected: (value) {
                    switch (value) {
                      case 'advance':
                        onAdvance();
                      case 'reschedule':
                        onReschedule();
                      case 'room':
                        onChangeRoom();
                      case 'edit':
                        onEdit();
                      case 'noshow':
                        onNoShow();
                      case 'cancel':
                        onCancel();
                      case 'reactivate':
                        onReactivate();
                    }
                  },
                  itemBuilder: (context) => [
                    if (canAdvance)
                      PopupMenuItem(
                        value: 'advance',
                        child: _MenuRow(
                          icon: Icons.arrow_forward,
                          label: _kAdvanceLabel[status] ?? 'Avanzar',
                        ),
                      ),
                    if (!isClosed) ...[
                      const PopupMenuItem(
                        value: 'reschedule',
                        child: _MenuRow(
                          icon: Icons.event_repeat_outlined,
                          label: 'Reprogramar',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'room',
                        child: _MenuRow(
                          icon: Icons.meeting_room_outlined,
                          label: 'Cambiar sala',
                        ),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'edit',
                      child: _MenuRow(
                        icon: Icons.edit_outlined,
                        label: 'Editar cita',
                      ),
                    ),
                    if (status == 'programada' || status == 'en_espera')
                      const PopupMenuItem(
                        value: 'noshow',
                        child: _MenuRow(
                          icon: Icons.person_off_outlined,
                          label: 'Marcar "No asistió"',
                        ),
                      ),
                    if (isClosed)
                      const PopupMenuItem(
                        value: 'reactivate',
                        child: _MenuRow(
                          icon: Icons.restart_alt,
                          label: 'Reactivar cita',
                        ),
                      ),
                    if (status != 'cancelada')
                      const PopupMenuItem(
                        value: 'cancel',
                        child: _MenuRow(
                          icon: Icons.event_busy_outlined,
                          label: 'Cancelar cita',
                          danger: true,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFB91C1C) : NexaColors.textPrimary;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

// ======================================================================
// Badge de estado (mismos colores que "Pacientes del día")
// ======================================================================

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (status) {
      case 'en_atencion':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        icon = Icons.check_circle_outline;
      case 'en_espera':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        icon = Icons.schedule;
      case 'atendida':
        backgroundColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF475569);
        icon = Icons.task_alt;
      case 'no_asistio':
        backgroundColor = const Color(0xFFFEE2E2);
        textColor = const Color(0xFFB91C1C);
        icon = Icons.person_off_outlined;
      case 'cancelada':
        backgroundColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF64748B);
        icon = Icons.event_busy_outlined;
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
          Icon(icon, size: 15, color: textColor),
          const SizedBox(width: 6),
          Text(
            _kStatusLabels[status] ?? status,
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

// ======================================================================
// Estados vacío / error
// ======================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasFilter, required this.onNew});

  final bool hasFilter;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.event_available_outlined,
            size: 44,
            color: NexaColors.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            hasFilter
                ? 'No hay citas con esos estados para este día.'
                : 'No hay citas agendadas para este día.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: NexaColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Nueva cita'),
            style: FilledButton.styleFrom(backgroundColor: NexaColors.primary),
          ),
        ],
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.onRetry, required this.message});

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, color: Color(0xFFDC2626)),
            const SizedBox(height: 10),
            Text(
              message,
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
      ),
    );
  }
}

// ======================================================================
// Diálogo: cambiar sala (acción rápida)
// ======================================================================

class _RoomChoice {
  const _RoomChoice(this.roomId);
  final String? roomId; // null -> sin sala
}

class _ChangeRoomDialog extends StatefulWidget {
  const _ChangeRoomDialog({required this.currentRoomId});

  final String? currentRoomId;

  @override
  State<_ChangeRoomDialog> createState() => _ChangeRoomDialogState();
}

class _ChangeRoomDialogState extends State<_ChangeRoomDialog> {
  late Future<List<Map<String, dynamic>>> _roomsFuture;
  String? _roomId;

  @override
  void initState() {
    super.initState();
    _roomId = widget.currentRoomId;
    _roomsFuture = ApiService.getRooms();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar sala'),
      content: SizedBox(
        width: 360,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _roomsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return const Text('No fue posible cargar el catálogo de salas.');
            }

            final rooms = snapshot.data ?? [];
            final ids = rooms.map((r) => r['id']?.toString()).toList();
            final value = ids.contains(_roomId) ? _roomId : null;

            return DropdownButtonFormField<String?>(
              initialValue: value,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Sala',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Sin sala asignada'),
                ),
                ...rooms.map(
                  (room) => DropdownMenuItem<String?>(
                    value: room['id']?.toString(),
                    child: Text(room['name']?.toString() ?? 'Sala'),
                  ),
                ),
              ],
              onChanged: (v) => setState(() => _roomId = v),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _RoomChoice(_roomId)),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}

// ======================================================================
// Diálogo: crear / editar cita
// ======================================================================

class _AppointmentEditorDialog extends StatefulWidget {
  const _AppointmentEditorDialog({this.appointment});

  final Map<String, dynamic>? appointment;

  @override
  State<_AppointmentEditorDialog> createState() =>
      _AppointmentEditorDialogState();
}

class _AppointmentEditorDialogState extends State<_AppointmentEditorDialog> {
  final _professionalController = TextEditingController();
  final _reasonController = TextEditingController();
  final _notesController = TextEditingController();

  int? _patientId;
  String? _patientName;
  late DateTime _date;
  late TimeOfDay _time;
  int _durationMin = 30;
  String? _roomId;
  late String _status;

  late Future<List<Map<String, dynamic>>> _roomsFuture;

  bool _isSubmitting = false;
  String? _error;

  bool get _isEditing => widget.appointment != null;

  @override
  void initState() {
    super.initState();
    _roomsFuture = ApiService.getRooms();

    final appointment = widget.appointment;
    if (appointment != null) {
      _patientId = appointment['patientId'] is int
          ? appointment['patientId'] as int
          : int.tryParse(appointment['patientId']?.toString() ?? '');
      _patientName = appointment['patientName']?.toString();

      final iso = appointment['scheduledAt']?.toString();
      final parsed = iso != null ? DateTime.tryParse(iso)?.toLocal() : null;
      final base = parsed ?? DateTime.now();
      _date = DateTime(base.year, base.month, base.day);
      _time = TimeOfDay(hour: base.hour, minute: base.minute);

      final dur = appointment['durationMin'];
      _durationMin = dur is int ? dur : int.tryParse(dur?.toString() ?? '') ?? 30;
      _roomId = appointment['roomId']?.toString();
      _status = appointment['status']?.toString() ?? 'programada';

      _professionalController.text =
          appointment['professional']?.toString() ?? '';
      _reasonController.text = appointment['reason']?.toString() ?? '';
      _notesController.text = appointment['notes']?.toString() ?? '';
    } else {
      final now = DateTime.now();
      _date = DateTime(now.year, now.month, now.day);
      // Redondea al próximo cuarto de hora para una hora de partida razonable.
      final minutes = ((now.minute ~/ 15) + 1) * 15;
      _time = TimeOfDay(
        hour: (now.hour + minutes ~/ 60) % 24,
        minute: minutes % 60,
      );
      _status = 'programada';
    }
  }

  @override
  void dispose() {
    _professionalController.dispose();
    _reasonController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  DateTime get _scheduledLocal => DateTime(
        _date.year,
        _date.month,
        _date.day,
        _time.hour,
        _time.minute,
      );

  Future<void> _pickPatient() async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const PatientPickerDialog(),
    );
    if (selected != null) {
      setState(() {
        _patientId = selected['id'] is int
            ? selected['id'] as int
            : int.tryParse(selected['id']?.toString() ?? '');
        _patientName = selected['name']?.toString();
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (_patientId == null) {
      setState(() => _error = 'Debes elegir un paciente para la cita.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      if (_isEditing) {
        final changes = _buildChanges();
        if (changes.isEmpty) {
          if (mounted) Navigator.pop(context, false);
          return;
        }
        await ApiService.updateAppointment(
          widget.appointment!['id'].toString(),
          changes,
        );
      } else {
        await ApiService.createAppointment(
          patientId: _patientId!,
          scheduledAt: _scheduledLocal.toUtc().toIso8601String(),
          roomId: _roomId,
          durationMin: _durationMin,
          professional: _professionalController.text.trim(),
          reason: _reasonController.text.trim(),
          notes: _notesController.text.trim(),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible guardar la cita.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // Solo los campos que cambiaron respecto de la cita original.
  Map<String, dynamic> _buildChanges() {
    final original = widget.appointment!;
    final changes = <String, dynamic>{};

    final originalIso = original['scheduledAt']?.toString();
    final originalInstant =
        originalIso != null ? DateTime.tryParse(originalIso)?.toUtc() : null;
    final newInstant = _scheduledLocal.toUtc();
    if (originalInstant == null ||
        !originalInstant.isAtSameMomentAs(newInstant)) {
      changes['scheduledAt'] = newInstant.toIso8601String();
    }

    final originalDur = original['durationMin'];
    final originalDurInt =
        originalDur is int ? originalDur : int.tryParse(originalDur?.toString() ?? '');
    if (originalDurInt != _durationMin) changes['durationMin'] = _durationMin;

    final originalRoom = original['roomId']?.toString();
    if ((originalRoom ?? '') != (_roomId ?? '')) {
      changes['roomId'] = _roomId ?? '';
    }

    if ((original['status']?.toString() ?? 'programada') != _status) {
      changes['status'] = _status;
    }

    final prof = _professionalController.text.trim();
    if ((original['professional']?.toString() ?? '') != prof) {
      changes['professional'] = prof;
    }

    final reason = _reasonController.text.trim();
    if ((original['reason']?.toString() ?? '') != reason) {
      changes['reason'] = reason;
    }

    final notes = _notesController.text.trim();
    if ((original['notes']?.toString() ?? '') != notes) {
      changes['notes'] = notes;
    }

    return changes;
  }

  @override
  Widget build(BuildContext context) {
    final durationItems = {..._kDurationOptions, _durationMin}.toList()..sort();

    return AlertDialog(
      title: Text(_isEditing ? 'Editar cita' : 'Nueva cita'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Paciente
              InkWell(
                onTap: _isEditing ? null : _pickPatient,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Paciente',
                    border: const OutlineInputBorder(),
                    suffixIcon: _isEditing
                        ? null
                        : const Icon(Icons.search),
                  ),
                  child: Text(
                    _patientName ?? 'Elegir paciente…',
                    style: TextStyle(
                      color: _patientName == null
                          ? NexaColors.textSecondary
                          : NexaColors.textPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // Fecha y hora
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(
                        '${_date.day} ${_kMonths[_date.month - 1]} ${_date.year}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 16),
                      label: Text(
                        '${_two(_time.hour)}:${_two(_time.minute)}',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Duración
              DropdownButtonFormField<int>(
                initialValue: _durationMin,
                decoration: const InputDecoration(
                  labelText: 'Duración',
                  border: OutlineInputBorder(),
                ),
                items: durationItems
                    .map(
                      (min) => DropdownMenuItem(
                        value: min,
                        child: Text('$min minutos'),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _durationMin = v);
                },
              ),
              const SizedBox(height: 14),
              // Sala
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _roomsFuture,
                builder: (context, snapshot) {
                  final rooms = snapshot.data ?? [];
                  final ids = rooms.map((r) => r['id']?.toString()).toList();
                  final value = ids.contains(_roomId) ? _roomId : null;
                  return DropdownButtonFormField<String?>(
                    initialValue: value,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Sala',
                      border: const OutlineInputBorder(),
                      helperText: snapshot.connectionState ==
                              ConnectionState.waiting
                          ? 'Cargando salas…'
                          : null,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Sin sala asignada'),
                      ),
                      ...rooms.map(
                        (room) => DropdownMenuItem<String?>(
                          value: room['id']?.toString(),
                          child: Text(room['name']?.toString() ?? 'Sala'),
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => _roomId = v),
                  );
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _professionalController,
                decoration: const InputDecoration(
                  labelText: 'Profesional a cargo',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'Motivo / examen',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _notesController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_isEditing) ...[
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: const InputDecoration(
                    labelText: 'Estado',
                    border: OutlineInputBorder(),
                  ),
                  items: _kStatusCodes
                      .map(
                        (code) => DropdownMenuItem(
                          value: code,
                          child: Text(_kStatusLabels[code] ?? code),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _status = v);
                  },
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEditing ? 'Guardar cambios' : 'Crear cita'),
        ),
      ],
    );
  }
}

