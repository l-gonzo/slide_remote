import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../common/protocol.dart';
import '../common/theme.dart';
import 'browser_server.dart';
import 'native_bridge.dart';
import 'wifi_client.dart';

enum Mode { bluetooth, wifi, browser }

/// Estado del modo Bluetooth (Android = teclado HID, iOS = BLE hacia la app de escritorio).
enum BtState { unknown, unavailable, off, noPermission, idle, connecting, connected, waiting }

/// Toda la lógica del control remoto. La UI solo escucha y llama métodos.
class RemoteController extends ChangeNotifier {
  RemoteController() {
    wifi.addListener(notifyListeners);
    browser.addListener(notifyListeners);
  }

  final wifi = WifiClient();
  final browser = BrowserServer();

  final bool isAndroid = Platform.isAndroid;
  final bool isIOS = Platform.isIOS;

  late SharedPreferences _prefs;
  StreamSubscription<Map<String, Object?>>? _nativeSub;
  bool _ready = false;
  bool _foreground = false;

  Mode mode = Mode.bluetooth;
  bool invert = false;
  bool arrows = false;

  // ---- Bluetooth
  BtState btState = BtState.unknown;
  String? btDeviceName; // PC conectada (Android)
  String? btMessage;
  List<BtDevice> bonded = const [];
  String? selectedAddress;
  bool _btAuto = false;

  // ---- avisos para la UI
  final _nudges = StreamController<String>.broadcast();
  Stream<String> get nudges => _nudges.stream;

  /// Contadores que la UI usa para animar los botones.
  final pulseNext = ValueNotifier<int>(0);
  final pulsePrev = ValueNotifier<int>(0);

  bool get ready => _ready;

  // ================================================================ ciclo de vida

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    mode = Mode.values.firstWhere((m) => m.name == _prefs.getString('mode'), orElse: () => Mode.bluetooth);
    invert = _prefs.getBool('invert') ?? false;
    arrows = _prefs.getBool('arrows') ?? false;
    selectedAddress = _prefs.getString('bt_addr');
    _btAuto = _prefs.getBool('bt_auto') ?? false;
    wifi.preferredName = _prefs.getString('wifi_name');
    final host = _prefs.getString('wifi_host');
    if (host != null) {
      await wifi.select(PcEntry(
        name: wifi.preferredName ?? host,
        host: host,
        port: _prefs.getInt('wifi_port') ?? kUdpPort,
        manual: _prefs.getBool('wifi_manual') ?? false,
      ));
    }
    await _restorePdf();

