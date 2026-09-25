import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa/widgets/correction_widgets.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('hasPendingCorrection solo con motivo', () {
    expect(hasPendingCorrection({'correctionReason': 'Falta la firma'}), isTrue);
    expect(hasPendingCorrection({'correctionReason': '  '}), isFalse);
    expect(hasPendingCorrection({'correctionReason': null}), isFalse);
    expect(hasPendingCorrection(null), isFalse);
  });

  testWidgets('el aviso muestra motivo, quién y cuándo', (tester) async {
    final at = DateTime(2026, 9, 25, 10, 30);
    await tester.pumpWidget(
      _wrap(
        CorrectionNotice(
          item: {
            'correctionReason': 'Falta la firma',
            'correctionRequestedBy': 'medica@test.cl',
            'correctionRequestedAt': at.toUtc().toIso8601String(),
          },
        ),
      ),
    );
    expect(
      find.text(
        'Devuelto para corrección: Falta la firma — medica@test.cl · 25/09/2026 10:30',
      ),
      findsOneWidget,
    );
  });

  testWidgets('sin corrección pendiente no hay aviso', (tester) async {
    await tester.pumpWidget(
      _wrap(const CorrectionNotice(item: {'correctionReason': null})),
    );
    expect(find.textContaining('Devuelto'), findsNothing);
  });

  testWidgets('el chip dice Devuelto', (tester) async {
    await tester.pumpWidget(_wrap(const ReturnedChip()));
    expect(find.text('Devuelto'), findsOneWidget);
  });

  testWidgets('el motivo es obligatorio (mínimo 5 caracteres)', (tester) async {
    String? result = 'sin respuesta';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showCorrectionReasonDialog(context),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    final submit = find.widgetWithText(FilledButton, 'Pedir corrección');

    // Vacío: no se cierra y avisa.
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('mínimo 5 caracteres'), findsOneWidget);
    expect(result, 'sin respuesta');

    // Muy corto.
    await tester.enterText(find.byType(TextField), ' abc ');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.textContaining('mínimo 5 caracteres'), findsOneWidget);

    // Válido: devuelve el motivo sin espacios de más.
    await tester.enterText(find.byType(TextField), '  Falta la firma  ');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(result, 'Falta la firma');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancelar no devuelve motivo', (tester) async {
    String? result = 'sin respuesta';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showCorrectionReasonDialog(context),
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
