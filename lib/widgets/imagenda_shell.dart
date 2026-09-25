import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../main.dart' show LoginPage;
import '../screens/appointments_page.dart';
import '../screens/clinics_page.dart';
import '../screens/dashboard_page.dart';
import '../screens/orthanc_studies_page.dart';
import '../screens/staff_management_page.dart';
import '../screens/validation_queue_page.dart';
import '../services/api_service.dart';

/// Secciones del menú lateral.
enum ShellSection {
  dashboard,
  agenda,
  unlinkedStudies,
  validation,
  team,
  clinics,
}

/// Estructura común de las pantallas de Imagenda: menú lateral blanco a la
/// izquierda y el contenido de la pantalla ([child]) sobre el fondo de la app.
///
/// Con menos de [ImagendaShell.drawerBreakpoint] px de ancho el menú pasa a un
/// Drawer, que se abre con el botón de menú de una barra superior mínima.
class ImagendaShell extends StatefulWidget {
  const ImagendaShell({super.key, required this.selected, required this.child});

  final ShellSection selected;
  final Widget child;

  static const double drawerBreakpoint = 900;
  static const double sidebarWidth = 248;

  /// Cantidad de estudios DICOM sin vincular (globo del ítem del menú y
  /// indicador del Centro de Control). null mientras no se conoce.
  static final ValueNotifier<int?> unlinkedStudiesCount = ValueNotifier(null);

  /// Vuelve a consultar los estudios sin vincular. Nunca lanza.
  static Future<void> refreshUnlinkedStudiesCount() async {
    if (!ApiService.canAccessClinical) {
      unlinkedStudiesCount.value = null;
      return;
    }
    try {
      final studies = await ApiService.getUnlinkedOrthancStudies();
      unlinkedStudiesCount.value = studies.length;
    } catch (_) {
      // Se conserva el último valor conocido.
    }
  }

  /// Total de informes por validar (globo del ítem "Por validar"). null
  /// mientras no se conoce o si quien está conectado no puede validar.
  static final ValueNotifier<int?> pendingValidationCount = ValueNotifier(null);

  /// Vuelve a consultar los informes por validar. Nunca lanza.
  static Future<void> refreshPendingValidationCount() async {
    if (!ApiService.canValidate) {
      pendingValidationCount.value = null;
      return;
    }
    try {
      final queue = await ApiService.getValidationQueue();
      final counts = queue['conteos'];
      final total = counts is Map ? counts['total'] : null;
      if (total is num) pendingValidationCount.value = total.toInt();
    } catch (_) {
      // Se conserva el último valor conocido.
    }
  }

  /// Reemplaza la pantalla actual por la de [section] (sin apilar).
  static void navigate(
    BuildContext context,
    ShellSection section, {
    bool openNewAppointment = false,
  }) {
    final Widget page = switch (section) {
      ShellSection.dashboard => const DashboardPage(),
      ShellSection.agenda => AppointmentsPage(
        openNewAppointment: openNewAppointment,
      ),
      ShellSection.unlinkedStudies => const OrthancStudiesPage(),
      ShellSection.validation => const ValidationQueuePage(),
      ShellSection.team => const StaffManagementPage(),
      ShellSection.clinics => const ClinicsPage(),
    };
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, _, _) => page,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  State<ImagendaShell> createState() => _ImagendaShellState();
}

class _ImagendaShellState extends State<ImagendaShell> {
  @override
  void initState() {
    super.initState();
    ImagendaShell.refreshUnlinkedStudiesCount();
    ImagendaShell.refreshPendingValidationCount();
  }

  @override
  Widget build(BuildContext context) {
    final narrow =
        MediaQuery.sizeOf(context).width < ImagendaShell.drawerBreakpoint;

    if (narrow) {
      return Scaffold(
        backgroundColor: NexaColors.background,
        appBar: AppBar(
          backgroundColor: NexaColors.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 56,
          titleSpacing: 0,
          shape: const Border(bottom: BorderSide(color: NexaColors.border)),
          leading: Builder(
            builder: (context) => IconButton(
              tooltip: 'Menú',
              icon: const Icon(Icons.menu, color: NexaColors.textPrimary),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          title: Image.asset('assets/images/imagenda_logo.png', height: 26),
        ),
        drawer: Drawer(
          width: ImagendaShell.sidebarWidth,
          backgroundColor: NexaColors.surface,
          shape: const RoundedRectangleBorder(),
          child: _Sidebar(selected: widget.selected, inDrawer: true),
        ),
        body: widget.child,
      );
    }

    return Scaffold(
      backgroundColor: NexaColors.background,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: ImagendaShell.sidebarWidth,
            decoration: const BoxDecoration(
              color: NexaColors.surface,
              border: Border(right: BorderSide(color: NexaColors.border)),
            ),
            child: _Sidebar(selected: widget.selected, inDrawer: false),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}

/// Encabezado de una pantalla dentro del contenido: título (y subtítulo) a la
/// izquierda y las acciones de la pantalla alineadas a la derecha.
class ImagendaPageHeader extends StatelessWidget {
  const ImagendaPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: NexaColors.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(color: NexaColors.textSecondary),
          ),
        ],
      ],
    );

