import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/protocol.dart';
import '../common/theme.dart';
import 'remote_controller.dart';
import 'wifi_client.dart';

/// Nombre del modo en una línea (cada modo tiene sus propias notas).
String modeName(Mode m) => switch (m) {
      Mode.bluetooth => t('Control Bluetooth', 'Bluetooth control'),
      Mode.wifi => t('Transmitir desde PC', 'Stream from PC'),
      Mode.browser => t('Transmitir desde móvil', 'Stream from phone'),
    };

IconData modeIcon(Mode m) => switch (m) {
      Mode.bluetooth => Icons.bluetooth_rounded,
      Mode.wifi => Icons.desktop_windows_rounded,
      Mode.browser => Icons.smartphone_rounded,
    };

String _modeBlurb(Mode m, bool ios) => switch (m) {
      Mode.bluetooth => ios
          ? t('Con Zlide para escritorio, por Bluetooth. Sin red WiFi.', 'With Zlide for desktop, over Bluetooth. No WiFi needed.')
          : t('El teléfono funciona como teclado. No hay que instalar nada en la PC.',
              'The phone works as a keyboard. Nothing to install on the computer.'),
      Mode.wifi => t('Con Zlide para escritorio: notas automáticas, proyección y dibujo en vivo.',
          'With Zlide for desktop: automatic notes, presenting and live drawing.'),
      Mode.browser => t('La presentación va en el teléfono; se abre en el navegador de cualquier PC.',
          'The presentation lives on the phone; it opens in any computer’s browser.'),
    };

