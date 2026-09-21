import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../widgets/milmed_brand_mark.dart';

class ClinicsPage extends StatefulWidget {
  const ClinicsPage({super.key});

  @override
  State<ClinicsPage> createState() => _ClinicsPageState();
}

class _ClinicsPageState extends State<ClinicsPage> {
  late Future<List<Map<String, dynamic>>> _clinicsFuture;

  @override
  void initState() {
    super.initState();
    _clinicsFuture = _load();
  }

  Future<List<Map<String, dynamic>>> _load() {
    return ApiService.getClinics();
  }

  void _reload() {
    setState(() {
      _clinicsFuture = _load();
    });
  }

  Future<void> _openAddDialog() async {
    final created = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (_) => const _AddClinicDialog(),
    );

    if (created == null) return;

    _reload();

    final orthancSetup = created['orthancSetup'];
    if (orthancSetup is Map<String, dynamic> && mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => _OrthancSetupDialog(orthancSetup: orthancSetup),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexaColors.background,
      appBar: AppBar(
        backgroundColor: NexaColors.surface,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MilmedBrandMark(),
            SizedBox(width: 12),
            Text(
              'Clínicas',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: NexaColors.textPrimary,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _openAddDialog,
              icon: const Icon(Icons.add_business_outlined, size: 18),
              label: const Text('Agregar clínica'),
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
                        Icons.local_hospital_outlined,
                        color: NexaColors.primary,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Clínicas de Imagenda',
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
                    'Cada clínica tiene su propio AE Title y puerto DICOM en Orthanc.',
                    style: TextStyle(color: NexaColors.textSecondary),
                  ),
                  const SizedBox(height: 22),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _clinicsFuture,
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
                              : 'No fue posible cargar las clínicas.',
                          onRetry: _reload,
                        );
                      }

                      final clinics = snapshot.data ?? [];

                      if (clinics.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('Todavía no hay clínicas registradas.'),
                        );
                      }

                      return Column(
                        children: clinics
                            .map((clinic) => _ClinicTile(clinic: clinic))
                            .toList(),
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

class _ClinicTile extends StatelessWidget {
  const _ClinicTile({required this.clinic});

  final Map<String, dynamic> clinic;

  @override
  Widget build(BuildContext context) {
    final name = clinic['name']?.toString() ?? '';
    final address = clinic['address']?.toString().trim() ?? '';
    final status = clinic['status']?.toString() ?? '';
    final aeTitle = clinic['dicomAeTitle']?.toString() ?? '—';
    final port = clinic['dicomPort']?.toString() ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
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
                Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    address,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _StatusBadge(status: status),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                aeTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'Puerto $port',
                style: const TextStyle(
                  fontSize: 12,
                  color: NexaColors.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final isActive = status == 'activa';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFDCFCE7) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.isEmpty ? '—' : status,
        style: TextStyle(
          color: isActive ? const Color(0xFF15803D) : const Color(0xFF475569),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _AddClinicDialog extends StatefulWidget {
  const _AddClinicDialog();

  @override
  State<_AddClinicDialog> createState() => _AddClinicDialogState();
}

class _AddClinicDialogState extends State<_AddClinicDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();

    if (name.isEmpty || _isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final result = await ApiService.createClinic(
        name: name,
        address: address.isEmpty ? null : address,
      );
      if (mounted) Navigator.pop(context, result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No fue posible crear la clínica.');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _nameController.text.trim();
    final canSubmit = name.isNotEmpty && !_isSubmitting;

    return AlertDialog(
      title: const Text('Agregar clínica'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Nombre de la clínica',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Dirección (opcional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'El AE Title y el puerto DICOM se asignan automáticamente.',
              style: TextStyle(fontSize: 12, color: NexaColors.textSecondary),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
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
              : const Text('Crear'),
        ),
      ],
    );
  }
}

/// Diálogo que muestra el bloque de configuración de Orthanc que devuelve el
/// backend al crear una clínica. Todavía no hay ninguna automatización que
/// toque el droplet: este bloque hay que aplicarlo a mano por SSH.
class _OrthancSetupDialog extends StatelessWidget {
  const _OrthancSetupDialog({required this.orthancSetup});

  final Map<String, dynamic> orthancSetup;

  @override
  Widget build(BuildContext context) {
    final aeTitle = orthancSetup['aeTitle']?.toString() ?? '';
    final port = orthancSetup['port']?.toString() ?? '';
    final internalPort = orthancSetup['internalPort']?.toString() ?? '';
    final label = orthancSetup['label']?.toString() ?? '';
    final serverConfig = orthancSetup['serverConfig']?.toString() ?? '';
    final stunnelConfig = orthancSetup['stunnelConfig']?.toString() ?? '';
    final instructions = orthancSetup['instructions']?.toString() ?? '';

    return AlertDialog(
      title: const Text('Configuración para Orthanc'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFED7AA)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFFC2410C), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Esta configuración todavía no se aplica sola: hay que '
                        'pegarla a mano en el droplet por SSH.',
                        style: TextStyle(fontSize: 12.5, color: Color(0xFF9A3412)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _SetupField(label: 'AE Title', value: aeTitle),
              _SetupField(label: 'Puerto público', value: port),
              _SetupField(label: 'Puerto interno (Orthanc)', value: internalPort),
              _SetupField(label: 'Label (clinic_id)', value: label),
              const SizedBox(height: 10),
              const Text(
                'Bloque para el array "Servers" de multitenant.json',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NexaColors.textPrimary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  serverConfig,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Bloque para /etc/stunnel/imagenda-<nombre>.conf',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NexaColors.textPrimary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  stunnelConfig,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (instructions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  instructions,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: NexaColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: serverConfig));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Bloque de Orthanc copiado al portapapeles.')),
              );
            }
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copiar bloque Orthanc'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: stunnelConfig));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Bloque de stunnel copiado al portapapeles.')),
              );
            }
          },
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copiar bloque stunnel'),
        ),
      ],
    );
  }
}

class _SetupField extends StatelessWidget {
  const _SetupField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: NexaColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
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