    if (actions.isEmpty) return titleBlock;

    // Si el título y las acciones no caben en una línea, las acciones pasan
    // debajo del título en vez de desbordar.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        titleBlock,
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.inDrawer});

  final ShellSection selected;
  final bool inDrawer;

  void _go(BuildContext context, ShellSection section) {
    if (inDrawer) Navigator.pop(context);
    if (section == selected) return;
    ImagendaShell.navigate(context, section);
  }

  void _logout(BuildContext context) {
    ApiService.logout();
    ImagendaShell.unlinkedStudiesCount.value = null;
    ImagendaShell.pendingValidationCount.value = null;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ApiService.role == 'administrador';

    Widget item(
      ShellSection section,
      IconData icon,
      String label, {
      Widget? trailing,
    }) => _SidebarItem(
      icon: icon,
      label: label,
      selected: section == selected,
      trailing: trailing,
      onTap: () => _go(context, section),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Image.asset(
                  'assets/images/imagenda_logo.png',
                  height: 30,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  item(
                    ShellSection.dashboard,
                    Icons.space_dashboard_outlined,
                    'Centro de Control',
                  ),
                  if (ApiService.canAccessAgenda)
                    item(
                      ShellSection.agenda,
                      Icons.event_note_outlined,
                      'Agenda',
                    ),
                  if (ApiService.canAccessClinical)
                    item(
                      ShellSection.unlinkedStudies,
                      Icons.link_off,
                      'Estudios sin vincular',
                      trailing: ValueListenableBuilder<int?>(
                        valueListenable: ImagendaShell.unlinkedStudiesCount,
                        builder: (context, count, _) =>
                            count != null && count > 0
                            ? _CountBubble(count: count)
                            : const SizedBox.shrink(),
                      ),
                    ),
                  if (ApiService.canValidate)
                    item(
                      ShellSection.validation,
                      Icons.fact_check_outlined,
                      'Por validar',
                      trailing: ValueListenableBuilder<int?>(
                        valueListenable: ImagendaShell.pendingValidationCount,
                        builder: (context, count, _) =>
                            count != null && count > 0
                            ? _CountBubble(count: count)
                            : const SizedBox.shrink(),
                      ),
                    ),
                  if (isAdmin) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 20, 12, 8),
                      child: Text(
                        'ADMINISTRACIÓN',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: NexaColors.textSecondary,
                        ),
                      ),
                    ),
                    item(ShellSection.team, Icons.groups_outlined, 'Equipo'),
                    if (ApiService.isPlatformAdmin)
                      item(
                        ShellSection.clinics,
                        Icons.local_hospital_outlined,
                        'Clínicas',
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            const _ClinicBadge(),
            const SizedBox(height: 6),
            _SidebarItem(
              icon: Icons.logout,
              label: 'Cerrar sesión',
              selected: false,
              onTap: () => _logout(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  static const Color _selectedBackground = Color(0xFFE6F1EE);

  @override
  Widget build(BuildContext context) {
    final color = selected ? NexaColors.primaryDark : NexaColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? _selectedBackground : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? NexaColors.primaryDark
                          : NexaColors.textPrimary,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountBubble extends StatelessWidget {
  const _CountBubble({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFE3A23C),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Credencial de la clínica de quien está conectado: logo, nombre de la
/// clínica y correo. Para la cuenta de administración de plataforma muestra
/// el ícono de administración y 'Administración Imagenda'.
class _ClinicBadge extends StatelessWidget {
  const _ClinicBadge();

  @override
  Widget build(BuildContext context) {
    final isPlatformAdmin = ApiService.isPlatformAdmin;
    final clinicName = isPlatformAdmin
        ? 'Administración Imagenda'
        : ApiService.clinicName ?? 'Sin clínica asignada';
    final email = ApiService.currentUser?['email']?.toString();

    final logoBox = Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NexaColors.border),
      ),
      child: isPlatformAdmin
          ? const Icon(
              Icons.admin_panel_settings_outlined,
              color: NexaColors.primary,
            )
          : ValueListenableBuilder<Uint8List?>(
              valueListenable: ApiService.clinicLogo,
              builder: (context, logo, _) => logo == null
                  ? const Icon(
                      Icons.local_hospital_outlined,
                      color: NexaColors.primary,
                    )
                  : Image.memory(logo, fit: BoxFit.contain),
            ),
    );

    return Tooltip(
      message: [clinicName, ?email].join('\n'),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFBFCFD),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: NexaColors.border),
        ),
        child: Row(
          children: [
            logoBox,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clinicName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: NexaColors.textPrimary,
                    ),
                  ),
                  if (email != null)
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: NexaColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
