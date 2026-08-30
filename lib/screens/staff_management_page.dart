import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

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

class _StaffManagementPageState extends State<StaffManagementPage> {
  late Future<List<Map<String, dynamic>>> _staffFuture;
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _staffFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    return ApiService.getStaff();
  }

  void _reload() {
    setState(() {
      _staffFuture = _load();
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _openInviteDialog() async {
    final invited = await showDialog<bool>(
      context: context,
      builder: (_) => const _InviteStaffDialog(),
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
      appBar: AppBar(
        backgroundColor: NexaColors.surface,
        title: const Text(
          'Gestión de equipo',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: NexaColors.textPrimary,
          ),
        ),
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
                      const Expanded(
                        child: Text(
                          'Personal de Nexa',
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
                  const SizedBox(height: 6),
                  const Text(
                    'Administra quién tiene acceso a Nexa y con qué rol.',
                    style: TextStyle(color: NexaColors.textSecondary),
                  ),
                  const SizedBox(height: 22),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _staffFuture,
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

                      final staff = snapshot.data ?? [];

                      if (staff.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('Todavía no hay personas invitadas.'),
                        );
                      }

                      return Column(
                        children: staff.map((member) {
                          final id = member['id']?.toString() ?? '';

                          return _StaffTile(
                            member: member,
                            isDeleting: _deletingId == id,
                            onEditRole: () => _openEditRoleDialog(member),
                            onDelete: () => _deleteMember(member),
                          );
                        }).toList(),
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

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: NexaColors.background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onEditRole,
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
            ),
          ),
        ),
      ),
    );
  }
}

class _InviteStaffDialog extends StatefulWidget {
  const _InviteStaffDialog();

  @override
  State<_InviteStaffDialog> createState() => _InviteStaffDialogState();
}

class _InviteStaffDialogState extends State<_InviteStaffDialog> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  String _role = _kStaffRoles.first;
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final fullName = _fullNameController.text.trim();

    if (email.isEmpty || fullName.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await ApiService.inviteStaff(
        email: email,
        fullName: fullName,
        role: _role,
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
    final canSubmit = email.isNotEmpty && fullName.isNotEmpty && !_isSubmitting;

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
