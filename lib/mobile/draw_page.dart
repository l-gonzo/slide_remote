import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'ink.dart';
import 'draw_source.dart';
import 'remote_controller.dart';
import 'timer_chip.dart';

/// "Dibujar": la diapositiva actual en el teléfono. Lo que dibujes (pluma, marcatextos o puntero
/// láser) aparece al instante sobre la presentación: en el navegador de la PC (modo Navegador) o
/// encima de PowerPoint/Impress gracias a la app de escritorio (modo WiFi).
class DrawPage extends StatefulWidget {
  const DrawPage({super.key, required this.c}) : wifi = false, wifiUri = null;
  const DrawPage.wifi({super.key, required this.c, required Uri uri}) : wifi = true, wifiUri = uri;
  final RemoteController c;
  final bool wifi;
  final Uri? wifiUri;

  @override
  State<DrawPage> createState() => _DrawPageState();
}

class _DrawPageState extends State<DrawPage> {
  RemoteController get c => widget.c;
  InkBoard get ink => src.ink;

  static const _colors = [
    Color(0xFFFF3B30), // rojo
    Color(0xFFFFD60A), // amarillo
    Color(0xFF32D74B), // verde
    Color(0xFF0A84FF), // azul
    Color(0xFFFFFFFF),
    Color(0xFF111111),
  ];

  /// Grosores: multiplicadores del tamaño normal de cada herramienta.
  static const _sizes = [0.5, 1.0, 1.8, 3.0];

  InkTool _tool = InkTool.pen;
  Color _penColor = _colors[0];
  Color _hlColor = _colors[1];
  bool _landscape = false;

  /// Grosor elegido (índice de [_sizes]) por herramienta. Se recuerda entre sesiones.
  final Map<InkTool, int> _size = {for (final tool in InkTool.values) tool: 1};