    _nativeSub = NativeBridge.events.listen(_onNative);
    _ready = true;
    notifyListeners();
    await onForeground();
  }

  @override
  void dispose() {
    _nativeSub?.cancel();
    wifi.dispose();
    browser.dispose();
    _nudges.close();
    super.dispose();
  }

  /// La app volvió al frente: capturar volumen y reconectar el modo actual.
  Future<void> onForeground() async {
    // Diálogos del sistema (permisos, "hacer visible") también disparan onResume: ignorar
    if (!_ready || _foreground) return;
    _foreground = true;
    await NativeBridge.setVolumeCapture(true);
    await WakelockPlus.enable();
    await _startMode(mode, resumed: true);
  }

  /// La app pasó a segundo plano: soltar el volumen y la PC.
  Future<void> onBackground() async {
    if (!_ready || !_foreground) return;
    _foreground = false;
    await NativeBridge.setVolumeCapture(false);
    await WakelockPlus.disable();
    await _stopTransports(keepBrowser: true);
  }

  Future<void> setMode(Mode m) async {
    if (m == mode) return;
    await _stopTransports(keepBrowser: m == Mode.browser);
    if (mode == Mode.browser && m != Mode.browser) await browser.stop();
    mode = m;
    await _prefs.setString('mode', m.name);
    notifyListeners();
    if (_foreground) await _startMode(m);
  }

  Future<void> _startMode(Mode m, {bool resumed = false}) async {
    switch (m) {
      case Mode.bluetooth:
        await _startBluetooth();
      case Mode.wifi:
        await wifi.start();
      case Mode.browser:
        if (resumed && isIOS) {
          await browser.restart();
        } else {
          await browser.start();
        }
        await browser.refreshUrls();
    }
  }

  Future<void> _stopTransports({required bool keepBrowser}) async {
    if (isAndroid) await NativeBridge.hidPause();
    if (isIOS) await NativeBridge.bleStop();
    await wifi.stop();
    if (!keepBrowser) await browser.stop();
    if (btState == BtState.connected || btState == BtState.connecting || btState == BtState.waiting) {
      btState = BtState.idle;
    }
    notifyListeners();
  }

  // ================================================================ envío

  void onVolume(bool up) => send(forward: invert ? !up : up);

  Future<void> send({required bool forward}) async {
    (forward ? pulseNext : pulsePrev).value++;
    final cmd = Cmd.of(forward: forward, arrows: arrows);
    switch (mode) {
      case Mode.bluetooth:
        if (isAndroid) {
          if (await NativeBridge.hidSend(hidUsageFor(cmd))) return;
          if (await NativeBridge.hidReconnect()) {
            _nudge('Reconectando con la PC…');
          } else {
            _nudge('Conecta tu PC primero');
          }
        } else {
          if (await NativeBridge.bleSend(cmd)) return;
          _nudge('Abre Slide Remote en la PC para conectar');
        }
      case Mode.wifi:
        if (wifi.target == null) return _nudge('Elige tu PC');
        final sent = wifi.send(cmd);
        if (!sent) {
          _nudge('No se pudo enviar');
        } else if (!wifi.online) {
          _nudge('La PC no responde. ¿Está abierta Slide Remote?');
        }
      case Mode.browser:
        if (!browser.hasPdf) return _nudge('Primero elige un PDF');
        if (!browser.go(forward ? 1 : -1)) _nudge('Abre la dirección en el navegador de la PC');
    }
  }

  void _nudge(String msg) {
    if (!_nudges.isClosed) _nudges.add(msg);
  }

  // ================================================================ ajustes

  Future<void> setInvert(bool v) async {
    invert = v;
    await _prefs.setBool('invert', v);
    notifyListeners();
  }

  Future<void> setArrows(bool v) async {
    arrows = v;
    await _prefs.setBool('arrows', v);
    notifyListeners();
  }

  // ================================================================ Bluetooth

  Future<void> _startBluetooth() async {
    if (isIOS) {
      btState = BtState.waiting;
      notifyListeners();
      await NativeBridge.bleStart();
      return;
    }
    if (!await NativeBridge.hidSupported()) {
      btState = BtState.unavailable;
      btMessage = 'Este teléfono no soporta el modo teclado Bluetooth';
      notifyListeners();
      return;
    }
    if (!await NativeBridge.requestBtPermissions()) {
      btState = BtState.noPermission;
      notifyListeners();
      return;
    }
    if (!await NativeBridge.btEnabled()) {
      btState = BtState.off;
      notifyListeners();
      return;
    }
    await refreshBonded();
    await NativeBridge.hidStart(_btAuto ? selectedAddress : null);
  }

  Future<void> retryBluetooth() => _startBluetooth();

  Future<void> refreshBonded() async {
    bonded = await NativeBridge.hidBonded();
    if (selectedAddress == null || bonded.every((d) => d.address != selectedAddress)) {
      selectedAddress = bonded.isNotEmpty ? bonded.first.address : null;
    }
    notifyListeners();
  }

  void selectDevice(String? address) {
    selectedAddress = address;
    notifyListeners();
  }

  Future<void> connectSelected() async {
    final addr = selectedAddress;
    if (addr == null) return _nudge('Primero empareja tu PC');
    await NativeBridge.hidConnect(addr);
  }

  Future<void> disconnectBluetooth() async {
    _btAuto = false;
    await _prefs.setBool('bt_auto', false);
    await NativeBridge.hidDisconnect();
  }

  Future<void> pairNew() => NativeBridge.makeDiscoverable();

  void _onNative(Map<String, Object?> e) {
    switch (e['type']) {
      case 'volume':
        if (_foreground) onVolume(e['dir'] == 'up');
      case 'hid':
        _onHid(e);
      case 'ble':
        _onBle(e);
      case 'discoverable':
        if (e['ok'] == true) _nudge('Visible por 2 min: empareja desde la configuración Bluetooth de la PC');
    }
  }

  void _onHid(Map<String, Object?> e) {
    final name = e['name'] as String?;
    final address = e['address'] as String?;
    btMessage = e['message'] as String?;
    btDeviceName = name;
    btState = switch (e['state']) {
      'UNAVAILABLE' => BtState.unavailable,
      'OFF' => BtState.off,
      'CONNECTING' => BtState.connecting,
      'CONNECTED' => BtState.connected,
      _ => BtState.idle,
    };
    if (btState == BtState.connected && address != null) {
      selectedAddress = address;
      _btAuto = true;
      _prefs.setString('bt_addr', address);
      _prefs.setBool('bt_auto', true);
      if (bonded.every((d) => d.address != address)) refreshBonded();
    }
    notifyListeners();
  }

  void _onBle(Map<String, Object?> e) {
    btMessage = null;
    btState = switch (e['state']) {
      'connected' => BtState.connected,
      'advertising' => BtState.waiting,
      'poweredOff' => BtState.off,
      'unauthorized' => BtState.noPermission,
      'unsupported' => BtState.unavailable,
      'stopped' => BtState.idle,
      _ => btState,
    };
    notifyListeners();
  }

  // ================================================================ WiFi

  Future<void> selectPc(PcEntry pc) async {
    await wifi.select(pc);
    await _prefs.setString('wifi_name', pc.name);
    await _prefs.setString('wifi_host', pc.host);
    await _prefs.setInt('wifi_port', pc.port);
    await _prefs.setBool('wifi_manual', pc.manual);
  }

  // ================================================================ Navegador

  Future<File> _pdfStore() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/presentacion.pdf');
  }

  Future<void> _restorePdf() async {
    final name = _prefs.getString('pdf_name');
    if (name == null) return;
    final f = await _pdfStore();
    if (await f.exists()) await browser.setPdf(f, name);
  }

  Future<void> pickPdf() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']);
    if (picked == null) return;
    final dest = await _pdfStore();
    final path = picked.path;
    if (path != null && await File(path).exists()) {
      await File(path).copy(dest.path);
    } else {
      await dest.writeAsBytes(await picked.readAsBytes(), flush: true);
    }
    await _prefs.setString('pdf_name', picked.name);
    await browser.setPdf(dest, picked.name);
  }

  // ================================================================ estado visible

  ConnView get status {
    switch (mode) {
      case Mode.bluetooth:
        return switch (btState) {
          BtState.connected => ConnView(Conn.on, 'Conectado', isIOS ? 'App de escritorio' : btDeviceName),
          BtState.connecting => ConnView(Conn.busy, 'Conectando…', btDeviceName),
          BtState.waiting => const ConnView(Conn.busy, 'Esperando PC', 'Abre Slide Remote en la PC'),
          BtState.off => const ConnView(Conn.error, 'Bluetooth apagado', 'Actívalo en el teléfono'),
          BtState.noPermission => const ConnView(Conn.error, 'Sin permiso', 'Permite el acceso a Bluetooth'),
          BtState.unavailable => ConnView(Conn.error, 'No disponible', btMessage),
          BtState.idle => ConnView(Conn.off, 'Desconectado', btMessage ?? 'Elige tu PC y conecta'),
          BtState.unknown => const ConnView(Conn.off, 'Preparando…'),
        };
      case Mode.wifi:
        final pc = wifi.target;
        if (pc == null) return const ConnView(Conn.off, 'Sin PC', 'Elige tu PC en la lista');
        if (wifi.online) {
          return ConnView(Conn.on, 'Conectado', '${pc.name}${wifi.latencyMs != null ? ' · ${wifi.latencyMs} ms' : ''}');
        }
        return ConnView(Conn.busy, 'Buscando…', pc.name);
      case Mode.browser:
        if (browser.error != null) return ConnView(Conn.error, 'Error', browser.error);
        if (!browser.hasPdf) return const ConnView(Conn.off, 'Sin PDF', 'Elige tu presentación');
        if (browser.viewers > 0) {
          return ConnView(Conn.on, 'Proyectando',
              browser.total > 0 ? 'Diapositiva ${browser.page} de ${browser.total}' : 'Cargando PDF…');
        }
        return const ConnView(Conn.busy, 'Esperando', 'Abre la dirección en la PC');
    }
  }

  bool get canSend => status.conn == Conn.on;
}
