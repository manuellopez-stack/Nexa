import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/imagenda_app_bar.dart';

const List<String> _kStaffRoles = [
  'administrador',
  'medico',
  'tecnico',
  'recepcion',
];

class StaffManagementPage extends StatefulWidget {
  const StaffManagementPage({super.key});

  @override
  State<StaffManagementPage> createState() => _StaffManagementPageState();
}

/// Personal + clínicas visibles para quien administra. Un admin de clínica
/// recibe solo su propia clínica en `clinics`; un admin de plataforma, todas.
class _TeamData {
  const _TeamData({required this.staff, required this.clinics});

  final List<Map<String, dynamic>> staff;
  final List<Map<String, dynamic>> clinics;

  String? clinicName(String? clinicId) {
    if (clinicId == null) return null;
    for (final clinic in clinics) {
      if (clinic['id'] == clinicId) return clinic['name']?.toString();
    }
    return null;
  }
}

class _StaffManagementPageState extends State<StaffManagementPage> {
  late Future<_TeamData> _dataFuture;
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_TeamData> _load() async {
    final results = await Future.wait([
      ApiService.getStaff(),
      ApiService.getClinics(),
    ]);
    return _TeamData(staff: results[0], clinics: results[1]);
  }

  void _reload() {
    setState(() {
      _dataFuture = _load();
    });
  }

  // Título según el alcance real de la pantalla: un admin de clínica gestiona
  // solo el personal de su clínica; un admin de plataforma, el de todas.
  String _title(_TeamData? data) {
    if (ApiService.isPlatformAdmin) return 'Personal por clínica';
    final name = data?.clinicName(ApiService.clinicId);
    return name == null ? 'Personal de tu clínica' : 'Personal de $name';
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openInviteDialog() async {
    final List<Map<String, dynamic>> clinics;
    try {
      clinics = (await _dataFuture).clinics;
    } catch (_) {
      _showError('No fue posible cargar las clínicas.');
      return;
    }
    if (!mounted) return;

    final invited = await showDialog<bool>(
      context: context,
      builder: (_) => _InviteStaffDialog(clinics: clinics),
    );

    if (invited == true) _reload();
  }

  Future<void> _openEditRoleDialog(Map<String, dynamic> member) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _EditRoleDialog(member: member),
    );

