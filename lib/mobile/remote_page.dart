import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'draw_page.dart';
import 'remote_controller.dart';
import 'timer_chip.dart';
import 'wifi_client.dart';

/// Pantalla principal del teléfono (dirección "Atril").
///
/// Tiene tres estados, según lo que el presentador necesita en ese momento:
///  - **Preparar** (sin conexión y sin notas): elegir el modo y conectar.
///  - **Listo** (conectado, sin notas): botones grandes de cambiar diapositiva.
///  - **Presentar** (con notas): número y título de la diapositiva, notas grandes y los botones
///    abajo. Si la conexión se cae, las notas se quedan y aparece un aviso para reconectar.
///
/// La conexión siempre está a un toque: la línea de estado de arriba abre la hoja "Conexión".
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

  double _notesFont = 22;
  bool _notesExpanded = false;

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

  bool get _canDraw =>
      (c.mode == Mode.browser && c.browser.hasPdf && !c.converting) || (c.mode == Mode.wifi && c.pcDrawUri != null);

  _View get _view => c.deck != null ? _View.notes : (_connected ? _View.ready : _View.setup);

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
            final expanded = view == _View.notes && _notesExpanded;
            return PopScope(
              // Con las notas expandidas, "atrás" solo las contrae
              canPop: !expanded,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && expanded) setState(() => _notesExpanded = false);
              },
              child: LayoutBuilder(builder: (context, box) {
                final short = box.maxHeight < 640;
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _topBar(),
                  if (view == _View.notes && !_connected) _reconnectBanner(),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: Mo.of(context, Mo.med),
                      switchInCurve: Mo.curve,
                      switchOutCurve: Curves.easeIn,
                      child: KeyedSubtree(
                        key: ValueKey(view),
                        child: switch (view) {
                          _View.setup => _setupView(),
                          _View.ready => _readyView(box.maxHeight),
                          _View.notes => _notesView(short: short, expanded: expanded),
                        },
                      ),
                    ),
                  ),
                  if (view != _View.ready)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.m),
                      child: SizedBox(
                        height: view == _View.setup || expanded ? 64 : (short ? 92 : 108),
                        child: _dockRow(compact: view == _View.setup || expanded),
                      ),
                    ),
                ]);
              }),
            );
          },
        ),
      ),
    );
  }

  // ================================================================ barra superior

  Widget _topBar() {
    final s = c.status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.s, Sp.xs, Sp.xs, 0),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            label: t('Conexión', 'Connection'),
            child: InkWell(
              borderRadius: BorderRadius.circular(Rad.s),
              onTap: _openConnection,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.xs),
                  child: Row(children: [
                    Dot(connColor(s.conn)),
                    const SizedBox(width: Sp.m),
                    Flexible(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Txt.text(15, weight: FontWeight.w600, height: 1.2)),
                        Text(
                          [_modeName(c.mode), if (s.subtitle != null && s.subtitle!.isNotEmpty) s.subtitle!].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Txt.text(12.5, color: Pal.muted, height: 1.25),
                        ),
                      ]),
                    ),
                    const SizedBox(width: Sp.xs),
                    Icon(Icons.expand_more_rounded, size: 18, color: Pal.muted),
                  ]),
                ),
              ),
            ),
          ),
        ),
        TimerChip(c.timer),
        IconButton(
          onPressed: _openSettings,
          icon: const Icon(Icons.tune_rounded),
          tooltip: t('Ajustes', 'Settings'),
        ),
      ]),
    );
  }

  /// Con notas en pantalla y sin conexión: las notas se quedan; este aviso lleva a reconectar.
  Widget _reconnectBanner() {
    final s = c.status;
    final color = s.conn == Conn.error ? Pal.error : Pal.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
      child: Material(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Rad.m),
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.m),
          onTap: _openConnection,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.xs, Sp.xs),
            child: Row(children: [
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
            ]),
          ),
        ),
      ),
    );
  }

  // ================================================================ Preparar

  Widget _setupView() => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Sp.page, Sp.l, Sp.page, Sp.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Image.asset('assets/icon/logo.png', width: 34, height: 34, filterQuality: FilterQuality.medium),
            const SizedBox(width: Sp.xs),
            Text('Zlide', style: Txt.number(30)),
          ]),
          const SizedBox(height: Sp.l),
          _modeSelector(),
          const SizedBox(height: Sp.xl),
          _modeContent(),
          const SizedBox(height: Sp.l),
          _addNotesLink(),
        ]),
      );

  Widget _modeSelector() => Segmented<Mode>(
        values: Mode.values,
        labels: [
          t('Control\nBluetooth', 'Bluetooth\ncontrol'),
          t('Transmitir\ndesde PC', 'Stream\nfrom PC'),
          t('Transmitir\ndesde móvil', 'Stream\nfrom phone'),
        ],
        selected: c.mode,
        onChanged: c.setMode,
      );

  // ================================================================ Listo (sin notas)

  Widget _readyView(double height) {
    final fwd = c.invert ? 'VOL −' : 'VOL +';
    final back = c.invert ? 'VOL +' : 'VOL −';
    final page = _knownPage();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Sp.page, Sp.xl, Sp.page, Sp.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (page != null) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(page.$1.toString().padLeft(2, '0'), style: Txt.number(64)),
                const SizedBox(width: Sp.s),
                Text('/ ${page.$2}', style: Txt.digits(18, color: Pal.muted, weight: FontWeight.w500)),
              ]),
              const SizedBox(height: Sp.l),
            ],
            Text(t('Listo para presentar', 'Ready to present'), style: Txt.title(30)),
            const SizedBox(height: Sp.s),
            Text(
              t('Cambia de diapositiva con los botones de volumen o con los de abajo.',
                  'Change slides with the volume buttons or the buttons below.'),
              style: Txt.text(16, color: Pal.muted),
            ),
            const SizedBox(height: Sp.l),
            Wrap(spacing: Sp.s, runSpacing: Sp.s, children: [
              _keyHint(fwd, t('siguiente', 'next')),
              _keyHint(back, t('anterior', 'previous')),
            ]),
            const SizedBox(height: Sp.l),
            Wrap(spacing: Sp.s, runSpacing: Sp.xs, children: [
              _addNotesLink(),
              if (_canDraw)
                TextButton.icon(
                  onPressed: _openDraw,
                  icon: const Icon(Icons.draw_rounded, size: 18),
                  label: Text(t('Dibujar sobre la diapositiva', 'Draw on the slide')),
                ),
            ]),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.m),
        child: SizedBox(height: (height * 0.42).clamp(200.0, 340.0), child: _dockColumn()),
      ),
    ]);
  }

  /// (página, total) cuando se sabe sin notas: transmitiendo desde el móvil o la PC.
  (int, int)? _knownPage() {
    if (c.mode == Mode.browser && c.browser.total > 0) return (c.browser.page, c.browser.total);
    return null;
  }

  Widget _keyHint(String key, String what) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.s),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Rad.s),
          border: Border.all(color: Pal.faint, width: 1.5),
        ),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: key, style: Txt.digits(13, color: Pal.accent)),
          TextSpan(text: '  $what', style: Txt.text(14, weight: FontWeight.w600, height: 1.2)),
        ])),
      );

  Widget _addNotesLink() {
    if (c.deckLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: Sp.m),
          Text(t('Leyendo notas…', 'Reading notes…'), style: Txt.text(15, color: Pal.muted)),
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
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
            t('O elige la presentación en la app de la PC: las notas llegan solas.',
                'Or choose the presentation in the desktop app: the notes arrive by themselves.'),
            style: Txt.text(13, color: Pal.muted, height: 1.35),
          ),
        ),
    ]);
  }

  // ================================================================ Presentar (con notas)

  Widget _notesView({required bool short, required bool expanded}) {
    final s = c.currentSlide;
    final next = c.nextSlide;
    final total = c.deck!.length;
    final hasNotes = s != null && s.notes.trim().isNotEmpty;
    final number = (c.slide + 1).toString().padLeft(2, '0');
    final title = s?.title.isNotEmpty == true ? s!.title : '${t('Diapositiva', 'Slide')} ${s?.number ?? c.slide + 1}';
    final slideKey = ValueKey('${c.slide}-${c.deckName}');

    final actions = Row(mainAxisSize: MainAxisSize.min, children: [
      // Corrección manual del contador (no mueve nada en la PC)
      if (!c.slideIsExact) ...[
        _iconAction(Icons.remove_rounded, t('Diapositiva anterior en las notas', 'Previous slide in the notes'),
            () => c.adjustSlide(-1)),
        _iconAction(Icons.add_rounded, t('Diapositiva siguiente en las notas', 'Next slide in the notes'),
            () => c.adjustSlide(1)),
      ],
      if (_canDraw) _iconAction(Icons.draw_rounded, t('Dibujar sobre la diapositiva', 'Draw on the slide'), _openDraw),
      _iconAction(
        expanded ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
        expanded ? t('Contraer notas', 'Collapse notes') : t('Expandir notas', 'Expand notes'),
        () => setState(() => _notesExpanded = !expanded),
      ),
    ]);

    final head = expanded
        // Expandidas: el encabezado se reduce a una línea
        ? Padding(
            padding: const EdgeInsets.fromLTRB(Sp.page, Sp.s, Sp.s, 0),
            child: Row(children: [
              Text('$number / $total', style: Txt.digits(16, color: Pal.accent)),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Text(title,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(15, weight: FontWeight.w600)),
              ),
              actions,
            ]),
          )
        : Padding(
            padding: EdgeInsets.fromLTRB(Sp.page, short ? Sp.s : Sp.l, Sp.s, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                _swap(
                  slideKey,
                  Text(number, style: Txt.number(short ? 60 : 76)),
                ),
                const SizedBox(width: Sp.s),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('/ $total', style: Txt.digits(19, color: Pal.muted, weight: FontWeight.w500)),
                ),
                const Spacer(),
                actions,
              ]),
              const SizedBox(height: Sp.m),
              Padding(
                padding: const EdgeInsets.only(right: Sp.m),
                child: _swap(
                  slideKey,
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Txt.title(short ? 21 : 24)),
                ),
              ),
              const SizedBox(height: Sp.l),
              Padding(
                padding: const EdgeInsets.only(right: Sp.m),
                child: Row(children: [
                  Expanded(child: _Progress(current: c.slide, total: total)),
                  if (s != null && s.clicks > 0) ...[
                    const SizedBox(width: Sp.m),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Sp.s + 2, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: Pal.faint, width: 1.5),
                      ),
                      child: Text('${t('animación', 'animation')} ${c.step}/${s.clicks}',
                          style: Txt.text(12, weight: FontWeight.w600, color: Pal.muted, height: 1.2)),
                    ),
                  ],
                ]),
              ),
            ]),
          );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
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
          child: SingleChildScrollView(
            key: slideKey, // al cambiar de diapositiva, regresar arriba
            padding: EdgeInsets.fromLTRB(Sp.page, expanded ? Sp.m : Sp.l + 4, Sp.page, Sp.xl),
            child: Text(
              hasNotes ? s.notes.trim() : t('Sin notas en esta diapositiva.', 'No notes on this slide.'),
              style: Txt.text(_notesFont, height: 1.5, color: hasNotes ? Pal.ink : Pal.faint),
            ),
          ),
        ),
      ),
      if (next != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xs),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '${t('Sigue', 'Next')}  →  ', style: Txt.text(14, color: Pal.muted)),
              TextSpan(
                text: next.title.isNotEmpty ? next.title : '${t('diapositiva', 'slide')} ${next.number}',
                style: Txt.text(14, weight: FontWeight.w600),
              ),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ]);
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

  Widget _iconAction(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        onPressed: onTap,
        tooltip: tooltip,
        style: IconButton.styleFrom(minimumSize: const Size(44, 44), padding: EdgeInsets.zero),
        icon: Icon(icon, size: 21, color: Pal.muted),
      );

  // ================================================================ botones de cambiar diapositiva

  /// Botón "anterior" chico a la izquierda y "siguiente" ancho: el pulgar cae en "siguiente".
  Widget _dockRow({bool compact = false}) {
    final dim = !c.canSend;
    return AnimatedOpacity(
      duration: Mo.of(context, Mo.med),
      opacity: dim ? 0.45 : 1,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: compact ? 72 : 92,
          child: _Pad(
            primary: false,
            label: t('Anterior', 'Previous'),
            icon: Icons.chevron_left_rounded,
            hint: c.invert ? 'VOL +' : 'VOL −',
            pulse: c.pulsePrev,
            layout: _PadLayout.icon,
            onTap: () => c.send(forward: false),
          ),
        ),
        const SizedBox(width: Sp.s + 2),
        Expanded(
          child: _Pad(
            primary: true,
            label: t('Siguiente', 'Next'),
            icon: Icons.arrow_forward_rounded,
            hint: c.invert ? 'VOL −' : 'VOL +',
            pulse: c.pulseNext,
            layout: compact ? _PadLayout.compact : _PadLayout.wide,
            onTap: () => c.send(forward: true),
          ),
        ),
      ]),
    );
  }

  /// Sin notas: botones grandes, uno arriba del otro.
  Widget _dockColumn() {
    final dim = !c.canSend;
    return AnimatedOpacity(
      duration: Mo.of(context, Mo.med),
      opacity: dim ? 0.45 : 1,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 2,
          child: _Pad(
            primary: true,
            label: t('Siguiente', 'Next'),
            icon: Icons.arrow_forward_rounded,
            hint: c.invert ? 'VOL −' : 'VOL +',
            pulse: c.pulseNext,
            layout: _PadLayout.big,
            onTap: () => c.send(forward: true),
          ),
        ),
        const SizedBox(height: Sp.s + 2),
        Expanded(
          child: _Pad(
            primary: false,
            label: t('Anterior', 'Previous'),
            icon: Icons.chevron_left_rounded,
            hint: c.invert ? 'VOL +' : 'VOL −',
            pulse: c.pulsePrev,
            layout: _PadLayout.compact,
            onTap: () => c.send(forward: false),
          ),
        ),
      ]),
    );
  }

  // ================================================================ hoja "Conexión"

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
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xl),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text(t('Conexión', 'Connection'), style: Txt.title(26)),
                const SizedBox(height: Sp.l),
                _modeSelector(),
                const SizedBox(height: Sp.xl),
                _modeContent(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeContent() => AnimatedSize(
        duration: Mo.of(context, Mo.med),
        curve: Mo.curve,
        alignment: Alignment.topCenter,
        child: KeyedSubtree(
          key: ValueKey(c.mode),
          child: switch (c.mode) {
            Mode.bluetooth => c.isIOS ? _bleSection() : _hidSection(),
            Mode.wifi => _wifiSection(),
            Mode.browser => _browserSection(),
          },
        ),
      );

  Widget _sectionHead(String title, [String? body]) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Txt.title(26)),
        if (body != null) ...[
          const SizedBox(height: Sp.s),
          Text(body, style: Txt.text(15.5, color: Pal.muted)),
        ],
      ]);

  /// Fila de lista con radio: PCs emparejadas o encontradas en la red.
  Widget _choiceRow({
    required bool selected,
    required String title,
    String? subtitle,
    bool mono = false,
    Widget? trailing,
    required VoidCallback onTap,
  }) =>
      Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Pal.rule))),
            child: Row(children: [
              AnimatedContainer(
                duration: Mo.of(context, Mo.fast),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? Pal.accent : Pal.faint, width: selected ? 7 : 2),
                ),
              ),
              const SizedBox(width: Sp.l),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(17, weight: FontWeight.w600, height: 1.25)),
                  if (subtitle != null)
                    Text(subtitle,
                        style: mono
                            ? Txt.digits(12.5, color: Pal.muted, weight: FontWeight.w500)
                            : Txt.text(13, color: Pal.muted, height: 1.3)),
                ]),
              ),
              if (trailing != null) trailing,
            ]),
          ),
        ),
      );

  // ---------------------------------------------------------------- Bluetooth (Android)

  Widget _hidSection() {
    final s = c.btState;
    if (s == BtState.connected) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionHead(
          c.btDeviceName ?? 'PC',
          t('Conectado como teclado Bluetooth. Los botones de volumen ya cambian la diapositiva.',
              'Connected as a Bluetooth keyboard. The volume buttons now change the slide.'),
        ),
        const SizedBox(height: Sp.l),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton(t('Desconectar', 'Disconnect'), onTap: c.disconnectBluetooth, dense: true),
        ),
      ]);
    }
    if (s == BtState.unavailable || s == BtState.off || s == BtState.noPermission) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionHead(
          switch (s) {
            BtState.off => t('Bluetooth apagado', 'Bluetooth is off'),
            BtState.noPermission => t('Falta un permiso', 'A permission is missing'),
            _ => t('No disponible', 'Not available'),
          },
          switch (s) {
            BtState.off => t('Actívalo en el teléfono y toca Reintentar.', 'Turn it on on the phone and tap Retry.'),
            BtState.noPermission => t('Zlide necesita el permiso de “Dispositivos cercanos” para funcionar como teclado.',
                'Zlide needs the “Nearby devices” permission to work as a keyboard.'),
            _ => c.btMessage ??
                t('El control Bluetooth no está disponible en este teléfono. Usa “Transmitir desde PC” o “Transmitir desde móvil”.',
                    'Bluetooth control is not available on this phone. Use “Stream from PC” or “Stream from phone”.'),
          },
        ),
        if (s != BtState.unavailable) ...[
          const SizedBox(height: Sp.l),
          PillButton(t('Reintentar', 'Retry'), primary: true, onTap: c.retryBluetooth),
        ],
      ]);
    }
    final connecting = s == BtState.connecting;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionHead(
        t('Conecta tu PC', 'Connect your computer'),
        t('El teléfono funciona como teclado Bluetooth. No hay que instalar nada en la PC (Windows, Mac, Linux o tablet).',
            'The phone works as a Bluetooth keyboard. Nothing to install on the computer (Windows, Mac, Linux or tablet).'),
      ),
      const SizedBox(height: Sp.m),
      DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Pal.rule))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (c.bonded.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: Text(
                t('Ninguna PC emparejada todavía. Toca “Emparejar nueva” y, en la PC, agrega el teléfono desde los ajustes de Bluetooth.',
                    'No paired computer yet. Tap “Pair new” and add the phone from the computer’s Bluetooth settings.'),
                style: Txt.text(15, color: Pal.muted),
              ),
            ),
          for (final d in c.bonded)
            _choiceRow(
              selected: d.address == c.selectedAddress,
              title: d.name,
              subtitle: t('Emparejada', 'Paired'),
              onTap: () => c.selectDevice(d.address),
            ),
        ]),
      ),
      const SizedBox(height: Sp.l),
      Row(children: [
        Expanded(
          child: PillButton(
            connecting ? t('Conectando…', 'Connecting…') : t('Conectar', 'Connect'),
            primary: true,
            onTap: connecting || c.selectedAddress == null ? null : c.connectSelected,
          ),
        ),
        const SizedBox(width: Sp.s + 2),
        Expanded(child: PillButton(t('Emparejar nueva', 'Pair new'), onTap: c.pairNew)),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: c.refreshBonded,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(t('Actualizar lista', 'Refresh list')),
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- Bluetooth (iPhone)

  Widget _bleSection() {
    final connected = c.btState == BtState.connected;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: _sectionHead(
          connected ? t('Conectado a la PC', 'Connected to the computer') : t('Buscando la PC…', 'Looking for the computer…'),
          connected
              ? t('Los botones de volumen ya cambian la diapositiva.', 'The volume buttons now change the slide.')
              : t('Abre Zlide para escritorio en la PC; se conecta sola. En iPhone, el Bluetooth necesita esa app.',
                  'Open Zlide for desktop on the computer; it connects by itself. On iPhone, Bluetooth needs that app.'),
        ),
      ),
      if (!connected)
        const Padding(
          padding: EdgeInsets.only(left: Sp.m, top: Sp.s),
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)),
        ),
    ]);
  }

  // ---------------------------------------------------------------- Transmitir desde PC

  Widget _wifiSection() {
    final found = c.wifi.found;
    final target = c.wifi.target;
    final all = [
      ...found,
      if (target != null && found.every((p) => p.name != target.name)) target,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: _sectionHead(
            t('Elige tu PC', 'Choose your computer'),
            t('Abre Zlide para escritorio en la PC y usa la misma red WiFi. Desde ahí también puedes proyectar y dibujar.',
                'Open Zlide for desktop on the computer and use the same WiFi network. From there you can also present and draw.'),
          ),
        ),
        if (c.wifi.searching)
          const Padding(
            padding: EdgeInsets.only(left: Sp.m, top: Sp.s),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ]),
      const SizedBox(height: Sp.m),
      DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Pal.rule))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: Text(t('Todavía no aparece ninguna PC.', 'No computer has shown up yet.'),
                  style: Txt.text(15, color: Pal.muted)),
            ),
          for (final pc in all)
            _choiceRow(
              selected: target?.name == pc.name,
              title: pc.name,
              subtitle: '${pc.host}:${pc.port}',
              mono: true,
              trailing: target?.name == pc.name ? Dot(c.wifi.online ? Pal.ok : Pal.busy) : null,
              onTap: () => c.selectPc(pc),
            ),
        ]),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _manualIpDialog,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(t('Agregar por IP', 'Add by IP')),
        ),
      ),
    ]);
  }

  Future<void> _manualIpDialog() async {
    final ip = TextEditingController(text: c.wifi.target?.manual == true ? c.wifi.target!.host : '');
    final port = TextEditingController(text: '$kUdpPort');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Agregar PC por IP', 'Add computer by IP')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t('La IP aparece en la app de escritorio.', 'The IP is shown in the desktop app.')),
          const SizedBox(height: Sp.l),
          TextField(
            controller: ip,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t('IP de la PC', 'Computer IP'), hintText: '192.168.1.50'),
            style: Txt.digits(17, weight: FontWeight.w500),
          ),
          const SizedBox(height: Sp.m),
          TextField(
            controller: port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t('Puerto', 'Port')),
            style: Txt.digits(17, weight: FontWeight.w500),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(foregroundColor: Pal.muted),
            child: Text(t('Cancelar', 'Cancel')),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('Agregar', 'Add'))),
        ],
      ),
    );
    final host = ip.text.trim();
    if (ok == true && host.isNotEmpty) {
      await c.selectPc(PcEntry(
        name: host,
        host: host,
        port: int.tryParse(port.text.trim()) ?? kUdpPort,
        manual: true,
      ));
    }
  }

  // ---------------------------------------------------------------- Transmitir desde móvil

  Widget _browserSection() {
    final b = c.browser;
    if (c.converting) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionHead(
          t('Convirtiendo a PDF…', 'Converting to PDF…'),
          t('Se hace en el teléfono, sin internet. La primera vez tarda más.',
              'Done on the phone, offline. The first time takes longer.'),
        ),
        const SizedBox(height: Sp.l),
        const LinearProgressIndicator(minHeight: 4, borderRadius: BorderRadius.all(Radius.circular(2))),
        if (c.convertingName != null) ...[
          const SizedBox(height: Sp.s),
          Text(c.convertingName!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(14, color: Pal.muted)),
        ],
      ]);
    }
    if (!b.hasPdf) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionHead(
          t('Proyecta desde el teléfono', 'Present from the phone'),
          t('Elige tu presentación (PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} o PDF) y ábrela en el navegador '
              'de la PC con la dirección que te daremos. No hay que instalar nada. Con .pptx u .odp también verás tus notas.',
              'Pick your presentation (PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} or PDF) and open it in the '
              'computer’s browser with the address we’ll give you. Nothing to install. With .pptx or .odp you’ll also see your notes.'),
        ),
        const SizedBox(height: Sp.l),
        PillButton(t('Elegir presentación', 'Choose presentation'),
            primary: true, icon: Icons.slideshow_rounded, onTap: c.pickPresentation),
      ]);
    }
    final url = b.urls.isNotEmpty ? b.urls.first.replaceFirst('http://', '') : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t('Abre esta dirección en la PC', 'Open this address on the computer'), style: Txt.title(24)),
      const SizedBox(height: Sp.m),
      if (url == null)
        Text(t('Conéctate a una red WiFi (o activa el punto de acceso del teléfono).',
                'Connect to a WiFi network (or turn on the phone’s hotspot).'),
            style: Txt.text(15.5, color: Pal.muted))
      else
        Semantics(
          button: true,
          label: t('Copiar dirección', 'Copy address'),
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.s),
            onTap: () {
              Clipboard.setData(ClipboardData(text: 'http://$url'));
              _showNudge(t('Dirección copiada', 'Address copied'));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.xs),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(url, style: Txt.digits(32, color: Pal.accent)),
                ),
                const SizedBox(height: Sp.xs),
                Text(t('Toca para copiar · misma red WiFi', 'Tap to copy · same WiFi network'),
                    style: Txt.text(13, color: Pal.muted)),
              ]),
            ),
          ),
        ),
      if (b.urls.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: Sp.xs),
          child: Text('${t('Otras', 'Others')}: ${b.urls.skip(1).map((u) => u.replaceFirst('http://', '')).join('  ·  ')}',
              style: Txt.digits(11.5, color: Pal.muted, weight: FontWeight.w500)),
        ),
      const SizedBox(height: Sp.l),
      Container(
        padding: const EdgeInsets.only(top: Sp.s),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Pal.rule))),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.pdfName ?? t('presentación', 'presentation'),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(16, weight: FontWeight.w600, height: 1.3)),
              Text(
                [
                  if (b.total > 0) t('${b.total} diapositivas', '${b.total} slides'),
                  c.deck != null ? t('con notas', 'with notes') : t('sin notas', 'no notes'),
                ].join(' · '),
                style: Txt.text(13, color: Pal.muted, height: 1.3),
              ),
            ]),
          ),
          TextButton(onPressed: c.pickPresentation, child: Text(t('Cambiar', 'Change'))),
        ]),
      ),
      const SizedBox(height: Sp.s),
      PillButton(t('Dibujar sobre la diapositiva', 'Draw on the slide'), icon: Icons.draw_rounded, onTap: _openDraw),
    ]);
  }

  void _openDraw() {
    final wifiUri = c.mode == Mode.wifi ? c.pcDrawUri : null;
    if (c.mode == Mode.wifi && wifiUri == null) {
      _showNudge(t('Conéctate a la PC primero', 'Connect to the computer first'));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => wifiUri != null ? DrawPage.wifi(c: c, uri: wifiUri) : DrawPage(c: c),
    ));
  }

  // ================================================================ ajustes

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => ListenableBuilder(
          listenable: Listenable.merge([c, I18n.current]),
          builder: (ctx, _) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xl),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Text(t('Ajustes', 'Settings'), style: Txt.title(26)),
                  const SizedBox(height: Sp.l),
                  Caption(t('Botones', 'Buttons')),
                  _switch(t('Invertir botones', 'Swap buttons'), t('Volumen − avanza', 'Volume − goes forward'), c.invert,
                      c.setInvert),
                  _switch(t('Usar flechas ← →', 'Use arrow keys ← →'),
                      t('Si tu programa no responde a AvPág/RePág', 'If your app ignores Page Down/Page Up'), c.arrows, c.setArrows),
                  const SizedBox(height: Sp.xl),
                  Caption(t('Apariencia', 'Appearance')),
                  _labeled(
                    t('Tema', 'Theme'),
                    Segmented<ThemePref>(
                      values: ThemePref.values,
                      labels: [t('Sistema', 'System'), t('Claro', 'Light'), t('Oscuro', 'Dark')],
                      selected: AppTheme.pref,
                      onChanged: AppTheme.setPref,
                      accent: true,
                    ),
                  ),
                  const SizedBox(height: Sp.m),
                  _labeled(
                    t('Idioma', 'Language'),
                    Segmented<LangPref>(
                      values: LangPref.values,
                      labels: [t('Sistema', 'System'), 'Español', 'English'],
                      selected: I18n.pref,
                      onChanged: (p) {
                        I18n.setPref(p);
                        c.languageChanged();
                      },
                      accent: true,
                    ),
                  ),
                  const SizedBox(height: Sp.xl),
                  Caption('${t('Notas del presentador', 'Speaker notes')} · ${_modeName(c.mode)}'),
                  ..._notesSettings(ctx, setSheet),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _notesSettings(BuildContext ctx, StateSetter setSheet) {
    if (c.deck == null) {
      return [
        Text(
          c.mode == Mode.wifi
              ? t('Elige la presentación en la app de la PC, o un archivo aquí.',
                  'Choose the presentation in the desktop app, or a file here.')
              : t('Cada modo guarda sus propias notas.', 'Each mode keeps its own notes.'),
          style: Txt.text(14, color: Pal.muted),
        ),
        const SizedBox(height: Sp.m),
        PillButton(t('Elegir archivo (.pptx, .odp)', 'Choose file (.pptx, .odp)'), icon: Icons.sticky_note_2_outlined, onTap: () {
          Navigator.pop(ctx);
          c.pickNotes();
        }),
      ];
    }
    void font(double d) {
      setState(() => _notesFont = (_notesFont + d).clamp(15, 34));
      setSheet(() {});
    }

    return [
      ListTile(
        leading: Icon(c.notesFromPc ? Icons.computer_rounded : Icons.description_outlined),
        title: Text(c.deckName ?? t('presentación', 'presentation'), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(c.notesFromPc
            ? t('Vienen de la app de la PC. Para cambiarlas, elige otra presentación allá.',
                'They come from the desktop app. To change them, choose another presentation there.')
            : t('${c.deck!.length} diapositivas', '${c.deck!.length} slides')),
        trailing: c.notesFromPc
            ? null
            : TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  c.pickNotes();
                },
                child: Text(t('Cambiar', 'Change')),
              ),
      ),
      const Divider(),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.s),
        child: Row(children: [
          Expanded(child: Text(t('Tamaño del texto', 'Text size'), style: Txt.text(16, weight: FontWeight.w600))),
          IconButton(onPressed: () => font(-2), icon: const Icon(Icons.text_decrease_rounded), tooltip: t('Más chico', 'Smaller')),
          SizedBox(
            width: 34,
            child: Text('${_notesFont.round()}', textAlign: TextAlign.center, style: Txt.digits(15, color: Pal.muted)),
          ),
          IconButton(onPressed: () => font(2), icon: const Icon(Icons.text_increase_rounded), tooltip: t('Más grande', 'Larger')),
        ]),
      ),
      Text(t('Así se ven tus notas.', 'This is how your notes look.'), style: Txt.text(_notesFont, height: 1.4)),
      const SizedBox(height: Sp.l),
      Wrap(spacing: Sp.s, runSpacing: Sp.s, children: [
        PillButton(t('Volver a la diapositiva 1', 'Back to slide 1'), dense: true, onTap: c.restartNotes),
        if (!c.notesFromPc)
          PillButton(t('Quitar notas', 'Remove notes'), dense: true, onTap: () {
            Navigator.pop(ctx);
            c.clearNotes();
          }),
      ]),
      const SizedBox(height: Sp.m),
      Text(
        t('Con PowerPoint o Impress el teléfono cuenta las pulsaciones (incluidas las animaciones); si se desfasa, '
            'corrígelo con − / + junto al número. Al transmitir (desde la PC o desde el móvil) se sincroniza solo.',
            'With PowerPoint or Impress the phone counts the presses (animations included); if it gets out of step, '
            'fix it with − / + next to the number. When streaming (from the PC or the phone) it syncs by itself.'),
        style: Txt.text(13, color: Pal.muted, height: 1.4),
      ),
    ];
  }

  Widget _labeled(String label, Widget child) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.s),
          child: Text(label, style: Txt.text(15, weight: FontWeight.w600)),
        ),
        child,
      ]);

  /// Nombre del modo en una línea (cada modo tiene sus propias notas).
  static String _modeName(Mode m) => switch (m) {
        Mode.bluetooth => t('Control Bluetooth', 'Bluetooth control'),
        Mode.wifi => t('Transmitir desde PC', 'Stream from PC'),
        Mode.browser => t('Transmitir desde móvil', 'Stream from phone'),
      };

  Widget _switch(String title, String sub, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: Text(sub),
      );
}

