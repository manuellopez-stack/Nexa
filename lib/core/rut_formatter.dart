import 'package:flutter/services.dart';

/// Largo máximo de un RUT sin puntos ni guion (8 dígitos de cuerpo + DV).
const int kRutMaxChars = 9;

/// Texto de ayuda común a todos los campos de RUT.
const String kRutHint = '12345678-5';
const String kRutHelper = 'Sin puntos y con guion. Ej: 12345678-5';

/// Deja solo dígitos y K (en mayúscula): '12.345.678-k' -> '12345678K'.
/// Mismo criterio que `normalizeRut` en backend/server.mjs.
String normalizeRut(String? value) =>
    (value ?? '').toUpperCase().replaceAll(RegExp(r'[^0-9K]'), '');

/// Formato canónico: sin puntos, con guion antes del dígito verificador y K
/// en mayúscula ('12.345.678-5' -> '12345678-5'). Con menos de 2 caracteres
/// no hay guion ('1' -> '1'). Igual a `formatRutCanonical` del backend.
String formatRut(String? value) {
  var clean = normalizeRut(value);
  if (clean.length > kRutMaxChars) clean = clean.substring(0, kRutMaxChars);
  if (clean.length < 2) return clean;
  return '${clean.substring(0, clean.length - 1)}-${clean.substring(clean.length - 1)}';
}

/// Da formato de RUT mientras se escribe o se pega: quita puntos, espacios y
/// cualquier otro carácter, pone la K en mayúscula, limita a 9 caracteres e
/// inserta el guion antes del último.
///
/// El cursor se mantiene detrás del mismo carácter en que estaba: al escribir
/// al final queda al final, y al borrar en medio no salta.
class RutInputFormatter extends TextInputFormatter {
  const RutInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = formatRut(newValue.text);
    final clean = normalizeRut(formatted);

    // Cuántos caracteres válidos quedan antes del cursor.
    final cursor = newValue.selection.isValid
        ? newValue.selection.end.clamp(0, newValue.text.length)
        : newValue.text.length;
    var validBefore = normalizeRut(newValue.text.substring(0, cursor)).length;
    if (validBefore > clean.length) validBefore = clean.length;

    // En el texto con formato, el guion va justo antes del último carácter:
    // si el cursor queda detrás del dígito verificador hay que sumarlo.
    final offset = (clean.length >= 2 && validBefore == clean.length)
        ? formatted.length
        : validBefore;

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
