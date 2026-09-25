import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/rut_formatter.dart';
import '../services/api_service.dart';

/// Valida un RUT chileno completo (cuerpo + dígito verificador, módulo 11).
/// Devuelve `null` si es válido o un mensaje de error si no.
/// Debe mantenerse alineado con `isValidRut` en backend/server.mjs.
String? validateRut(String raw) {
  final clean = raw.toUpperCase().replaceAll(RegExp(r'[^0-9K]'), '');
  if (clean.length < 2) return 'RUT incompleto';
  final body = clean.substring(0, clean.length - 1);
  final dv = clean.substring(clean.length - 1);
  if (!RegExp(r'^\d+$').hasMatch(body)) return 'RUT inválido';

  var sum = 0;
  var multiplier = 2;
  for (var i = body.length - 1; i >= 0; i--) {
    sum += int.parse(body[i]) * multiplier;
    multiplier = multiplier == 7 ? 2 : multiplier + 1;
  }
  final remainder = 11 - (sum % 11);
  final expected =
      remainder == 11 ? '0' : (remainder == 10 ? 'K' : '$remainder');
  return dv == expected ? null : 'El dígito verificador no corresponde';
}

/// Diálogo para registrar un paciente nuevo o editar la identidad de uno
/// existente (nombre, rut, edad, sexo, teléfono, observaciones).
///
/// - `PatientFormDialog()` -> alta.
/// - `PatientFormDialog.edit(patient: ...)` -> edición; `patient` debe traer
///   al menos `id` y, si están disponibles, `name/rut/age/sexo/phone/
///   observations` (ver `ApiService.getPatientIdentity`).
///
/// Devuelve, vía `Navigator.pop`, el mapa del paciente creado/editado
/// (`{id, name, rut, age, sexo, phone, observations}`) o `null` si se
/// cancela.
class PatientFormDialog extends StatefulWidget {
  const PatientFormDialog({super.key}) : editPatient = null;

  const PatientFormDialog.edit({super.key, required Map<String, dynamic> patient})
      : editPatient = patient;

  final Map<String, dynamic>? editPatient;

  bool get isEditing => editPatient != null;

  @override
  State<PatientFormDialog> createState() => _PatientFormDialogState();
}

class _PatientFormDialogState extends State<PatientFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _rutController = TextEditingController();
  final _ageController = TextEditingController();
  final _phoneController = TextEditingController();
  final _observationsController = TextEditingController();

  String? _sexo; // 'M' | 'F' | null

  bool _isSubmitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final patient = widget.editPatient;
    if (patient != null) {
      _nameController.text = patient['name']?.toString() ?? '';
      // Fichas antiguas pueden venir con puntos: se muestran ya en el formato
      // único para que al guardar queden igual que las nuevas.
      _rutController.text = formatRut(patient['rut']?.toString());
      _ageController.text = patient['age'] == null ? '' : '${patient['age']}';
      _phoneController.text = patient['phone']?.toString() ?? '';
      _observationsController.text = patient['observations']?.toString() ?? '';
      final sexo = patient['sexo']?.toString().trim().toUpperCase();
      _sexo = (sexo == 'M' || sexo == 'F') ? sexo : null;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rutController.dispose();
    _ageController.dispose();
    _phoneController.dispose();
    _observationsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final ageText = _ageController.text.trim();
      final age = ageText.isEmpty ? null : int.tryParse(ageText);
      final name = _nameController.text.trim();
      final rut = _rutController.text.trim();
      final phone =
          _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim();
      final observations = _observationsController.text.trim().isEmpty
          ? null
          : _observationsController.text.trim();

      Map<String, dynamic> patient;
      if (widget.isEditing) {
        final id = widget.editPatient!['id'];
        patient = await ApiService.updatePatient(
          id: id is int ? id : int.parse('$id'),
          name: name,
          rut: rut,
          age: age,
          sexo: _sexo,
          phone: phone,
          observations: observations,
        );
        // El backend solo devuelve la identidad corta (id/name/rut/phone);
        // completamos con lo que el propio formulario acaba de guardar para
        // que quien llame pueda refrescar la ficha entera sin otro round-trip.
        patient = {
          ...patient,
          'age': age,
          'sexo': _sexo,
          'observations': observations,
        };
      } else {
        patient = await ApiService.createPatient(
          name: name,
          rut: rut,
          age: age,
          sexo: _sexo,
          phone: phone,
          observations: observations,
        );
      }
      if (mounted) Navigator.pop(context, patient);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.isEditing
              ? 'No fue posible actualizar el paciente.'
              : 'No fue posible crear el paciente.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? 'Editar ficha' : 'Registrar paciente'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nombre completo *',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'El nombre es obligatorio'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _rutController,
                  keyboardType: TextInputType.text,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  inputFormatters: const [RutInputFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'RUT *',
                    hintText: kRutHint,
                    helperText: kRutHelper,
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty) return 'El RUT es obligatorio';
                    return validateRut(text);
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _ageController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(3),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Edad',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final text = value?.trim() ?? '';
                          if (text.isEmpty) return null;
                          final n = int.tryParse(text);
                          if (n == null || n < 0 || n > 130) {
                            return 'Edad entre 0 y 130';
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _sexo,
                        decoration: const InputDecoration(
                          labelText: 'Sexo',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'F', child: Text('Femenino')),
                          DropdownMenuItem(value: 'M', child: Text('Masculino')),
                        ],
                        onChanged: (value) => setState(() => _sexo = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono',
                    hintText: '+56 9 1234 5678',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _observationsController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Observaciones',
                    border: OutlineInputBorder(),
                  ),
                ),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
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
              : Text(widget.isEditing ? 'Guardar cambios' : 'Crear paciente'),
        ),
      ],
    );
  }
}
