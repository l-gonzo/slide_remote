import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'draw_source.dart';
import 'ink.dart';

// =====================================================================================
// La diapositiva en vivo dentro de la pantalla de presentar: la imagen con lo dibujado
// encima, las herramientas de dibujo y los enlaces y videos de la diapositiva. Lo que se
// dibuja (pluma, marcatextos o puntero: láser, foco o lupa) aparece al instante sobre la presentación: en
// el navegador de la PC (modo Navegador) o encima de la proyección de la app de escritorio
// (modo WiFi).
// =====================================================================================

/// Herramienta elegida, colores y grosores. Sin herramienta ([tool] null) la diapositiva solo
/// se ve: así un roce con la palma no deja un trazo frente al público.
class InkTools extends ChangeNotifier {
  InkTools() {
    _load();
  }

  static const colors = [
    Color(0xFFFF3B30), // rojo
    Color(0xFFFFD60A), // amarillo
    Color(0xFF32D74B), // verde
    Color(0xFF0A84FF), // azul
    Color(0xFFFFFFFF),
    Color(0xFF111111),
  ];

  /// Grosores: multiplicadores del tamaño normal de cada herramienta.
  static const sizes = [0.5, 1.0, 1.8, 3.0];

  InkTool? _tool;
  InkTool? get tool => _tool;
  Color penColor = colors[0];
  Color hlColor = colors[1];

  /// Qué hace el puntero: láser, foco o lupa. Se recuerda entre sesiones.
  PointerKind pointer = PointerKind.laser;

  /// Grosor elegido (índice de [sizes]) por herramienta. Se recuerda entre sesiones.
  final Map<InkTool, int> _size = {for (final tool in InkTool.values) tool: 1};

  int sizeOf(InkTool tool) => _size[tool]!;

  /// Color de la pluma o del marcatextos (el que esté en uso).
  Color get current => _tool == InkTool.highlighter ? hlColor : penColor;

  /// Tocar la herramienta que ya está en la mano la guarda.
  void pick(InkTool tool) {
    _tool = _tool == tool ? null : tool;
    notifyListeners();
  }

  void putAway() {
    if (_tool == null) return;
    _tool = null;
    notifyListeners();
  }

  /// Elegir láser, foco o lupa deja el puntero en la mano.
  void pickPointer(PointerKind k) {
    pointer = k;
    _tool = InkTool.laser;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setString('pointer_kind', k.name)).catchError((_) => false);
  }

  void pickColor(Color col) {
    if (_tool != InkTool.pen && _tool != InkTool.highlighter) _tool = InkTool.pen;
    if (_tool == InkTool.highlighter) {
      hlColor = col;
    } else {
      penColor = col;
    }
    notifyListeners();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final tool in InkTool.values) {
        _size[tool] = (p.getInt('ink_size_${tool.name}') ?? 1).clamp(0, sizes.length - 1);
      }
      pointer = PointerKind.values.firstWhere((k) => k.name == p.getString('pointer_kind'), orElse: () => pointer);
      notifyListeners();
    } catch (_) {}
  }

  void setSize(int i) {
    final tool = _tool;
    if (tool == null) return;
    _size[tool] = i;
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.setInt('ink_size_${tool.name}', i)).catchError((_) => false);
  }

  /// Radio del borrador como fracción del ancho de la página.
  double get eraserRadius => 0.03 * sizes[_size[InkTool.eraser]!];

  /// Grosor del trazo de [tool]. Pluma y marcatextos: fracción del ancho de la página. Láser:
  /// tamaño relativo.
  double widthOf(InkTool tool) {
    final k = sizes[_size[tool]!];
    return switch (tool) {
      InkTool.pen => 0.0045 * k,
      InkTool.highlighter => 0.026 * k,
      InkTool.laser || InkTool.eraser => k,
    };
  }
}

IconData pointerIcon(PointerKind k) => switch (k) {
  PointerKind.laser => Icons.adjust_rounded,
  PointerKind.spot => Icons.highlight_rounded,
  PointerKind.zoom => Icons.zoom_in_rounded,
};