// ==================================================================== piezas

/// Progreso de la presentación: un segmento por diapositiva (o una barra si son muchas).
class _Progress extends StatelessWidget {
  const _Progress({required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox(height: 4);
    if (total > 40) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: (current + 1) / total, minHeight: 4),
      );
    }
    return Semantics(
      label: t('Diapositiva ${current + 1} de $total', 'Slide ${current + 1} of $total'),
      child: Row(children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: AnimatedContainer(
              duration: Mo.of(context, Mo.med),
              height: i == current ? 5 : 4,
              decoration: BoxDecoration(
                color: i <= current ? Pal.accent : Pal.rule,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

enum _PadLayout {
  /// Solo el ícono (botón "anterior" junto a "siguiente").
  icon,

  /// Una línea: ícono y texto (notas expandidas, preparando).
  compact,

  /// Texto a la izquierda, flecha a la derecha (debajo de las notas).
  wide,

  /// Grande (sin notas).
  big,
}

/// Botón de cambiar diapositiva. También se anima cuando la pulsación viene del botón de volumen.
class _Pad extends StatefulWidget {
  const _Pad({
    required this.primary,
    required this.label,
    required this.icon,
    required this.hint,
    required this.pulse,
    required this.onTap,
    required this.layout,
  });

  final bool primary;
  final String label;
  final IconData icon;
  final String hint;
  final ValueNotifier<int> pulse;
  final VoidCallback onTap;
  final _PadLayout layout;

  @override
  State<_Pad> createState() => _PadState();
}

class _PadState extends State<_Pad> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void initState() {
    super.initState();
    widget.pulse.addListener(_onPulse);
  }

  @override
  void didUpdateWidget(_Pad old) {
    super.didUpdateWidget(old);
    if (old.pulse != widget.pulse) {
      old.pulse.removeListener(_onPulse);
      widget.pulse.addListener(_onPulse);
    }
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_onPulse);
    _anim.dispose();
    super.dispose();
  }

  void _onPulse() {
    HapticFeedback.selectionClick();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return;
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.primary ? Pal.onAccent : Pal.ink;
    final bg = widget.primary ? Pal.accent : Pal.raise;
    final radius = BorderRadius.circular(widget.layout == _PadLayout.big ? Rad.xl + 4 : Rad.xl - 2);
    return Semantics(
      button: true,
      label: '${widget.label} (${widget.hint})',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          // 0 → 1: se hunde un poco y regresa, con un destello
          final v = _anim.value;
          final k = v < 0.35 ? v / 0.35 : (1 - v) / 0.65;
          return Transform.scale(
            scale: 1 - 0.035 * k,
            child: Stack(fit: StackFit.expand, children: [
              child!,
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: (widget.primary ? Colors.black : Pal.ink).withValues(alpha: 0.16 * k),
                    borderRadius: radius,
                  ),
                ),
              ),
            ]),
          );
        },
        child: Material(
          color: bg,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: widget.onTap, child: _content(fg)),
        ),
      ),
    );
  }

  Widget _content(Color fg) {
    final hint = Text(widget.hint, style: Txt.digits(12, color: fg.withValues(alpha: 0.75), weight: FontWeight.w500));
    switch (widget.layout) {
      case _PadLayout.icon:
        return Center(child: Icon(widget.icon, size: 34, color: fg));
      case _PadLayout.compact:
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.icon, size: 26, color: fg),
                const SizedBox(width: Sp.s),
                Text(widget.label, style: Txt.title(19, color: fg)),
              ]),
            ),
          ),
        );
      case _PadLayout.wide:
      case _PadLayout.big:
        final big = widget.layout == _PadLayout.big;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: big ? Sp.xxl - 4 : Sp.xl),
          child: Row(children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.label, style: Txt.title(big ? 36 : 26, color: fg)),
                  const SizedBox(height: 2),
                  hint,
                ]),
              ),
            ),
            Icon(widget.icon, size: big ? 48 : 36, color: fg),
          ]),
        );
    }
  }
}
