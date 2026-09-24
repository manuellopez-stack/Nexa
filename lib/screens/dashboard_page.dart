import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/imagenda_shell.dart';
import '../widgets/nexa_ai_section.dart';
import '../widgets/operational_status_section.dart';
import '../widgets/patient_form.dart';
import '../widgets/today_patients_section.dart';

const List<String> _kWeekdays = [
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
];
const List<String> _kMonths = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

String _two(int n) => n.toString().padLeft(2, '0');

String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// 'Jueves 24 de septiembre'.
String _longDate(DateTime d) =>
    '${_kWeekdays[d.weekday - 1]} ${d.day} de ${_kMonths[d.month - 1]}';

String _greeting(DateTime now) {
  if (now.hour < 12) return 'Buenos días';
  if (now.hour < 20) return 'Buenas tardes';
  return 'Buenas noches';
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _isClosed(String status) =>
    status == 'cancelada' || status == 'no_asistio';

/// Centro de Control: saludo, accesos rápidos, indicadores del día (solo
/// personal clínico), agenda de hoy, pendientes, asistente de IA y la lista
/// de pacientes de hoy.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<List<Map<String, dynamic>>> _appointmentsFuture;
  Future<Map<String, dynamic>>? _summaryFuture;

  // Cambia al registrar un paciente para que la lista de hoy se recargue.
  Key _patientsKey = UniqueKey();
  final GlobalKey _patientsSectionKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _appointmentsFuture = ApiService.canAccessAgenda
        ? ApiService.getAppointments(date: _ymd(DateTime.now()))
        : Future.value(const []);
    if (ApiService.canAccessClinical) {
      _summaryFuture = ApiService.getDashboardSummary();
    }
  }

  Future<void> _registerPatient() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const PatientFormDialog(),
    );
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Paciente registrado.')));
    setState(() => _patientsKey = UniqueKey());
  }

  void _newAppointment() => ImagendaShell.navigate(
    context,
    ShellSection.agenda,
    openNewAppointment: true,
  );

  void _openAgenda() => ImagendaShell.navigate(context, ShellSection.agenda);

  void _scrollToPatients() {
    final target = _patientsSectionKey.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final clinical = ApiService.canAccessClinical;
    final width = MediaQuery.sizeOf(context).width;
    final padding = width < 600 ? 16.0 : 28.0;

    return ImagendaShell(
      selected: ShellSection.dashboard,
      child: SingleChildScrollView(
        padding: EdgeInsets.all(padding),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1250),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 24),
                if (clinical) ...[
                  _buildIndicators(),
                  const SizedBox(height: 20),
                ],
                LayoutBuilder(
                  builder: (context, constraints) {
                    final agenda = _TodayAgendaCard(
                      future: _appointmentsFuture,
                      onOpenAgenda: _openAgenda,
                      onNewAppointment: ApiService.canAccessAgenda
                          ? _newAppointment
                          : null,
                    );
                    if (!clinical) return agenda;

                    final attention = _AttentionCard(
                      summaryFuture: _summaryFuture!,
                      onPendingReports: _scrollToPatients,
                      onUnlinkedStudies: () => ImagendaShell.navigate(
                        context,
                        ShellSection.unlinkedStudies,
                      ),
                    );
                    if (constraints.maxWidth < 760) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          agenda,
                          const SizedBox(height: 20),
                          attention,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: agenda),
                        const SizedBox(width: 20),
                        SizedBox(width: 340, child: attention),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 28),
                // La IA (/chat) solo está habilitada para AI_STAFF.
                if (ApiService.canUseAi) ...[
                  const NexaAiSection(),
                  const SizedBox(height: 28),
                ],
                SizedBox(key: _patientsSectionKey, height: 0),
                TodayPatientsSection(key: _patientsKey),
                // Estado técnico de la plataforma: solo para la cuenta de
                // administración de Imagenda.
                if (ApiService.isPlatformAdmin) ...[
                  const SizedBox(height: 28),
                  const _ServerStatusCard(),
                  const SizedBox(height: 20),
                  const OperationalStatusSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final now = DateTime.now();
    final firstName = (ApiService.fullName ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .first;
    final greeting = firstName.isEmpty
        ? _greeting(now)
        : '${_greeting(now)}, $firstName';

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          greeting,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            color: NexaColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _appointmentsFuture,
          builder: (context, snapshot) {
            var text = _longDate(now);
            if (ApiService.canAccessAgenda && snapshot.hasData) {
              final count = snapshot.data!
                  .where((a) => a['status']?.toString() != 'cancelada')
                  .length;
              text += count == 1
                  ? ' · 1 cita agendada para hoy'
                  : ' · $count citas agendadas para hoy';
            }
            return Text(
              text,
              style: const TextStyle(
                fontSize: 14.5,
                color: NexaColors.textSecondary,
              ),
            );
          },
        ),
      ],
    );

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 14,
      children: [
        titleBlock,
        if (ApiService.canAccessAgenda)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _registerPatient,
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Registrar paciente'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: NexaColors.primary,
                  side: const BorderSide(color: NexaColors.border),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
              ),
              FilledButton(
                onPressed: _newAppointment,
                style: FilledButton.styleFrom(
                  backgroundColor: NexaColors.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                ),
                child: const Text('+ Nueva cita'),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildIndicators() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _appointmentsFuture,
      builder: (context, appointmentsSnapshot) {
        final appointments = appointmentsSnapshot.data;
        final statuses = appointments
            ?.map((a) => a['status']?.toString() ?? 'programada')
            .toList();
        final active = statuses?.where((s) => s != 'cancelada').toList();
        final attended = statuses?.where((s) => s == 'atendida').length;
        final upcoming = statuses
            ?.where((s) => s == 'programada' || s == 'en_espera')
            .length;
        final waiting = statuses?.where((s) => s == 'en_espera').length;

        return FutureBuilder<Map<String, dynamic>>(
          future: _summaryFuture,
          builder: (context, summarySnapshot) {
            final pending = summarySnapshot.hasData
                ? _asInt(summarySnapshot.data!['pendingValidation'])
                : null;

            final cards = <Widget>[
              _IndicatorCard(
                icon: Icons.event_note_outlined,
                accent: NexaColors.primary,
                label: 'Citas de hoy',
                value: active?.length,
                detail: attended == null
                    ? null
                    : '$attended atendidas · $upcoming por venir',
                onTap: _openAgenda,
              ),
              _IndicatorCard(
                icon: Icons.chair_outlined,
                accent: const Color(0xFFE3A23C),
                label: 'En sala de espera',
                value: waiting,
                detail: waiting == null
                    ? null
                    : waiting == 1
                    ? 'paciente esperando'
                    : 'pacientes esperando',
                onTap: _openAgenda,
              ),
              ValueListenableBuilder<int?>(
                valueListenable: ImagendaShell.unlinkedStudiesCount,
                builder: (context, count, _) => _IndicatorCard(
                  icon: Icons.link_off,
                  accent: const Color(0xFF6366F1),
                  label: 'Estudios sin vincular',
                  value: count,
                  detail: count == null
                      ? null
                      : count == 0
                      ? 'Todo vinculado'
                      : 'por asociar a una orden',
                  onTap: () => ImagendaShell.navigate(
                    context,
                    ShellSection.unlinkedStudies,
                  ),
                ),
              ),
              _IndicatorCard(
                icon: Icons.fact_check_outlined,
                accent: const Color(0xFFF59E0B),
                label: 'Informes por validar',
                value: pending,
                detail: pending == null
                    ? null
                    : pending == 0
                    ? 'Al día'
                    : 'requieren revisión',
                onTap: _scrollToPatients,
              ),
            ];

            return LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 760
                    ? 4
                    : constraints.maxWidth >= 360
                    ? 2
                    : 1;
                const spacing = 14.0;
                final cardWidth =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final card in cards)
                      SizedBox(width: cardWidth, child: card),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ======================================================================
// Tarjetas
// ======================================================================

BoxDecoration _cardDecoration() => BoxDecoration(
  color: NexaColors.surface,
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: NexaColors.border),
);

class _IndicatorCard extends StatelessWidget {
  const _IndicatorCard({
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    required this.detail,
    this.onTap,
  });

  final IconData icon;
  final Color accent;
  final String label;
  final int? value;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: _cardDecoration(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 17, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: NexaColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value?.toString() ?? '—',
                style: const TextStyle(
                  fontSize: 26,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: NexaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail ?? ' ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: NexaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: NexaColors.textPrimary,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _TodayAgendaCard extends StatelessWidget {
  const _TodayAgendaCard({
    required this.future,
    required this.onOpenAgenda,
    required this.onNewAppointment,
  });

  final Future<List<Map<String, dynamic>>> future;
  final VoidCallback onOpenAgenda;
  final VoidCallback? onNewAppointment;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardTitle(
            'Agenda de hoy',
            trailing: TextButton(
              onPressed: onOpenAgenda,
              child: const Text('Ver agenda completa →'),
            ),
          ),
          const Divider(height: 1, color: NexaColors.border),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (snapshot.hasError) {
                final error = snapshot.error;
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error is ApiException
                        ? error.message
                        : 'No fue posible cargar la agenda de hoy.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF991B1B)),
                  ),
                );
              }

              final appointments = snapshot.data ?? const [];
              if (appointments.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 36,
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.event_available_outlined,
                        size: 36,
                        color: NexaColors.textSecondary,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'No hay citas agendadas para hoy',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: NexaColors.textSecondary),
                      ),
                      if (onNewAppointment != null) ...[
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: onNewAppointment,
                          style: FilledButton.styleFrom(
                            backgroundColor: NexaColors.primary,
                          ),
                          child: const Text('+ Nueva cita'),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return Column(
                children: [
                  for (var i = 0; i < appointments.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: NexaColors.border),
                    _AgendaRow(appointment: appointments[i]),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({required this.appointment});

  final Map<String, dynamic> appointment;

  static String? _text(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final status = appointment['status']?.toString() ?? 'programada';
    final closed = _isClosed(status);
    final current = status == 'en_atencion';
    final clock = _text(appointment['clock']) ?? '';
    final patient = _text(appointment['patientName']) ?? 'Paciente sin nombre';
    final exam = _text(appointment['reason']);
    final room = _text(appointment['roomName']);

    final strike = closed ? TextDecoration.lineThrough : null;
    final mainColor = closed ? const Color(0xFF94A3B8) : NexaColors.textPrimary;
    final secondaryColor = closed
        ? const Color(0xFF94A3B8)
        : NexaColors.textSecondary;

    return Container(
      decoration: BoxDecoration(
        color: current ? const Color(0xFFFFFBEB) : null,
        border: Border(
          left: BorderSide(
            color: current ? const Color(0xFFE3A23C) : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(17, 12, 16, 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // En anchos chicos la sala va debajo del paciente, junto al examen.
          final showRoomColumn = constraints.maxWidth >= 460;
          final meta = [?exam, if (!showRoomColumn) ?room].join(' · ');

          return Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  clock,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: mainColor,
                    decoration: strike,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      patient,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: mainColor,
                        decoration: strike,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: secondaryColor,
                          decoration: strike,
                        ),
                      ),
                  ],
                ),
              ),
              if (showRoomColumn) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: Text(
                    room ?? 'Sin sala',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: secondaryColor,
                      decoration: strike,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              _StatusChip(status: status),
            ],
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, background, foreground) = switch (status) {
      'atendida' => (
        'Atendida',
        const Color(0xFFDCFCE7),
        const Color(0xFF15803D),
      ),
      'en_atencion' => (
        'En atención',
        const Color(0xFFDBEAFE),
        const Color(0xFF1D4ED8),
      ),
      'en_espera' => (
        'En espera',
        const Color(0xFFFEF3C7),
        const Color(0xFFB45309),
      ),
      'cancelada' => (
        'Cancelada',
        const Color(0xFFF1F5F9),
        const Color(0xFF94A3B8),
      ),
      'no_asistio' => (
        'No asistió',
        const Color(0xFFF1F5F9),
        const Color(0xFF94A3B8),
      ),
      _ => ('Programada', const Color(0xFFF1F5F9), const Color(0xFF475569)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: foreground,
          decoration: _isClosed(status) ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({
    required this.summaryFuture,
    required this.onPendingReports,
    required this.onUnlinkedStudies,
  });

  final Future<Map<String, dynamic>> summaryFuture;
  final VoidCallback onPendingReports;
  final VoidCallback onUnlinkedStudies;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardTitle('Requiere tu atención'),
          const Divider(height: 1, color: NexaColors.border),
          FutureBuilder<Map<String, dynamic>>(
            future: summaryFuture,
            builder: (context, snapshot) {
              return ValueListenableBuilder<int?>(
                valueListenable: ImagendaShell.unlinkedStudiesCount,
                builder: (context, unlinked, _) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  final pending = snapshot.hasData
                      ? _asInt(snapshot.data!['pendingValidation'])
                      : null;

                  if (pending == 0 && (unlinked ?? 0) == 0) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 28,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: Color(0xFF15803D),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Todo al día',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: [
                      _AttentionRow(
                        icon: Icons.fact_check_outlined,
                        label: 'Informes por validar',
                        count: pending,
                        onTap: onPendingReports,
                      ),
                      const Divider(height: 1, color: NexaColors.border),
                      _AttentionRow(
                        icon: Icons.link_off,
                        label: 'Estudios sin vincular',
                        count: unlinked,
                        onTap: onUnlinkedStudies,
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasItems = (count ?? 0) > 0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: NexaColors.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  color: NexaColors.textPrimary,
                ),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minWidth: 28),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: hasItems
                    ? const Color(0xFFFEF3C7)
                    : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                count?.toString() ?? '—',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: hasItems
                      ? const Color(0xFFB45309)
                      : NexaColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: NexaColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Estado del servidor según /health (solo cuenta de administración).
class _ServerStatusCard extends StatefulWidget {
  const _ServerStatusCard();

  @override
  State<_ServerStatusCard> createState() => _ServerStatusCardState();
}

class _ServerStatusCardState extends State<_ServerStatusCard> {
  late Future<Map<String, dynamic>> _healthFuture;

  @override
  void initState() {
    super.initState();
    _healthFuture = ApiService.getBackendHealth();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: FutureBuilder<Map<String, dynamic>>(
        future: _healthFuture,
        builder: (context, snapshot) {
          final checking = snapshot.connectionState == ConnectionState.waiting;
          final ok = snapshot.data?['ok'] == true;
          final latency = snapshot.data?['latencyMs'];
          final color = checking
              ? NexaColors.textSecondary
              : ok
              ? const Color(0xFF15803D)
              : const Color(0xFFB91C1C);

          return Row(
            children: [
              Icon(
                ok ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                color: color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Servidor Imagenda',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: NexaColors.textPrimary,
                      ),
                    ),
                    Text(
                      checking
                          ? 'Verificando…'
                          : ok
                          ? 'Operativo · /health respondió en $latency ms'
                          : 'Sin respuesta de /health',
                      style: TextStyle(fontSize: 13, color: color),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Volver a verificar',
                onPressed: () => setState(
                  () => _healthFuture = ApiService.getBackendHealth(),
                ),
                icon: const Icon(Icons.refresh),
              ),
            ],
          );
        },
      ),
    );
  }
}