String pointerName(PointerKind k) => switch (k) {
  PointerKind.laser => t('Láser', 'Laser'),
  PointerKind.spot => t('Foco', 'Spotlight'),
  PointerKind.zoom => t('Lupa', 'Magnifier'),
};

/// Radio del foco y de la lupa como fracción del ancho de la página ([scale]: tamaño elegido).
/// Igual que en el navegador (assets/web/index.html).
double pointerRadius(double scale) => 0.075 * math.sqrt(scale);

// ============================================================ la diapositiva

/// La diapositiva actual, del tamaño que quepa, con lo dibujado encima. Si hay una herramienta
/// en la mano, el dedo dibuja; si no, [onIdleTouch] (para explicar cómo dibujar).
class SlideCanvas extends StatefulWidget {
  const SlideCanvas({super.key, required this.src, required this.tools, this.enabled = true, this.onIdleTouch});
  final DrawSource src;
  final InkTools tools;

  /// false con la pantalla bloqueada: se ve, pero no se dibuja.
  final bool enabled;
  final VoidCallback? onIdleTouch;

  @override
  State<SlideCanvas> createState() => _SlideCanvasState();
}

class _SlideCanvasState extends State<SlideCanvas> {
  DrawSource get src => widget.src;
  InkTools get tools => widget.tools;
  InkBoard get ink => src.ink;
  int get _page => src.page;

