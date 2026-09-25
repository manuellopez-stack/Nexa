import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexa/screens/validation_queue_page.dart';
import 'package:nexa/services/api_service.dart';

// Datos de ejemplo (no vienen de la base): uno de cada tipo, con textos
// largos para forzar el peor caso de ancho.
Map<String, dynamic> _queue() {
  final now = DateTime.now();
  String ago(Duration d) => now.subtract(d).toUtc().toIso8601String();
  return {
    'items': [
      {
        'tipo': 'dental',
        'id': 'd1',
        'patientId': 4,
        'patientName': 'María Fernanda de los Ángeles Pérez Sotomayor',
        'patientRut': '12345678-5',
        'titulo': 'Exodoncia simple, Destartraje y pulido coronario completo',
        'detalle': 'Realizado',
        'esIA': false,
        'desde': ago(const Duration(days: 9)),
      },
      {
        'tipo': 'documento',
        'id': 1,
        'patientId': 1,
        'patientName': 'Juan Pérez',
        'patientRut': '9876543-K',
        'titulo': 'Resonancia magnética de columna lumbosacra con contraste',
        'detalle': 'Leído y resumido por IA',
        'esIA': true,
        'desde': ago(const Duration(hours: 26)),
        'archivo': 'informe.pdf',
      },
      {
        'tipo': 'imagenologia',
        'id': 'i1',
        'patientId': 2,
        'patientName': 'Ana Rojas',
        'patientRut': null,
        'titulo': 'Radiografía de tórax AP y lateral',
        'detalle': 'Informado por Dr. Roberto Andrés González Valenzuela',
        'esIA': false,
        'desde': ago(const Duration(hours: 3)),
      },
      {
        'tipo': 'laboratorio',
        'id': 'l1',
        'patientId': 3,
        'patientName': 'Pedro Soto',
        'patientRut': '11111111-1',
        'titulo': 'Hemograma, Perfil bioquímico, Perfil lipídico',
        'detalle': 'Resultados cargados',
        'esIA': false,
        'desde': ago(const Duration(minutes: 20)),
      },
    ],
    'conteos': {
      'total': 4,
      'documento': 1,
      'laboratorio': 1,
      'imagenologia': 1,
      'dental': 1,
    },
  };
}

Map<String, dynamic> _empty() => {
  'items': <Map<String, dynamic>>[],
  'conteos': {
    'total': 0,
    'documento': 0,
    'laboratorio': 0,
    'imagenologia': 0,
    'dental': 0,
  },
};

Future<void> _pumpAt(
  WidgetTester tester,
  double width,
  Map<String, dynamic> Function() data,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ValidationQueuePage(loadQueue: () async => data()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => ApiService.debugSetRole('medico'));
  tearDown(() => ApiService.debugSetRole(null));

  for (final width in [1440.0, 1100.0, 900.0, 400.0]) {
    testWidgets('lista sin overflow a ${width.toInt()} px', (tester) async {
      await _pumpAt(tester, width, _queue);

      expect(find.text('Por validar'), findsWidgets);
      expect(
        find.text(
          '4 informes esperan revisión de un profesional · los más antiguos primero',
        ),
        findsOneWidget,
      );
      expect(find.text('Revisar'), findsNWidgets(4));
      expect(find.text('IA'), findsOneWidget);
      expect(find.textContaining('hace más de 2 h'), findsNWidgets(3));
      expect(find.textContaining('hoy '), findsWidgets);
      expect(find.textContaining('ayer '), findsWidgets);

      // Filtro: solo laboratorio.
      await tester.tap(find.text('Laboratorio').first);
      await tester.pumpAndSettle();
      expect(find.text('Revisar'), findsOneWidget);
      expect(find.text('Pedro Soto'), findsOneWidget);
    });

    testWidgets('estado vacío sin overflow a ${width.toInt()} px', (
      tester,
    ) async {
      await _pumpAt(tester, width, _empty);
      expect(
        find.text('Todo al día: no hay informes por validar.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('el ítem Por validar está en el menú (Drawer a 400 px)', (
    tester,
  ) async {
    await _pumpAt(tester, 400, _queue);
    await tester.tap(find.byTooltip('Menú'));
    await tester.pumpAndSettle();
    expect(find.text('Por validar'), findsWidgets);
    expect(find.text('Estudios sin vincular'), findsOneWidget);
  });
}
