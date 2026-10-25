import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'ink.dart';
import 'draw_source.dart';
import 'link_panel.dart';
import 'native_bridge.dart';
import 'orientation.dart';
import 'remote_controller.dart';
import 'stage_widgets.dart';
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
    NativeBridge.setLowLatencyWifi(true);
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
    NativeBridge.setLowLatencyWifi(false);
    defaultOrientations();
    super.dispose();
  }

  void _toggleRotation() {
    setState(() => _landscape = !_landscape);
    if (_landscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      defaultOrientations();
    }
  }

  bool get _left => c.hand == Hand.left;

  // ---------------------------------------------------------------- interfaz

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, src, ink, I18n.current]),
          builder: (context, _) => OrientationBuilder(
            builder: (context, o) => o == Orientation.landscape ? _landscapeLayout() : _portraitLayout(),
          ),
        ),
      ),
    );
  }

  Widget _portraitLayout() => LayoutBuilder(
        builder: (context, box) => Padding(
          padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xs, Sp.s, Sp.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _topBar(),
            const SizedBox(height: Sp.xs),
            // En tableta la diapositiva crecería hasta dejar las notas sin lugar
            if (src.link case final link?)
              SizedBox(height: (box.maxHeight * 0.46).clamp(260.0, 420.0), child: LinkPanel(src: src, link: link))
            else ...[
              ConstrainedBox(constraints: BoxConstraints(maxHeight: box.maxHeight * 0.46), child: _slide()),
              const SizedBox(height: Sp.s + 2),
              _toolbar(),
            ],
            ..._extras(),
            const SizedBox(height: Sp.s + 2),
            Expanded(child: _notes()),
            const SizedBox(height: Sp.s + 2),
            SizedBox(height: 64, child: _navButtons()),
          ]),
        ),
      );

  /// Diapositiva a un lado; herramientas, notas y botones en un panel del lado de la mano.
  /// Si la pantalla es baja (teléfono acostado), el panel se desplaza y las notas van dentro.
  Widget _landscapeLayout() => LayoutBuilder(builder: (context, box) {
        final roomy = box.maxHeight >= 460;
        final tools = [
          Align(alignment: Alignment.centerLeft, child: TimerChip(c.timer)),
          const SizedBox(height: Sp.s),
          if (src.link == null) _toolbar(),
          ..._extras(),
          const SizedBox(height: Sp.s),
        ];
        // Con un enlace abierto en la PC, sus controles van en lugar de la diapositiva
        final slide = Expanded(
          child: src.link != null ? LinkPanel(src: src, link: src.link!) : Center(child: _slide()),
        );
        final panel = SizedBox(
          width: (box.maxWidth * 0.34).clamp(280.0, 400.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _topBar(compact: true),
            if (roomy) ...[
              ...tools,
              Expanded(child: _notes()),
            ] else
              Expanded(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ...tools,
                    _notes(scroll: false),
                  ]),
                ),
              ),
            const SizedBox(height: Sp.s),
            SizedBox(height: 56, child: _navButtons()),
          ]),
        );
        const gap = SizedBox(width: Sp.m);
        return Padding(
          padding: const EdgeInsets.all(Sp.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _left ? [panel, gap, slide] : [slide, gap, panel],
          ),
        );
      });

  Widget _topBar({bool compact = false}) {
    final label = src.pageLabel;
    final hidden = !ink.visible;
    return Row(children: [
      IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        icon: const Icon(Icons.arrow_back_rounded),
        tooltip: t('Volver', 'Back'),
      ),
      if (label != null)
        Padding(
          padding: const EdgeInsets.only(left: Sp.xs),
          child: Text(label, style: Txt.digits(16, color: Pal.accent)),
        ),
      const Spacer(),
      if (!compact) ...[TimerChip(c.timer), const SizedBox(width: Sp.xs)],
      if (!src.connected)
        Tooltip(
          message: src.offlineHint ?? '',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
            child: Icon(Icons.cloud_off_rounded, size: 18, color: Pal.busy),
          ),
        ),
      // Ocultar/mostrar: el público deja de ver los dibujos, pero no se borran
      IconButton(
        onPressed: () {
          HapticFeedback.selectionClick();
          ink.setVisible(hidden);
        },
        isSelected: hidden,
        icon: Icon(hidden ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: hidden ? Pal.accent : null),
        tooltip: hidden
            ? t('Mostrar anotaciones en la PC', 'Show annotations on the computer')
            : t('Ocultar anotaciones en la PC', 'Hide annotations on the computer'),
      ),
      IconButton(
        onPressed: _toggleRotation,
        icon: Icon(_landscape ? Icons.stay_current_portrait_rounded : Icons.stay_current_landscape_rounded),
        tooltip: t('Girar', 'Rotate'),
      ),
      PopupMenuButton<String>(
        tooltip: t('Más', 'More'),
        icon: Icon(Icons.more_vert_rounded, color: Pal.muted),
        onSelected: (v) {
          HapticFeedback.selectionClick();
          switch (v) {
            case 'clear':
              ink.clearPage(_page);
            case 'clearAll':
              _confirmClearAll();
            case 'refresh':
              src.refresh();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'clear',
            enabled: ink.hasInk(_page),
            child: _menuRow(Icons.layers_clear_rounded, t('Borrar esta diapositiva', 'Clear this slide')),
          ),
          PopupMenuItem(
            value: 'clearAll',
            enabled: ink.hasAnyInk,
            child: _menuRow(Icons.delete_sweep_rounded, t('Borrar todas las diapositivas', 'Clear all slides')),
          ),
          if (src.canRefresh)
            PopupMenuItem(value: 'refresh', child: _menuRow(Icons.refresh_rounded, t('Actualizar imagen', 'Refresh image'))),
        ],
      ),
    ]);
  }

  Widget _menuRow(IconData icon, String text) => Row(children: [
        Icon(icon, size: 20, color: Pal.muted),
        const SizedBox(width: Sp.m),
        Flexible(child: Text(text)),
      ]);

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('¿Borrar todos los dibujos?', 'Clear all drawings?')),
        content: Text(t('Se quitan de todas las diapositivas. No se puede deshacer.',
            'They are removed from every slide. This can’t be undone.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: Pal.muted),
            child: Text(t('Cancelar', 'Cancel')),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('Borrar', 'Clear'))),
        ],
      ),
    );
    if (ok == true) ink.clearAll();
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
        // heightFactor: ocupa solo el alto de la diapositiva, no todo el disponible
        return Center(
          heightFactor: 1,
          child: SizedBox(
            width: w,
            height: h,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Rad.s),
                border: Border.all(color: !ink.visible ? Pal.accent.withValues(alpha: 0.6) : Pal.rule, width: 1.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Rad.s - 1.5),
                child: Stack(fit: StackFit.expand, children: [
                  if (img != null)
                    Image.memory(img.bytes, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                  else
                    ColoredBox(
                      color: Pal.raise,
                      child: Center(
                        child: src.failed(page)
                            ? Text(t('No se pudo mostrar la diapositiva', 'Could not show the slide'),
                                style: Txt.text(14, color: Pal.muted))
                            : !src.connected && widget.wifi
                                ? Padding(
                                    padding: const EdgeInsets.all(Sp.l),
                                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                                      Flexible(
                                        child: Text(src.offlineHint ?? '',
                                            textAlign: TextAlign.center, style: Txt.text(14, color: Pal.muted, height: 1.35)),
                                      ),
                                      if (src case final WifiDrawSource w when w.canStart) ...[
                                        const SizedBox(height: Sp.m),
                                        PillButton(t('Proyectar en la PC', 'Present on the computer'),
                                            primary: true, dense: true, icon: Icons.cast_rounded, onTap: w.startPresenting),
                                      ],
                                    ]),
                                  )
                                : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    ),
                  // Listener y no un gesto de arrastre: el trazo empieza al tocar, sin esperar
                  // a que el dedo recorra la distancia mínima de un arrastre
                  Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      if (_pointer != null) return; // un solo dedo dibuja
                      _pointer = e.pointer;
                      _begin(e.localPosition, Size(w, h));
                    },
                    onPointerMove: (e) {
                      if (e.pointer != _pointer) return;
                      if (_tool == InkTool.eraser) {
                        _erase(e.localPosition, Size(w, h));
                      } else {
                        ink.move(page, _norm(e.localPosition, Size(w, h)), _tool);
                      }
                    },
                    onPointerUp: _lift,
                    onPointerCancel: _lift,
                    // Capa propia: al moverse el dedo no se vuelve a pintar la diapositiva
                    child: RepaintBoundary(
                      child: CustomPaint(painter: _InkPainter(ink, page, eraserRadius: _eraserRadius)),
                    ),
                  ),
                  if (!ink.visible)
                    Positioned(
                      left: Sp.s,
                      top: Sp.s,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: 3),
                          decoration: BoxDecoration(color: Pal.accent, borderRadius: BorderRadius.circular(99)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.visibility_off_rounded, size: 13, color: Pal.onAccent),
                            const SizedBox(width: 4),
                            Text(t('Ocultas en la PC', 'Hidden on the computer'),
                                style: Txt.text(11.5, weight: FontWeight.w700, color: Pal.onAccent, height: 1.2)),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        );
      });

  /// Dedo que está dibujando.
  int? _pointer;

  void _lift(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    ink.end();
  }

  Offset _norm(Offset p, Size s) => Offset((p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));

  /// Radio del borrador como fracción del ancho de la página.
  double get _eraserRadius => 0.03 * _sizes[_size[InkTool.eraser]!];

  void _erase(Offset p, Size s) =>
      ink.erase(_page, _norm(p, s), radius: _eraserRadius, aspect: s.width / s.height);

  void _begin(Offset p, Size s) {
    if (_tool == InkTool.eraser) return _erase(p, s);
    final color = _tool == InkTool.highlighter ? _hlColor : _penColor;
    final k = _sizes[_size[_tool]!];
    // Pluma y marcatextos: fracción del ancho de la página. Láser: tamaño relativo.
    final width = switch (_tool) {
      InkTool.pen => 0.0045 * k,
      InkTool.highlighter => 0.026 * k,
      InkTool.laser || InkTool.eraser => k,
    };
    ink.begin(_page, _norm(p, s), tool: _tool, color: color, width: width);
  }

  // ---------------------------------------------------------------- herramientas

  Widget _toolbar() {
    final current = _tool == InkTool.highlighter ? _hlColor : _penColor;
    final page = _page;

    Widget toolBtn(InkTool tool, Widget icon, String tip) {
      final on = _tool == tool;
      return Semantics(
        button: true,
        selected: on,
        label: tip,
        excludeSemantics: true,
        child: Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.s + 2),
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _tool = tool);
            },
            child: AnimatedContainer(
              duration: Mo.of(context, Mo.fast),
              width: 46,
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

    Widget colorDot(Color col) {
      final on = current == col && (_tool == InkTool.pen || _tool == InkTool.highlighter);
      return Semantics(
        button: true,
        selected: on,
        child: GestureDetector(
          onTap: () => setState(() {
            if (_tool == InkTool.laser || _tool == InkTool.eraser) _tool = InkTool.pen;
            if (_tool == InkTool.highlighter) {
              _hlColor = col;
            } else {
              _penColor = col;
            }
          }),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: AnimatedContainer(
              duration: Mo.of(context, Mo.fast),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: col,
                shape: BoxShape.circle,
                border: Border.all(color: on ? Pal.accent : Pal.faint.withValues(alpha: 0.6), width: on ? 3 : 1),
                boxShadow: on ? [BoxShadow(color: Pal.accent.withValues(alpha: 0.35), blurRadius: 6)] : null,
              ),
            ),
          ),
        ),
      );
    }

    // Grosor: cuatro puntos de tamaño creciente con el color de la herramienta
    final sizeColor = switch (_tool) {
      InkTool.laser => const Color(0xFFFF2D2D),
      InkTool.eraser => Pal.muted,
      _ => current,
    };
    Widget sizeDot(int i) {
      final on = _size[_tool] == i;
      final d = 6.0 + i * 5.0;
      final hl = _tool == InkTool.highlighter;
      return Tooltip(
        message: [t('Fino', 'Thin'), t('Normal', 'Normal'), t('Grueso', 'Thick'), t('Muy grueso', 'Extra thick')][i],
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s),
          onTap: () => _setSize(i),
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
                color: _tool == InkTool.eraser ? null : (hl ? sizeColor.withValues(alpha: 0.6) : sizeColor),
                shape: hl ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: hl ? BorderRadius.circular(2) : null,
                border: Border.all(color: _tool == InkTool.eraser ? Pal.ink : Pal.faint.withValues(alpha: 0.5), width: 1.5),
              ),
            ),
          ),
        ),
      );
    }

    final tools = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Pal.bg, borderRadius: BorderRadius.circular(Rad.m)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        toolBtn(InkTool.pen, const Icon(Icons.edit_rounded), t('Pluma', 'Pen')),
        toolBtn(InkTool.highlighter, const Icon(Icons.border_color_rounded), t('Marcatextos', 'Highlighter')),
        toolBtn(InkTool.laser, const Icon(Icons.adjust_rounded), t('Puntero láser', 'Laser pointer')),
        toolBtn(InkTool.eraser, const _EraserIcon(), t('Borrador', 'Eraser')),
      ]),
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
    final colors = _tool == InkTool.eraser
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.s),
            child: Text(t('Toca o arrastra sobre un trazo para borrarlo', 'Tap or drag over a stroke to erase it'),
                maxLines: 2, style: Txt.text(12.5, color: Pal.muted, height: 1.3)),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (_tool == InkTool.laser)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                child: Text(t('Puntero láser', 'Laser pointer'), style: Txt.text(12.5, color: Pal.muted)),
              )
            else
              for (final col in _colors) colorDot(col),
          ]);
    final sizes = Row(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < _sizes.length; i++) sizeDot(i)]);

    Widget fit(Widget w, {Alignment align = Alignment.centerLeft}) =>
        FittedBox(fit: BoxFit.scaleDown, alignment: align, child: w);
    // Dos filas fijas (herramientas · deshacer / colores · grosores); en el lado de la mano lo
    // que más se toca
    final row1 = [fit(tools), const Spacer(), undo];
    final row2 = [
      Expanded(child: _tool == InkTool.eraser ? colors : fit(colors)),
      const SizedBox(width: Sp.s),
      sizes,
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, Sp.xs, Sp.xs),
      decoration: BoxDecoration(color: Pal.raise, borderRadius: BorderRadius.circular(Rad.l)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: _left ? row1.reversed.toList() : row1),
        const SizedBox(height: Sp.xs),
        SizedBox(height: 40, child: Row(children: row2)),
      ]),
    );
  }

  /// Enlaces y videos de la diapositiva: se abren o reproducen en la PC.
  List<Widget> _extras() {
    // Con un enlace abierto, sus controles ya están en el panel
    if (src.link != null) return const [];
    final links = src.links(_page);
    final media = src.mediaCount;
    final items = src.mediaItems;
    if (links.isEmpty && media == 0) return const [];
    Widget chip(IconData icon, String label, VoidCallback onTap, {bool active = false}) => Padding(
          padding: const EdgeInsets.only(right: Sp.s),
          child: ActionChip(
            avatar: Icon(icon, size: 18, color: active ? Pal.onAccent : Pal.accent),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            labelStyle: Txt.text(13.5, weight: FontWeight.w600, color: active ? Pal.onAccent : Pal.ink, height: 1.2),
            backgroundColor: active ? Pal.accent : Pal.raise,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
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

    return [
      const SizedBox(height: Sp.s),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, children: [
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
          for (final l in links) chip(Icons.link_rounded, host(l), () => _openLink(l)),
        ]),
      ),
    ];
  }

  void _openLink(String url) {
    src.openLink(url);
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(t('Abriendo en la PC: $url', 'Opening on the computer: $url'), maxLines: 2, overflow: TextOverflow.ellipsis),
      duration: const Duration(milliseconds: 1800),
    ));
  }

  /// [scroll]: false cuando ya va dentro de algo que se desplaza (panel horizontal bajo).
  Widget _notes({bool scroll = true}) {
    final s = c.currentSlide;
    if (c.deck == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Sp.l),
          child: Text(
            t('Dibuja sobre la diapositiva: se ve al instante en la pantalla de la PC.',
                'Draw on the slide: it shows up instantly on the computer’s screen.'),
            textAlign: TextAlign.center,
            style: Txt.text(14.5, color: Pal.muted, height: 1.4),
          ),
        ),
      );
    }
    final has = s != null && s.notes.trim().isNotEmpty;
    final text = Text(
      has ? s.notes : t('Sin notas en esta diapositiva.', 'No notes on this slide.'),
      style: Txt.text((c.notesFont * 0.75).clamp(14, 22), height: 1.45, color: has ? Pal.ink : Pal.faint),
    );
    return SrCard(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.m, Sp.m),
      child: scroll ? SingleChildScrollView(key: ValueKey(c.slide), child: text) : text,
    );
  }

  Widget _navButtons() => NavPads(
        onPrev: () => src.go(false),
        onNext: () => src.go(true),
        prevPulse: c.pulsePrev,
        nextPulse: c.pulseNext,
        prevHint: c.invert ? 'VOL +' : 'VOL −',
        nextHint: c.invert ? 'VOL −' : 'VOL +',
        leftHanded: _left,
        compact: true,
      );
}

/// Ícono de borrador (Material no trae uno): una goma inclinada con la punta marcada.
class _EraserIcon extends StatelessWidget {
  const _EraserIcon();

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
    final body = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: 18 * u, height: 9 * u), Radius.circular(2 * u));
    canvas.drawRRect(body, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * u);
    // La punta que borra, rellena
    canvas.clipRRect(body);
    canvas.drawRect(Rect.fromLTRB(-9 * u, -5 * u, -2 * u, 5 * u), Paint()..color = color);
    canvas.restore();
    // La línea del suelo
    canvas.drawLine(Offset(9 * u, 20.5 * u), Offset(21 * u, 20.5 * u), Paint()
      ..color = color
      ..strokeWidth = 2 * u
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_EraserGlyph old) => old.color != color;
}

/// Dibuja los trazos de una página (y el puntero láser) sobre la imagen.
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
      canvas.drawCircle(o, r, Paint()
        ..color = const Color(0xCC000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      canvas.drawCircle(o, r + 1.5, Paint()
        ..color = const Color(0xCCFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
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
  bool shouldRepaint(_InkPainter old) => old.page != page || old.ink != ink || old.eraserRadius != eraserRadius;
}
