import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/protocol.dart';
import '../common/theme.dart';
import 'remote_controller.dart';
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
          listenable: c,
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
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: _notesPanel()),
                        const SizedBox(height: 10),
                        SizedBox(height: 64, child: _padsRow(compact: true)),
                      ]),
                    )
                  : Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _header(),
                  const SizedBox(height: 16),
                  Segmented<Mode>(
                    values: Mode.values,
                    labels: const ['Bluetooth', 'WiFi', 'Navegador'],
                    selected: c.mode,
                    onChanged: c.setMode,
                  ),
                  const SizedBox(height: 12),
                  // La tarjeta del modo nunca se come la pantalla: si crece, hace scroll
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: box.maxHeight * (notes ? 0.28 : 0.4)),
                    child: SingleChildScrollView(
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        alignment: Alignment.topCenter,
                        child: _modeCard(),
                      ),
                    ),
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
          const Expanded(
            child: Text(
              'Slide\nRemote',
              style: TextStyle(
                fontSize: 28,
                height: 0.95,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
              ),
            ),
          ),
          StatusChip(c.status, maxWidth: 190),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded, color: Pal.muted),
            tooltip: 'Ajustes',
          ),
        ],
      );

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
              const Caption('Teclado conectado a'),
              Text(c.btDeviceName ?? 'PC',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ]),
          ),
          PillButton('Desconectar', onTap: c.disconnectBluetooth, dense: true),
        ]),
      );
    }
    if (s == BtState.unavailable || s == BtState.off || s == BtState.noPermission) {
      return SrCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            switch (s) {
              BtState.off => 'Activa el Bluetooth del teléfono.',
              BtState.noPermission => 'Slide Remote necesita el permiso de “Dispositivos cercanos”.',
              _ => c.btMessage ?? 'El modo teclado no está disponible en este teléfono. Usa WiFi o Navegador.',
            },
            style: const TextStyle(color: Pal.muted, height: 1.4),
          ),
          if (s != BtState.unavailable) ...[
            const SizedBox(height: 12),
            PillButton('Reintentar', primary: true, onTap: c.retryBluetooth),
          ],
        ]),
      );
    }
    return SrCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Caption('Tu PC'),
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
              hint: const Text('Ninguna PC emparejada', style: TextStyle(color: Pal.muted)),
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
              c.btState == BtState.connecting ? 'Conectando…' : 'Conectar',
              primary: true,
              onTap: c.btState == BtState.connecting ? null : c.connectSelected,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: PillButton('Emparejar nueva', onTap: c.pairNew)),
        ]),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: c.refreshBonded,
            icon: const Icon(Icons.refresh, size: 16, color: Pal.muted),
            label: const Text('Actualizar lista', style: TextStyle(color: Pal.muted)),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
          ),
        ),
        const Text(
          'Sin instalar nada en la PC: el teléfono funciona como teclado Bluetooth '
          '(Windows, Mac y Linux).',
          style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
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
              connected ? 'Conectado a la PC' : 'Buscando la PC…',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              connected
                  ? 'Los botones de volumen ya cambian la diapositiva.'
                  : 'Abre Slide Remote para escritorio en la PC; se conecta sola. '
                      'En iPhone, el Bluetooth necesita esa app.',
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
          const Expanded(child: Caption('PCs con Slide Remote')),
          if (c.wifi.searching)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: Pal.muted)),
            ),
        ]),
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Abre Slide Remote para escritorio en la PC y conéctate a la misma red WiFi.',
              style: TextStyle(color: Pal.muted, height: 1.4),
            ),
          ),
        for (final pc in all) _pcTile(pc, selected: target?.name == pc.name),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _manualIpDialog,
            icon: const Icon(Icons.add, size: 16, color: Pal.muted),
            label: const Text('Agregar por IP', style: TextStyle(color: Pal.muted)),
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
              if (selected) Dot(online ? Pal.accent : Pal.busy),
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
        title: const Text('Agregar PC por IP'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ip,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'IP de la PC', hintText: '192.168.1.50'),
            style: monoStyle,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Puerto'),
            style: monoStyle,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Agregar')),
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
              const Text('Convirtiendo a PDF…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '${c.convertingName ?? ''}\nSe hace en el teléfono, sin internet. La primera vez tarda más.',
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
          const Text('Proyecta sin instalar nada en la PC',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Elige tu presentación (PowerPoint${c.isIOS ? ', Keynote' : ''} o PDF) y abre en el navegador '
            'de la PC la dirección que aparece. Si es .pptx u .odp, también verás tus notas aquí.',
            style: const TextStyle(color: Pal.muted, height: 1.4),
          ),
          const SizedBox(height: 14),
          PillButton('Elegir presentación', primary: true, icon: Icons.slideshow_rounded, onTap: c.pickPresentation),
        ]),
      );
    }
    final url = b.urls.isNotEmpty ? b.urls.first : null;
    return SrCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Caption('En la PC, abre en el navegador'),
        if (url == null)
          const Text('Conéctate a una red WiFi (o activa el punto de acceso del teléfono).',
              style: TextStyle(color: Pal.muted))
        else
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Clipboard.setData(ClipboardData(text: url));
              _showNudge('Dirección copiada');
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
            child: Text('Otras: ${b.urls.skip(1).map((u) => u.replaceFirst('http://', '')).join('  ·  ')}',
                style: monoStyle.copyWith(color: Pal.muted, fontSize: 11)),
          ),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.slideshow_rounded, size: 18, color: Pal.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(b.pdfName ?? 'presentación',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Pal.text)),
          ),
          if (c.deck != null)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Tooltip(
                message: 'Notas cargadas',
                child: Icon(Icons.sticky_note_2_outlined, size: 18, color: Pal.accent),
              ),
            ),
          PillButton('Cambiar', dense: true, onTap: c.pickPresentation),
        ]),
      ]),
    );
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
            label: 'Anterior',
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
            label: 'Siguiente',
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
            label: 'Siguiente',
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
            label: 'Anterior',
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
                    ? const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Ver notas del presentador', style: TextStyle(fontWeight: FontWeight.w600)),
                        SizedBox(height: 2),
                        Text('Elige la presentación en la app de la PC',
                            style: TextStyle(color: Pal.muted, fontSize: 12.5)),
                      ])
                    : const Text('Ver notas del presentador', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (c.deckLoading)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Text(c.mode == Mode.wifi ? 'o elígela aquí' : 'Elegir archivo',
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
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Tooltip(
                message: 'Notas enviadas por la app de la PC',
                child: Icon(Icons.computer_rounded, size: 16, color: Pal.muted),
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
              child: Text('animación ${c.step}/${s.clicks}', style: const TextStyle(color: Pal.muted, fontSize: 11)),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s?.title.isNotEmpty == true ? s!.title : 'Diapositiva ${s?.number ?? ''}',
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
            tooltip: _notesExpanded ? 'Contraer notas' : 'Expandir notas',
          ),
        ]),
        const Divider(color: Pal.stroke, height: 14),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey(c.slide), // al cambiar de diapositiva, regresar arriba
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              hasNotes ? s.notes : 'Sin notas en esta diapositiva.',
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
            'Sigue: ${next.title.isNotEmpty ? next.title : 'diapositiva ${next.number}'}',
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
        listenable: c,
        builder: (ctx, _) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              const Text('Ajustes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              _switch('Invertir botones', 'Volumen − avanza', c.invert, c.setInvert),
              _switch('Usar flechas ← →', 'Si tu programa no responde a AvPág/RePág', c.arrows, c.setArrows),
              const SizedBox(height: 14),
              const Caption('Notas del presentador'),
              if (c.deck == null)
                PillButton('Elegir presentación (.pptx, .odp)', icon: Icons.sticky_note_2_outlined, onTap: () {
                  Navigator.pop(ctx);
                  c.pickNotes();
                })
              else ...[
                Row(children: [
                  Icon(c.notesFromPc ? Icons.computer_rounded : Icons.slideshow_rounded, size: 18, color: Pal.muted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(c.deckName ?? 'presentación.pptx', maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                if (c.notesFromPc)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Vienen de la app de la PC. Para cambiarlas, elige otra presentación allá.',
                      style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  const Expanded(child: Text('Tamaño del texto')),
                  _tinyButton(Icons.text_decrease, () => setState(() => _notesFont = (_notesFont - 2).clamp(13, 32))),
                  _tinyButton(Icons.text_increase, () => setState(() => _notesFont = (_notesFont + 2).clamp(13, 32))),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  PillButton('Volver a la diapositiva 1', dense: true, onTap: c.restartNotes),
                  if (!c.notesFromPc) ...[
                    PillButton('Cambiar archivo', dense: true, onTap: () {
                      Navigator.pop(ctx);
                      c.pickNotes();
                    }),
                    PillButton('Quitar notas', dense: true, onTap: () {
                      Navigator.pop(ctx);
                      c.clearNotes();
                    }),
                  ],
                ]),
                const SizedBox(height: 10),
                const Text(
                  'Por Bluetooth y WiFi el teléfono cuenta las pulsaciones (incluidas las animaciones). '
                  'Si se desfasa, corrígelo con − / + en el panel de notas. En el modo Navegador se sincroniza solo.',
                  style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

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