  /// Dedo que está dibujando.
  int? _pointer;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final page = _page;
      final img = src.image(page);
      final aspect = img != null ? img.width / img.height : 16 / 9;
      // Tamaño que cabe en el espacio disponible
      var w = box.maxWidth;
      var h = w / aspect;
      if (box.maxHeight.isFinite && h > box.maxHeight) {
        h = box.maxHeight;
        w = h * aspect;
      }
      src.request(page, (w * MediaQuery.devicePixelRatioOf(context)).clamp(480, 1800).round());
      final drawing = tools.tool != null && widget.enabled;
      final size = Size(w, h);
      // heightFactor: ocupa solo el alto de la diapositiva, no todo el disponible
      return Center(
        heightFactor: 1,
        child: AnimatedContainer(
          duration: Mo.of(context, Mo.fast),
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Rad.s + 2),
            // Con una herramienta en la mano el borde se enciende: lo que toques se ve en la PC
            border: Border.all(
              color: drawing ? Pal.accent : (!ink.visible ? Pal.accent.withValues(alpha: 0.5) : Pal.rule),
              width: drawing ? 2 : 1.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Rad.s),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (img != null)
                  Image.memory(img.bytes, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                else
                  ColoredBox(
                    color: Pal.raise,
                    child: Center(
                      child: src.failed(page)
                          ? Text(
                              t('No se pudo mostrar la diapositiva', 'Could not show the slide'),
                              style: Txt.text(14, color: Pal.muted),
                            )
                          : src is WifiDrawSource && !src.connected
                          ? Padding(
                              padding: const EdgeInsets.all(Sp.l),
                              child: Text(
                                src.offlineHint ?? '',
                                textAlign: TextAlign.center,
                                style: Txt.text(14, color: Pal.muted, height: 1.35),
                              ),
                            )
                          : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
                // Listener y no un gesto de arrastre: el trazo empieza al tocar, sin esperar
                // a que el dedo recorra la distancia mínima de un arrastre
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    if (!widget.enabled) return;
                    if (tools.tool == null) return widget.onIdleTouch?.call();
                    if (_pointer != null) return; // un solo dedo dibuja
                    _pointer = e.pointer;
                    _begin(e.localPosition, size);
                  },
                  onPointerMove: (e) {
                    if (e.pointer != _pointer) return;
                    final tool = tools.tool;
                    if (tool == null) return;
                    if (tool == InkTool.eraser) {
                      _erase(e.localPosition, size);
                    } else {
                      ink.move(page, _norm(e.localPosition, size), tool);
                    }
                  },
                  onPointerUp: _lift,
                  onPointerCancel: _lift,
                  // Capa propia: al moverse el dedo no se vuelve a pintar la diapositiva
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _InkPainter(ink, page, eraserRadius: tools.eraserRadius)),
                  ),
                ),
                if (!ink.visible)
                  Positioned(
                    left: Sp.s,
                    top: Sp.s,
                    // Tocarla las vuelve a mostrar
                    child: Material(
                      color: Pal.accent,
                      shape: const StadiumBorder(),
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: widget.enabled
                            ? () {
                                HapticFeedback.selectionClick();
                                ink.setVisible(true);
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Sp.s + 2, vertical: 5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.visibility_off_rounded, size: 14, color: Pal.onAccent),
                              const SizedBox(width: 5),
                              Text(
                                t('Ocultas en la PC', 'Hidden on the computer'),
                                style: Txt.text(12, weight: FontWeight.w700, color: Pal.onAccent, height: 1.2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  void _lift(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    ink.end();
  }

  Offset _norm(Offset p, Size s) => Offset((p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));

  void _erase(Offset p, Size s) =>
      ink.erase(_page, _norm(p, s), radius: tools.eraserRadius, aspect: s.width / s.height);

  void _begin(Offset p, Size s) {
    final tool = tools.tool!;
    if (tool == InkTool.eraser) return _erase(p, s);
    final color = tool == InkTool.highlighter ? tools.hlColor : tools.penColor;
    ink.begin(_page, _norm(p, s), tool: tool, color: color, width: tools.widthOf(tool), pointer: tools.pointer);
  }
}

// ============================================================ herramientas

/// Herramientas de dibujo. Una fila siempre visible (herramientas, deshacer y más opciones);
/// con una herramienta en la mano se abre la segunda (colores y grosores, o qué hace).
class InkToolbar extends StatelessWidget {
  const InkToolbar({
    super.key,
    required this.src,
    required this.tools,
    required this.leftHanded,
    this.onRotate,
    this.landscape = false,
  });
  final DrawSource src;
  final InkTools tools;
  final bool leftHanded;

  /// Girar el teléfono para ver la diapositiva más grande (null en tableta).
  final VoidCallback? onRotate;
  final bool landscape;

  InkBoard get ink => src.ink;

  @override
  Widget build(BuildContext context) {
    final page = src.page;
    final tool = tools.tool;

    final kit = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Pal.bg, borderRadius: BorderRadius.circular(Rad.m)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(tools, InkTool.pen, const Icon(Icons.edit_rounded), t('Pluma', 'Pen')),
          _ToolButton(
            tools,
            InkTool.highlighter,
            const Icon(Icons.border_color_rounded),
            t('Marcatextos', 'Highlighter'),
          ),
          _ToolButton(tools, InkTool.laser, Icon(pointerIcon(tools.pointer)), t('Puntero', 'Pointer')),
          _ToolButton(tools, InkTool.eraser, const EraserIcon(), t('Borrador', 'Eraser')),
        ],
      ),
    );
    final undo = IconButton(
      onPressed: ink.canUndo(page)
          ? () {
              HapticFeedback.selectionClick();
              ink.undo(page);
            }
          : null,
      icon: const Icon(Icons.undo_rounded),
      tooltip: t('Deshacer', 'Undo'),
    );
    final hidden = !ink.visible;
    final more = PopupMenuButton<String>(
      tooltip: t('Más opciones de dibujo', 'More drawing options'),
      icon: Icon(Icons.more_horiz_rounded, color: Pal.ink),
      onSelected: (v) {
        HapticFeedback.selectionClick();
        switch (v) {
          case 'vis':
            ink.setVisible(hidden);
          case 'rotate':
            onRotate?.call();
          case 'clear':
            ink.clearPage(page);
          case 'clearAll':
            _confirmClearAll(context);
          case 'refresh':
            src.refresh();
        }
      },
      itemBuilder: (_) => [
        // Ocultar/mostrar: el público deja de ver los dibujos, pero no se borran
        PopupMenuItem(
          value: 'vis',
          child: _menuRow(
            hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            hidden
                ? t('Mostrar anotaciones en la PC', 'Show annotations on the computer')
                : t('Ocultar anotaciones en la PC', 'Hide annotations on the computer'),
          ),
        ),
        if (onRotate != null)
          PopupMenuItem(
            value: 'rotate',
            child: _menuRow(
              landscape ? Icons.stay_current_portrait_rounded : Icons.stay_current_landscape_rounded,
              landscape
                  ? t('Volver a vertical', 'Back to portrait')
                  : t('Girar: diapositiva más grande', 'Rotate: larger slide'),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'clear',
          enabled: ink.hasInk(page),
          child: _menuRow(Icons.layers_clear_rounded, t('Borrar esta diapositiva', 'Clear this slide')),
        ),
        PopupMenuItem(
          value: 'clearAll',
          enabled: ink.hasAnyInk,
          child: _menuRow(
            Icons.delete_sweep_rounded,
            t('Borrar todas las diapositivas', 'Clear all slides'),
            danger: true,
          ),
        ),
        if (src.canRefresh)
          PopupMenuItem(
            value: 'refresh',
            child: _menuRow(Icons.refresh_rounded, t('Actualizar imagen', 'Refresh image')),
          ),
      ],
    );

    Widget fit(Widget w) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: leftHanded ? Alignment.centerLeft : Alignment.centerRight,
      child: w,
    );
    // Las herramientas del lado de la mano (a la derecha para diestros); deshacer y más, del otro
    final row1 = [more, undo, const Spacer(), Flexible(child: fit(kit))];

    return Container(
      padding: const EdgeInsets.fromLTRB(Sp.xs + 2, Sp.xs + 2, Sp.xs, Sp.xs + 2),
      decoration: BoxDecoration(color: Pal.raise, borderRadius: BorderRadius.circular(Rad.l)),
      child: AnimatedSize(
        duration: Mo.of(context, Mo.med),
        curve: Mo.curve,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: leftHanded ? row1.reversed.toList() : row1),
            if (tool != null)
              Padding(
                padding: const EdgeInsets.only(top: Sp.xs),
                child: SizedBox(height: 40, child: _Options(tools)),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _menuRow(IconData icon, String text, {bool danger = false}) => Row(
    children: [
      Icon(icon, size: 20, color: danger ? Pal.error : Pal.muted),
      const SizedBox(width: Sp.m),
      Flexible(child: Text(text)),
    ],
  );

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('¿Borrar todos los dibujos?', 'Clear all drawings?')),
        content: Text(
          t(
            'Se quitan de todas las diapositivas. No se puede deshacer.',
            'They are removed from every slide. This can’t be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: Pal.muted),
            child: Text(t('Cancelar', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Pal.error, foregroundColor: Colors.white),
            child: Text(t('Borrar', 'Clear')),
          ),
        ],
      ),
    );
    if (ok == true) ink.clearAll();
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton(this.tools, this.tool, this.icon, this.tip);
  final InkTools tools;
  final InkTool tool;
  final Widget icon;
  final String tip;

  @override
  Widget build(BuildContext context) {
    final on = tools.tool == tool;
    return Semantics(
      button: true,
      selected: on,
      label: tip,
      excludeSemantics: true,
      child: Tooltip(
        message: on ? t('$tip · toca para guardarla', '$tip · tap to put it away') : tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s + 2),
          onTap: () {
            HapticFeedback.selectionClick();
            tools.pick(tool);
          },
          child: AnimatedContainer(
            duration: Mo.of(context, Mo.fast),
            width: 48,
            height: 42,
            decoration: BoxDecoration(
              color: on ? Pal.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(Rad.s + 2),
            ),
            child: IconTheme(
              data: IconThemeData(size: 21, color: on ? Pal.onAccent : Pal.ink),
              child: Center(child: icon),
            ),
          ),
        ),
      ),
    );
  }
}

