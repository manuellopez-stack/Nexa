import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../core/rut_formatter.dart';
import '../services/api_service.dart';
import 'patient_form.dart';

/// Diálogo reutilizable para elegir un paciente existente (o registrar uno
/// nuevo), buscando por nombre o RUT. Devuelve el paciente elegido
/// (`{id, name, rut, ...}`) al hacer `Navigator.pop(context, patient)`, o
/// `null` si se cancela.
///
/// Extraído de appointments_page.dart (donde se usa para elegir a quién se
/// le agenda una cita) para reutilizarlo también en el vínculo manual de
/// estudios de Orthanc.
class PatientPickerDialog extends StatefulWidget {
  const PatientPickerDialog({super.key});

  @override
  State<PatientPickerDialog> createState() => _PatientPickerDialogState();
}

class _PatientPickerDialogState extends State<PatientPickerDialog> {
  final _searchController = TextEditingController();
  late Future<List<Map<String, dynamic>>> _future;
  List<Map<String, dynamic>> _all = [];

  @override
  void initState() {
    super.initState();
    _future = _loadInitial();
  }

  Future<List<Map<String, dynamic>>> _loadInitial() async {
    _all = await ApiService.getPatientsList();
    return _all;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createNewPatient() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const PatientFormDialog(),
    );
    // El formulario ya deduplicó y validó; si devolvió un paciente, lo
    // seleccionamos y cerramos el picker.
    if (created != null && mounted) {
      Navigator.pop(context, created);
    }
  }

  Future<void> _editPatient(Map<String, dynamic> row) async {
    final id = row['id'];
    if (id is! int) return;

    Map<String, dynamic> identity;
    try {
      identity = await ApiService.getPatientIdentity(id);
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No fue posible cargar la ficha del paciente.')),
        );
      }
      return;
    }

    if (!mounted) return;
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PatientFormDialog.edit(patient: identity),
    );

    // Solo refrescamos la fila en el picker (nombre/rut visibles); no cierra
    // el picker, para que se pueda seguir eligiendo un paciente.
    if (updated != null && mounted) {
      setState(() {
        final index = _all.indexWhere((patient) => patient['id'] == id);
        if (index != -1) _all[index] = {..._all[index], ...updated};
      });
    }
  }

  // Parece un RUT si no tiene letras salvo la K (dígitos, puntos, guion,
  // espacios) y al menos un dígito: '12.345.678-5', '12345678-5', '123456785'.
  static final _rutLikeQuery = RegExp(r'^[0-9kK.\-\s]+$');

  List<Map<String, dynamic>> get _filtered {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _all;
    final rutQuery = _rutLikeQuery.hasMatch(query) && RegExp(r'\d').hasMatch(query)
        ? normalizeRut(query)
        : null;
    return _all.where((patient) {
      final name = patient['name']?.toString().toLowerCase() ?? '';
      if (name.contains(query)) return true;
      final rut = patient['rut']?.toString();
      // Con un RUT se compara sin puntos ni guion, para encontrar la ficha
      // escriba como se escriba (y aunque se haya guardado con puntos).
      if (rutQuery != null) return normalizeRut(rut).contains(rutQuery);
      return (rut ?? '').toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Elegir paciente'),
      content: SizedBox(
        width: 420,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Buscar por nombre o RUT',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Center(
                      child: Text('No fue posible cargar los pacientes.'),
                    );
                  }

                  final patients = _filtered;
                  if (patients.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Sin pacientes que coincidan.'),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _createNewPatient,
                            icon: const Icon(Icons.person_add_alt, size: 18),
                            label: const Text('Registrar paciente'),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    itemCount: patients.length,
                    itemBuilder: (context, index) {
                      final patient = patients[index];
                      final name = patient['name']?.toString() ?? 'Sin nombre';
                      final rut = patient['rut']?.toString() ?? '';
                      return ListTile(
                        dense: true,
                        title: Text(name),
                        subtitle: rut.isEmpty ? null : Text(rut),
                        trailing: IconButton(
                          tooltip: 'Editar ficha',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _editPatient(patient),
                        ),
                        onTap: () => Navigator.pop(context, patient),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _createNewPatient,
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('Paciente nuevo'),
          style: FilledButton.styleFrom(backgroundColor: NexaColors.primary),
        ),
      ],
    );
  }
}