  @override
  void initState() {
    super.initState();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        for (final tool in InkTool.values) {
          _size[tool] = (p.getInt('ink_size_${tool.name}') ?? 1).clamp(0, _sizes.length - 1);
        }
      });
    } catch (_) {}
  }

  void _setSize(int i) {
    setState(() => _size[_tool] = i);
    final tool = _tool;
    SharedPreferences.getInstance().then((p) => p.setInt('ink_size_${tool.name}', i)).catchError((_) => false);
  }


  late final DrawSource src = widget.wifi ? WifiDrawSource(c, widget.wifiUri!) : BrowserDrawSource(c);

  int get _page => src.page;

  @override
  void dispose() {
    src.close();
    // La app del teléfono va siempre en vertical
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _toggleRotation() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(
        _landscape ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
  }

  // ---------------------------------------------------------------- interfaz

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, src, I18n.current]),
          builder: (context, _) => OrientationBuilder(
            builder: (context, o) => o == Orientation.landscape ? _landscapeLayout() : _portraitLayout(),
          ),
        ),
      ),
    );
  }

  Widget _portraitLayout() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _topBar(),
          const SizedBox(height: 6),
          _slide(),
          const SizedBox(height: 10),
          _toolbar(),
          const SizedBox(height: 10),
          Expanded(child: _notes()),
          const SizedBox(height: 10),
          SizedBox(height: 64, child: _navButtons(horizontal: true)),
        ]),
      );

  Widget _landscapeLayout() => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: Center(child: _slide())),
          const SizedBox(width: 10),
          SizedBox(
            width: 230,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _topBar(compact: true),
              Align(alignment: Alignment.centerLeft, child: TimerChip(c.timer)),
              const SizedBox(height: 8),
              _toolbar(),
              const SizedBox(height: 8),
              Expanded(child: _notes()),
              const SizedBox(height: 8),
              SizedBox(height: 56, child: _navButtons(horizontal: true)),
            ]),
          ),
        ]),
      );

  Widget _topBar({bool compact = false}) {
    final label = src.pageLabel;
    return Row(children: [
      IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: t('Volver', 'Back'),
      ),
      const SizedBox(width: 4),
      if (label != null)
        Text(label, style: monoStyle.copyWith(color: Pal.accent, fontWeight: FontWeight.w700)),
      const Spacer(),
      if (!compact) ...[TimerChip(c.timer), const SizedBox(width: 4)],
      if (!src.connected)
        Tooltip(
          message: src.offlineHint ?? '',
          child: Icon(Icons.cloud_off_rounded, size: 18, color: Pal.busy),
        ),
      if (src.canRefresh && !compact)
        IconButton(
          onPressed: src.refresh,
          icon: const Icon(Icons.refresh_rounded),
          tooltip: t('Actualizar imagen', 'Refresh image'),
        ),
      IconButton(
        onPressed: _toggleRotation,
        icon: Icon(_landscape ? Icons.stay_current_portrait_rounded : Icons.stay_current_landscape_rounded),
        tooltip: t('Girar', 'Rotate'),
      ),
    ]);
  }

  Widget _slide() => LayoutBuilder(builder: (context, box) {
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
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(fit: StackFit.expand, children: [
                if (img != null)
                  Image.memory(img.bytes, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                else
                  ColoredBox(
                    color: Pal.card,
                    child: Center(
                      child: src.failed(page)
                          ? Text(t('No se pudo mostrar la diapositiva', 'Could not show the slide'),
                              style: TextStyle(color: Pal.muted))
                          : !src.connected && widget.wifi
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    Flexible(
                                      child: Text(src.offlineHint ?? '',
                                          textAlign: TextAlign.center, style: TextStyle(color: Pal.muted, height: 1.35)),
                                    ),
                                    if (src case final WifiDrawSource w when w.canStart) ...[
                                      const SizedBox(height: 10),
                                      PillButton(t('Proyectar en la PC', 'Present on the computer'),
                                          primary: true, dense: true, icon: Icons.cast_rounded, onTap: w.startPresenting),
                                    ],
                                  ]),
                                )
                              : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _begin(d.localPosition, Size(w, h)),
                  onPanUpdate: (d) => ink.move(page, _norm(d.localPosition, Size(w, h)), _tool),
                  onPanEnd: (_) => ink.end(),
                  onPanCancel: ink.end,
                  child: CustomPaint(painter: _InkPainter(ink, page)),
                ),
              ]),
            ),
          ),
        );
      });

  Offset _norm(Offset p, Size s) => Offset((p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));

  void _begin(Offset p, Size s) {
    final color = _tool == InkTool.highlighter ? _hlColor : _penColor;
    final k = _sizes[_size[_tool]!];
    // Pluma y marcatextos: fracción del ancho de la página. Láser: tamaño relativo.
    final width = switch (_tool) {
      InkTool.pen => 0.0045 * k,
      InkTool.highlighter => 0.026 * k,
      InkTool.laser => k,
    };
    ink.begin(_page, _norm(p, s), tool: _tool, color: color, width: width);
  }

  Widget _toolbar() {
    final current = _tool == InkTool.highlighter ? _hlColor : _penColor;
    Widget toolBtn(InkTool tool, IconData icon, String tip) {
      final on = _tool == tool;
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _tool = tool),
          child: Container(
            width: 44,
            height: 40,
            decoration: BoxDecoration(
              color: on ? Pal.accent : Pal.cardHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: on ? Pal.onAccent : Pal.text),
          ),
        ),
      );
    }

    Widget colorDot(Color col) {
      final on = current == col && _tool != InkTool.laser;
      return GestureDetector(
        onTap: () => setState(() {
          if (_tool == InkTool.laser) _tool = InkTool.pen;
          if (_tool == InkTool.highlighter) {
            _hlColor = col;
          } else {
            _penColor = col;
          }
        }),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: col,
            shape: BoxShape.circle,
            border: Border.all(color: on ? Pal.accent : Pal.stroke, width: on ? 3 : 1.5),
          ),
        ),
      );
    }

    // Grosor: cuatro puntos de tamaño creciente con el color de la herramienta
    final sizeColor = _tool == InkTool.laser ? const Color(0xFFFF2D2D) : current;
    Widget sizeDot(int i) {
      final on = _size[_tool] == i;
      final d = 7.0 + i * 5.5;
      return Tooltip(
        message: [t('Fino', 'Thin'), t('Normal', 'Normal'), t('Grueso', 'Thick'), t('Muy grueso', 'Extra thick')][i],
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _setSize(i),
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? Pal.cardHi : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? Pal.accent : Colors.transparent, width: 2),
            ),
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                color: _tool == InkTool.highlighter ? sizeColor.withValues(alpha: 0.6) : sizeColor,
                shape: _tool == InkTool.highlighter ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: _tool == InkTool.highlighter ? BorderRadius.circular(2) : null,
                border: Border.all(color: Pal.stroke),
              ),
            ),
          ),
        ),
      );
    }

    final page = _page;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Wrap(
        spacing: 6,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        children: [
          toolBtn(InkTool.pen, Icons.edit_rounded, t('Pluma', 'Pen')),
          toolBtn(InkTool.highlighter, Icons.border_color_rounded, t('Marcatextos', 'Highlighter')),
          toolBtn(InkTool.laser, Icons.adjust_rounded, t('Puntero láser', 'Laser pointer')),
          const SizedBox(width: 6),
          for (var i = 0; i < _sizes.length; i++) sizeDot(i),
        ],
      ),
      const SizedBox(height: 8),
      _colorsRow(colorDot, page),
    ]);
  }

  Widget _colorsRow(Widget Function(Color) colorDot, int page) => Wrap(
      spacing: 6,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      children: [
        for (final col in _colors) colorDot(col),
        const SizedBox(width: 4),
        IconButton(
          onPressed: ink.hasInk(page) ? () => ink.undo(page) : null,
          icon: const Icon(Icons.undo_rounded),
          tooltip: t('Deshacer', 'Undo'),
        ),
        IconButton(
          onPressed: ink.hasInk(page) ? () => ink.clearPage(page) : null,
          icon: const Icon(Icons.delete_sweep_rounded),
          tooltip: t('Borrar esta diapositiva', 'Clear this slide'),
        ),
      ],
    );

  Widget _notes() {
    final s = c.currentSlide;
    if (c.deck == null) {
      return Center(
        child: Text(
          t('Dibuja sobre la diapositiva: se ve al instante en el navegador de la PC.',
              'Draw on the slide: it shows up instantly in the computer’s browser.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Pal.muted, height: 1.4),
        ),
      );
    }
    final has = s != null && s.notes.trim().isNotEmpty;
    return SrCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: SingleChildScrollView(
        key: ValueKey(c.slide),
        child: Text(
          has ? s.notes : t('Sin notas en esta diapositiva.', 'No notes on this slide.'),
          style: TextStyle(fontSize: 16, height: 1.4, color: has ? Pal.text : Pal.off),
        ),
      ),
    );
  }

  Widget _navButtons({required bool horizontal}) {
    Widget btn(bool forward) => Material(
          color: forward ? Pal.accent : Pal.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: forward ? BorderSide.none : BorderSide(color: Pal.stroke),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => src.go(forward),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(forward ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
                      color: forward ? Pal.onAccent : Pal.text),
                  const SizedBox(width: 6),
                  Text(
                    (forward ? t('Siguiente', 'Next') : t('Anterior', 'Previous')).toUpperCase(),
                    style: TextStyle(
                      color: forward ? Pal.onAccent : Pal.text,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
    return Row(children: [
      Expanded(child: btn(false)),
      const SizedBox(width: 10),
      Expanded(flex: 2, child: btn(true)),
    ]);
  }
}

/// Dibuja los trazos de una página (y el puntero láser) sobre la imagen.
class _InkPainter extends CustomPainter {
  _InkPainter(this.ink, this.page) : super(repaint: ink);
  final InkBoard ink;
  final int page;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in ink.strokes(page)) {
      paintStroke(canvas, size, s);
    }
    final l = ink.laser;
    if (l != null && ink.laserPage == page) {
      final o = Offset(l.dx * size.width, l.dy * size.height);
      final r = (size.width * 0.012 + 4) * ink.laserScale;
      canvas.drawCircle(o, r * 2.2, Paint()..color = const Color(0x55FF2D2D)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
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
  bool shouldRepaint(_InkPainter old) => old.page != page || old.ink != ink;
}