/// Segunda fila: colores y grosores de la herramienta en la mano (el puntero elige entre láser,
/// foco y lupa; el borrador explica cómo se usa).
class _Options extends StatelessWidget {
  const _Options(this.tools);
  final InkTools tools;

  @override
  Widget build(BuildContext context) {
    final tool = tools.tool!;
    final current = tools.current;

    Widget colorDot(Color col) {
      final on = current == col && (tool == InkTool.pen || tool == InkTool.highlighter);
      return Semantics(
        button: true,
        selected: on,
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            tools.pickColor(col);
          },
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: AnimatedContainer(
              duration: Mo.of(context, Mo.fast),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: col,
                shape: BoxShape.circle,
                border: Border.all(color: on ? Pal.accent : Pal.faint.withValues(alpha: 0.6), width: on ? 3 : 1),
              ),
            ),
          ),
        ),
      );
    }

    // Grosor: cuatro puntos de tamaño creciente con el color de la herramienta
    // Foco y lupa: solo el contorno, como el borrador
    final outline = tool == InkTool.eraser || (tool == InkTool.laser && tools.pointer != PointerKind.laser);
    final sizeColor = switch (tool) {
      InkTool.laser => const Color(0xFFFF2D2D),
      InkTool.eraser => Pal.muted,
      _ => current,
    };
    final hl = tool == InkTool.highlighter;
    Widget sizeDot(int i) {
      final on = tools.sizeOf(tool) == i;
      final d = 6.0 + i * 5.0;
      return Tooltip(
        message: tool == InkTool.laser
            ? [t('Pequeño', 'Small'), t('Normal', 'Normal'), t('Grande', 'Large'), t('Muy grande', 'Extra large')][i]
            : [t('Fino', 'Thin'), t('Normal', 'Normal'), t('Grueso', 'Thick'), t('Muy grueso', 'Extra thick')][i],
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s),
          onTap: () {
            HapticFeedback.selectionClick();
            tools.setSize(i);
          },
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Pal.bg : Colors.transparent,
              borderRadius: BorderRadius.circular(Rad.s),
            ),
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                color: outline ? null : (hl ? sizeColor.withValues(alpha: 0.6) : sizeColor),
                shape: hl ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: hl ? BorderRadius.circular(2) : null,
                border: Border.all(
                  color: outline ? Pal.ink : Pal.faint.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final Widget left = switch (tool) {
      InkTool.eraser => _hint(
        t('Toca o arrastra sobre un trazo para borrarlo', 'Tap or drag over a stroke to erase it'),
      ),
      InkTool.laser => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Row(mainAxisSize: MainAxisSize.min, children: [for (final k in PointerKind.values) _kind(context, k)]),
      ),
      _ => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Row(mainAxisSize: MainAxisSize.min, children: [for (final col in InkTools.colors) colorDot(col)]),
      ),
    };
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: Sp.s),
        Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < InkTools.sizes.length; i++) sizeDot(i)]),
      ],
    );
  }

  /// Láser, foco o lupa: el que está en uso, resaltado.
  Widget _kind(BuildContext context, PointerKind k) {
    final on = tools.pointer == k;
    final tip = switch (k) {
      PointerKind.laser => t('Un punto rojo sigue tu dedo', 'A red dot follows your finger'),
      PointerKind.spot => t('Oscurece todo menos donde está tu dedo', 'Dims everything except where your finger is'),
      PointerKind.zoom => t('Agranda lo que está bajo tu dedo', 'Enlarges what is under your finger'),
    };
    return Semantics(
      button: true,
      selected: on,
      child: Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s),
          onTap: () {
            HapticFeedback.selectionClick();
            tools.pickPointer(k);
          },
          child: AnimatedContainer(
            duration: Mo.of(context, Mo.fast),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: Sp.s),
            decoration: BoxDecoration(
              color: on ? Pal.accentSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(Rad.s),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(pointerIcon(k), size: 18, color: on ? Pal.onAccentSoft : Pal.muted),
                const SizedBox(width: 5),
                Text(
                  pointerName(k),
                  style: Txt.text(13, weight: FontWeight.w600, color: on ? Pal.onAccentSoft : Pal.ink, height: 1.2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Sp.s),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Txt.text(12.5, color: Pal.muted, height: 1.3),
      ),
    ),
  );
}

