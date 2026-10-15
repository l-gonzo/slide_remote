import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/protocol.dart';
import '../common/theme.dart';
import 'key_injector.dart';
import 'receiver_controller.dart';

/// Ventana de la app de escritorio. Puede quedarse minimizada: no necesita el foco.
class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  final c = ReceiverController();

  @override
  void initState() {
    super.initState();
    c.init();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: c,
        builder: (context, _) => Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _header(),
                const SizedBox(height: 22),
                _activity(),
                const SizedBox(height: 14),
                _notesCard(),
                const SizedBox(height: 14),
                if (c.injector.problem != null) ...[_permissionCard(), const SizedBox(height: 14)],
                _wifiCard(),
                const SizedBox(height: 14),
                _bleCard(),
                const SizedBox(height: 18),
                const Text(
                  'Deja esta ventana abierta (puede estar minimizada) y pon tu presentación al frente. '
                  'Con Android por Bluetooth no necesitas esta app: el teléfono funciona como teclado.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Pal.muted, fontSize: 12.5, height: 1.5),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: Pal.accent, borderRadius: BorderRadius.circular(14)),
          child: const Icon(Icons.slideshow_rounded, color: Pal.onAccent, size: 28),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Slide Remote', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            Text('Receptor para la PC', style: TextStyle(color: Pal.muted)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Pal.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Pal.stroke),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.computer, size: 16, color: Pal.muted),
            const SizedBox(width: 8),
            Text(c.hostName, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
      ]);

  Widget _activity() {
    final l = c.last;
    final recent = l != null && DateTime.now().difference(l.at) < const Duration(seconds: 3);
    final connected = c.wifiPhoneConnected || c.bleStatus == BleStatus.connected;
    return SrCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Row(children: [
        AnimatedContainer(
          key: ValueKey(c.count),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: recent ? Pal.accent : Pal.cardHi,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(
            l == null
                ? Icons.touch_app_outlined
                : Cmd.isForward(l.cmd)
                    ? Icons.arrow_forward_rounded
                    : Icons.arrow_back_rounded,
            size: 34,
            color: recent ? Pal.onAccent : Pal.muted,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              l == null
                  ? (connected ? 'Teléfono conectado' : 'Esperando al teléfono')
                  : '${Cmd.isForward(l.cmd) ? 'Siguiente' : 'Anterior'}  ·  ${Cmd.label(l.cmd)}',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              l == null
                  ? 'Abre Slide Remote en el teléfono y presiona volumen.'
                  : 'Por ${l.source}  ·  ${c.count} ${c.count == 1 ? 'cambio' : 'cambios'}',
              style: const TextStyle(color: Pal.muted),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _notesCard() {
    final n = c.notes;
    final deck = n.deck;
    return SrCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Pal.cardHi, borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.sticky_note_2_outlined, color: deck != null ? Pal.accent : Pal.muted, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                child: Text('Notas en el teléfono', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (n.loading)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Dot(connColor(deck != null ? Conn.on : Conn.off)),
            ]),
            const SizedBox(height: 4),
            if (deck == null)
              const Text(
                'Elige aquí tu presentación (PowerPoint, LibreOffice, OnlyOffice…) y el teléfono mostrará sus notas por WiFi. '
                'El archivo no tiene que estar en el teléfono.',
                style: TextStyle(color: Pal.muted, height: 1.4),
              )
            else ...[
              Text(n.name ?? 'presentación.pptx',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '${n.slideCount} diapositivas · ${n.withNotes} con notas. '
                'Si guardas cambios en el archivo, se actualizan solas.',
                style: const TextStyle(color: Pal.muted, height: 1.4, fontSize: 13),
              ),
            ],
            if (n.error != null) ...[
              const SizedBox(height: 6),
              Text(n.error!, style: const TextStyle(color: Pal.error, height: 1.4, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              PillButton(
                deck == null ? 'Elegir presentación' : 'Cambiar',
                primary: deck == null,
                dense: true,
                icon: Icons.folder_open_rounded,
                onTap: n.loading ? null : n.pick,
              ),
              if (deck != null) PillButton('Quitar', dense: true, onTap: n.clear),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _permissionCard() {
    final isLinux = Platform.isLinux;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Pal.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Pal.error.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.lock_outline, color: Pal.error, size: 20),
          SizedBox(width: 8),
          Text('Falta un permiso', style: TextStyle(fontWeight: FontWeight.w700, color: Pal.error)),
        ]),
        const SizedBox(height: 8),
        Text(c.injector.problem!, style: const TextStyle(height: 1.45)),
        if (isLinux) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Pal.bg, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(linuxUinputFixCommand, style: monoStyle.copyWith(fontSize: 11.5, color: Pal.muted)),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (Platform.isMacOS)
            PillButton('Abrir Accesibilidad', primary: true, dense: true, onTap: openMacAccessibilitySettings),
          if (isLinux)
            PillButton('Copiar comando', primary: true, dense: true, icon: Icons.copy_rounded, onTap: () {
              Clipboard.setData(const ClipboardData(text: linuxUinputFixCommand));
            }),
          PillButton('Volver a comprobar', dense: true, onTap: c.retryInjector),
        ]),
      ]),
    );
  }

  Widget _row({required Conn conn, required IconData icon, required String title, required String detail, String? extra}) {
    return SrCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Pal.cardHi, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: conn == Conn.on ? Pal.accent : Pal.muted, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              Dot(connColor(conn)),
            ]),
            const SizedBox(height: 4),
            Text(detail, style: const TextStyle(color: Pal.muted, height: 1.4)),
            if (extra != null) ...[
              const SizedBox(height: 6),
              SelectableText(extra, style: monoStyle.copyWith(fontSize: 12, color: Pal.muted)),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _wifiCard() {
    if (c.wifiError != null) {
      return _row(conn: Conn.error, icon: Icons.wifi, title: 'WiFi', detail: c.wifiError!);
    }
    if (!c.wifiListening) {
      return _row(conn: Conn.busy, icon: Icons.wifi, title: 'WiFi', detail: 'Iniciando…');
    }
    final ips = c.localIps.isEmpty ? null : c.localIps.map((ip) => '$ip:$kUdpPort').join('   ');
    if (c.wifiPhoneConnected) {
      return _row(
        conn: Conn.on,
        icon: Icons.wifi,
        title: 'WiFi',
        detail: 'Teléfono conectado (${c.wifiPeer})',
        extra: ips,
      );
    }
    return _row(
      conn: Conn.busy,
      icon: Icons.wifi,
      title: 'WiFi',
      detail: c.wifiAnnounced
          ? 'Visible en la red como “${c.hostName}”. En el teléfono elige el modo WiFi.'
          : 'Escuchando. Si el teléfono no encuentra la PC, agrégala por IP:',
      extra: ips,
    );
  }

  Widget _bleCard() {
    final (conn, detail) = switch (c.bleStatus) {
      BleStatus.connected => (Conn.on, 'Conectado a ${c.bleDeviceName ?? 'iPhone'}'),
      BleStatus.connecting => (Conn.busy, 'Conectando con ${c.bleDeviceName ?? 'el iPhone'}…'),
      BleStatus.searching => (Conn.busy, 'Buscando el iPhone. Abre Slide Remote y elige Bluetooth.'),
      BleStatus.off => (Conn.error, 'El Bluetooth de la PC está apagado.'),
      BleStatus.unauthorized => (Conn.error, 'Permite el uso de Bluetooth a Slide Remote en los ajustes del sistema.'),
      BleStatus.unsupported => (Conn.off, 'Esta PC no tiene Bluetooth LE.'),
      BleStatus.unknown => (Conn.off, 'Iniciando…'),
    };
    return _row(
      conn: conn,
      icon: Icons.bluetooth,
      title: 'Bluetooth (iPhone)',
      detail: detail,
      extra: c.bleError != null && c.bleStatus != BleStatus.connected ? c.bleError : null,
    );
  }
}
