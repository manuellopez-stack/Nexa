import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa/core/rut_formatter.dart';

// Simula lo que hace un TextField: aplica el formatter sobre el valor nuevo.
TextEditingValue _apply(String oldText, String newText, {int? cursor}) {
  return const RutInputFormatter().formatEditUpdate(
    TextEditingValue(
      text: oldText,
      selection: TextSelection.collapsed(offset: oldText.length),
    ),
    TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: cursor ?? newText.length),
    ),
  );
}

void main() {
  group('RutInputFormatter: escribir o pegar', () {
    final cases = {
      '123456785': '12345678-5',
      '12.345.678-5': '12345678-5',
      '9876543k': '9876543-K',
      '1': '1',
      '12': '1-2',
      ' 12 345 678 5 ': '12345678-5',
      '1234567890': '12345678-9', // máximo 9 caracteres sin el guion
    };
    cases.forEach((input, expected) {
      test("'$input' -> '$expected' con el cursor al final", () {
        final result = _apply('', input);
        expect(result.text, expected);
        expect(result.selection.baseOffset, expected.length);
      });
    });

    test('escribir carácter por carácter deja el cursor al final', () {
      var value = '';
      for (final char in '123456785'.split('')) {
        final result = _apply(value, value + char);
        expect(result.selection.baseOffset, result.text.length);
        value = result.text;
      }
      expect(value, '12345678-5');
    });
  });

  group('RutInputFormatter: borrar', () {
    test('borrar el último carácter mueve el guion y deja el cursor al final', () {
      final result = _apply('12345678-5', '12345678-');
      expect(result.text, '1234567-8');
      expect(result.selection.baseOffset, result.text.length);
    });

    test('borrar en medio no hace saltar el cursor', () {
      // '12345678-5' con el cursor detrás del '4' (offset 4) y backspace:
      // queda '1235678-5' y el cursor detrás del '3' (offset 3).
      final result = _apply('12345678-5', '1235678-5', cursor: 3);
      expect(result.text, '1235678-5');
      expect(result.selection.baseOffset, 3);
    });

    test('borrar el guion no rompe el formato', () {
      // Cursor detrás del '8' (offset 8) tras borrar el guion.
      final result = _apply('12345678-5', '123456785', cursor: 8);
      expect(result.text, '12345678-5');
      expect(result.selection.baseOffset, 8);
    });

    test('borrar hasta quedar con 1 carácter quita el guion', () {
      final result = _apply('1-2', '1-');
      expect(result.text, '1');
      expect(result.selection.baseOffset, 1);
    });
  });

  test('normalizeRut compara igual con o sin puntos y guion', () {
    expect(normalizeRut('12.345.678-5'), '123456785');
    expect(normalizeRut('12345678-5'), '123456785');
    expect(normalizeRut('123456785'), '123456785');
    expect(normalizeRut('9.876.543-k'), '9876543K');
  });
}
