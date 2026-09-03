import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// Prepara el HTML de un correo real para que `flutter_html` pueda
/// renderizarlo sin romperse. Los correos corporativos/marketing casi
/// siempre usan layouts de tabla y hacks pensados para Outlook/navegadores,
/// que el motor de `flutter_html` no soporta bien:
/// - `<table>/<tr>/<td>` sin la extensión de tablas simplemente se descartan
///   (todo el contenido dentro de ellas desaparece), así que se "aplanan"
///   a `<div>` para conservar el texto e imágenes en orden de lectura.
/// - Bloques `<style>` con `@media` disparan un bug del parser CSS del
///   paquete (`LateInitializationError` o valores corruptos), así que se
///   quitan (el contenido real ya usa estilos inline, práctica estándar
///   en HTML de correos).
/// - Comentarios condicionales exclusivos de Outlook (`<!--[if mso]>...`)
///   se eliminan; los correos web/no-Outlook no deben verlos.
/// - Anchos/altos en porcentaje (`width:50%`, `height:100%`) producen
///   `NaN`/valores negativos en el cálculo intrínseco de tamaño del
///   paquete, así que se normalizan a `auto`.
/// - `font-size:0` es un truco de maquetación (colapsar el espacio en blanco
///   entre celdas/inline-blocks). `flutter_html` lo hereda al calcular el
///   ancho del bloque y el párrafo se dispone en una sola línea larguísima
///   que queda recortada fuera del contenedor: el cuerpo se ve "vacío". Se
///   quita.
/// - `line-height` con unidad absoluta (`18px`, `8px`, `1.2pt`) no lo entiende
///   `flutter_html` (lo interpreta como `null`) e infla cada línea a cientos
///   de píxeles, dejando el texto perdido entre huecos enormes. Solo se quitan
///   esas: los valores sin unidad (`1`, `1.4`) y `%` sí se respetan porque el
///   paquete los maneja bien, así no se altera el interlineado de los correos
///   que ya se veían correctos.
String _prepararHtmlCorreo(String html) {
  var resultado = html.replaceAll(
    RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
    '',
  );
  resultado = resultado.replaceAll(
    RegExp(r'<!--\[if\s+(?!!)[^\]]*\][\s\S]*?<!\[endif\]-->',
        caseSensitive: false),
    '',
  );
  resultado = resultado.replaceAllMapped(
    RegExp(r'<(/?)(table|tbody|thead|tfoot|tr|td|th)(\s[^>]*)?>',
        caseSensitive: false),
    (match) => '<${match.group(1)}div>',
  );
  resultado = resultado.replaceAllMapped(
    RegExp(r'(width|height)\s*:\s*\d+%', caseSensitive: false),
    (match) => '${match.group(1)}:auto',
  );
  resultado = resultado.replaceAll(
    RegExp(r'(?<![\w-])font-size\s*:\s*0(?![\d.])[a-z%]*\s*;?',
        caseSensitive: false),
    '',
  );
  resultado = resultado.replaceAll(
    RegExp(r'(?<![\w-])line-height\s*:\s*\d[\d.]*\s*(?:px|pt|pc|cm|mm|in|ex|ch)\b[^;"]*;?',
        caseSensitive: false),
    '',
  );
  return resultado;
}

/// Ícono estático que reemplaza a una imagen que no se puede mostrar.
const Widget _iconoImagenCorreo = Icon(
  Icons.image_outlined,
  size: 20,
  color: NexaColors.textSecondary,
);

/// Reemplaza el manejo por defecto de `<img>` de `flutter_html` para las
/// imágenes remotas (no afecta imágenes embebidas en base64/assets).
///
/// El backend ya reescribió cada imagen remota del correo para que apunte a
/// su propio proxy (`/gmail/image-proxy`), que las descarga server-to-server
/// y las devuelve con los headers CORS correctos. Así que:
/// - Si el `src` apunta al backend de Nexa, se carga con `Image.network`
///   (acotada en ancho para que nunca desborde el contenedor). Si la
///   descarga falla —la fuente sigue bloqueando, error de red, referencia
///   expirada—, `errorBuilder` cae al ícono: imagen oculta sin romper el
///   layout.
/// - Cualquier otro `src` remoto (no debería ocurrir tras la reescritura,
///   pero por si el backend no la aplicó) se muestra directamente como ícono,
///   sin intentar la petición de red: un `<img>` a un CDN de terceros
///   bloqueado por CORS puede lanzar un error de *layout* que tumba el
///   párrafo completo donde está anidado, perdiendo también el texto vecino.
final HtmlExtension _imagenToleranteCorreo = ImageExtension(
  handleAssetImages: false,
  handleDataImages: false,
  builder: (context) {
    final src = context.attributes['src'] ?? '';
    if (!ApiService.esUrlDeBackend(src)) {
      return _iconoImagenCorreo;
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: Image.network(
        src,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _iconoImagenCorreo,
        loadingBuilder: (_, child, progreso) =>
            progreso == null ? child : _iconoImagenCorreo,
      ),
    );
  },
);

/// Renderiza el cuerpo de un correo real: HTML (ya normalizado y con
/// imágenes remotas reescritas por el backend) o, si no hay HTML, el texto
/// plano. Punto único de renderizado para que la campanita de notificaciones
/// y la sección "Correo" se vean y se comporten igual.
class EmailBodyView extends StatefulWidget {
  const EmailBodyView({
    super.key,
    required this.cuerpoHtml,
    required this.cuerpoTexto,
    this.fontSize = 13.5,
  });

  final String cuerpoHtml;
  final String cuerpoTexto;
  final double fontSize;

  @override
  State<EmailBodyView> createState() => _EmailBodyViewState();
}

class _EmailBodyViewState extends State<EmailBodyView> {
  late final ErrorWidgetBuilder _errorWidgetBuilderPrevio;

  @override
  void initState() {
    super.initState();
    // Algunas plantillas de correo (marketing/transaccionales muy complejas)
    // tienen HTML que hace fallar el renderizador de flutter_html incluso
    // tras normalizarlo. Mientras este widget está montado, reemplazamos la
    // pantalla de error por defecto de Flutter con el texto plano del
    // correo, para no dejar la vista en blanco/rota.
    _errorWidgetBuilderPrevio = ErrorWidget.builder;
    ErrorWidget.builder = (details) => _buildCuerpoTextoPlano();
  }

  @override
  void dispose() {
    ErrorWidget.builder = _errorWidgetBuilderPrevio;
    super.dispose();
  }

  Widget _buildCuerpoTextoPlano() {
    final texto = widget.cuerpoTexto.trim();
    if (texto.isEmpty) {
      return const Text(
        'Este correo no tiene contenido para mostrar.',
        style: TextStyle(color: NexaColors.textSecondary),
      );
    }

    return SelectableText(
      texto,
      style: TextStyle(
        fontSize: widget.fontSize,
        color: NexaColors.textPrimary,
        height: 1.5,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final html = widget.cuerpoHtml.trim();
    if (html.isEmpty) return _buildCuerpoTextoPlano();

    return Html(
      data: _prepararHtmlCorreo(html),
      extensions: [_imagenToleranteCorreo],
      style: {
        'body': Style(
          margin: Margins.zero,
          padding: HtmlPaddings.zero,
          fontSize: FontSize(widget.fontSize),
          color: NexaColors.textPrimary,
          lineHeight: LineHeight.number(1.5),
        ),
        'a': Style(
          color: NexaColors.primary,
          textDecoration: TextDecoration.underline,
        ),
      },
    );
  }
}
