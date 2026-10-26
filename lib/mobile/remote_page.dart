import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/pptx_notes.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'connection_view.dart';
import 'draw_source.dart';
import 'link_panel.dart';
import 'native_bridge.dart';
import 'orientation.dart';
import 'remote_controller.dart';
import 'settings_page.dart';
import 'slide_stage.dart';
import 'stage_widgets.dart';
import 'timer_chip.dart';

/// Pantalla principal del teléfono.
///
/// Tiene tres estados, según lo que el presentador necesita en ese momento:
///  - **Preparar** (sin conexión y sin notas): elegir el modo y conectar.
///  - **Listo** (conectado, sin notas): botones grandes de cambiar diapositiva.
///  - **Presentar** (con notas): número y título de la diapositiva, notas grandes y los botones
///    abajo. Si la conexión se cae, las notas se quedan y aparece un aviso para reconectar.
///
/// Al transmitir (modo Navegador, o WiFi con la PC proyectando con Zlide) se ve además el
/// **escenario**: la diapositiva en vivo arriba de las notas, con las herramientas de dibujo y
/// los enlaces y videos de la diapositiva. Todo en la misma pantalla: tomar una herramienta
/// agranda la diapositiva; guardarla devuelve el espacio a las notas.
///
/// Abajo siempre está el "control": una barra de acciones (ir a, notas, bloquear) y los botones
/// de cambiar diapositiva, acomodados del lado de la mano dominante. Con el modo una mano, todo
/// lo que se toca queda abajo.
class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

enum _View { setup, ready, notes }

class _RemotePageState extends State<RemotePage> {
  final c = RemoteController();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _nudgeSub;

  bool _notesExpanded = false;

  /// Se cerró el aviso "tu presentación está lista en la PC".
  bool _startDismissed = false;

  /// De dónde salen la diapositiva del escenario y a dónde van los dibujos (null si no se transmite).
  DrawSource? _src;
  String? _srcKey;
  final _tools = InkTools();

  /// Sin conexión todavía, se pidió ver el escenario ("Ver la diapositiva y dibujar").
  bool _wantStage = false;

