import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'ink.dart';
import 'native_bridge.dart';
import 'remote_controller.dart';

/// Modo Navegador → "Dibujar": la diapositiva actual en el teléfono. Lo que dibujes (pluma,
/// marcatextos o puntero láser) aparece al instante sobre la presentación en el navegador de la PC.
class DrawPage extends StatefulWidget {
  const DrawPage({super.key, required this.c});
  final RemoteController c;

  @override
  State<DrawPage> createState() => _DrawPageState();
}

class _DrawPageState extends State<DrawPage> {
  RemoteController get c => widget.c;
  InkBoard get ink => c.browser.ink;

  static const _colors = [
    Color(0xFFFF3B30), // rojo
    Color(0xFFFFD60A), // amarillo
    Color(0xFF32D74B), // verde
    Color(0xFF0A84FF), // azul
    Color(0xFFFFFFFF),
    Color(0xFF111111),
  ];

  InkTool _tool = InkTool.pen;
  Color _penColor = _colors[0];
  Color _hlColor = _colors[1];
  bool _landscape = false;

  /// Página que se muestra si ningún navegador está conectado (sin navegador no hay "página actual").
  int _localPage = 1;
  int _pdfPages = 0;

  final Map<int, PdfPageImage> _images = {};
  final Set<int> _loading = {};
  String? _pdfPath;
  bool _failed = false;

  int get _page => c.browser.viewers > 0 && c.browser.page > 0 ? c.browser.page : _localPage;
  int get _total => c.browser.total > 0 ? c.browser.total : _pdfPages;

  @override
  void dispose() {
    ink.end();
    // La app del teléfono va siempre en vertical
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _toggleRotation() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(
        _landscape ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
  }

  // ---------------------------------------------------------------- imágenes de las páginas

  void _ensureImages(int page, double logicalWidth) {
    final path = c.browser.pdfFile?.path;
    if (path == null) return;
    if (path != _pdfPath) {
      // Cambió el PDF: tirar las imágenes viejas
      _pdfPath = path;
      _images.clear();
      _failed = false;
    }
    final px = (logicalWidth * MediaQuery.devicePixelRatioOf(context)).clamp(480, 1800).round();
    for (final p in [page, page + 1]) {
      if (p < 1 || (_total > 0 && p > _total)) continue;
      if (_images.containsKey(p) || _loading.contains(p)) continue;
      _loading.add(p);
      NativeBridge.renderPdfPage(path, p, px).then((img) {
        _loading.remove(p);
        if (!mounted || path != _pdfPath) return;
        setState(() {
          if (img == null) {
            _failed = p == page;
            return;
          }
          _images[p] = img;
          if (img.pages > 0) _pdfPages = img.pages;
          // Guardar pocas en memoria
          if (_images.length > 6) {
            final far = _images.keys.toList()..sort((a, b) => (a - _page).abs().compareTo((b - _page).abs()));
            for (final k in far.skip(6)) {
              _images.remove(k);
            }
          }
        });
      });
    }
  }

  // ---------------------------------------------------------------- navegación

  void _go(bool forward) {
    if (c.browser.viewers > 0) {
      c.send(forward: forward);
    } else {
      HapticFeedback.selectionClick();
      setState(() {
        final max = _total > 0 ? _total : 9999;
        _localPage = (_localPage + (forward ? 1 : -1)).clamp(1, max);
      });
    }
  }

  // ---------------------------------------------------------------- interfaz

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, ink, I18n.current]),
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
              const SizedBox(height: 6),
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
    final total = _total;
    return Row(children: [
      IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: t('Volver', 'Back'),
      ),
      if (!compact)
        Text(t('Dibujar', 'Draw'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(width: 10),
      Text(
        total > 0 ? '$_page / $total' : '$_page',
        style: monoStyle.copyWith(color: Pal.accent, fontWeight: FontWeight.w700),
      ),
      const Spacer(),
      if (c.browser.viewers == 0)
        Tooltip(
          message: t('Abre la dirección en el navegador de la PC', 'Open the address in the computer’s browser'),
          child: const Icon(Icons.cloud_off_rounded, size: 18, color: Pal.busy),
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
        final img = _images[page];
        final aspect = img != null ? img.width / img.height : 16 / 9;
        // Tamaño que cabe en el espacio disponible
        var w = box.maxWidth;
        var h = w / aspect;
        if (box.maxHeight.isFinite && h > box.maxHeight) {
          h = box.maxHeight;
          w = h * aspect;
        }
        _ensureImages(page, w);
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
                      child: _failed
                          ? Text(t('No se pudo mostrar la diapositiva', 'Could not show the slide'),
                              style: const TextStyle(color: Pal.muted))
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
    final width = switch (_tool) {
      InkTool.pen => 0.0045,
      InkTool.highlighter => 0.026,
      InkTool.laser => 0.0,
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

    final page = _page;
    return Wrap(
      spacing: 6,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      children: [
        toolBtn(InkTool.pen, Icons.edit_rounded, t('Pluma', 'Pen')),
        toolBtn(InkTool.highlighter, Icons.border_color_rounded, t('Marcatextos', 'Highlighter')),
        toolBtn(InkTool.laser, Icons.adjust_rounded, t('Puntero láser', 'Laser pointer')),
        const SizedBox(width: 4),
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
  }

  Widget _notes() {
    final s = c.currentSlide;
    if (c.deck == null) {
      return Center(
        child: Text(
          t('Dibuja sobre la diapositiva: se ve al instante en el navegador de la PC.',
              'Draw on the slide: it shows up instantly in the computer’s browser.'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Pal.muted, height: 1.4),
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
            side: forward ? BorderSide.none : const BorderSide(color: Pal.stroke),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _go(forward),
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
      final r = size.width * 0.012 + 4;
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
      ..strokeWidth = (s.width * size.width).clamp(1.5, 80)
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
