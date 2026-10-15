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

class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  final c = RemoteController();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<String>? _nudgeSub;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: c.onForeground,
      onPause: c.onBackground,
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([c, I18n.current]),
          builder: (context, _) {
            if (!c.ready) return const Center(child: CircularProgressIndicator());
            final notes = c.deck != null;
            if (!notes) _notesExpanded = false; // al quitar las notas, volver a la vista normal
            final expanded = notes && _notesExpanded;
            return PopScope(
              // Con las notas expandidas, "atrás" solo las contrae
              canPop: !expanded,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && expanded) setState(() => _notesExpanded = false);
              },
              child: LayoutBuilder(
              builder: (context, box) => expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          TimerChip(c.timer),
                          const Spacer(),
                          Dot(connColor(c.status.conn)),
                          const SizedBox(width: 8),
                        ]),
                        const SizedBox(height: 8),
                        Expanded(child: _notesPanel()),
                        const SizedBox(height: 10),
                        SizedBox(height: 64, child: _padsRow(compact: true)),
                      ]),
                    )
                  : Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _header(),
                  const SizedBox(height: 12),
                  Segmented<Mode>(
                    values: Mode.values,
                    labels: [
                      t('Control\nBluetooth', 'Bluetooth\ncontrol'),
                      t('Transmitir\ndesde PC', 'Stream\nfrom PC'),
                      t('Transmitir\ndesde móvil', 'Stream\nfrom phone'),
                    ],
                    selected: c.mode,
                    onChanged: (m) {
                      _detailsOpen = null;
                      c.setMode(m);
                    },
                  ),
                  const SizedBox(height: 10),
                  _connectionBar(),
                  // Detalles del modo (elegir PC, dirección, etc.): se abren solos mientras falta
                  // algo y se recogen al conectarse, para dejar espacio a notas y botones.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _detailsVisible
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: box.maxHeight * (notes ? 0.34 : 0.45)),
                              child: SingleChildScrollView(child: _modeCard()),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  const SizedBox(height: 12),
                  if (notes) ...[
                    Expanded(child: _notesPanel()),
                    const SizedBox(height: 10),
                    SizedBox(height: box.maxHeight < 640 ? 104 : 128, child: _padsRow()),
                  ] else ...[
                    Expanded(child: _pads()),
                    const SizedBox(height: 10),
                    _addNotesButton(),
                  ],
                ]),
              ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ================================================================ encabezado

  Widget _header() => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: Pal.accent, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.slideshow_rounded, size: 20, color: Pal.onAccent),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Slide Remote',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4),
            ),
          ),
          TimerChip(c.timer),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded, color: Pal.muted),
            tooltip: t('Ajustes', 'Settings'),
          ),
        ],
      );

  // ================================================================ barra de conexión

  /// null = automático (abiertos mientras no hay conexión); true/false = lo eligió el usuario.
  bool? _detailsOpen;
  bool _wasReady = false;

  bool get _ready => c.status.conn == Conn.on;
  bool get _detailsVisible => _detailsOpen ?? !_ready;

  /// Una sola línea con el estado del modo; tocarla muestra u oculta los detalles.
  Widget _connectionBar() {
    final s = c.status;
    if (_ready != _wasReady) {
      _wasReady = _ready;
      _detailsOpen = null; // al conectar/desconectar, volver al comportamiento automático
    }
    final open = _detailsVisible;
    final canDraw = (c.mode == Mode.browser && c.browser.hasPdf && !c.converting) ||
        (c.mode == Mode.wifi && c.pcDrawUri != null);
    return Material(
      color: Pal.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _ready ? Pal.ok.withValues(alpha: 0.35) : Pal.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _detailsOpen = !open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(children: [
            Dot(connColor(s.conn)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _ready ? Pal.ok : Pal.text,
                    )),
                if (s.subtitle != null && s.subtitle!.isNotEmpty)
                  Text(s.subtitle!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Pal.muted, fontSize: 12.5)),
              ]),
            ),
            if (canDraw)
              IconButton(
                onPressed: _openDraw,
                icon: const Icon(Icons.draw_rounded, color: Pal.accent),
                tooltip: t('Dibujar sobre la diapositiva', 'Draw on the slide'),
              ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.expand_more_rounded, color: Pal.muted),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ================================================================ tarjetas por modo

  Widget _modeCard() => switch (c.mode) {
        Mode.bluetooth => c.isIOS ? _bleCard() : _hidCard(),
        Mode.wifi => _wifiCard(),
        Mode.browser => _browserCard(),
      };

  Widget _hidCard() {
    final s = c.btState;
    if (s == BtState.connected) {
      return SrCard(
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Caption(t('Teclado conectado a', 'Keyboard connected to')),
              Text(c.btDeviceName ?? 'PC',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ]),
          ),
          PillButton(t('Desconectar', 'Disconnect'), onTap: c.disconnectBluetooth, dense: true),
        ]),
      );
    }
    if (s == BtState.unavailable || s == BtState.off || s == BtState.noPermission) {
      return SrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            switch (s) {
              BtState.off => t('Activa el Bluetooth del teléfono.', 'Turn on Bluetooth on your phone.'),
              BtState.noPermission => t('Slide Remote necesita el permiso de “Dispositivos cercanos”.',
                  'Slide Remote needs the “Nearby devices” permission.'),
              _ => c.btMessage ??
                  t('El control Bluetooth no está disponible en este teléfono. Usa “Transmitir desde PC” o “Transmitir desde móvil”.',
                      'Bluetooth control is not available on this phone. Use “Stream from PC” or “Stream from phone”.'),
            },
            style: const TextStyle(color: Pal.muted, height: 1.4),
          ),
          if (s != BtState.unavailable) ...[
            const SizedBox(height: 12),
            PillButton(t('Reintentar', 'Retry'), primary: true, onTap: c.retryBluetooth),
          ],
        ]),
      );
    }
    return SrCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Caption(t('Tu PC', 'Your computer')),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Pal.cardHi,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Pal.stroke),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              // El valor debe existir en la lista o Flutter lanza una aserción
              value: c.bonded.any((d) => d.address == c.selectedAddress) ? c.selectedAddress : null,
              isExpanded: true,
              dropdownColor: Pal.cardHi,
              borderRadius: BorderRadius.circular(12),
              hint: Text(t('Ninguna PC emparejada', 'No paired computer'), style: const TextStyle(color: Pal.muted)),
              items: [
                for (final d in c.bonded)
                  DropdownMenuItem(value: d.address, child: Text(d.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: c.selectDevice,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: PillButton(
              c.btState == BtState.connecting ? t('Conectando…', 'Connecting…') : t('Conectar', 'Connect'),
              primary: true,
              onTap: c.btState == BtState.connecting ? null : c.connectSelected,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: PillButton(t('Emparejar nueva', 'Pair new'), onTap: c.pairNew)),
        ]),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: c.refreshBonded,
            icon: const Icon(Icons.refresh, size: 16, color: Pal.muted),
            label: Text(t('Actualizar lista', 'Refresh list'), style: const TextStyle(color: Pal.muted)),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ),
        Text(
          t('Sin instalar nada en la PC: el teléfono funciona como teclado Bluetooth '
              '(Windows, Mac, Linux, tablets).',
              'Nothing to install on the computer: the phone works as a Bluetooth keyboard '
              '(Windows, Mac, Linux, tablets).'),
          style: const TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
        ),
      ]),
    );
  }

  Widget _bleCard() {
    final connected = c.btState == BtState.connected;
    return SrCard(
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: connected ? Pal.accent : Pal.cardHi,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(Icons.bluetooth, color: connected ? Pal.onAccent : Pal.muted),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              connected ? t('Conectado a la PC', 'Connected to the computer') : t('Buscando la PC…', 'Looking for the computer…'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              connected
                  ? t('Los botones de volumen ya cambian la diapositiva.', 'The volume buttons now change the slide.')
                  : t('Abre Slide Remote para escritorio en la PC; se conecta sola. '
                      'En iPhone, el Bluetooth necesita esa app.',
                      'Open Slide Remote for desktop on the computer; it connects by itself. '
                      'On iPhone, Bluetooth needs that app.'),
              style: const TextStyle(color: Pal.muted, fontSize: 13, height: 1.4),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _wifiCard() {
    final found = c.wifi.found;
    final target = c.wifi.target;
    final all = [
      ...found,
      if (target != null && found.every((p) => p.name != target.name)) target,
    ];
    return SrCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Caption(t('PCs con Slide Remote', 'Computers with Slide Remote'))),
          if (c.wifi.searching)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: Pal.muted)),
            ),
        ]),
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              t('Abre Slide Remote para escritorio en la PC y conéctate a la misma red WiFi.',
                  'Open Slide Remote for desktop on the computer and join the same WiFi network.'),
              style: const TextStyle(color: Pal.muted, height: 1.4),
            ),
          ),
        for (final pc in all) _pcTile(pc, selected: target?.name == pc.name),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _manualIpDialog,
            icon: const Icon(Icons.add, size: 16, color: Pal.muted),
            label: Text(t('Agregar por IP', 'Add by IP'), style: const TextStyle(color: Pal.muted)),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ),
      ]),
    );
  }

  Widget _pcTile(PcEntry pc, {required bool selected}) {
    final online = selected && c.wifi.online;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? Pal.cardHi : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? Pal.accent.withValues(alpha: 0.6) : Pal.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => c.selectPc(pc),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(Icons.computer, size: 20, color: selected ? Pal.accent : Pal.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(pc.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${pc.host}:${pc.port}', style: monoStyle.copyWith(color: Pal.muted, fontSize: 12)),
                ]),
              ),
              if (selected) Dot(online ? Pal.ok : Pal.busy),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _manualIpDialog() async {
    final ip = TextEditingController(text: c.wifi.target?.manual == true ? c.wifi.target!.host : '');
    final port = TextEditingController(text: '$kUdpPort');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Pal.card,
        title: Text(t('Agregar PC por IP', 'Add computer by IP')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ip,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t('IP de la PC', 'Computer IP'), hintText: '192.168.1.50'),
            style: monoStyle,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: t('Puerto', 'Port')),
            style: monoStyle,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('Cancelar', 'Cancel'))),
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

  Widget _converting() => SrCard(
        child: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Convirtiendo a PDF…', 'Converting to PDF…'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${c.convertingName ?? ''}\n${t('Se hace en el teléfono, sin internet. La primera vez tarda más.', 'Done on the phone, offline. The first time takes longer.')}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Pal.muted, fontSize: 13, height: 1.4),
              ),
            ]),
          ),
        ]),
      );

  Widget _browserCard() {
    final b = c.browser;
    if (c.converting) return _converting();
    if (!b.hasPdf) {
      return SrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('Proyecta sin instalar nada en la PC', 'Present without installing anything on the computer'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            t('Elige tu presentación (PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} o PDF) y abre en el navegador '
                'de la PC la dirección que aparece. Si es .pptx u .odp, también verás tus notas aquí.',
                'Pick your presentation (PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} or PDF) and open the address '
                'shown here in the computer’s browser. With .pptx or .odp you’ll also see your notes here.'),
            style: const TextStyle(color: Pal.muted, height: 1.4),
          ),
          const SizedBox(height: 14),
          PillButton(t('Elegir presentación', 'Choose presentation'), primary: true, icon: Icons.slideshow_rounded, onTap: c.pickPresentation),
        ]),
      );
    }
    final url = b.urls.isNotEmpty ? b.urls.first : null;
    return SrCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Caption(t('En la PC, abre en el navegador', 'On the computer, open in the browser')),
        if (url == null)
          Text(t('Conéctate a una red WiFi (o activa el punto de acceso del teléfono).', 'Connect to a WiFi network (or turn on the phone’s hotspot).'),
              style: const TextStyle(color: Pal.muted))
        else
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Clipboard.setData(ClipboardData(text: url));
              _showNudge(t('Dirección copiada', 'Address copied'));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Pal.cardHi,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Pal.stroke),
              ),
              child: Row(children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(url.replaceFirst('http://', ''),
                        style: monoStyle.copyWith(fontSize: 22, color: Pal.accent, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.copy_rounded, size: 18, color: Pal.muted),
              ]),
            ),
          ),
        if (b.urls.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${t('Otras', 'Others')}: ${b.urls.skip(1).map((u) => u.replaceFirst('http://', '')).join('  ·  ')}',
                style: monoStyle.copyWith(color: Pal.muted, fontSize: 11)),
          ),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.slideshow_rounded, size: 18, color: Pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(b.pdfName ?? t('presentación', 'presentation'),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Pal.text)),
          ),
          if (c.deck != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: t('Notas cargadas', 'Notes loaded'),
                child: const Icon(Icons.sticky_note_2_outlined, size: 18, color: Pal.accent),
              ),
            ),
          PillButton(t('Cambiar', 'Change'), dense: true, onTap: c.pickPresentation),
        ]),
        const SizedBox(height: 10),
        PillButton(
          t('Dibujar sobre la diapositiva', 'Draw on the slide'),
          icon: Icons.draw_rounded,
          onTap: _openDraw,
        ),
      ]),
    );
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

  // ================================================================ botones grandes

  Widget _padsRow({bool compact = false}) {
    final dim = !c.canSend;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: dim ? 0.55 : 1,
      child: Row(children: [
        Expanded(
          child: _Pad(
            primary: false,
            label: t('Anterior', 'Previous'),
            icon: Icons.arrow_back_rounded,
            hint: c.invert ? 'VOL +' : 'VOL −',
            pulse: c.pulsePrev,
            compact: compact,
            onTap: () => c.send(forward: false),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: _Pad(
            primary: true,
            label: t('Siguiente', 'Next'),
            icon: Icons.arrow_forward_rounded,
            hint: c.invert ? 'VOL −' : 'VOL +',
            pulse: c.pulseNext,
            compact: compact,
            onTap: () => c.send(forward: true),
          ),
        ),
      ]),
    );
  }

  Widget _pads() {
    final dim = !c.canSend;
    final fwdHint = c.invert ? 'VOL −' : 'VOL +';
    final backHint = c.invert ? 'VOL +' : 'VOL −';
    final counter = c.mode == Mode.browser && c.browser.total > 0 ? '${c.browser.page} / ${c.browser.total}' : null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: dim ? 0.55 : 1,
      child: Column(children: [
        Expanded(
          flex: 2,
          child: _Pad(
            primary: true,
            label: t('Siguiente', 'Next'),
            icon: Icons.arrow_forward_rounded,
            hint: fwdHint,
            counter: counter,
            pulse: c.pulseNext,
            onTap: () => c.send(forward: true),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _Pad(
            primary: false,
            label: t('Anterior', 'Previous'),
            icon: Icons.arrow_back_rounded,
            hint: backHint,
            pulse: c.pulsePrev,
            onTap: () => c.send(forward: false),
          ),
        ),
      ]),
    );
  }

  // ================================================================ notas

  Widget _addNotesButton() => Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Pal.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: c.deckLoading ? null : c.pickNotes,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              const Icon(Icons.sticky_note_2_outlined, size: 20, color: Pal.muted),
              const SizedBox(width: 10),
              Expanded(
                child: c.mode == Mode.wifi
                    // Por WiFi lo normal es que la presentación esté solo en la PC
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t('Ver notas del presentador', 'Show speaker notes'), style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(t('Elige la presentación en la app de la PC', 'Choose the presentation in the desktop app'),
                            style: const TextStyle(color: Pal.muted, fontSize: 12.5)),
                      ])
                    : Text(t('Ver notas del presentador', 'Show speaker notes'), style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (c.deckLoading)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Text(c.mode == Mode.wifi ? t('o elígela aquí', 'or pick it here') : t('Elegir archivo', 'Choose file'),
                    style: const TextStyle(color: Pal.muted, fontSize: 13)),
            ]),
          ),
        ),
      );

  Widget _notesPanel() {
    final s = c.currentSlide;
    final next = c.nextSlide;
    final total = c.deck!.length;
    final hasNotes = s != null && s.notes.trim().isNotEmpty;
    return SrCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (c.notesFromPc)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: t('Notas enviadas por la app de la PC', 'Notes sent by the desktop app'),
                child: const Icon(Icons.computer_rounded, size: 16, color: Pal.muted),
              ),
            ),
          Text(
            '${c.slide + 1} / $total',
            style: monoStyle.copyWith(color: Pal.accent, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          if (s != null && s.clicks > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: Pal.cardHi, borderRadius: BorderRadius.circular(8)),
              child: Text('${t('animación', 'animation')} ${c.step}/${s.clicks}', style: const TextStyle(color: Pal.muted, fontSize: 11)),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s?.title.isNotEmpty == true ? s!.title : '${t('Diapositiva', 'Slide')} ${s?.number ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Pal.muted, fontSize: 13),
            ),
          ),
          // Corrección manual del contador (no cambia la diapositiva en la PC)
          if (!c.slideIsExact) ...[
            _tinyButton(Icons.remove, () => c.adjustSlide(-1)),
            _tinyButton(Icons.add, () => c.adjustSlide(1)),
          ],
          _tinyButton(
            _notesExpanded ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded,
            () => setState(() => _notesExpanded = !_notesExpanded),
            tooltip: _notesExpanded ? t('Contraer notas', 'Collapse notes') : t('Expandir notas', 'Expand notes'),
          ),
        ]),
        const Divider(color: Pal.stroke, height: 14),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey(c.slide), // al cambiar de diapositiva, regresar arriba
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              hasNotes ? s.notes : t('Sin notas en esta diapositiva.', 'No notes on this slide.'),
              style: TextStyle(
                fontSize: _notesFont,
                height: 1.45,
                color: hasNotes ? Pal.text : Pal.off,
              ),
            ),
          ),
        ),
        if (next != null) ...[
          const SizedBox(height: 8),
          Text(
            '${t('Sigue', 'Next')}: ${next.title.isNotEmpty ? next.title : '${t('diapositiva', 'slide')} ${next.number}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Pal.muted, fontSize: 12),
          ),
        ],
      ]),
    );
  }

  Widget _tinyButton(IconData icon, VoidCallback onTap, {String? tooltip}) => SizedBox(
        width: 34,
        height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 18,
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, color: Pal.muted),
        ),
      );

  double _notesFont = 19;
  bool _notesExpanded = false;

  // ================================================================ ajustes

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Pal.card,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => ListenableBuilder(
        listenable: Listenable.merge([c, I18n.current]),
        builder: (ctx, _) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text(t('Ajustes', 'Settings'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              _switch(t('Invertir botones', 'Swap buttons'), t('Volumen − avanza', 'Volume − goes forward'), c.invert, c.setInvert),
              _switch(t('Usar flechas ← →', 'Use arrow keys ← →'),
                  t('Si tu programa no responde a AvPág/RePág', 'If your app ignores Page Down/Page Up'), c.arrows, c.setArrows),
              const SizedBox(height: 10),
              _languagePicker(),
              const SizedBox(height: 14),
              Caption(t('Notas del presentador', 'Speaker notes')),
              if (c.deck == null)
                PillButton(t('Elegir presentación (.pptx, .odp)', 'Choose presentation (.pptx, .odp)'), icon: Icons.sticky_note_2_outlined, onTap: () {
                  Navigator.pop(ctx);
                  c.pickNotes();
                })
              else ...[
                Row(children: [
                  Icon(c.notesFromPc ? Icons.computer_rounded : Icons.slideshow_rounded, size: 18, color: Pal.muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(c.deckName ?? t('presentación.pptx', 'presentation.pptx'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                if (c.notesFromPc)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      t('Vienen de la app de la PC. Para cambiarlas, elige otra presentación allá.',
                          'They come from the desktop app. To change them, choose another presentation there.'),
                      style: const TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: Text(t('Tamaño del texto', 'Text size'))),
                  _tinyButton(Icons.text_decrease, () => setState(() => _notesFont = (_notesFont - 2).clamp(13, 32))),
                  _tinyButton(Icons.text_increase, () => setState(() => _notesFont = (_notesFont + 2).clamp(13, 32))),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  PillButton(t('Volver a la diapositiva 1', 'Back to slide 1'), dense: true, onTap: c.restartNotes),
                  if (!c.notesFromPc) ...[
                    PillButton(t('Cambiar archivo', 'Change file'), dense: true, onTap: () {
                      Navigator.pop(ctx);
                      c.pickNotes();
                    }),
                    PillButton(t('Quitar notas', 'Remove notes'), dense: true, onTap: () {
                      Navigator.pop(ctx);
                      c.clearNotes();
                    }),
                  ],
                ]),
                const SizedBox(height: 10),
                Text(
                  t('Con PowerPoint o Impress el teléfono cuenta las pulsaciones (incluidas las animaciones); si se desfasa, '
                      'corrígelo con − / + en el panel de notas. Al transmitir (desde la PC o desde el móvil) se sincroniza solo.',
                      'With PowerPoint or Impress the phone counts the presses (animations included); if it gets out of step, '
                      'fix it with − / + in the notes panel. When streaming (from the PC or the phone) it syncs by itself.'),
                  style: const TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  /// Idioma: Sistema / Español / English (se guarda; "Sistema" usa inglés si el sistema no está en español).
  Widget _languagePicker() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Caption(t('Idioma', 'Language')),
        Segmented<LangPref>(
          values: LangPref.values,
          labels: [t('Sistema', 'System'), 'Español', 'English'],
          selected: I18n.pref,
          onChanged: (p) {
            I18n.setPref(p);
            c.languageChanged();
          },
        ),
      ]);

  Widget _switch(String title, String sub, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        subtitle: Text(sub, style: const TextStyle(color: Pal.muted, fontSize: 12)),
      );
}

/// Botón grande que también se anima cuando la pulsación viene del botón de volumen.
class _Pad extends StatefulWidget {
  const _Pad({
    required this.primary,
    required this.label,
    required this.icon,
    required this.hint,
    required this.pulse,
    required this.onTap,
    this.counter,
    this.compact = false,
  });

  /// Versión baja (una sola fila) para cuando las notas ocupan la pantalla.
  final bool compact;

  final bool primary;
  final String label;
  final IconData icon;
  final String hint;
  final String? counter;
  final ValueNotifier<int> pulse;
  final VoidCallback onTap;

  @override
  State<_Pad> createState() => _PadState();
}

class _PadState extends State<_Pad> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

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
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.primary ? Pal.onAccent : Pal.text;
    final bg = widget.primary ? Pal.accent : Pal.card;
    final big = widget.primary;
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        // 0 → 1: se encoge un poco y regresa
        final t = _anim.value;
        final scale = 1 - 0.04 * (t < 0.35 ? t / 0.35 : (1 - t) / 0.65);
        final flash = (t < 0.35 ? t / 0.35 : (1 - t) / 0.65) * 0.18;
        return Transform.scale(
          scale: scale,
          child: Stack(fit: StackFit.expand, children: [
            child!,
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: (widget.primary ? Colors.black : Colors.white).withValues(alpha: flash),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
            ),
          ]),
        );
      },
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: widget.primary ? BorderSide.none : const BorderSide(color: Pal.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: widget.compact ? _compactContent(fg) : Stack(children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                // FittedBox reduce el contenido si el botón queda chico (pantallas bajas)
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(widget.icon, size: big ? 64 : 36, color: fg),
                    Text(
                      widget.label.toUpperCase(),
                      style: TextStyle(
                        color: fg,
                        fontSize: big ? 24 : 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: widget.primary ? Colors.black.withValues(alpha: 0.12) : Pal.cardHi,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        widget.hint,
                        style: TextStyle(
                          color: widget.primary ? Pal.onAccent.withValues(alpha: 0.7) : Pal.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.8,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            if (widget.counter != null)
              Positioned(
                top: 14,
                right: 18,
                child: Text(
                  widget.counter!,
                  style: monoStyle.copyWith(color: fg.withValues(alpha: 0.7), fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _compactContent(Color fg) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(widget.icon, size: 26, color: fg),
              const SizedBox(width: 8),
              Text(
                widget.label.toUpperCase(),
                style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.2),
              ),
            ]),
          ),
        ),
      );
}
