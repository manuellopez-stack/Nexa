import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/nexa_colors.dart';
import '../services/api_service.dart';

/// Barra superior común de Imagenda: logo a la izquierda, título centrado
/// respecto del ancho total de la barra y, a la derecha, las acciones de la
/// pantalla seguidas de la "credencial" de la clínica (logo, nombre y correo).
///
/// Responsivo:
///   - < 1000 px: se ocultan el subtítulo y el texto de la credencial.
///   - < 700 px: el título va a la izquierda después del logo, y el logo de
///     Imagenda muestra solo el símbolo.
class ImagendaAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ImagendaAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  static const double _height = 72;

  static const TextStyle _titleStyle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: NexaColors.textPrimary,
  );

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Size get preferredSize => const Size.fromHeight(_height);

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.canPop(context);

    return Material(
      color: NexaColors.surface,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: NexaColors.border)),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final wide = width >= 1000;
                final centered = width >= 700;

                final padLeft = canPop ? 4.0 : 20.0;
                const padRight = 12.0;

                return Padding(
                  padding: EdgeInsets.only(left: padLeft, right: padRight),
                  child: CustomMultiChildLayout(
                    delegate: _AppBarLayout(
                      centerTitle: centered,
                      centerShift: (padRight - padLeft) / 2,
                      titleWidth: _textWidth(context, title, _titleStyle),
                    ),
                    children: [
                      LayoutId(
                        id: _Slot.leading,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (canPop) ...[
                              const BackButton(color: NexaColors.textSecondary),
                              const SizedBox(width: 4),
                            ],
                            Image.asset(
                              centered
                                  ? 'assets/images/imagenda_logo.png'
                                  : 'assets/images/imagenda_simbolo.png',
                              height: centered ? 34 : 30,
                            ),
                          ],
                        ),
                      ),
                      LayoutId(
                        id: _Slot.title,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: centered
                              ? CrossAxisAlignment.center
                              : CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _titleStyle,
                            ),
                            if (wide && subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: NexaColors.textSecondary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      LayoutId(
                        id: _Slot.trailing,
                        // Red de seguridad: si en pantallas muy angostas las
                        // acciones no caben, se achican en vez de desbordar.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ...?actions,
                              const SizedBox(width: 8),
                              _ClinicBadge(showText: wide),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

enum _Slot { leading, title, trailing }

/// Ubica el título centrado respecto del ancho total (como en un Stack), pero
/// lo corre lo justo para no montarse sobre el logo ni sobre las acciones, y
/// le da como máximo el espacio libre entre ambos (con ellipsis si no cabe).
class _AppBarLayout extends MultiChildLayoutDelegate {
  _AppBarLayout({
    required this.centerTitle,
    required this.centerShift,
    required this.titleWidth,
  });

  final bool centerTitle;

  /// Corrección para centrar respecto del ancho total de la barra y no del
  /// área interior (el padding izquierdo y derecho no son iguales).
  final double centerShift;

  /// Ancho natural del título (medido con TextPainter: un delegate no puede
  /// hacer layout de un hijo dos veces).
  final double titleWidth;

  static const double _gap = 16;
  static const double _minTitleWidth = 130;

  @override
  void performLayout(Size size) {
    final leading = layoutChild(_Slot.leading, BoxConstraints.loose(size));
    final left = leading.width + _gap;

    // El título tiene prioridad sobre las acciones hasta _minTitleWidth: si
    // no cabe todo, primero se achican las acciones (FittedBox) y recién
    // después el título pasa a ellipsis.
    final titleReserve = math.min(titleWidth, _minTitleWidth);

    final trailing = layoutChild(
      _Slot.trailing,
      BoxConstraints.loose(
        Size(math.max(0, size.width - left - _gap - titleReserve), size.height),
      ),
    );

    final right = size.width - trailing.width - _gap;
    final title = layoutChild(
      _Slot.title,
      BoxConstraints.loose(Size(math.max(0, right - left), size.height)),
    );

    final titleX = centerTitle
        ? ((size.width - title.width) / 2 + centerShift)
              .clamp(left, math.max(left, right - title.width))
              .toDouble()
        : left;

    positionChild(_Slot.leading, Offset(0, (size.height - leading.height) / 2));
    positionChild(
      _Slot.title,
      Offset(titleX, (size.height - title.height) / 2),
    );
    positionChild(
      _Slot.trailing,
      Offset(size.width - trailing.width, (size.height - trailing.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_AppBarLayout oldDelegate) =>
      oldDelegate.centerTitle != centerTitle ||
      oldDelegate.centerShift != centerShift ||
      oldDelegate.titleWidth != titleWidth;
}

/// Credencial de la clínica de quien está conectado: logo en un cuadro blanco
/// y, en pantallas anchas, el nombre de la clínica y el correo del usuario.
class _ClinicBadge extends StatelessWidget {
  const _ClinicBadge({required this.showText});

  final bool showText;

  @override
  Widget build(BuildContext context) {
    final clinicName = ApiService.clinicName ?? 'Sin clínica asignada';
    final email = ApiService.currentUser?['email']?.toString();

    final logoBox = Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
      ),
      child: ValueListenableBuilder<Uint8List?>(
        valueListenable: ApiService.clinicLogo,
        builder: (context, logo, _) => logo == null
            ? const Icon(
                Icons.local_hospital_outlined,
                color: NexaColors.primary,
              )
            : Image.memory(logo, fit: BoxFit.contain),
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFCFD),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NexaColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showText)
            logoBox
          else
            Tooltip(message: [clinicName, ?email].join('\n'), child: logoBox),
          if (showText) ...[
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clinicName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: NexaColors.textPrimary,
                    ),
                  ),
                  if (email != null)
                    Text(
                      email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: NexaColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