    if (updated == true) _reload();
  }

  Future<void> _deleteMember(Map<String, dynamic> member) async {
    final id = member['id']?.toString() ?? '';
    if (id.isEmpty) return;

    final name = member['fullName']?.toString().trim();
    final label = (name != null && name.isNotEmpty)
        ? name
        : (member['email']?.toString() ?? 'esta persona');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Quitar del equipo'),
        content: Text(
          '¿Quitar a "$label" del equipo? Esta acción no se puede deshacer.',
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
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _deletingId = id);

    try {
      await ApiService.deleteStaff(id);
      if (mounted) _reload();
    } on ApiException catch (error) {
      if (mounted) _showError(error.message);
    } catch (_) {
      if (mounted) {
        _showError('No fue posible quitar a esta persona del equipo.');
      }
    } finally {
      if (mounted) setState(() => _deletingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: ImagendaAppBar(
        title: 'Gestión de equipo',
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _openInviteDialog,
              icon: const Icon(Icons.person_add_alt, size: 18),
              label: const Text('Invitar'),
              style: FilledButton.styleFrom(
                backgroundColor: NexaColors.primary,
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Container(
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
                        Icons.groups_outlined,
                        color: NexaColors.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FutureBuilder<_TeamData>(
                          future: _dataFuture,
                          builder: (context, snapshot) => Text(
                            _title(snapshot.data),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: NexaColors.textPrimary,
                            ),
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
                  const SizedBox(height: 6),
                  Text(
                    ApiService.isPlatformAdmin
                        ? 'Administra quién tiene acceso a cada clínica y con qué rol.'
                        : 'Administra quién tiene acceso a tu clínica y con qué rol.',
                    style: const TextStyle(color: NexaColors.textSecondary),
                  ),
                  const SizedBox(height: 22),
                  FutureBuilder<_TeamData>(
                    future: _dataFuture,
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
                              : 'No fue posible cargar el equipo.',
                          onRetry: _reload,
                        );
                      }

                      final data = snapshot.data;
                      final staff = data?.staff ?? [];

                      if (data == null || staff.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('Todavía no hay personas invitadas.'),
                        );
                      }

                      Widget tile(Map<String, dynamic> member) {
                        final id = member['id']?.toString() ?? '';
                        return _StaffTile(
                          member: member,
                          isDeleting: _deletingId == id,
                          onEditRole: () => _openEditRoleDialog(member),
                          onDelete: () => _deleteMember(member),
                        );
                      }

                      if (!ApiService.isPlatformAdmin) {
                        return Column(children: staff.map(tile).toList());
                      }

                      // Admin de plataforma: una sección por clínica, en el
                      // orden de la lista de clínicas; al final quien no
                      // tenga clínica asignada.
                      final groups = <String?, List<Map<String, dynamic>>>{};
                      for (final clinic in data.clinics) {
                        groups[clinic['id']?.toString()] = [];
                      }
                      for (final member in staff) {
                        groups
                            .putIfAbsent(member['clinicId']?.toString(), () => [])
                            .add(member);
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final entry in groups.entries)
                            if (entry.value.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 8),
                                child: Text(
                                  data.clinicName(entry.key) ??
                                      (entry.key == null
                                          ? 'Sin clínica asignada'
                                          : 'Clínica desconocida'),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: NexaColors.textPrimary,
                                  ),
                                ),
                              ),
                              ...entry.value.map(tile),
                            ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({
    required this.member,
    required this.isDeleting,
    required this.onEditRole,
    required this.onDelete,
  });

  final Map<String, dynamic> member;
  final bool isDeleting;
  final VoidCallback onEditRole;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final fullName = member['fullName']?.toString().trim() ?? '';
    final email = member['email']?.toString() ?? '';
    final role = member['role']?.toString() ?? '';
    // La propia cuenta no se puede editar ni quitar (el backend responde 403).
    final isSelf =
        member['id']?.toString() == ApiService.currentUser?['id']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isSelf ? null : onEditRole,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: NexaColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fullName.isEmpty ? email : fullName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (fullName.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          email,
                          style: const TextStyle(
                            fontSize: 12,
                            color: NexaColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _RoleBadge(role: role),
                if (!isSelf) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Cambiar rol',
                    onPressed: onEditRole,
                    icon: const Icon(Icons.edit_outlined, size: 19),
                  ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: isDeleting
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: 'Quitar del equipo',
                            onPressed: onDelete,
                            icon: const Icon(
                              Icons.person_remove_outlined,
                              size: 19,
                              color: Color(0xFFB91C1C),
                            ),
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InviteStaffDialog extends StatefulWidget {
  const _InviteStaffDialog({required this.clinics});

  final List<Map<String, dynamic>> clinics;

  @override
  State<_InviteStaffDialog> createState() => _InviteStaffDialogState();
}

class _InviteStaffDialogState extends State<_InviteStaffDialog> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  String _role = _kStaffRoles.first;
  // Admin de plataforma: sin valor inicial, para que elija la clínica a
  // conciencia (así se coló la invitación de APSA en MILMED). Admin de
  // clínica: fija en la suya, el selector queda deshabilitado.
  String? _clinicId;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!ApiService.isPlatformAdmin) _clinicId = ApiService.clinicId;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final fullName = _fullNameController.text.trim();
    final clinicId = _clinicId;

    if (email.isEmpty || fullName.isEmpty || clinicId == null || _isSubmitting) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.inviteStaff(
        email: email,
        fullName: fullName,
        role: _role,
        clinicId: clinicId,
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
    final email = _emailController.text.trim();
    final fullName = _fullNameController.text.trim();
    final canSubmit = email.isNotEmpty &&
        fullName.isNotEmpty &&
        _clinicId != null &&
        !_isSubmitting;

    return AlertDialog(
      title: const Text('Invitar a una persona'),
      content: SizedBox(
        width: 420,
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
              initialValue: _clinicId,
              decoration: const InputDecoration(
                labelText: 'Clínica',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Elige la clínica'),
              items: widget.clinics
                  .map(
                    (clinic) => DropdownMenuItem(
                      value: clinic['id']?.toString(),
                      child: Text(
                        clinic['name']?.toString() ?? '',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: ApiService.isPlatformAdmin
                  ? (value) => setState(() => _clinicId = value)
                  : null,
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(
                labelText: 'Rol',
                border: OutlineInputBorder(),
              ),
              items: _kStaffRoles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(_roleLabel(role)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB91C1C)),
              ),
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
          onPressed: canSubmit ? _submit : null,
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

class _EditRoleDialog extends StatefulWidget {
  const _EditRoleDialog({required this.member});

  final Map<String, dynamic> member;

  @override
  State<_EditRoleDialog> createState() => _EditRoleDialogState();
}

class _EditRoleDialogState extends State<_EditRoleDialog> {
  late String _role;
  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final currentRole = widget.member['role']?.toString();
    _role = _kStaffRoles.contains(currentRole)
        ? currentRole!
        : _kStaffRoles.first;
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final id = widget.member['id']?.toString() ?? '';
    if (id.isEmpty) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.updateStaffRole(staffId: id, role: _role);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible actualizar el rol.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fullName = widget.member['fullName']?.toString().trim() ?? '';
    final email = widget.member['email']?.toString() ?? '';

    return AlertDialog(
      title: const Text('Cambiar rol'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fullName.isEmpty ? email : fullName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (fullName.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                email,
                style: const TextStyle(
                  fontSize: 12,
                  color: NexaColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: const InputDecoration(
                labelText: 'Rol',
                border: OutlineInputBorder(),
              ),
              items: _kStaffRoles
                  .map(
                    (role) => DropdownMenuItem(
                      value: role,
                      child: Text(_roleLabel(role)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFB91C1C)),
              ),
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
              : const Text('Guardar'),
        ),
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;

    switch (role) {
      case 'administrador':
        backgroundColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF15803D);
        break;
      case 'medico':
        backgroundColor = const Color(0xFFEFF6FF);
        textColor = const Color(0xFF1D4ED8);
        break;
      case 'tecnico':
        backgroundColor = const Color(0xFFFFF7ED);
        textColor = const Color(0xFFC2410C);
        break;
      case 'recepcion':
        backgroundColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF475569);
        break;
      default:
        backgroundColor = const Color(0xFFF1F5F9);
        textColor = const Color(0xFF475569);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _roleLabel(role),
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            color: Color(0xFFDC2626),
          ),
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

String _roleLabel(String role) {
  switch (role) {
    case 'administrador':
      return 'Administrador';
    case 'medico':
      return 'Médico';
    case 'tecnico':
      return 'Técnico';
    case 'recepcion':
      return 'Recepción';
    default:
      return role;
  }
}
