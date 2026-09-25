import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa/services/api_service.dart';
import 'package:nexa/widgets/dvd_download.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  tearDown(() => ApiService.debugSetRole(null));

  testWidgets('el botón se ve para personal clínico y recepción', (tester) async {
    for (final role in ['administrador', 'medico', 'tecnico', 'recepcion']) {
      ApiService.debugSetRole(role);
      await tester.pumpWidget(
        _wrap(const DvdDownloadButton(patientId: 1, orderId: 'io-1')),
      );
      expect(find.text('Descargar para DVD'), findsOneWidget, reason: role);
      expect(find.byIcon(Icons.album_outlined), findsOneWidget, reason: role);
      expect(find.text('Cómo grabar el DVD'), findsOneWidget, reason: role);
    }
  });

  testWidgets('sin permiso no se muestra', (tester) async {
    ApiService.debugSetRole(null);
    await tester.pumpWidget(
      _wrap(const DvdDownloadButton(patientId: 1, orderId: 'io-1')),
    );
    expect(find.text('Descargar para DVD'), findsNothing);
  });

  testWidgets('la ayuda muestra los 6 pasos para Windows', (tester) async {
    ApiService.debugSetRole('recepcion');
    await tester.pumpWidget(
      _wrap(const DvdDownloadButton(patientId: 1, orderId: 'io-1')),
    );
    await tester.tap(find.text('Cómo grabar el DVD'));
    await tester.pumpAndSettle();

    expect(find.text('Descargar el archivo.'), findsOneWidget);
    expect(find.textContaining('Extraer todo'), findsOneWidget);
    expect(find.textContaining('(no la carpeta'), findsOneWidget);
    expect(find.textContaining('Grabar en disco'), findsOneWidget);
    expect(find.textContaining("'Abrir imágenes'"), findsOneWidget);
    expect(find.text('6)'), findsOneWidget);
  });
}