/// Elegir el modo. [compact]: tres tarjetas en fila (hoja "Conexión"); si no, una lista con
/// descripción (primera vez).
class ModePicker extends StatelessWidget {
  const ModePicker({super.key, required this.c, this.compact = false});
  final RemoteController c;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Row(children: [
        for (final m in Mode.values) ...[
          if (m != Mode.values.first) const SizedBox(width: Sp.s),
          Expanded(child: _card(context, m)),
        ],
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final m in Mode.values) ...[
        if (m != Mode.values.first) const SizedBox(height: Sp.s),
        _card(context, m),
      ],
    ]);
  }

  Widget _card(BuildContext context, Mode m) {
    final on = c.mode == m;
    final icon = AnimatedContainer(
      duration: Mo.of(context, Mo.fast),
      width: compact ? 36 : 44,
      height: compact ? 36 : 44,
      decoration: BoxDecoration(
        color: on ? Pal.accent : Pal.raiseHi,
        borderRadius: BorderRadius.circular(Rad.s + 2),
      ),
      child: Icon(modeIcon(m), size: compact ? 19 : 22, color: on ? Pal.onAccent : Pal.ink),
    );
    final title = Text(
      modeName(m),
      maxLines: 2,
      textAlign: compact ? TextAlign.center : TextAlign.start,
      style: Txt.text(compact ? 13 : 16, weight: FontWeight.w700, height: 1.2),
    );
    return Semantics(
      selected: on,
      button: true,
      child: AnimatedContainer(
        duration: Mo.of(context, Mo.fast),
        decoration: BoxDecoration(
          color: on ? Pal.accent.withValues(alpha: Pal.p.dark ? 0.14 : 0.08) : Pal.raise,
          borderRadius: BorderRadius.circular(Rad.l),
          border: Border.all(color: on ? Pal.accent : Colors.transparent, width: 1.5),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.l),
            onTap: () {
              if (!on) HapticFeedback.selectionClick();
              c.setMode(m);
            },
            child: Padding(
              padding: EdgeInsets.all(compact ? Sp.m : Sp.l),
              child: compact
                  ? Column(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(height: Sp.s), title])
                  : Row(children: [
                      icon,
                      const SizedBox(width: Sp.l),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          title,
                          const SizedBox(height: 2),
                          Text(_modeBlurb(m, c.isIOS), style: Txt.text(13.5, color: Pal.muted, height: 1.35)),
                        ]),
                      ),
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lo que hace falta para conectar el modo actual.
class ConnectionContent extends StatelessWidget {
  const ConnectionContent({super.key, required this.c, required this.onNudge, required this.onDraw});
  final RemoteController c;
  final void Function(String) onNudge;
  final VoidCallback onDraw;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: Mo.of(context, Mo.med),
        curve: Mo.curve,
        alignment: Alignment.topCenter,
        child: KeyedSubtree(
          key: ValueKey(c.mode),
          child: switch (c.mode) {
            Mode.bluetooth => c.isIOS ? _bleSection() : _hidSection(),
            Mode.wifi => _wifiSection(context),
            Mode.browser => _browserSection(),
          },
        ),
      );

  Widget _sectionHead(String title, [String? body]) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Txt.title(24)),
        if (body != null) ...[
          const SizedBox(height: Sp.s),
          Text(body, style: Txt.text(15, color: Pal.muted)),
        ],
      ]);

  /// Fila de lista con radio: PCs emparejadas o encontradas en la red.
  Widget _choiceRow(
    BuildContext context, {
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
            padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
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
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(16, weight: FontWeight.w600, height: 1.25)),
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

  Widget _emptyRow(String text) => Padding(
        padding: const EdgeInsets.all(Sp.l),
        child: Text(text, style: Txt.text(14.5, color: Pal.muted)),
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
    return Builder(
      builder: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionHead(
          t('Conecta tu PC', 'Connect your computer'),
          t('El teléfono funciona como teclado Bluetooth. No hay que instalar nada en la PC (Windows, Mac, Linux o tablet).',
              'The phone works as a Bluetooth keyboard. Nothing to install on the computer (Windows, Mac, Linux or tablet).'),
        ),
        const SizedBox(height: Sp.l),
        Panel(
          title: t('PCs emparejadas', 'Paired computers'),
          children: [
            if (c.bonded.isEmpty)
              _emptyRow(t('Ninguna todavía. Toca “Emparejar nueva” y, en la PC, agrega el teléfono desde los ajustes de Bluetooth.',
                  'None yet. Tap “Pair new” and add the phone from the computer’s Bluetooth settings.')),
            for (final d in c.bonded)
              _choiceRow(
                context,
                selected: d.address == c.selectedAddress,
                title: d.name,
                subtitle: t('Emparejada', 'Paired'),
                onTap: () => c.selectDevice(d.address),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: c.refreshBonded,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(t('Actualizar lista', 'Refresh list')),
          ),
        ),
        const SizedBox(height: Sp.s),
        ButtonPair(
          PillButton(
            connecting ? t('Conectando…', 'Connecting…') : t('Conectar', 'Connect'),
            primary: true,
            onTap: connecting || c.selectedAddress == null ? null : c.connectSelected,
          ),
          PillButton(t('Emparejar nueva', 'Pair new'), onTap: c.pairNew),
        ),
      ]),
    );
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

  Widget _wifiSection(BuildContext context) {
    final w = c.wifi;
    final found = w.found;
    final target = w.target;
    final all = [
      ...found,
      if (target != null && found.every((p) => p.name != target.name)) target,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: _sectionHead(
            t('Elige tu PC', 'Choose your computer'),
            t('Abre Zlide para escritorio en la PC y usa la misma red WiFi.',
                'Open Zlide for desktop on the computer and use the same WiFi network.'),
          ),
        ),
        if (w.searching)
          const Padding(
            padding: EdgeInsets.only(left: Sp.m, top: Sp.s),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
      ]),
      const SizedBox(height: Sp.l),
      Panel(
        title: t('En la red', 'On the network'),
        children: [
          if (all.isEmpty) _emptyRow(t('Todavía no aparece ninguna PC.', 'No computer has shown up yet.')),
          for (final pc in all)
            _choiceRow(
              context,
              selected: target?.name == pc.name,
              title: pc.name,
              subtitle: '${pc.host}:${pc.port}',
              mono: true,
              trailing: target?.name == pc.name ? Dot(w.online ? (w.busy ? Pal.error : Pal.ok) : Pal.busy) : null,
              onTap: () => c.selectPc(pc),
            ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _manualIpDialog(context),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(t('Agregar por IP', 'Add by IP')),
        ),
      ),
      if (w.online && w.busy) ...[
        const SizedBox(height: Sp.s),
        _notice(
          Icons.lock_person_outlined,
          Pal.error,
          t('Otro teléfono está presentando', 'Another phone is presenting'),
          t('Mientras la PC presenta, solo la controla el teléfono que empezó. Podrás conectarte cuando termine '
              '(o cuando lo liberen desde la app de escritorio).',
              'While the computer is presenting, only the phone that started can control it. You can connect when it '
              'ends (or when it is released from the desktop app).'),
        ),
      ] else if (w.online) ...[
        const SizedBox(height: Sp.s),
        PresentOnPc(c: c),
      ],
    ]);
  }

  Widget _notice(IconData icon, Color color, String title, String body) => Container(
        padding: const EdgeInsets.all(Sp.l),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(Rad.l),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Txt.text(15, weight: FontWeight.w700, height: 1.3)),
              const SizedBox(height: 2),
              Text(body, style: Txt.text(13.5, color: Pal.muted, height: 1.4)),
            ]),
          ),
        ]),
      );

  Future<void> _manualIpDialog(BuildContext context) async {
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
              'de la PC con la dirección que te daremos. No hay que instalar nada. Con .pptx u .odp también verás tus notas, '
              'y sus enlaces y videos funcionan en la PC.',
              'Pick your presentation (PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} or PDF) and open it in the '
              'computer’s browser with the address we’ll give you. Nothing to install. With .pptx or .odp you’ll also see your '
              'notes, and its links and videos work on the computer.'),
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
          child: Material(
            color: Pal.raise,
            borderRadius: BorderRadius.circular(Rad.l),
            child: InkWell(
              borderRadius: BorderRadius.circular(Rad.l),
              onTap: () {
                Clipboard.setData(ClipboardData(text: 'http://$url'));
                onNudge(t('Dirección copiada', 'Address copied'));
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.m, Sp.m),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(url, style: Txt.digits(28, color: Pal.accent)),
                      ),
                      const SizedBox(height: Sp.xs),
                      Text(t('Toca para copiar · misma red WiFi', 'Tap to copy · same WiFi network'),
                          style: Txt.text(13, color: Pal.muted)),
                    ]),
                  ),
                  Icon(Icons.copy_rounded, size: 20, color: Pal.muted),
                ]),
              ),
            ),
          ),
        ),
      if (b.urls.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: Sp.s, left: Sp.xs),
          child: Text('${t('Otras', 'Others')}: ${b.urls.skip(1).map((u) => u.replaceFirst('http://', '')).join('  ·  ')}',
              style: Txt.digits(11.5, color: Pal.muted, weight: FontWeight.w500)),
        ),
      const SizedBox(height: Sp.l),
      Panel(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.s, Sp.s),
          child: Row(children: [
            Icon(Icons.slideshow_rounded, color: Pal.muted, size: 22),
            const SizedBox(width: Sp.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.pdfName ?? t('presentación', 'presentation'),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Txt.text(15.5, weight: FontWeight.w600, height: 1.3)),
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
      ]),
      const SizedBox(height: Sp.m),
      PillButton(t('Ver la diapositiva y dibujar', 'View the slide and draw'), icon: Icons.draw_rounded, onTap: onDraw),
    ]);
  }
}

