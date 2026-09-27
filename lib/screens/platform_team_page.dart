import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/imagenda_shell.dart';

/// Tipos de acceso del equipo Imagenda, en el orden en que se ofrecen.
const List<String> _kPlatformRoles = ['admin', 'soporte'];

String _platformRoleLabel(String? role) {
  switch (role) {
    case 'admin':
      return 'Administrador total';
    case 'soporte':
      return 'Soporte';
    default:
      return 'Sin tipo';
  }
}

/// Valores del selector "Acceso a pacientes", los mismos que acepta el
/// backend en patientAccess: 'todas', 'ninguna' o el id de una clínica.
const String _kAllClinics = 'todas';
const String _kImagendaOnly = 'ninguna';

/// Acceso a pacientes actual de un miembro, en los valores del selector.
String _patientAccessOf(Map<String, dynamic> member) {
  if (member['allClinics'] == true) return _kAllClinics;
  return member['clinicId']?.toString() ?? _kImagendaOnly;
}

String _clinicLabel(Map<String, dynamic> member) {
  if (member['allClinics'] == true) return 'Todas las clínicas';
  if (member['clinicId'] == null) return 'Solo Imagenda';
  return member['clinicName']?.toString() ?? 'Clínica desconocida';
}

String _memberLabel(Map<String, dynamic> member) {
  final name = member['fullName']?.toString().trim() ?? '';
  if (name.isNotEmpty) return name;
  return member['email']?.toString() ?? 'esta persona';
}

/// Equipo interno de la plataforma (staff_profiles con is_platform_admin, más
/// quienes fueron del equipo y se les quitó el acceso). Un Administrador total
/// puede invitar, cambiar el tipo de acceso, quitar y reactivar; Soporte solo
/// ve la lista.
class PlatformTeamPage extends StatefulWidget {
  const PlatformTeamPage({super.key});

  @override
  State<PlatformTeamPage> createState() => _PlatformTeamPageState();
}

class _PlatformTeamPageState extends State<PlatformTeamPage> {
  late Future<List<Map<String, dynamic>>> _teamFuture;
  String? _busyId;

  bool get _canManage => ApiService.platformRole == 'admin';

  @override
  void initState() {
    super.initState();
    _teamFuture = ApiService.getPlatformTeam();
  }

