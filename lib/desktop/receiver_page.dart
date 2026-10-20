import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
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
        listenable: Listenable.merge([c, I18n.current]),
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
                Text(
                  t('Deja esta ventana abierta (puede estar minimizada) y pon tu presentación al frente. '
                      'Con Android por Bluetooth no necesitas esta app: el teléfono funciona como teclado.',
                      'Keep this window open (it can be minimized) and bring your presentation to the front. '
                      'With Android over Bluetooth you don’t need this app: the phone works as a keyboard.'),
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
        Image.asset('assets/icon/logo.png', width: 60, height: 60, filterQuality: FilterQuality.medium),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Zlide', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            Text(t('Receptor para la PC', 'Receiver for the computer'), style: TextStyle(color: Pal.muted)),
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
            Icon(Icons.computer, size: 16, color: Pal.muted),
            const SizedBox(width: 8),
            Text(c.hostName, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(width: 6),
        _themeMenu(),
        _languageMenu(),
      ]);

  /// Tema: Sistema / Claro / Oscuro.
  Widget _themeMenu() => PopupMenuButton<ThemePref>(
        tooltip: t('Tema', 'Theme'),
        icon: Icon(Pal.p.dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded, color: Pal.muted),
        color: Pal.cardHi,
        initialValue: AppTheme.pref,
        onSelected: AppTheme.setPref,
        itemBuilder: (_) => [
          PopupMenuItem(value: ThemePref.system, child: Text(t('Tema del sistema', 'System theme'))),
          PopupMenuItem(value: ThemePref.light, child: Text(t('Claro', 'Light'))),
          PopupMenuItem(value: ThemePref.dark, child: Text(t('Oscuro', 'Dark'))),
        ],
      );

  /// Idioma: Sistema / Español / English.
  Widget _languageMenu() => PopupMenuButton<LangPref>(
        tooltip: t('Idioma', 'Language'),
        icon: Icon(Icons.translate_rounded, color: Pal.muted),
        color: Pal.cardHi,
        initialValue: I18n.pref,
        onSelected: (p) {
          I18n.setPref(p);
          // Los avisos de permisos se generan al comprobar: volver a generarlos en el idioma nuevo
          if (c.injector.problem != null) c.retryInjector();
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: LangPref.system, child: Text(t('Idioma del sistema', 'System language'))),
          const PopupMenuItem(value: LangPref.es, child: Text('Español')),
          const PopupMenuItem(value: LangPref.en, child: Text('English')),
        ],
      );

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
                  ? (connected ? t('Teléfono conectado', 'Phone connected') : t('Esperando al teléfono', 'Waiting for the phone'))
                  : '${Cmd.isForward(l.cmd) ? t('Siguiente', 'Next') : t('Anterior', 'Previous')}  ·  ${Cmd.label(l.cmd)}',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              l == null
                  ? t('Abre Zlide en el teléfono y presiona volumen.', 'Open Zlide on the phone and press volume.')
                  : '${t('Por', 'Via')} ${l.source}  ·  ${c.count} ${c.count == 1 ? t('cambio', 'change') : t('cambios', 'changes')}',
              style: TextStyle(color: Pal.muted),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _notesCard() {
    final n = c.notes;
    final p = c.present;
    final deck = n.deck;
    final has = n.path != null;
    return SrCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: Pal.cardHi, borderRadius: BorderRadius.circular(12)),
          child: Icon(Icons.slideshow_rounded, color: has ? Pal.accent : Pal.muted, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(t('Tu presentación', 'Your presentation'),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (n.loading || p.converting)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Dot(connColor(p.active ? Conn.on : (has ? Conn.busy : Conn.off))),
            ]),
            const SizedBox(height: 4),
            if (!has)
              Text(
                t('Elige aquí tu presentación (PowerPoint, LibreOffice, OnlyOffice, PDF…). El teléfono mostrará sus notas por WiFi, '
                    'y con “Proyectar en esta PC” también podrás dibujar sobre ella desde el teléfono.',
                    'Choose your presentation here (PowerPoint, LibreOffice, OnlyOffice, PDF…). The phone will show its notes over WiFi, '
                    'and with “Present on this computer” you can also draw on it from the phone.'),
                style: TextStyle(color: Pal.muted, height: 1.4),
              )
            else ...[
              Text(n.name ?? t('presentación', 'presentation'),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                deck == null
                    ? t('PDF: sirve para proyectar, pero no trae notas.', 'PDF: good for presenting, but it has no notes.')
                    : t('${n.slideCount} diapositivas · ${n.withNotes} con notas. '
                        'Si guardas cambios en el archivo, se actualizan solas.',
                        '${n.slideCount} slides · ${n.withNotes} with notes. '
                        'If you save changes to the file, they update automatically.'),
                style: TextStyle(color: Pal.muted, height: 1.4, fontSize: 13),
              ),
            ],
            if (p.converting) ...[
              const SizedBox(height: 6),
              Text(t('Preparando la presentación para proyectar…', 'Preparing the presentation for presenting…'),
                  style: TextStyle(color: Pal.busy, fontSize: 13)),
            ] else if (p.active) ...[
              const SizedBox(height: 6),
              Text(
                '${t('Proyectando en el navegador', 'Presenting in the browser')} · '
                '${p.total > 0 ? t('diapositiva ${p.page} de ${p.total}', 'slide ${p.page} of ${p.total}') : '…'}'
                '${p.viewers == 0 ? ' · ${t('abre la ventana del navegador', 'open the browser window')}' : ''}',
                style: TextStyle(color: Pal.ok, fontSize: 13, height: 1.4),
              ),
            ],
            if (n.error != null || p.error != null) ...[
              const SizedBox(height: 6),
              Text((p.error ?? n.error)!, style: TextStyle(color: Pal.error, height: 1.4, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (has && !p.active)
                PillButton(
                  t('Proyectar en esta PC', 'Present on this computer'),
                  primary: true,
                  dense: true,
                  icon: Icons.cast_rounded,
                  onTap: p.converting ? null : c.startPresenting,
                ),
              if (p.active) ...[
                PillButton(t('Abrir en el navegador', 'Open in the browser'),
                    primary: true, dense: true, icon: Icons.open_in_new_rounded, onTap: p.openInBrowser),
                PillButton(t('Detener', 'Stop'), dense: true, icon: Icons.stop_rounded, onTap: p.stop),
              ],
              PillButton(
                has ? t('Cambiar', 'Change') : t('Elegir presentación', 'Choose presentation'),
                primary: !has,
                dense: true,
                icon: Icons.folder_open_rounded,
                onTap: n.loading ? null : n.pick,
              ),
              if (has && !p.active) PillButton(t('Quitar', 'Remove'), dense: true, onTap: n.clear),
            ]),
            if (has && !p.active) ...[
              const SizedBox(height: 8),
              Text(
                t('Proyectar en esta PC: la presentación se abre a pantalla completa en el navegador y la controlas desde el teléfono, '
                    'con dibujo y notas sincronizadas. Para .pptx/.odp hace falta LibreOffice (o PowerPoint en Windows).',
                    'Present on this computer: the presentation opens full screen in the browser and you control it from the phone, '
                    'with drawing and synced notes. .pptx/.odp need LibreOffice (or PowerPoint on Windows).'),
                style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.4),
              ),
            ],
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
        Row(children: [
          Icon(Icons.lock_outline, color: Pal.error, size: 20),
          const SizedBox(width: 8),
          Text(t('Falta un permiso', 'A permission is missing'), style: TextStyle(fontWeight: FontWeight.w700, color: Pal.error)),
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
            PillButton(t('Abrir Accesibilidad', 'Open Accessibility'), primary: true, dense: true, onTap: openMacAccessibilitySettings),
          if (isLinux)
            PillButton(t('Copiar comando', 'Copy command'), primary: true, dense: true, icon: Icons.copy_rounded, onTap: () {
              Clipboard.setData(const ClipboardData(text: linuxUinputFixCommand));
            }),
          PillButton(t('Volver a comprobar', 'Check again'), dense: true, onTap: c.retryInjector),
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
          child: Icon(icon, color: conn == Conn.on ? Pal.ok : Pal.muted, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              Dot(connColor(conn)),
            ]),
            const SizedBox(height: 4),
            Text(detail, style: TextStyle(color: Pal.muted, height: 1.4)),
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
      return _row(conn: Conn.busy, icon: Icons.wifi, title: 'WiFi', detail: t('Iniciando…', 'Starting…'));
    }
    final ips = c.localIps.isEmpty ? null : c.localIps.map((ip) => '$ip:$kUdpPort').join('   ');
    if (c.wifiPhoneConnected) {
      return _row(
        conn: Conn.on,
        icon: Icons.wifi,
        title: 'WiFi',
        detail: '${t('Teléfono conectado', 'Phone connected')} (${c.wifiPeer})',
        extra: ips,
      );
    }
    return _row(
      conn: Conn.busy,
      icon: Icons.wifi,
      title: 'WiFi',
      detail: c.wifiAnnounced
          ? t('Visible en la red como “${c.hostName}”. En el teléfono elige “Transmitir desde PC”.',
              'Visible on the network as “${c.hostName}”. On the phone choose “Stream from PC”.')
          : t('Escuchando. Si el teléfono no encuentra la PC, agrégala por IP:',
              'Listening. If the phone can’t find the computer, add it by IP:'),
      extra: ips,
    );
  }

  Widget _bleCard() {
    final (conn, detail) = switch (c.bleStatus) {
      BleStatus.connected => (Conn.on, '${t('Conectado a', 'Connected to')} ${c.bleDeviceName ?? 'iPhone'}'),
      BleStatus.connecting => (Conn.busy, t('Conectando con ${c.bleDeviceName ?? 'el iPhone'}…', 'Connecting to ${c.bleDeviceName ?? 'the iPhone'}…')),
      BleStatus.searching => (Conn.busy, t('Buscando el iPhone. Abre Zlide y elige “Control Bluetooth”.', 'Looking for the iPhone. Open Zlide and choose “Bluetooth control”.')),
      BleStatus.off => (Conn.error, t('El Bluetooth de la PC está apagado.', 'The computer’s Bluetooth is off.')),
      BleStatus.unauthorized => (Conn.error, t('Permite el uso de Bluetooth a Zlide en los ajustes del sistema.', 'Allow Zlide to use Bluetooth in the system settings.')),
      BleStatus.unsupported => (Conn.off, t('Esta PC no tiene Bluetooth LE.', 'This computer has no Bluetooth LE.')),
      BleStatus.unknown => (Conn.off, t('Iniciando…', 'Starting…')),
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