// ============================================================ enlaces y videos

/// Enlaces y videos de la diapositiva: se abren o reproducen en la PC. Vacío si no hay.
class SlideExtras extends StatelessWidget {
  const SlideExtras({super.key, required this.src});
  final DrawSource src;

  static bool has(DrawSource src) => src.link == null && (src.links(src.page).isNotEmpty || src.mediaCount > 0);

  @override
  Widget build(BuildContext context) {
    if (!has(src)) return const SizedBox.shrink();
    final links = src.links(src.page);
    final media = src.mediaCount;
    final items = src.mediaItems;
    Widget chip(IconData icon, String label, VoidCallback onTap, {bool active = false}) => Padding(
      padding: const EdgeInsetsDirectional.only(end: Sp.s),
      child: ActionChip(
        avatar: Icon(icon, size: 18, color: active ? Pal.onAccentSoft : Pal.accent),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        labelStyle: Txt.text(13.5, weight: FontWeight.w600, color: active ? Pal.onAccentSoft : Pal.ink, height: 1.2),
        backgroundColor: active ? Pal.accentSoft : Pal.raise,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        onPressed: () {
          HapticFeedback.selectionClick();
          onTap();
        },
      ),
    );
    String host(String url) {
      final u = Uri.tryParse(url);
      final h = u?.host ?? '';
      return h.isEmpty ? url : h.replaceFirst('www.', '');
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // Varios videos en la diapositiva: un botón para cada uno
          if (items.length > 1) ...[
            for (var i = 0; i < items.length; i++)
              chip(
                items[i] ? Icons.pause_rounded : Icons.play_arrow_rounded,
                '${t('Video', 'Video')} ${i + 1}',
                () => src.mediaCtl('toggle', index: i),
                active: items[i],
              ),
            chip(Icons.replay_rounded, t('Desde el inicio', 'From the start'), () => src.mediaCtl('restart')),
          ] else if (media > 0) ...[
            chip(
              src.mediaPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              src.mediaPlaying ? t('Pausar video', 'Pause video') : t('Reproducir video', 'Play video'),
              () => src.mediaCtl('toggle'),
              active: src.mediaPlaying,
            ),
            chip(Icons.replay_rounded, t('Desde el inicio', 'From the start'), () => src.mediaCtl('restart')),
          ],
          for (final l in links)
            chip(Icons.open_in_new_rounded, host(l), () {
              src.openLink(l);
              final m = ScaffoldMessenger.of(context);
              m.hideCurrentSnackBar();
              m.showSnackBar(
                SnackBar(
                  content: Text(
                    t('Abriendo en la PC: $l', 'Opening on the computer: $l'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  duration: const Duration(milliseconds: 1800),
                ),
              );
            }),
        ],
      ),
    );
  }
}