  void _reload() {
    setState(() {
      _teamFuture = ApiService.getPlatformTeam();
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Clínicas para el selector "Acceso a pacientes". null si falló (ya se
  /// mostró el mensaje).
  Future<List<Map<String, dynamic>>?> _loadClinics() async {
    try {
      return await ApiService.getClinics();
    } on ApiException catch (error) {
      _showMessage(error.message);
    } catch (_) {
      _showMessage('No fue posible cargar las clínicas.');
    }
    return null;
  }

  Future<void> _openInviteDialog() async {
    final clinics = await _loadClinics();
    if (clinics == null || !mounted) return;

    final invited = await showDialog<bool>(
      context: context,
      builder: (_) => _InviteMemberDialog(clinics: clinics),
    );
    if (invited == true) _reload();
  }

  Future<void> _runAction(
    Map<String, dynamic> member,
    Future<void> Function(String id) action,
    String fallbackError,
  ) async {
    final id = member['id']?.toString() ?? '';
    if (id.isEmpty) return;

    setState(() => _busyId = id);
    try {
      await action(id);
      if (mounted) _reload();
    } on ApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage(fallbackError);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _changeRole(Map<String, dynamic> member) async {
    final newRole = await showDialog<String>(
      context: context,
      builder: (_) => _PlatformRoleDialog(
        title: 'Cambiar tipo de acceso',
        member: member,
        initialRole: member['platformRole']?.toString(),
        confirmLabel: 'Guardar',
      ),
    );
    if (newRole == null || newRole == member['platformRole']) return;

    await _runAction(
      member,
      (id) =>
          ApiService.updatePlatformRole(memberId: id, platformRole: newRole),
      'No fue posible cambiar el tipo de acceso.',
    );
  }

  Future<void> _changeClinic(Map<String, dynamic> member) async {
    final clinics = await _loadClinics();
    if (clinics == null || !mounted) return;

    final choice = await showDialog<String>(
      context: context,
      builder: (_) => _PatientAccessDialog(member: member, clinics: clinics),
    );
    if (choice == null || choice == _patientAccessOf(member)) return;

    await _runAction(
      member,
      (id) =>
          ApiService.updatePlatformClinic(memberId: id, patientAccess: choice),
      'No fue posible cambiar el acceso a pacientes.',
    );
  }

  Future<void> _revoke(Map<String, dynamic> member) async {
    final label = _memberLabel(member);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Quitar acceso'),
        content: SizedBox(
          width: 420,
          child: Text(
            '¿Quitarle el acceso a "$label"?\n\n'
            'Esta persona ya no podrá iniciar sesión en Imagenda y cualquier '
            'sesión que tenga abierta dejará de funcionar. Su cuenta no se '
            'borra: podrás reactivarla más adelante desde esta misma lista.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Quitar acceso'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _runAction(
      member,
      (id) => ApiService.revokePlatformAccess(id),
      'No fue posible quitar el acceso a esta persona.',
    );
  }

  Future<void> _deleteInvite(Map<String, dynamic> member) async {
    final email = member['email']?.toString() ?? _memberLabel(member);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar invitación'),
        content: SizedBox(
          width: 420,
          child: Text(
            'Se eliminará la invitación enviada a $email. El enlace que '
            'recibió dejará de funcionar. ¿Continuar?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Eliminar invitación'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _runAction(
      member,
      ApiService.deletePlatformInvite,
      'No fue posible eliminar la invitación.',
    );
  }

  Future<void> _restore(Map<String, dynamic> member) async {
    final role = await showDialog<String>(
      context: context,
      builder: (_) => _PlatformRoleDialog(
        title: 'Reactivar acceso',
        member: member,
        initialRole: member['platformRole']?.toString(),
        confirmLabel: 'Reactivar',
        explanation:
            'La persona podrá volver a iniciar sesión en Imagenda con el tipo '
            'de acceso que elijas.',
      ),
    );
    if (role == null) return;

    await _runAction(
      member,
      (id) =>
          ApiService.restorePlatformAccess(memberId: id, platformRole: role),
      'No fue posible reactivar el acceso a esta persona.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImagendaShell(
      selected: ShellSection.platformTeam,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ImagendaPageHeader(
                  title: 'Equipo Imagenda',
                  subtitle: _canManage
                      ? 'Quién del equipo interno tiene acceso a la plataforma y de qué tipo.'
                      : 'Tu acceso es de Soporte: puedes ver al equipo, pero no modificarlo.',
                  actions: [
                    if (_canManage)
                      FilledButton.icon(
                        onPressed: _openInviteDialog,
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('Invitar al equipo'),
                        style: FilledButton.styleFrom(
                          backgroundColor: NexaColors.primary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: NexaColors.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: NexaColors.border),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x0D0F172A),
                        blurRadius: 24,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.admin_panel_settings_outlined,
                            color: NexaColors.primary,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Integrantes',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: NexaColors.textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Actualizar',
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      FutureBuilder<List<Map<String, dynamic>>>(
                        future: _teamFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }

                          if (snapshot.hasError) {
                            final error = snapshot.error;
                            return _ErrorMessage(
                              message: error is ApiException
                                  ? error.message
                                  : 'No fue posible cargar el equipo Imagenda.',
                              onRetry: _reload,
                            );
                          }

                          final team = snapshot.data ?? [];
                          if (team.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text('Todavía no hay nadie en el equipo.'),
                            );
                          }

                          return _TeamTable(
                            team: team,
                            canManage: _canManage,
                            busyId: _busyId,
                            onChangeRole: _changeRole,
                            onChangeClinic: _changeClinic,
                            onRevoke: _revoke,
                            onRestore: _restore,
                            onDeleteInvite: _deleteInvite,
                          );
                        },
                      ),
                    ],
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

class _TeamTable extends StatelessWidget {
  const _TeamTable({
    required this.team,
    required this.canManage,
    required this.busyId,
    required this.onChangeRole,
    required this.onChangeClinic,
    required this.onRevoke,
    required this.onRestore,
    required this.onDeleteInvite,
  });

  final List<Map<String, dynamic>> team;
  final bool canManage;
  final String? busyId;
  final void Function(Map<String, dynamic>) onChangeRole;
  final void Function(Map<String, dynamic>) onChangeClinic;
  final void Function(Map<String, dynamic>) onRevoke;
  final void Function(Map<String, dynamic>) onRestore;
  final void Function(Map<String, dynamic>) onDeleteInvite;

  Widget _actions(Map<String, dynamic> member) {
    final id = member['id']?.toString();
    // La propia cuenta no se puede cambiar ni quitar (el backend responde 400).
    final isSelf = id == ApiService.currentUser?['id']?.toString();
    final active = member['active'] == true;
    // Invitación que nunca se aceptó: se puede eliminar (correo mal escrito).
    final pending = member['pendingInvite'] == true;

    if (busyId == id) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (isSelf) {
      return const Text(
        'Tu cuenta',
        style: TextStyle(fontSize: 12, color: NexaColors.textSecondary),
      );
    }
    if (!active) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: () => onRestore(member),
            icon: const Icon(Icons.lock_open_outlined, size: 18),
            label: const Text('Reactivar'),
          ),
          if (pending)
            IconButton(
              tooltip: 'Eliminar invitación',
              onPressed: () => onDeleteInvite(member),
              icon: const Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
            ),
        ],
      );
    }
    return PopupMenuButton<void Function(Map<String, dynamic>)>(
      tooltip: 'Acciones',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => action(member),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: onChangeRole,
          child: const ListTile(
            leading: Icon(Icons.swap_horiz),
            title: Text('Cambiar tipo de acceso'),
          ),
        ),
        PopupMenuItem(
          value: onChangeClinic,
          child: const ListTile(
            leading: Icon(Icons.local_hospital_outlined),
            title: Text('Cambiar acceso a pacientes'),
          ),
        ),
        PopupMenuItem(
          value: onRevoke,
          child: const ListTile(
            leading: Icon(Icons.block, color: Color(0xFFB91C1C)),
            title: Text(
              'Quitar acceso',
              style: TextStyle(color: Color(0xFFB91C1C)),
            ),
          ),
        ),
        if (pending)
          PopupMenuItem(
            value: onDeleteInvite,
            child: const ListTile(
              leading: Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
              title: Text(
                'Eliminar invitación',
                style: TextStyle(color: Color(0xFFB91C1C)),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const headerStyle = TextStyle(
      fontWeight: FontWeight.w700,
      color: NexaColors.textSecondary,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        columnSpacing: 28,
        columns: [
          const DataColumn(label: Text('Nombre', style: headerStyle)),
          const DataColumn(label: Text('Email', style: headerStyle)),
          const DataColumn(label: Text('Tipo de acceso', style: headerStyle)),
          const DataColumn(label: Text('Clínica base', style: headerStyle)),
          const DataColumn(label: Text('Estado', style: headerStyle)),
          if (canManage)
            const DataColumn(label: Text('Acciones', style: headerStyle)),
        ],
        rows: [
          for (final member in team)
            DataRow(
              cells: [
                DataCell(
                  Text(
                    member['fullName']?.toString().trim().isNotEmpty == true
                        ? member['fullName'].toString()
                        : '—',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                DataCell(Text(member['email']?.toString() ?? '—')),
                DataCell(
                  _AccessBadge(role: member['platformRole']?.toString()),
                ),
                DataCell(Text(_clinicLabel(member))),
                DataCell(
                  _StatusBadge(
                    active: member['active'] == true,
                    pendingInvite: member['pendingInvite'] == true,
                  ),
                ),
                if (canManage) DataCell(_actions(member)),
              ],
            ),
        ],
      ),
    );
  }
}

class _AccessBadge extends StatelessWidget {
  const _AccessBadge({required this.role});

  final String? role;

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin';
    return _Pill(
      text: _platformRoleLabel(role),
      background: isAdmin ? const Color(0xFFDCFCE7) : const Color(0xFFEFF6FF),
      foreground: isAdmin ? const Color(0xFF15803D) : const Color(0xFF1D4ED8),
    );
  }
}

/// Estado de la fila: Activo / Sin acceso, e "Invitación pendiente" si la
/// persona nunca aceptó la invitación (en lugar de "Activo", o junto a "Sin
/// acceso" si además se le quitó el acceso).
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.active, required this.pendingInvite});

  final bool active;
  final bool pendingInvite;

  @override
  Widget build(BuildContext context) {
    const pendingPill = _Pill(
      text: 'Invitación pendiente',
      background: Color(0xFFFEF3C7),
      foreground: Color(0xFFB45309),
    );
    if (active) {
      return pendingInvite
          ? pendingPill
          : const _Pill(
              text: 'Activo',
              background: Color(0xFFDCFCE7),
              foreground: Color(0xFF15803D),
            );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Pill(
          text: 'Sin acceso',
          background: Color(0xFFFEE2E2),
          foreground: Color(0xFFB91C1C),
        ),
        if (pendingInvite) ...[const SizedBox(width: 6), pendingPill],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Elige un tipo de acceso para una persona del equipo (cambiar o reactivar).
/// Devuelve el tipo elegido, o null si se cancela.
class _PlatformRoleDialog extends StatefulWidget {
  const _PlatformRoleDialog({
    required this.title,
    required this.member,
    required this.initialRole,
    required this.confirmLabel,
    this.explanation,
  });

  final String title;
  final Map<String, dynamic> member;
  final String? initialRole;
  final String confirmLabel;
  final String? explanation;

  @override
  State<_PlatformRoleDialog> createState() => _PlatformRoleDialogState();
}

class _PlatformRoleDialogState extends State<_PlatformRoleDialog> {
  late String _role;

  @override
  void initState() {
    super.initState();
    _role = _kPlatformRoles.contains(widget.initialRole)
        ? widget.initialRole!
        : 'soporte';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _memberLabel(widget.member),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (widget.explanation != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.explanation!,
                style: const TextStyle(color: NexaColors.textSecondary),
              ),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(
                labelText: 'Tipo de acceso',
                border: OutlineInputBorder(),
              ),
              items: _kPlatformRoles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(_platformRoleLabel(role)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
            const SizedBox(height: 10),
            const _AccessHelp(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _role),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _AccessHelp extends StatelessWidget {
  const _AccessHelp();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Administrador total: gestiona clínicas y al equipo Imagenda.\n'
      'Soporte: ve todo, pero no crea ni edita clínicas ni gestiona al equipo.',
      style: TextStyle(fontSize: 12, color: NexaColors.textSecondary),
    );
  }
}

class _InviteMemberDialog extends StatefulWidget {
  const _InviteMemberDialog({required this.clinics});

  final List<Map<String, dynamic>> clinics;

  @override
  State<_InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends State<_InviteMemberDialog> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  // El tipo de acceso se elige a conciencia (sin valor inicial). El acceso a
  // pacientes parte en "Solo Imagenda": dar acceso a una clínica es la
  // decisión que hay que tomar a propósito.
  String? _platformRole;
  String _clinicChoice = _kImagendaOnly;
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _emailController.text.trim().isNotEmpty &&
      _fullNameController.text.trim().isNotEmpty &&
      _platformRole != null &&
      !_isSubmitting;

  Future<void> _submit() async {
    if (!_canSubmit) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.invitePlatformMember(
        email: _emailController.text.trim(),
        fullName: _fullNameController.text.trim(),
        platformRole: _platformRole!,
        patientAccess: _clinicChoice,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible invitar a esta persona.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invitar al equipo Imagenda'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _emailController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Correo electrónico',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _fullNameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Nombre completo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _platformRole,
              decoration: const InputDecoration(
                labelText: 'Tipo de acceso',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Elige el tipo de acceso'),
              items: _kPlatformRoles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(_platformRoleLabel(role)),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _platformRole = value),
            ),
            const SizedBox(height: 14),
            _PatientAccessField(
              clinics: widget.clinics,
              value: _clinicChoice,
              onChanged: (value) => setState(() => _clinicChoice = value),
            ),
            const SizedBox(height: 10),
            const _AccessHelp(),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Enviar invitación'),
        ),
      ],
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.onRetry, required this.message});

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
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
    );
  }
}

/// Selector "Acceso a pacientes": "Todas las clínicas" ([_kAllClinics]),
/// "Solo Imagenda" ([_kImagendaOnly]) o una clínica, con la explicación
/// debajo.
class _PatientAccessField extends StatelessWidget {
  const _PatientAccessField({
    required this.clinics,
    required this.value,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> clinics;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final validValues = {
      _kAllClinics,
      _kImagendaOnly,
      for (final clinic in clinics) clinic['id']?.toString(),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          // Si la clínica actual ya no está en la lista, cae a Solo Imagenda
          // en vez de romper el Dropdown.
          initialValue: validValues.contains(value) ? value : _kImagendaOnly,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Acceso a pacientes',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
              value: _kAllClinics,
              child: Text('Todas las clínicas (selector de clínica)'),
            ),
            const DropdownMenuItem(
              value: _kImagendaOnly,
              child: Text('Solo Imagenda (sin acceso a pacientes)'),
            ),
            for (final clinic in clinics)
              if (clinic['id'] != null)
                DropdownMenuItem(
                  value: clinic['id'].toString(),
                  child: Text(
                    clinic['name']?.toString() ?? '',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
          onChanged: (selected) {
            if (selected != null) onChanged(selected);
          },
        ),
        const SizedBox(height: 6),
        const Text(
          'Si eliges una clínica, esta persona también verá los pacientes de esa clínica. '
          'Con "Todas las clínicas" elige con cuál trabajar desde el menú lateral.',
          style: TextStyle(fontSize: 12, color: NexaColors.textSecondary),
        ),
      ],
    );
  }
}

/// "Cambiar acceso a pacientes" de una fila. Devuelve la opción elegida
/// ([_kAllClinics], [_kImagendaOnly] o el id de la clínica), o null si se
/// cancela.
class _PatientAccessDialog extends StatefulWidget {
  const _PatientAccessDialog({required this.member, required this.clinics});

  final Map<String, dynamic> member;
  final List<Map<String, dynamic>> clinics;

  @override
  State<_PatientAccessDialog> createState() => _PatientAccessDialogState();
}

class _PatientAccessDialogState extends State<_PatientAccessDialog> {
  late String _choice = _patientAccessOf(widget.member);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar acceso a pacientes'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _memberLabel(widget.member),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            _PatientAccessField(
              clinics: widget.clinics,
              value: _choice,
              onChanged: (value) => setState(() => _choice = value),
            ),
            const SizedBox(height: 10),
            const Text(
              'El acceso a los datos cambia de inmediato; su menú se actualiza la '
              'próxima vez que inicie sesión.',
              style: TextStyle(fontSize: 12, color: NexaColors.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _choice),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
