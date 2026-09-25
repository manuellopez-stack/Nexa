import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';
import '../services/browser_download.dart';

/// "Descargar para DVD": ZIP del estudio con DICOMDIR, visor Weasis para
/// Windows, autorun.inf y LEAME.txt, listo para grabar. Lo arma el backend
/// (GET `/dvd-downloads/<token>`, ver backend/dvdExport.mjs); acá solo se pide
/// el enlace firmado y se le pasa al navegador para que lo baje.
///
/// Muestra "Preparando descarga…" mientras el backend responde (la primera
/// vez tarda más: descarga el visor).
Future<void> downloadStudyForDvd(
  BuildContext context, {
  required int patientId,
  required String orderId,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  // showDialog usa el navegador raíz: se cierra con ese mismo.
  final navigator = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PointerInterceptor(
      child: const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Preparando descarga…')),
          ],
        ),
      ),
    ),
  );

  String message;
  try {
    final link = await ApiService.prepareDvdDownload(
      patientId: patientId,
      orderId: orderId,
    );
    final started = startBrowserDownload(
      link['url'] as String,
      filename: link['filename']?.toString(),
    );
    if (!started) {
      message = 'La descarga para DVD solo está disponible en la versión web '
          'de Imagenda.';
    } else if (link['viewerIncluded'] == true) {
      message = 'Descarga iniciada: ${link['filename']}';
    } else {
      message = 'Descarga iniciada: ${link['filename']}. Esta vez el visor no '
          'va incluido (el LEAME del disco lo explica).';
    }
  } on ApiException catch (error) {
    message = error.message;
  } catch (_) {
    message = 'No fue posible preparar la descarga para DVD.';
  }

  navigator.pop();
  messenger?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
  );
}

/// Ayuda "Cómo grabar el DVD" (Windows).
Future<void> showDvdBurnHelp(BuildContext context) {
  const steps = [
    'Descargar el archivo.',
    'Clic derecho sobre el archivo descargado > Extraer todo.',
    'Insertar un DVD en blanco.',
    'Seleccionar todo el contenido de la carpeta extraída (no la carpeta '
        'misma), clic derecho > Enviar a > la unidad de DVD.',
    "En la unidad de DVD, 'Grabar en disco'.",
    "Probar el disco: al insertarlo debe ofrecer 'Abrir imágenes'.",
  ];

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => PointerInterceptor(
      child: AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.album_outlined, color: NexaColors.primary),
            SizedBox(width: 10),
            Text('Cómo grabar el DVD'),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'En Windows:',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '${i + 1})',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(
                        child: Text(steps[i], style: const TextStyle(height: 1.35)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Entendido'),
          ),
        ],
      ),
    ),
  );
}

/// Botón "Descargar para DVD" con el enlace "Cómo grabar el DVD" al lado.
/// No se muestra si el rol no tiene el permiso.
class DvdDownloadButton extends StatelessWidget {
  const DvdDownloadButton({
    super.key,
    required this.patientId,
    required this.orderId,
  });

  final int patientId;
  final String orderId;

  @override
  Widget build(BuildContext context) {
    if (!ApiService.canDownloadDvd) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: () => downloadStudyForDvd(
            context,
            patientId: patientId,
            orderId: orderId,
          ),
          icon: const Icon(Icons.album_outlined, size: 18),
          label: const Text('Descargar para DVD'),
        ),
        TextButton(
          onPressed: () => showDvdBurnHelp(context),
          child: const Text('Cómo grabar el DVD'),
        ),
      ],
    );
  }
}

/// Orden de imagenología a bajar para DVD (paciente + orden).
typedef DvdOrderRef = ({int patientId, String orderId});

/// Estudios del paciente que se pueden bajar para DVD, cada uno con su
/// botón. Es la pestaña "Imágenes" de recepción, que no ve la ficha clínica
/// (GET /patients/:id/dvd-studies: solo fecha, tipo de examen y N° de acceso).
class DvdStudiesList extends StatefulWidget {
  const DvdStudiesList({super.key, required this.patientId});

  final int? patientId;

  @override
  State<DvdStudiesList> createState() => _DvdStudiesListState();
}

class _DvdStudiesListState extends State<DvdStudiesList> {
  late Future<List<Map<String, dynamic>>> _studiesFuture = _load();

  Future<List<Map<String, dynamic>>> _load() {
    final patientId = widget.patientId;
    if (patientId == null) {
      return Future.error(
        const ApiException('El paciente no tiene un identificador válido.'),
      );
    }
    return ApiService.getDvdStudies(patientId);
  }

  static String _formatDate(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return 'Sin fecha';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}-${two(date.month)}-${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _studiesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is ApiException
                    ? error.message
                    : 'No fue posible cargar los estudios.',
                style: const TextStyle(
                  color: Color(0xFFB91C1C),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => setState(() => _studiesFuture = _load()),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          );
        }

        final studies = snapshot.data ?? [];
        final patientId = widget.patientId;
        if (studies.isEmpty || patientId == null) {
          return const Text(
            'Este paciente no tiene estudios con imágenes para grabar.',
            style: TextStyle(color: NexaColors.textSecondary),
          );
        }

        return ListView.separated(
          itemCount: studies.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final study = studies[index];
            final types = (study['examTypes'] as List? ?? []).join(', ');
            final accession = study['accessionNumber']?.toString() ?? '';
            final imageCount = study['imageCount'];

            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: NexaColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NexaColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    types.isEmpty ? 'Estudio de imagenología' : types,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      _formatDate(study['examDate']),
                      if (accession.isNotEmpty) 'N° de acceso: $accession',
                      if (imageCount is int)
                        imageCount == 1 ? '1 imagen' : '$imageCount imágenes',
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: NexaColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DvdDownloadButton(
                    patientId: patientId,
                    orderId: study['orderId'].toString(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