  /// Teléfono girado para ver la diapositiva más grande.
  bool _landscape = false;
  bool _lowLatency = false;
  DateTime _lastDrawHint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: c.onForeground, onPause: c.onBackground);
    _nudgeSub = c.nudges.listen(_showNudge);
    c.addListener(_syncSource);
    _tools.addListener(_syncLatency);
    c.init();
  }

  @override
  void dispose() {
    _nudgeSub?.cancel();
    _lifecycle.dispose();
    c.removeListener(_syncSource);
    _src?.close();
    _tools.dispose();
    if (_lowLatency) NativeBridge.setLowLatencyWifi(false);
    if (_landscape) defaultOrientations();
    c.dispose();
    super.dispose();
  }

  /// Abre (o cierra) la fuente del escenario según el modo: el PDF del teléfono en modo
  /// Navegador, o el WebSocket de la app de escritorio en modo WiFi.
  void _syncSource() {
    final uri = c.mode == Mode.wifi ? c.pcDrawUri : null;
    final key = c.mode == Mode.browser && c.browser.hasPdf && !c.converting ? 'browser' : uri?.toString();
    if (key != _srcKey) {
      _srcKey = key;
      final old = _src;
      _src = key == null ? null : (uri != null ? WifiDrawSource(c, uri) : BrowserDrawSource(c));
      old?.close();
    }
    if (!_stageOn) {
      _wantStage = false;
      _tools.putAway();
      if (_landscape) {
        _landscape = false;
        defaultOrientations();
      }
    }
    _syncLatency();
  }

  /// WiFi de baja latencia solo mientras se dibuja (gasta más batería).
  void _syncLatency() {
    final want = _stageOn && _tools.tool != null;
    if (want == _lowLatency) return;
    _lowLatency = want;
    NativeBridge.setLowLatencyWifi(want);
  }

  /// Hay diapositiva que mostrar: en WiFi, solo si la PC proyecta con Zlide.
  bool get _stageOn => switch (_src) {
    BrowserDrawSource() => true,
    final WifiDrawSource w => w.presenting,
    _ => false,
  };

  void _toggleRotation() {
    setState(() => _landscape = !_landscape);
    if (_landscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      defaultOrientations();
    }
  }

  /// Se tocó la diapositiva sin herramienta: explicar cómo dibujar (sin insistir).
  void _drawHint() {
    final now = DateTime.now();
    if (now.difference(_lastDrawHint) < const Duration(seconds: 6)) return;
    _lastDrawHint = now;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(
          t(
            'Toma la pluma, el marcatextos o el puntero (láser, foco o lupa) para dibujar o señalar.',
            'Pick the pen, highlighter or pointer (laser, spotlight or magnifier) to draw or point.',
          ),
        ),
        duration: const Duration(milliseconds: 2200),
      ),
    );
  }

  /// Cambiar de diapositiva. En modo Navegador sin la PC conectada, el escenario se recorre
  /// igual (para preparar o dibujar antes de empezar).
  void _go(bool forward) {
    final s = _src;
    if (s is BrowserDrawSource && !s.connected && !c.locked) return s.go(forward);
    c.tap(forward: forward);
  }

  void _showNudge(String msg) {
    HapticFeedback.heavyImpact();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1800)));
  }

  bool get _connected => c.status.conn == Conn.on;
  bool get _left => c.hand == Hand.left;

  _View get _view =>
      c.deck != null ? _View.notes : (_connected || (_wantStage && _stageOn) ? _View.ready : _View.setup);

  /// Aviso para empezar a presentar en la PC (modo WiFi, la PC tiene la presentación elegida).
  bool get _showStart => c.pcCanStart && c.wifi.pcDeckMode == DeckMode.none && !_startDismissed;

  // ================================================================ estructura

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, I18n.current, _tools, if (_src != null) _src!]),
          builder: (context, _) {
            if (!c.ready) return const Center(child: CircularProgressIndicator());
            final view = _view;
            if (view != _View.notes) _notesExpanded = false;
            if (!c.pcCanStart) _startDismissed = false;
            final expanded = view == _View.notes && _notesExpanded;
            final stage = _stageOn && view != _View.setup;
            final drawing = stage && !expanded && _tools.tool != null;
            return PopScope(
              // Con la pantalla bloqueada "atrás" no hace nada; con las notas expandidas, las
              // contrae; con una herramienta en la mano, la guarda
              canPop: !expanded && !c.locked && !drawing,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (c.locked) {
                  HapticFeedback.heavyImpact();
                } else if (expanded) {
                  setState(() => _notesExpanded = false);
                } else if (drawing) {
                  _tools.putAway();
                }
              },
              child: LayoutBuilder(
                builder: (context, box) {
                  // Teléfono acostado: su propio acomodo, también con las notas expandidas (si no, al
                  // expandirlas volvería el de vertical, que no cabe)
                  final lying = box.maxWidth > box.maxHeight && box.maxHeight < 520;
                  if (stage && lying) return _stageLandscape(view, box, expanded: expanded);
                  if (stage && !expanded) {
                    return box.maxWidth > box.maxHeight || box.maxWidth >= Bp.expanded
                        ? _stageWide(view, box)
                        : _stagePortrait(view, box);
                  }
                  // Pantalla ancha (tableta horizontal): contenido y control lado a lado.
                  // Preparar sigue en una columna: es un formulario, no gana nada con dos paneles.
                  if (box.maxWidth >= Bp.expanded && view != _View.setup) {
                    return _twoPane(view, expanded: expanded, box: box);
                  }
                  return _onePane(view, expanded: expanded, box: box);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _onePane(_View view, {required bool expanded, required BoxConstraints box}) {
    final short = box.maxHeight < 640;
    // Muy baja (pantalla dividida, ventana): encabezado de una línea y control compacto
    final tight = box.maxHeight < 520;
    return MaxWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(),
          ..._banners(view),
          Expanded(
            child: _viewSwitcher(view, switch (view) {
              _View.setup => _setupView(),
              _View.ready => _readyIntro(),
              _View.notes => _notesView(short: short, expanded: expanded, tight: tight),
            }),
          ),
          if (view != _View.setup)
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.m),
              child: _control(view, expanded: expanded, tight: tight, short: short, height: box.maxHeight),
            ),
        ],
      ),
    );
  }

  /// Listo y Presentar en pantallas anchas: a un lado el contenido (notas o indicaciones), del
  /// lado de la mano lo que se toca (siguiente diapositiva, acciones y los botones grandes).
  Widget _twoPane(_View view, {required bool expanded, required BoxConstraints box}) {
    final next = view == _View.notes ? c.nextSlide : null;
    final content = Expanded(
      child: _viewSwitcher(
        view,
        view == _View.ready ? _readyIntro() : _notesView(short: false, expanded: expanded, showNext: false),
      ),
    );
    final panel = SizedBox(
      width: (box.maxWidth * 0.32).clamp(320.0, 420.0),
      child: Padding(
        padding: EdgeInsets.fromLTRB(_left ? Sp.l : 0, Sp.l, _left ? 0 : Sp.l, Sp.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (next != null) ...[
              _nextLine(next, compact: false, short: false, padding: EdgeInsets.zero),
              const SizedBox(height: Sp.l),
            ],
            _actionsOrLock(view, expanded: expanded, tight: false),
            const SizedBox(height: Sp.s + 2),
            Expanded(child: _pads(vertical: true)),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _topBar(),
        ..._banners(view),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _left ? [panel, content] : [content, panel],
          ),
        ),
      ],
    );
  }

  /// Cambio entre Preparar / Listo / Presentar. Cada vista ocupa todo el espacio, desde arriba
  /// (el AnimatedSwitcher por defecto las centraría verticalmente).
  Widget _viewSwitcher(_View view, Widget child) => AnimatedSwitcher(
    duration: Mo.of(context, Mo.med),
    switchInCurve: Mo.curve,
    switchOutCurve: Curves.easeIn,
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
    child: KeyedSubtree(key: ValueKey(view), child: child),
  );

  List<Widget> _banners(_View view) => [
    if ((view == _View.notes || _stageOn) && view != _View.setup && !_connected) _reconnectBanner(),
    if (view != _View.setup && _showStart)
      IgnorePointer(
        ignoring: c.locked,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
          child: PresentOnPc(c: c, onDismiss: () => setState(() => _startDismissed = true)),
        ),
      ),
  ];

  // ================================================================ control (abajo)

  /// Barra de acciones (o la de pantalla bloqueada) y los botones de cambiar diapositiva.
  Widget _control(
    _View view, {
    required bool expanded,
    required bool tight,
    required bool short,
    required double height,
    bool compactPads = false,
    bool stage = false,
  }) {
    // Siempre "anterior" y "siguiente" lado a lado, con "siguiente" del lado de la mano: el pulgar
    // los encuentra en el mismo lugar con o sin notas. Sin notas hay más espacio y crecen un poco.
    const vertical = false;
    final double padsHeight;
    // Con la diapositiva en pantalla, los botones no crecen aunque no haya notas
    if (view == _View.ready && !stage) {
      padsHeight = (height * (c.oneHand ? 0.24 : 0.2)).clamp(tight ? 88.0 : 116.0, 176.0);
    } else {
      final compact = expanded || tight || compactPads;
      padsHeight = c.oneHand ? (tight ? 80.0 : 116.0) : (compact ? 64.0 : (short ? 88.0 : 100.0));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionsOrLock(view, expanded: expanded, tight: tight),
        const SizedBox(height: Sp.s + 2),
        SizedBox(
          height: padsHeight,
          child: _pads(vertical: vertical, compact: !vertical && (expanded || tight || compactPads)),
        ),
      ],
    );
  }

  Widget _pads({required bool vertical, bool compact = false, bool rail = false}) => NavPads(
    onPrev: () => _go(false),
    onNext: () => _go(true),
    prevPulse: c.pulsePrev,
    nextPulse: c.pulseNext,
    prevHint: c.invert ? 'VOL +' : 'VOL −',
    nextHint: c.invert ? 'VOL −' : 'VOL +',
    leftHanded: _left,
    vertical: vertical,
    compact: compact,
    rail: rail,
    enabled: !c.locked,
    dim: !c.canSend,
  );

  Widget _actionsOrLock(_View view, {required bool expanded, required bool tight}) => AnimatedSwitcher(
    duration: Mo.of(context, Mo.fast),
    child: c.locked
        ? LockBar(key: const ValueKey('lock'), dense: tight, onUnlock: () => c.setLocked(false))
        : ActionBar(
            key: const ValueKey('actions'),
            dense: tight,
            leftHanded: _left,
            actions: _actions(view, expanded: expanded),
          ),
  );

  /// En orden de cercanía al pulgar: lo primero queda del lado de la mano.
  List<StageAction> _actions(_View view, {required bool expanded}) {
    final canJump = c.deck != null || _knownPage() != null;
    return [
      StageAction(
        icon: Icons.format_list_numbered_rounded,
        label: t('Ir a', 'Go to'),
        tooltip: t('Ir a otra diapositiva', 'Go to another slide'),
        onTap: canJump ? _openSlideList : null,
      ),
      if (view == _View.notes)
        StageAction(
          icon: expanded ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
          label: t('Notas', 'Notes'),
          tooltip: expanded ? t('Contraer notas', 'Collapse notes') : t('Expandir notas', 'Expand notes'),
          active: expanded,
          onTap: () {
            // Notas a lo grande: la diapositiva se esconde, así que la herramienta se guarda
            if (!expanded) _tools.putAway();
            setState(() => _notesExpanded = !expanded);
          },
        ),
      if (c.oneHand) StageAction(icon: Icons.more_horiz_rounded, label: t('Más', 'More'), onTap: _openMore),
      StageAction(
        icon: Icons.lock_outline_rounded,
        label: t('Bloquear', 'Lock'),
        tooltip: t('Bloquear la pantalla (solo volumen)', 'Lock the screen (volume only)'),
        onTap: () => c.setLocked(true),
      ),
    ];
  }

  // ================================================================ barra superior

  /// [dense]: una sola línea (teléfono acostado), sin el modo ni el detalle.
  Widget _topBar({bool dense = false}) {
    final s = c.status;
    final dnd = c.dndState == DndState.on;
    return IgnorePointer(
      ignoring: c.locked,
      child: AnimatedOpacity(
        duration: Mo.of(context, Mo.med),
        opacity: c.locked ? 0.5 : 1,
        child: Padding(
          padding: dense
              ? const EdgeInsets.fromLTRB(Sp.s, Sp.s, 0, 0)
              : const EdgeInsets.fromLTRB(Sp.m, Sp.s, Sp.xs, Sp.xs),
          child: Row(
            children: [
              // Pastilla de conexión: estado, modo y dispositivo. Al tocarla, la hoja de conexión.
              // Ocupa lo que necesita, hasta todo el ancho que dejan el cronómetro y Ajustes.
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Semantics(
                    button: true,
                    label: t('Conexión', 'Connection'),
                    child: Material(
                      color: Pal.raise,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.l)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _openConnection,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: dense ? 44 : 50),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(Sp.m + 2, Sp.xs + 2, Sp.s + 2, Sp.xs + 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Dot(connColor(s.conn)),
                                const SizedBox(width: Sp.m),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        s.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Txt.text(14.5, weight: FontWeight.w700, height: 1.2),
                                      ),
                                      if (!dense)
                                        Text(
                                          [
                                            modeName(c.mode),
                                            if (s.subtitle != null && s.subtitle!.isNotEmpty) s.subtitle!,
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Txt.text(12, color: Pal.muted, height: 1.25),
                                        ),
                                    ],
                                  ),
                                ),
                                if (dnd) ...[
                                  const SizedBox(width: Sp.s),
                                  Tooltip(
                                    message: t('No molestar activo', 'Do not disturb is on'),
                                    child: Icon(Icons.do_not_disturb_on_rounded, size: 16, color: Pal.muted),
                                  ),
                                ],
                                const SizedBox(width: Sp.xs),
                                Icon(Icons.unfold_more_rounded, size: 18, color: Pal.muted),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Sp.s),
              TimerChip(c.timer),
              if (!c.oneHand)
                IconButton(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune_rounded),
                  tooltip: t('Ajustes', 'Settings'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Con notas en pantalla y sin conexión: las notas se quedan; este aviso lleva a reconectar.
  Widget _reconnectBanner() {
    final s = c.status;
    final color = s.conn == Conn.error ? Pal.error : Pal.busy;
    return IgnorePointer(
      ignoring: c.locked,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
        child: Material(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Rad.l),
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.l),
            onTap: _openConnection,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.xs, Sp.xs),
              child: Row(
                children: [
                  Icon(Icons.link_off_rounded, size: 20, color: color),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: Text(
                      s.subtitle?.isNotEmpty == true ? '${s.title} · ${s.subtitle}' : s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.text(14, weight: FontWeight.w600, height: 1.3),
                    ),
                  ),
                  TextButton(onPressed: _openConnection, child: Text(t('Conectar', 'Connect'))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ================================================================ Preparar

  Widget _setupView() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(Sp.page, Sp.l, Sp.page, Sp.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Image.asset('assets/icon/logo.png', width: 34, height: 34, filterQuality: FilterQuality.medium),
            const SizedBox(width: Sp.xs),
            Text('Zlide', style: Txt.number(30)),
          ],
        ),
        const SizedBox(height: Sp.xl),
        Text(t('¿Cómo vas a presentar?', 'How will you present?'), style: Txt.title(28)),
        const SizedBox(height: Sp.s),
        Text(
          t(
            'Elige cómo se conecta el teléfono con la PC. Puedes cambiarlo cuando quieras.',
            'Choose how the phone connects to the computer. You can change it anytime.',
          ),
          style: Txt.text(15, color: Pal.muted),
        ),
        const SizedBox(height: Sp.l),
        ModePicker(c: c),
        const SizedBox(height: Sp.xxl),
        ConnectionContent(c: c, onNudge: _showNudge, onDraw: _showStage),
        const SizedBox(height: Sp.l),
        _addNotesLink(),
      ],
    ),
  );

  // ================================================================ Listo (sin notas)

  /// Número (si se sabe), "Listo para presentar" y las indicaciones.
  Widget _readyIntro() {
    final fwd = c.invert ? 'VOL −' : 'VOL +';
    final back = c.invert ? 'VOL +' : 'VOL −';
    final page = _knownPage();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xl, Sp.page, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (page != null) ...[
            _jumpTarget(
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(page.$1.toString().padLeft(2, '0'), style: Txt.number(64)),
                  const SizedBox(width: Sp.s),
                  Text(
                    '/ ${page.$2}',
                    style: Txt.digits(18, color: Pal.muted, weight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Sp.l),
          ],
          Text(t('Listo para presentar', 'Ready to present'), style: Txt.title(30)),
          const SizedBox(height: Sp.s),
          Text(
            t(
              'Cambia de diapositiva con los botones de volumen o con los de abajo.',
              'Change slides with the volume buttons or the buttons below.',
            ),
            style: Txt.text(16, color: Pal.muted),
          ),
          const SizedBox(height: Sp.l),
          Wrap(
            spacing: Sp.l,
            runSpacing: Sp.s,
            children: [_keyHint(fwd, t('siguiente', 'next')), _keyHint(back, t('anterior', 'previous'))],
          ),
          const SizedBox(height: Sp.xl),
          IgnorePointer(ignoring: c.locked, child: _addNotesLink()),
        ],
      ),
    );
  }

  /// (página, total) cuando se sabe sin notas: transmitiendo desde el móvil o la PC.
  (int, int)? _knownPage() {
    if (c.mode == Mode.browser && c.browser.total > 0) return (c.browser.page, c.browser.total);
    if (c.mode == Mode.wifi && c.shownTotal > 0) return (c.shownPage, c.shownTotal);
    return null;
  }

  /// "[VOL +] siguiente": la tecla como una tecla física, y lo que hace.
  Widget _keyHint(String key, String what) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.s + 2, vertical: 5),
        decoration: BoxDecoration(
          color: Pal.raiseHi,
          borderRadius: BorderRadius.circular(Rad.s - 2),
          border: Border(bottom: BorderSide(color: Pal.faint.withValues(alpha: 0.6), width: 2)),
        ),
        child: Text(key, style: Txt.digits(13, color: Pal.ink)),
      ),
      const SizedBox(width: Sp.s),
      Text(what, style: Txt.text(14.5, weight: FontWeight.w600, height: 1.2)),
      const SizedBox(width: Sp.s),
    ],
  );

  Widget _addNotesLink() {
    if (c.deckLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Sp.m),
            Text(t('Leyendo notas…', 'Reading notes…'), style: Txt.text(15, color: Pal.muted)),
          ],
        ),
      );
    }
    // Estado vacío que orienta: qué ganas con las notas y cómo agregarlas
    return Material(
      color: Pal.raise,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.l)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: c.pickNotes,
        child: Padding(
          padding: const EdgeInsets.all(Sp.l),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: Pal.accentSoft, borderRadius: BorderRadius.circular(Rad.m - 2)),
                child: Icon(Icons.sticky_note_2_outlined, color: Pal.onAccentSoft),
              ),
              const SizedBox(width: Sp.m + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('Agrega tus notas', 'Add your notes'),
                      style: Txt.text(16, weight: FontWeight.w700, height: 1.25),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      c.mode == Mode.wifi
                          ? t(
                              'Elige el .pptx aquí, o la presentación en la app de la PC: las notas llegan solas.',
                              'Pick the .pptx here, or the presentation in the desktop app: the notes arrive by themselves.',
                            )
                          : t(
                              'Elige el .pptx y verás aquí, en grande, lo que vas a decir en cada diapositiva.',
                              'Pick the .pptx and you’ll see here, large, what to say on each slide.',
                            ),
                      style: Txt.text(13.5, color: Pal.muted, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.s),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Icon(Icons.add_rounded, color: Pal.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================================================================ Presentar (con notas)

  Widget _notesView({required bool short, required bool expanded, bool tight = false, bool showNext = true}) {
    final s = c.currentSlide;
    final next = c.nextSlide;
    final total = c.deck!.length;
    final number = (c.slide + 1).toString().padLeft(2, '0');
    final title = s?.title.isNotEmpty == true ? s!.title : '${t('Diapositiva', 'Slide')} ${s?.number ?? c.slide + 1}';
    final slideKey = ValueKey('${c.slide}-${c.deckName}');
    final steps = _stepsBadge();

    final Widget head = expanded || tight || c.oneHand
        // Expandidas, poca altura o una mano: el encabezado se reduce a una línea
        ? _compactHead(padding: const EdgeInsets.fromLTRB(Sp.page, Sp.s, Sp.page, 0))
        : Padding(
            padding: EdgeInsets.fromLTRB(Sp.page, short ? Sp.s : Sp.l, Sp.page, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _jumpTarget(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _swap(slideKey, Text(number, style: Txt.number(short ? 60 : 76))),
                          const SizedBox(width: Sp.s),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '/ $total',
                              style: Txt.digits(19, color: Pal.muted, weight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (steps != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: steps),
                  ],
                ),
                const SizedBox(height: Sp.m),
                _swap(
                  slideKey,
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.title(short ? 21 : 24)),
                ),
                const SizedBox(height: Sp.l),
                SlideProgress(current: c.slide, total: total),
              ],
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IgnorePointer(ignoring: c.locked, child: head),
        Expanded(
          child: _notesText(padding: EdgeInsets.fromLTRB(Sp.page, expanded || tight ? Sp.m : Sp.l + 4, Sp.page, Sp.xl)),
        ),
        if (next != null && showNext) _nextLine(next, compact: expanded || tight, short: short),
      ],
    );
  }

  /// Las notas de la diapositiva actual, desplazables, con el final desvanecido.
  Widget _notesText({required EdgeInsets padding, double scale = 1}) {
    final s = c.currentSlide;
    final hasNotes = s != null && s.notes.trim().isNotEmpty;
    return ShaderMask(
      // Desvanecer el final para que se note que hay más texto
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0, 0.9, 1],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      // Bloqueada, las notas se siguen pudiendo desplazar (leer no cambia nada)
      child: SingleChildScrollView(
        key: ValueKey('${c.slide}-${c.deckName}'), // al cambiar de diapositiva, regresar arriba
        padding: padding,
        child: AnimatedDefaultTextStyle(
          duration: Mo.of(context, Mo.med),
          curve: Mo.curve,
          style: Txt.text(c.notesFont * scale, height: 1.5, color: hasNotes ? Pal.ink : Pal.faint),
          child: Text(hasNotes ? s.notes.trim() : t('Sin notas en esta diapositiva.', 'No notes on this slide.')),
        ),
      ),
    );
  }

  /// "2/5": paso de animación de la diapositiva, si tiene.
  Widget? _stepsBadge() {
    final fx = c.animProgress;
    if (fx == null) return null;
    return Semantics(
      label: t('Animación ${fx.step} de ${fx.total}', 'Animation ${fx.step} of ${fx.total}'),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.s + 2, vertical: 4),
        decoration: BoxDecoration(color: Pal.accentSoft, borderRadius: BorderRadius.circular(99)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_motion_rounded, size: 14, color: Pal.onAccentSoft),
            const SizedBox(width: 5),
            Text('${fx.step}/${fx.total}', style: Txt.digits(12.5, color: Pal.onAccentSoft)),
          ],
        ),
      ),
    );
  }

  /// Encabezado de una línea: "03 / 18", el título y el paso de animación. Tocar el número
  /// abre la lista para saltar. Sin notas, la página que se transmite.
  Widget _compactHead({required EdgeInsets padding}) {
    final d = c.deck;
    final s = c.currentSlide;
    final page = _knownPage();
    final String counter;
    final String title;
    if (d != null) {
      counter = '${(c.slide + 1).toString().padLeft(2, '0')} / ${d.length}';
      title = s?.title.isNotEmpty == true ? s!.title : '${t('Diapositiva', 'Slide')} ${s?.number ?? c.slide + 1}';
    } else {
      final p = page ?? (_src != null ? (_src!.page, 0) : null);
      counter = p == null ? '' : (p.$2 > 0 ? '${p.$1.toString().padLeft(2, '0')} / ${p.$2}' : '${p.$1}');
      title = _connected ? t('Presentando', 'Presenting') : t('Sin conectar', 'Not connected');
    }
    final steps = _stepsBadge();
    return IgnorePointer(
      ignoring: c.locked,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            if (counter.isNotEmpty) ...[
              _jumpTarget(
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.s, horizontal: 2),
                  child: Text(counter, style: Txt.digits(16, color: Pal.accent)),
                ),
              ),
              const SizedBox(width: Sp.m),
            ],
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Txt.text(15, weight: FontWeight.w700, color: d != null ? Pal.ink : Pal.muted),
              ),
            ),
            if (steps != null) ...[const SizedBox(width: Sp.s), steps],
          ],
        ),
      ),
    );
  }

  // ================================================================ escenario (diapositiva en vivo)

  /// Teléfono en vertical: encabezado, diapositiva, herramientas, notas y el control. Con una
  /// herramienta en la mano la diapositiva gana ancho, las notas se achican y los botones de
  /// cambiar diapositiva se compactan.
  Widget _stagePortrait(_View view, BoxConstraints box) {
    final tight = box.maxHeight < 520;
    final drawing = _tools.tool != null;
    final src = _src!;
    final next = view == _View.notes ? c.nextSlide : null;
    return MaxWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(),
          ..._banners(view),
          Expanded(
            child: LayoutBuilder(
              builder: (context, b) {
                // La diapositiva crece al dibujar, pero siempre deja unas líneas de notas
                final rest = 40 + (drawing ? 112 : 68) + (SlideExtras.has(src) ? 48 : 0) + 72;
                final slideMax = (b.maxHeight - rest).clamp(120.0, b.maxHeight * (drawing ? 0.56 : 0.42));
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _compactHead(padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xs, Sp.page, Sp.xs)),
                    AnimatedPadding(
                      duration: Mo.of(context, Mo.med),
                      curve: Mo.curve,
                      padding: EdgeInsets.symmetric(horizontal: drawing ? Sp.s : Sp.l),
                      child: _slideArea(src, maxHeight: slideMax, room: b.maxHeight - 96), // encabezado y "Sigue"
                    ),
                    if (src.link == null) ...[
                      const SizedBox(height: Sp.s),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Sp.l),
                        child: _inkToolbar(src),
                      ),
                    ],
                    if (SlideExtras.has(src))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, 0, 0),
                        child: IgnorePointer(
                          ignoring: c.locked,
                          child: SlideExtras(src: src),
                        ),
                      ),
                    Expanded(child: _stageBelow(view, scale: drawing ? 0.8 : 0.92)),
                    if (next != null && !drawing && !tight) _nextLine(next, compact: true, short: true),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.m),
            child: _control(
              view,
              expanded: false,
              compactPads: drawing,
              stage: true,
              tight: tight,
              short: true,
              height: box.maxHeight,
            ),
          ),
        ],
      ),
    );
  }

  /// Tableta (o ventana ancha y alta): la diapositiva lo más grande posible a un lado; notas,
  /// acciones y botones del lado de la mano.
  Widget _stageWide(_View view, BoxConstraints box) {
    final src = _src!;
    final next = view == _View.notes ? c.nextSlide : null;
    final content = Expanded(
      child: Padding(
        padding: EdgeInsets.fromLTRB(_left ? Sp.s : Sp.l, Sp.xs, _left ? Sp.l : Sp.s, Sp.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _compactHead(padding: const EdgeInsets.only(bottom: Sp.xs)),
            Expanded(
              child: Center(child: _slideArea(src, maxHeight: double.infinity)),
            ),
            if (src.link == null) ...[
              const SizedBox(height: Sp.s),
              Center(
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: _inkToolbar(src)),
              ),
            ],
          ],
        ),
      ),
    );
    final panel = SizedBox(
      width: (box.maxWidth * 0.36).clamp(300.0, 420.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (SlideExtras.has(src))
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, 0, 0),
              child: IgnorePointer(
                ignoring: c.locked,
                child: SlideExtras(src: src),
              ),
            ),
          Expanded(child: _stageBelow(view)),
          if (next != null) _nextLine(next, compact: false, short: true),
          Padding(
            padding: EdgeInsets.fromLTRB(_left ? Sp.l : 0, Sp.s, _left ? 0 : Sp.l, Sp.m),
            child: _control(
              view,
              expanded: false,
              compactPads: true,
              stage: true,
              tight: false,
              short: true,
              height: box.maxHeight,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _topBar(),
        ..._banners(view),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _left ? [panel, content] : [content, panel],
          ),
        ),
      ],
    );
  }

  /// Teléfono acostado (poca altura). Tres franjas, de afuera hacia la mano:
  ///  - la diapositiva con sus herramientas, del alto completo (su ancho sale de ese alto);
  ///  - las notas, con el estado de la conexión y el número arriba, en una línea cada uno;
  ///  - un riel al borde, donde cae el pulgar: acciones arriba y los botones de cambiar
  ///    diapositiva abajo, a todo lo que queda de alto.
  /// "Notas" esconde la diapositiva (sin volver a vertical) y las notas toman su lugar. Al
  /// dibujar, la diapositiva se queda igual y la fila de colores le quita un poco de alto.
  Widget _stageLandscape(_View view, BoxConstraints box, {required bool expanded}) {
    final src = _src!;
    final drawing = _tools.tool != null;
    final next = view == _View.notes ? c.nextSlide : null;
    const railW = 96.0;
    // Ancho de la diapositiva: el que corresponde a su alto, sin pasar de un 58 % (las notas
    // necesitan líneas legibles); al dibujar o con un enlace abierto, las notas ceden más
    final img = src.image(src.page);
    final aspect = img != null ? img.width / img.height : 16 / 9;
    final toolbarH = src.link != null ? 0.0 : (drawing ? 112.0 : 68.0);
    final free = box.maxWidth - railW;
    final maxW = drawing || src.link != null ? free - 240 : free * 0.58;
    final slideW = ((box.maxHeight - Sp.s * 2 - toolbarH) * aspect).clamp(220.0, maxW);
    final slide = SizedBox(
      width: slideW + Sp.s * 2,
      child: Padding(
        padding: const EdgeInsets.all(Sp.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Center(child: _slideArea(src, maxHeight: double.infinity)),
            ),
            if (src.link == null) ...[const SizedBox(height: Sp.s), _inkToolbar(src)],
          ],
        ),
      ),
    );
    final notes = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _topBar(dense: true),
          _compactHead(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.s, 0)),
          if (SlideExtras.has(src))
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, 0, 0),
              child: IgnorePointer(
                ignoring: c.locked,
                child: SlideExtras(src: src),
              ),
            ),
          Expanded(child: _stageBelow(view, scale: expanded ? 1 : 0.9)),
          if (next != null && !drawing) _nextLine(next, compact: true, short: true),
          // Bloqueada: el aviso va aquí, a lo ancho; el riel queda solo con los botones
          if (c.locked)
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xs, Sp.s, Sp.s),
              child: LockBar(onUnlock: () => c.setLocked(false)),
            ),
        ],
      ),
    );
    final actions = _actions(view, expanded: expanded);
    final rail = SizedBox(
      width: railW,
      child: Padding(
        padding: EdgeInsets.fromLTRB(_left ? Sp.s : 0, Sp.s, _left ? 0 : Sp.s, Sp.s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!c.locked) ...[
              ActionBar(
                actions: actions,
                leftHanded: _left,
                vertical: true,
                // Con poco alto o muchas acciones, solo íconos (el nombre sale al mantener presionado)
                dense: box.maxHeight < 400 || actions.length > 3,
              ),
              const SizedBox(height: Sp.s),
            ],
            Expanded(child: _pads(vertical: true, rail: true)),
          ],
        ),
      ),
    );
    final strips = [if (!expanded) slide, notes, rail];
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: _left ? strips.reversed.toList() : strips);
  }

  /// La diapositiva con lo dibujado; con un enlace abierto en la PC, sus controles en su lugar.
  /// [room]: todo el alto que queda (el panel de un enlace puede usar más que la diapositiva).
  Widget _slideArea(DrawSource src, {required double maxHeight, double room = double.infinity}) {
    if (src.link case final link?) {
      // Con un enlace abierto no hay herramientas de dibujo: el panel toma ese espacio, sin
      // pasarse del que hay en pantallas pequeñas
      final h = maxHeight.isFinite ? (maxHeight + 60).clamp(300.0, 420.0).clamp(0.0, room) : null;
      return SizedBox(
        height: h,
        child: IgnorePointer(
          ignoring: c.locked,
          child: LinkPanel(src: src, link: link),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SlideCanvas(src: src, tools: _tools, enabled: !c.locked, onIdleTouch: _drawHint),
    );
  }

  Widget _inkToolbar(DrawSource src) => IgnorePointer(
    ignoring: c.locked,
    child: AnimatedOpacity(
      duration: Mo.of(context, Mo.med),
      opacity: c.locked ? 0.4 : 1,
      child: InkToolbar(
        src: src,
        tools: _tools,
        leftHanded: _left,
        onRotate: isTablet ? null : _toggleRotation,
        landscape: _landscape,
      ),
    ),
  );

  /// Debajo de la diapositiva: las notas o, sin ellas, cómo agregarlas.
  /// [scale]: tamaño de las notas respecto al elegido en Ajustes (comparten la pantalla).
  Widget _stageBelow(_View view, {double scale = 0.92}) {
    if (view == _View.notes) {
      return _notesText(padding: const EdgeInsets.fromLTRB(Sp.page, Sp.m, Sp.page, Sp.l), scale: scale);
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.l),
      child: IgnorePointer(ignoring: c.locked, child: _addNotesLink()),
    );
  }

  /// "Sigue → título". Al transmitir, la miniatura de la siguiente diapositiva en su lugar.
  Widget _nextLine(
    SlideInfo next, {
    required bool compact,
    required bool short,
    EdgeInsets padding = const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xs),
  }) {
    final title = next.title.isNotEmpty ? next.title : '${t('diapositiva', 'slide')} ${next.number}';
    final text = Padding(
      padding: padding,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: t('Sigue', 'Next'),
              style: Txt.text(14, color: Pal.muted),
            ),
            // Ícono y no el carácter "→": así se ve igual con cualquier tipografía
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.s),
                child: Icon(Icons.arrow_forward_rounded, size: 15, color: Pal.muted),
              ),
            ),
            TextSpan(
              text: title,
              style: Txt.text(14, weight: FontWeight.w600),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final path = c.thumbPdf;
    final page = c.nextPage;
    if (compact || path == null || page == null) return text;
    return ListenableBuilder(
      listenable: c.thumbs,
      builder: (context, _) {
        if (c.thumbs.failed(path, page)) return text;
        final h = short ? 58.0 : 72.0;
        c.thumbs.request(path, page, (h * 16 / 9 * MediaQuery.devicePixelRatioOf(context)).round());
        final img = c.thumbs.image(path, page);
        return Padding(
          padding: padding.copyWith(top: padding.top + Sp.xs),
          child: SizedBox(
            height: h,
            child: Row(
              children: [
                AspectRatio(
                  aspectRatio: img == null ? 16 / 9 : img.width / img.height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Pal.raise,
                      borderRadius: BorderRadius.circular(Rad.s - 4),
                      border: Border.all(color: Pal.rule),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Rad.s - 5),
                      child: AnimatedSwitcher(
                        duration: Mo.of(context, Mo.fast),
                        child: img == null
                            ? const SizedBox.expand()
                            : Image.memory(img.bytes, key: ValueKey(img), fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(t('Sigue', 'Next'), style: Txt.text(12.5, color: Pal.muted, height: 1.2)),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Txt.text(14, weight: FontWeight.w600, height: 1.25),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Cambio suave del número y el título al pasar de diapositiva.
  Widget _swap(Key key, Widget child) => AnimatedSwitcher(
    duration: Mo.of(context, Mo.fast),
    layoutBuilder: (current, previous) =>
        Stack(alignment: Alignment.bottomLeft, children: [...previous, if (current != null) current]),
    transitionBuilder: (w, a) => FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(a),
        child: w,
      ),
    ),
    child: KeyedSubtree(key: key, child: child),
  );

  // ================================================================ ir a una diapositiva

  /// El número de la diapositiva: al tocarlo sale la lista para saltar a otra.
  Widget _jumpTarget(Widget child) => Semantics(
    button: true,
    label: t('Ir a otra diapositiva', 'Go to another slide'),
    child: InkWell(borderRadius: BorderRadius.circular(Rad.s), onTap: _openSlideList, child: child),
  );

  void _openSlideList() {
    final d = c.deck;
    final total = d?.length ?? (_knownPage()?.$2 ?? 0);
    if (total <= 0) return;
    HapticFeedback.selectionClick();
    final current = d != null ? c.slide : (_knownPage()!.$1 - 1).clamp(0, total - 1);
    const rowH = 60.0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.82),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t('Ir a la diapositiva', 'Go to slide'), style: Txt.title(26)),
                    if (!c.slideIsExact) ...[
                      const SizedBox(height: Sp.xs),
                      Text(
                        t(
                          'El teléfono escribe el número y Enter, como en PowerPoint o Impress.',
                          'The phone types the number and Enter, as in PowerPoint or Impress.',
                        ),
                        style: Txt.text(14, color: Pal.muted, height: 1.35),
                      ),
                    ],
                  ],
                ),
              ),
              // Sin transmitir el teléfono cuenta las pulsaciones: aquí se corrige si se desfasó
              if (d != null && !c.slideIsExact)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xs, Sp.page, Sp.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(
                            '¿Las notas se desfasaron? Ajústalas sin mover la PC:',
                            'Notes out of step? Adjust them without moving the computer:',
                          ),
                          style: Txt.text(13.5, color: Pal.muted, height: 1.35),
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.adjustSlide(-1);
                        },
                        tooltip: t('Diapositiva anterior en las notas', 'Previous slide in the notes'),
                        icon: const Icon(Icons.remove_rounded),
                      ),
                      const SizedBox(width: Sp.s),
                      IconButton.filledTonal(
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.adjustSlide(1);
                        },
                        tooltip: t('Diapositiva siguiente en las notas', 'Next slide in the notes'),
                        icon: const Icon(Icons.add_rounded),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              Flexible(
                child: ListView.builder(
                  controller: ScrollController(initialScrollOffset: ((current - 2) * rowH).clamp(0, double.infinity)),
                  itemExtent: rowH,
                  itemCount: total,
                  itemBuilder: (ctx, i) {
                    final s = d?[i];
                    final here = i == current;
                    return Semantics(
                      selected: here,
                      button: true,
                      child: InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          if (d != null) {
                            c.goToSlide(i);
                          } else {
                            c.goToPage(i + 1);
                          }
                        },
                        child: Container(
                          color: here ? Pal.raise : null,
                          padding: const EdgeInsets.symmetric(horizontal: Sp.page),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(
                                  (i + 1).toString().padLeft(2, '0'),
                                  style: Txt.digits(17, color: here ? Pal.accent : Pal.muted),
                                ),
                              ),
                              const SizedBox(width: Sp.m),
                              Expanded(
                                child: Text(
                                  s?.title.isNotEmpty == true
                                      ? s!.title
                                      : '${t('Diapositiva', 'Slide')} ${s?.number ?? i + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Txt.text(16, weight: here ? FontWeight.w700 : FontWeight.w500, height: 1.25),
                                ),
                              ),
                              if (s != null && s.notes.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: Sp.s),
                                  child: Icon(Icons.notes_rounded, size: 16, color: Pal.faint),
                                ),
                              if (here) ...[const SizedBox(width: Sp.s), Dot(Pal.accent)],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================================================================ hojas y pantallas

  void _openConnection() {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: Listenable.merge([c, I18n.current]),
        builder: (ctx, _) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('Conexión', 'Connection'), style: Txt.title(26)),
                  const SizedBox(height: Sp.l),
                  ModePicker(c: c, compact: true),
                  const SizedBox(height: Sp.xl),
                  ConnectionContent(
                    c: c,
                    onNudge: _showNudge,
                    onDraw: () {
                      Navigator.pop(ctx);
                      _showStage();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Modo una mano: lo que estaba arriba (conexión, ajustes, cronómetro), en una hoja abajo.
  void _openMore() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: Listenable.merge([c, c.timer]),
        builder: (ctx, _) {
          final tm = c.timer;
          final s = c.status;
          Widget row(IconData icon, String title, String? sub, VoidCallback onTap) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Sp.page),
            leading: Icon(icon),
            title: Text(title),
            subtitle: sub == null ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(ctx);
              onTap();
            },
          );
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  Icons.link_rounded,
                  t('Conexión', 'Connection'),
                  '${s.title} · ${modeName(c.mode)}',
                  _openConnection,
                ),
                row(
                  tm.running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  tm.running ? t('Pausar cronómetro', 'Pause timer') : t('Iniciar cronómetro', 'Start timer'),
                  tm.label,
                  tm.toggle,
                ),
                if (!tm.running && !tm.isZero)
                  row(Icons.restart_alt_rounded, t('Reiniciar cronómetro', 'Reset timer'), null, tm.reset),
                row(
                  Icons.flag_outlined,
                  t('Tiempo objetivo', 'Target time'),
                  tm.target == null ? t('Sin objetivo', 'No target') : '${tm.target!.inMinutes} min',
                  () => showTargetPicker(context, tm),
                ),
                row(Icons.settings_outlined, t('Ajustes', 'Settings'), null, _openSettings),
                const SizedBox(height: Sp.s),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(c: c, modeName: modeName(c.mode)),
      ),
    );
  }

  /// "Ver la diapositiva y dibujar": el escenario, aunque la PC todavía no esté conectada.
  void _showStage() {
    if (!_stageOn) {
      _showNudge(
        c.mode == Mode.wifi
            ? t('La PC tiene que proyectar con Zlide', 'The computer has to present with Zlide')
            : t('Primero elige tu presentación', 'Choose your presentation first'),
      );
      return;
    }
    setState(() {
      _wantStage = true;
      _notesExpanded = false;
    });
  }
}
