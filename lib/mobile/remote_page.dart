import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/pptx_notes.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'connection_view.dart';
import 'draw_page.dart';
import 'remote_controller.dart';
import 'settings_page.dart';
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
/// Abajo siempre está el "control": una barra de acciones (ir a, diapositiva y dibujo, notas,
/// bloquear) y los botones de cambiar diapositiva, acomodados del lado de la mano dominante.
/// Con el modo una mano, todo lo que se toca queda abajo.
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

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: c.onForeground, onPause: c.onBackground);
    _nudgeSub = c.nudges.listen(_showNudge);
    c.init();
  }

  @override
  void dispose() {
    _nudgeSub?.cancel();
    _lifecycle.dispose();
    c.dispose();
    super.dispose();
  }

  void _showNudge(String msg) {
    HapticFeedback.heavyImpact();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1800)));
  }

  bool get _connected => c.status.conn == Conn.on;
  bool get _left => c.hand == Hand.left;

  bool get _canDraw =>
      (c.mode == Mode.browser && c.browser.hasPdf && !c.converting) || (c.mode == Mode.wifi && c.pcDrawUri != null);

  _View get _view => c.deck != null ? _View.notes : (_connected ? _View.ready : _View.setup);

  /// Aviso para empezar a presentar en la PC (modo WiFi, la PC tiene la presentación elegida).
  bool get _showStart => c.pcCanStart && c.wifi.pcDeckMode == DeckMode.none && !_startDismissed;

  // ================================================================ estructura

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, I18n.current]),
          builder: (context, _) {
            if (!c.ready) return const Center(child: CircularProgressIndicator());
            final view = _view;
            if (view != _View.notes) _notesExpanded = false;
            if (!c.pcCanStart) _startDismissed = false;
            final expanded = view == _View.notes && _notesExpanded;
            return PopScope(
              // Con la pantalla bloqueada "atrás" no hace nada; con las notas expandidas, las contrae
              canPop: !expanded && !c.locked,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                if (c.locked) {
                  HapticFeedback.heavyImpact();
                } else if (expanded) {
                  setState(() => _notesExpanded = false);
                }
              },
              child: LayoutBuilder(
                builder: (context, box) {
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
    if (view == _View.notes && !_connected) _reconnectBanner(),
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
  }) {
    final double padsHeight;
    final bool vertical;
    if (view == _View.ready) {
      // Sin notas: botones grandes, uno sobre otro
      vertical = true;
      padsHeight = (height * (c.oneHand ? 0.4 : 0.36)).clamp(tight ? 140.0 : 180.0, 320.0);
    } else {
      vertical = false;
      padsHeight = c.oneHand ? (tight ? 80.0 : 116.0) : (expanded || tight ? 64.0 : (short ? 88.0 : 100.0));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionsOrLock(view, expanded: expanded, tight: tight),
        const SizedBox(height: Sp.s + 2),
        SizedBox(
          height: padsHeight,
          child: _pads(vertical: vertical, compact: !vertical && (expanded || tight)),
        ),
      ],
    );
  }

  Widget _pads({required bool vertical, bool compact = false}) => NavPads(
    onPrev: () => c.tap(forward: false),
    onNext: () => c.tap(forward: true),
    prevPulse: c.pulsePrev,
    nextPulse: c.pulseNext,
    prevHint: c.invert ? 'VOL +' : 'VOL −',
    nextHint: c.invert ? 'VOL −' : 'VOL +',
    leftHanded: _left,
    vertical: vertical,
    compact: compact,
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
      if (_canDraw)
        StageAction(
          icon: Icons.draw_rounded,
          label: t('Dibujar', 'Draw'),
          tooltip: t('Ver la diapositiva y dibujar', 'View the slide and draw'),
          onTap: _openDraw,
        ),
      if (view == _View.notes)
        StageAction(
          icon: expanded ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
          label: t('Notas', 'Notes'),
          tooltip: expanded ? t('Contraer notas', 'Collapse notes') : t('Expandir notas', 'Expand notes'),
          active: expanded,
          onTap: () => setState(() => _notesExpanded = !expanded),
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

  Widget _topBar() {
    final s = c.status;
    return IgnorePointer(
      ignoring: c.locked,
      child: AnimatedOpacity(
        duration: Mo.of(context, Mo.med),
        opacity: c.locked ? 0.5 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xs, Sp.xs, 0),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: t('Conexión', 'Connection'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Rad.m),
                    onTap: _openConnection,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.xs),
                        child: Row(
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
                                    style: Txt.text(15, weight: FontWeight.w700, height: 1.2),
                                  ),
                                  Text(
                                    [
                                      modeName(c.mode),
                                      if (s.subtitle != null && s.subtitle!.isNotEmpty) s.subtitle!,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Txt.text(12.5, color: Pal.muted, height: 1.25),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: Sp.xs),
                            Icon(Icons.expand_more_rounded, size: 18, color: Pal.muted),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (c.dndState == DndState.on)
                Tooltip(
                  message: t('No molestar activo', 'Do not disturb is on'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                    child: Icon(Icons.do_not_disturb_on_outlined, size: 18, color: Pal.muted),
                  ),
                ),
              TimerChip(c.timer),
              if (!c.oneHand)
                IconButton(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
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
        ConnectionContent(c: c, onNudge: _showNudge, onDraw: _openDraw),
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
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [_keyHint(fwd, t('siguiente', 'next')), _keyHint(back, t('anterior', 'previous'))],
          ),
          const SizedBox(height: Sp.l),
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

  Widget _keyHint(String key, String what) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.s),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(Rad.s),
      border: Border.all(color: Pal.faint, width: 1.5),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: key,
            style: Txt.digits(13, color: Pal.accent),
          ),
          TextSpan(
            text: '  $what',
            style: Txt.text(14, weight: FontWeight.w600, height: 1.2),
          ),
        ],
      ),
    ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: c.pickNotes,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: Sp.s)),
          icon: const Icon(Icons.add_rounded, size: 20),
          label: Text(t('Agregar notas del presentador', 'Add speaker notes')),
        ),
        if (c.mode == Mode.wifi)
          Padding(
            padding: const EdgeInsets.only(left: Sp.s),
            child: Text(
              t(
                'O elige la presentación en la app de la PC: las notas llegan solas.',
                'Or choose the presentation in the desktop app: the notes arrive by themselves.',
              ),
              style: Txt.text(13, color: Pal.muted, height: 1.35),
            ),
          ),
      ],
    );
  }

  // ================================================================ Presentar (con notas)

  Widget _notesView({required bool short, required bool expanded, bool tight = false, bool showNext = true}) {
    final s = c.currentSlide;
    final next = c.nextSlide;
    final total = c.deck!.length;
    final hasNotes = s != null && s.notes.trim().isNotEmpty;
    final number = (c.slide + 1).toString().padLeft(2, '0');
    final title = s?.title.isNotEmpty == true ? s!.title : '${t('Diapositiva', 'Slide')} ${s?.number ?? c.slide + 1}';
    final slideKey = ValueKey('${c.slide}-${c.deckName}');
    final fx = c.animProgress;
    final steps = fx != null
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: Sp.s + 2, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: Pal.faint, width: 1.5),
            ),
            child: Text(
              '${t('animación', 'animation')} ${fx.step}/${fx.total}',
              style: Txt.text(12, weight: FontWeight.w600, color: Pal.muted, height: 1.2),
            ),
          )
        : null;

    final Widget head = expanded || tight || c.oneHand
        // Expandidas, poca altura o una mano: el encabezado se reduce a una línea
        ? Padding(
            padding: const EdgeInsets.fromLTRB(Sp.page, Sp.s, Sp.page, 0),
            child: Row(
              children: [
                _jumpTarget(
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Sp.s),
                    child: Text('$number / $total', style: Txt.digits(16, color: Pal.accent)),
                  ),
                ),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.text(15, weight: FontWeight.w700),
                  ),
                ),
                if (steps != null) ...[const SizedBox(width: Sp.s), steps],
              ],
            ),
          )
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
          child: ShaderMask(
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
              key: slideKey, // al cambiar de diapositiva, regresar arriba
              padding: EdgeInsets.fromLTRB(Sp.page, expanded || tight ? Sp.m : Sp.l + 4, Sp.page, Sp.xl),
              child: Text(
                hasNotes ? s.notes.trim() : t('Sin notas en esta diapositiva.', 'No notes on this slide.'),
                style: Txt.text(c.notesFont, height: 1.5, color: hasNotes ? Pal.ink : Pal.faint),
              ),
            ),
          ),
        ),
        if (next != null && showNext) _nextLine(next, compact: expanded || tight, short: short),
      ],
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
              text: '${t('Sigue', 'Next')}  →  ',
              style: Txt.text(14, color: Pal.muted),
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
                  padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xs, Sp.s, Sp.s),
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
                      _openDraw();
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

  void _openDraw() {
    final wifiUri = c.mode == Mode.wifi ? c.pcDrawUri : null;
    if (c.mode == Mode.wifi && wifiUri == null) {
      _showNudge(t('Conéctate a la PC primero', 'Connect to the computer first'));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => wifiUri != null ? DrawPage.wifi(c: c, uri: wifiUri) : DrawPage(c: c),
      ),
    );
  }
}
