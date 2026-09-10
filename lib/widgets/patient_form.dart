import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/nexa_colors.dart';
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

/// Diálogo para registrar un paciente nuevo (solo identidad).
///
/// Devuelve, vía `Navigator.pop`, el mapa del paciente creado
/// (`{id, name, rut, phone}` — misma forma que `ApiService.getPatientsList`)
/// o `null` si se cancela.
///
/// Todavía NO hay edición de ficha en la app: un error acá solo se corrige
/// a mano en Supabase.
class PatientFormDialog extends StatefulWidget {
  const PatientFormDialog({super.key});

  @override
  State<PatientFormDialog> createState() => _PatientFormDialogState();
}

class _PatientFormDialogState extends State<PatientFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _rutController = TextEditingController();
  final _ageController = TextEditingController();
  final _phoneController = TextEditingController();

  String? _sexo; // 'M' | 'F' | null

  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _rutController.dispose();
    _ageController.dispose();
    _phoneController.dispose();
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
      final patient = await ApiService.createPatient(
        name: _nameController.text.trim(),
        rut: _rutController.text.trim(),
        age: ageText.isEmpty ? null : int.tryParse(ageText),
        sexo: _sexo,
        phone: _phoneController.text.trim().isEmpty
            ? null
            : _phoneController.text.trim(),
      );
      if (mounted) Navigator.pop(context, patient);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No fue posible crear el paciente.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar paciente'),
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
                  decoration: const InputDecoration(
                    labelText: 'RUT *',
                    hintText: '12.345.678-5',
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
                const SizedBox(height: 6),
                const Text(
                  'La ficha aún no se puede editar desde la app: revisa los '
                  'datos antes de guardar.',
                  style: TextStyle(
                    fontSize: 12,
                    color: NexaColors.textSecondary,
                  ),
                ),
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
              : const Text('Crear paciente'),
        ),
      ],
    );
  }
}