// ============================================================ dibujo

/// Ícono de borrador (Material no trae uno): una goma inclinada con la punta marcada.
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final size = theme.size ?? 24;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _EraserGlyph(theme.color ?? Pal.ink)),
    );
  }
}

class _EraserGlyph extends CustomPainter {
  _EraserGlyph(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final u = s.width / 24;
    canvas.save();
    canvas.translate(s.width / 2, s.height / 2 - u);
    canvas.rotate(-0.785398); // -45°
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 18 * u, height: 9 * u),
      Radius.circular(2 * u),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * u,
    );
    // La punta que borra, rellena
    canvas.clipRRect(body);
    canvas.drawRect(Rect.fromLTRB(-9 * u, -5 * u, -2 * u, 5 * u), Paint()..color = color);
    canvas.restore();
    // La línea del suelo
    canvas.drawLine(
      Offset(9 * u, 20.5 * u),
      Offset(21 * u, 20.5 * u),
      Paint()
        ..color = color
        ..strokeWidth = 2 * u
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_EraserGlyph old) => old.color != color;
}

/// Dibuja los trazos de una página (y el puntero) sobre la imagen.
class _InkPainter extends CustomPainter {
  _InkPainter(this.ink, this.page, {required this.eraserRadius}) : super(repaint: ink.repaint);
  final InkBoard ink;
  final int page;
  final double eraserRadius;