/// "Presentar en la PC" (modo WiFi): empezar con Zlide o con el programa original, o terminar.
class PresentOnPc extends StatelessWidget {
  const PresentOnPc({super.key, required this.c, this.onDismiss});
  final RemoteController c;

  /// Si se da, el panel se puede cerrar (aviso en la pantalla de presentar).
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final w = c.wifi;
    if (w.pcDeckMode != DeckMode.none) {
      final zlide = w.pcDeckMode == DeckMode.zlide;
      return Panel(
        title: t('Presentando en la PC', 'Presenting on the computer'),
        children: [
          _option(
            icon: zlide ? Icons.cast_connected_rounded : Icons.slideshow_rounded,
            title: zlide ? t('Con Zlide, en el navegador', 'With Zlide, in the browser') : t('Con el programa original', 'With the original app'),
            body: zlide
                ? t('Notas exactas y dibujo en vivo.', 'Exact notes and live drawing.')
                : t('Animaciones, videos y enlaces tal cual. Los botones mandan teclas.',
                    'Animations, videos and links as they are. The buttons send keys.'),
            trailing: TextButton(onPressed: c.stopOnPc, child: Text(t('Terminar', 'End'))),
          ),
        ],
      );
    }
    if (!w.pcHasDeck) {
      if (onDismiss != null) return const SizedBox.shrink();
      return Panel(children: [
        _option(
          icon: Icons.folder_open_rounded,
          title: t('Presentar en la PC', 'Present on the computer'),
          body: t('Elige la presentación en la app de la PC; después puedes empezar desde aquí.',
              'Choose the presentation in the desktop app; then you can start from here.'),
        ),
      ]);
    }
    return Panel(
      title: onDismiss == null ? t('Presentar en la PC', 'Present on the computer') : null,
      footer: c.deckHasAnimations
          ? t('Esta presentación tiene animaciones: se ven con el programa original.',
              'This presentation has animations: they play with the original app.')
          : null,
      children: [
        if (onDismiss != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.xs, 0),
            child: Row(children: [
              Expanded(
                child: Text(t('Tu presentación está lista en la PC', 'Your presentation is ready on the computer'),
                    style: Txt.text(14.5, weight: FontWeight.w700)),
              ),
              IconButton(
                onPressed: onDismiss,
                tooltip: t('Cerrar', 'Close'),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ]),
          ),
        _option(
          icon: Icons.cast_rounded,
          title: t('Proyectar con Zlide', 'Present with Zlide'),
          body: t('En el navegador de la PC: notas exactas, dibujo en vivo, enlaces y videos.',
              'In the computer’s browser: exact notes, live drawing, links and videos.'),
          onTap: () => c.startOnPc(native: false),
        ),
        _option(
          icon: Icons.slideshow_rounded,
          title: t('Abrir en PowerPoint o Impress', 'Open in PowerPoint or Impress'),
          body: t('En su programa: animaciones, transiciones, videos y enlaces tal cual.',
              'In its own app: animations, transitions, videos and links as they are.'),
          onTap: () => c.startOnPc(native: true),
        ),
      ],
    );
  }

  Widget _option({required IconData icon, required String title, required String body, VoidCallback? onTap, Widget? trailing}) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.s, Sp.m),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: onTap != null ? Pal.accent.withValues(alpha: 0.14) : Pal.raiseHi,
                borderRadius: BorderRadius.circular(Rad.s + 2),
              ),
              child: Icon(icon, size: 21, color: onTap != null ? Pal.accent : Pal.ink),
            ),
            const SizedBox(width: Sp.m + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Txt.text(15.5, weight: FontWeight.w700, height: 1.25)),
                const SizedBox(height: 2),
                Text(body, style: Txt.text(13, color: Pal.muted, height: 1.35)),
              ]),
            ),
            if (trailing != null) trailing else if (onTap != null) Icon(Icons.chevron_right_rounded, color: Pal.muted),
          ]),
        ),
      );
}