  @override
  void paint(Canvas canvas, Size size) {
    // Ocultas en la PC: aquí se ven tenues, para saber que siguen ahí
    final hidden = !ink.visible;
    if (hidden) canvas.saveLayer(Offset.zero & size, Paint()..color = const Color(0x55000000));
    for (final s in ink.strokes(page)) {
      paintStroke(canvas, size, s);
    }
    if (hidden) canvas.restore();
    final e = ink.eraser;
    if (e != null) {
      final o = Offset(e.dx * size.width, e.dy * size.height);
      final r = eraserRadius * size.width;
      canvas.drawCircle(o, r, Paint()..color = const Color(0x33FFFFFF));
      canvas.drawCircle(
        o,
        r,
        Paint()
          ..color = const Color(0xCC000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(
        o,
        r + 1.5,
        Paint()
          ..color = const Color(0xCCFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    final l = ink.laser;
    if (l == null || ink.laserPage != page) return;
    final o = Offset(l.dx * size.width, l.dy * size.height);
    switch (ink.laserKind) {
      case PointerKind.spot:
        // Más tenue que en la PC: el presentador sigue viendo toda la diapositiva
        final r = pointerRadius(ink.laserScale) * size.width;
        canvas.drawPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(Offset.zero & size)
            ..addOval(Rect.fromCircle(center: o, radius: r)),
          Paint()..color = const Color(0x88000000),
        );
      case PointerKind.zoom:
        // Aquí solo el borde de la lupa (el dedo tapa el centro); la PC la muestra agrandada
        final r = pointerRadius(ink.laserScale) * size.width;
        canvas.drawCircle(o, r, Paint()..color = const Color(0x22FFFFFF));
        canvas.drawCircle(
          o,
          r,
          Paint()
            ..color = const Color(0xAA000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
        canvas.drawCircle(
          o,
          r,
          Paint()
            ..color = const Color(0xEEFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      case PointerKind.laser:
        final r = (size.width * 0.012 + 4) * ink.laserScale;
        canvas.drawCircle(
          o,
          r * 2.2,
          Paint()
            ..color = const Color(0x55FF2D2D)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawCircle(o, r, Paint()..color = const Color(0xFFFF2D2D));
        canvas.drawCircle(o, r * 0.45, Paint()..color = const Color(0xFFFFD0D0));
    }
  }

  static void paintStroke(Canvas canvas, Size size, InkStroke s) {
    if (s.points.isEmpty) return;
    final hl = s.tool == InkTool.highlighter;
    final paint = Paint()
      ..color = hl ? s.color.withValues(alpha: 0.38) : s.color
      ..strokeWidth = (s.width * size.width).clamp(1.5, 200)
      ..style = PaintingStyle.stroke
      ..strokeCap = hl ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final pts = [for (final p in s.points) Offset(p.dx * size.width, p.dy * size.height)];
    if (pts.length == 1) {
      canvas.drawCircle(pts.first, paint.strokeWidth / 2, Paint()..color = paint.color);
      return;
    }
    // Curva suave por los puntos medios
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final mid = (pts[i] + pts[i + 1]) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_InkPainter old) => old.page != page || old.ink != ink || old.eraserRadius != eraserRadius;
}
