import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../common/i18n.dart';
import '../common/protocol.dart';
import 'key_injector.dart';
import 'notes_host.dart';
import 'office.dart';
import 'present_host.dart';
import 'quiet_mode.dart';

enum BleStatus { unknown, off, unauthorized, unsupported, searching, connecting, connected }

/// Un comando recibido, para mostrarlo en pantalla.
@immutable
class Received {
  const Received(this.cmd, this.source, this.at, [this.slide = 0]);
  final int cmd;
  final int slide; // con Cmd.goTo
  final String source; // "WiFi" o "Bluetooth"
  final DateTime at;
}

/// App de escritorio: recibe comandos del teléfono (WiFi/UDP y Bluetooth LE) y presiona teclas.
class ReceiverController extends ChangeNotifier {
  ReceiverController() {
    notes = NotesHost(isAllowed: _isKnownPhone);
    notes.addListener(_notify);
    present = PresentHost(port: () => notes.port);
    notes.extraRoutes = present.handle;
    present.addListener(_notify);
    present.onPageChanged = _sendPageToPhone;
    present.onPhoneStart = startPresenting;
    present.lang = I18n.current.value;
    I18n.current.addListener(_langChanged);
  }

  final KeyInjector injector = KeyInjector.create();
  final String hostName = _niceHostName();

  /// Notas del .pptx que está en la PC; se mandan al teléfono por WiFi.
  late final NotesHost notes;

  /// "Proyectar en esta PC": la presentación en el navegador de la PC, controlada por el teléfono.
  late final PresentHost present;

  /// Último teléfono que habló por UDP (para avisarle al instante del cambio de página).
  InternetAddress? _phoneAddr;
  int _phonePort = 0;

  /// Teléfonos que hablaron por UDP hace poco: los únicos que pueden pedir las notas.
  final Map<String, DateTime> _phones = {};

  // ---- un solo teléfono mientras se presenta
  // Al presentar (con Zlide o con el programa original), la PC obedece solo al teléfono que
  // empezó: los demás reciben BUSY y sus comandos se ignoran. Se libera al terminar, desde esta
  // ventana, o si ese teléfono no da señales en [_ownerTimeout].
  static const _ownerTimeout = Duration(seconds: 90);

  /// `ip:<dirección>` o `ble`. null = el primero que hable lo toma.
  String? _owner;
  DateTime _ownerSeen = DateTime.fromMillisecondsSinceEpoch(0);

  /// Quien se liberó a mano: no lo vuelve a tomar enseguida (para dejar entrar a otro).
  String? _released;
  DateTime _releasedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Última fuente que habló (para dársela al empezar a presentar).
  String? _recent;
  DateTime _recentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// La presentación se abrió en su programa (PowerPoint, Keynote, Impress).
  bool nativeShow = false;
  String? nativeApp;
  String? nativeError;

  /// Presentando de alguna forma: es cuando se protege el control.
  bool get presenting => present.active || nativeShow;

  /// Quién controla la presentación, para mostrarlo ("192.168.1.20", "iPhone"), o null.
  String? get controller {
    final o = _activeOwner;
    if (o == null) return null;
    return o == 'ble' ? (bleDeviceName ?? 'iPhone') : o.substring(3);
  }

  String? get _activeOwner {
    if (!presenting || _owner == null) return null;
    // El iPhone por Bluetooth no manda pings: mientras siga conectado, sigue siendo suyo
    if (_owner == 'ble' && bleStatus == BleStatus.connected) return _owner;
    if (DateTime.now().difference(_ownerSeen) > _ownerTimeout) return null;
    return _owner;
  }

  /// ¿Se aceptan comandos de [source]? Si nadie controla todavía, lo toma.
  bool _accept(String source) {
    final now = DateTime.now();
    _recent = source;
    _recentAt = now;
    if (!presenting) return true;
    final owner = _activeOwner;
    if (owner == null) {
      if (source == _released && now.difference(_releasedAt) < const Duration(seconds: 10)) return false;
      _owner = source;
      _ownerSeen = now;
      _notify();
      return true;
    }
    if (owner != source) return false;
    _ownerSeen = now;
    return true;
  }

  /// "Liberar": el próximo teléfono que hable toma el control.
  void releaseControl() {
    _released = _owner;
    _releasedAt = DateTime.now();
    _owner = null;
    _notify();
  }

  void _claimForRecent() {
    final recent = DateTime.now().difference(_recentAt) < const Duration(seconds: 20) ? _recent : null;
    _owner = recent;
    _ownerSeen = DateTime.now();
  }

  // ---- WiFi
  RawDatagramSocket? _udp;
  BonsoirBroadcast? _broadcast;
  bool wifiListening = false;
  bool wifiAnnounced = false;
  String? wifiError;
  List<String> localIps = const [];
  String? wifiPeer; // IP del último teléfono
  DateTime? _wifiSeen;
  bool get wifiPhoneConnected =>
      _wifiSeen != null && DateTime.now().difference(_wifiSeen!) < const Duration(seconds: 6);

  // ---- Bluetooth LE (iPhone)
  BleStatus bleStatus = BleStatus.unknown;
  String? bleDeviceName;
  String? bleError;
  BleDevice? _bleDevice;
  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<dynamic>? _valueSub;
  StreamSubscription<bool>? _connSub;
  bool _scanning = false;
  bool _connecting = false;
  int _lastSeq = -1;
  DateTime _lastSeqAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- actividad
  Received? last;
  int count = 0;

  Timer? _tick;
  bool _disposed = false;

  Future<void> init() async {
    // Si la app se cerró de golpe presentando, los avisos quedaron en silencio: devolverlos
    await QuietMode.restore();
    injector.init();
    await notes.start();
    await _startWifi();
    await _startBle();
    // Refresca estados que dependen del tiempo (teléfono visto hace poco, permisos)
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      notes.checkModified();
      present.checkSourceModified();
      _notify();
    });
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    QuietMode.restore();
    _tick?.cancel();
    _udp?.close();
    _broadcast?.stop();
    _scanSub?.cancel();
    _valueSub?.cancel();
    _connSub?.cancel();
    _bleDevice?.disconnect();
    notes.removeListener(_notify);
    notes.dispose();
    present.removeListener(_notify);
    I18n.current.removeListener(_langChanged);
    present.dispose();
    injector.dispose();
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    _syncQuiet();
    notifyListeners();
  }

  /// Avisos de la PC en silencio mientras se presenta (ver [QuietMode]).
  bool _quietWanted = false;
  void _syncQuiet() {
    if (presenting == _quietWanted) return;
    _quietWanted = presenting;
    (presenting ? QuietMode.enable() : QuietMode.restore()).then((_) => _notify());
  }

  /// Reintentar permisos (tras activar Accesibilidad o arreglar /dev/uinput).
  void retryInjector() {
    injector.init();
    _notify();
  }

  void _press(int cmd, String source) {
    if (!Cmd.isValid(cmd)) return;
    if (!_accept(source == 'Bluetooth' ? 'ble' : 'ip:$wifiPeer')) return;
    if (present.active) {
      // Proyectando desde la app: cambiar la página directamente (sin simular teclas)
      present.go(Cmd.isForward(cmd) ? 1 : -1);
    } else {
      injector.press(cmd);
    }
    last = Received(cmd, source, DateTime.now());
    count++;
    _notify();
  }

  /// "Ir a la diapositiva [n]": proyectando, [n] es la página; si no, se escribe n y Enter.
  void _goTo(int n, String source) {
    if (n < 1) return;
    if (!_accept(source == 'Bluetooth' ? 'ble' : 'ip:$wifiPeer')) return;
    if (present.active) {
      present.goTo(n);
    } else {
      injector.typeNumber(n);
    }
    last = Received(Cmd.goTo, source, DateTime.now(), n);
    count++;
    _notify();
  }

  // ================================================================ WiFi

  Future<void> _startWifi() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kUdpPort);
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d != null) _onDatagram(s, d);
      });
      _udp = s;
      wifiListening = true;
    } on SocketException catch (e) {
      wifiError = t('El puerto $kUdpPort está ocupado (¿hay otra copia abierta?): ${e.message}',
          'Port $kUdpPort is in use (is another copy open?): ${e.message}');
      _notify();
      return;
    }
    localIps = await _localIps();
    try {
      final b = BonsoirBroadcast(
        service: BonsoirService(name: hostName, type: kServiceType, port: kUdpPort),
      );
      await b.initialize();
      await b.start();
      _broadcast = b;
      wifiAnnounced = true;
    } catch (e) {
      // Sin mDNS el teléfono aún puede conectarse escribiendo la IP
      debugPrint('Bonsoir: $e');
    }
    _notify();
  }

  void _onDatagram(RawDatagramSocket s, Datagram d) {
    final msg = ascii.decode(d.data, allowInvalid: true).trim();
    final parts = msg.split(' ');
    if (parts.isEmpty || parts.first != Udp.prefix || parts.length < 2) return;
    wifiPeer = d.address.address;
    _wifiSeen = DateTime.now();
    _phones[d.address.address] = _wifiSeen!;
    final source = 'ip:${d.address.address}';
    switch (parts[1]) {
      case 'PING':
        s.send(ascii.encode(Udp.pong(hostName)), d.address, d.port);
        if (!_accept(source)) {
          // Otro teléfono está presentando: este solo sabe que la PC está ocupada
          s.send(ascii.encode(Udp.busy), d.address, d.port);
          _notify();
          return;
        }
        if (notes.port > 0) s.send(ascii.encode(Udp.notes(notes.version, notes.port)), d.address, d.port);
        s.send(ascii.encode(present.active ? Udp.page(present.page, present.total, present.version, present.fxStep, present.fxSteps) : Udp.page(0, 0)), d.address, d.port);
        s.send(ascii.encode(Udp.deck(notes.path != null, deckMode)), d.address, d.port);
        _phoneAddr = d.address;
        _phonePort = d.port;
        _notify();
      case 'C':
        if (parts.length >= 3) _press(int.tryParse(parts[2]) ?? 0, 'WiFi');
      case 'G':
        if (parts.length >= 3) _goTo(int.tryParse(parts[2]) ?? 0, 'WiFi');
      case 'START':
        if (!_accept(source) || notes.path == null) return;
        _recent = source;
        _recentAt = DateTime.now();
        if (parts.length >= 3 && parts[2] == '1') {
          startNative();
        } else {
          startPresenting();
        }
      case 'STOP':
        if (presenting && _accept(source)) stopPresenting();
    }
  }

  int get deckMode => present.active ? DeckMode.zlide : (nativeShow ? DeckMode.native : DeckMode.none);

  void _sendPageToPhone() {
    final a = _phoneAddr;
    if (a == null || _udp == null) return;
    _udp!.send(ascii.encode(Udp.page(present.page, present.total, present.version, present.fxStep, present.fxSteps)), a, _phonePort);
  }

  void _langChanged() => present.setLanguage(I18n.current.value);

  /// Proyectar la presentación elegida en "Notas en el teléfono".
  Future<void> startPresenting() async {
    final p = notes.path;
    if (p == null) return;
    nativeShow = false;
    if (!presenting) _claimForRecent();
    await present.start(p, notes.name ?? 'presentación');
  }

  /// Abrirla en su programa (PowerPoint, Keynote, Impress): animaciones, videos y enlaces
  /// funcionan como siempre y el teléfono la controla con teclas.
  Future<void> startNative() async {
    final p = notes.path;
    if (p == null) return;
    nativeError = null;
    if (present.active) present.stop();
    try {
      if (!presenting) _claimForRecent();
      nativeApp = await Office.openSlideshow(File(p));
      nativeShow = true;
    } on FormatException catch (e) {
      nativeError = e.message;
    } catch (e) {
      nativeError = '${t('No se pudo abrir la presentación', 'Could not open the presentation')}: $e';
    }
    _notify();
  }

  void stopPresenting() {
    present.stop();
    nativeShow = false;
    _owner = null;
    _notify();
  }

  bool _isKnownPhone(InternetAddress a) {
    final seen = _phones[a.address];
    if (seen == null || DateTime.now().difference(seen) >= const Duration(minutes: 2)) return false;
    // Presentando, la presentación y las notas son solo del teléfono que la controla
    final owner = _activeOwner;
    return owner == null || owner == 'ip:${a.address}';
  }

  static Future<List<String>> _localIps() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      return [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLinkLocal) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ================================================================ Bluetooth LE

  Future<void> _startBle() async {
    try {
      UniversalBle.availabilityStream.listen(_onAvailability);
      _onAvailability(await UniversalBle.getBluetoothAvailabilityState());
    } catch (e) {
      bleStatus = BleStatus.unsupported;
      bleError = '$e';
      _notify();
    }
  }

  void _onAvailability(AvailabilityState s) {
    switch (s) {
      case AvailabilityState.poweredOn:
        if (bleStatus == BleStatus.off || bleStatus == BleStatus.unknown ||
            bleStatus == BleStatus.unauthorized) {
          bleStatus = BleStatus.searching;
        }
        _scan();
      case AvailabilityState.poweredOff:
        bleStatus = BleStatus.off;
        _resetBle();
      case AvailabilityState.unauthorized:
        bleStatus = BleStatus.unauthorized;
      case AvailabilityState.unsupported:
        bleStatus = BleStatus.unsupported;
      default:
        break;
    }
    _notify();
  }

  Future<void> _scan() async {
    if (_scanning || _connecting || _bleDevice != null) return;
    _scanning = true;
    bleStatus = BleStatus.searching;
    _notify();
    _scanSub ??= UniversalBle.scanStream.listen(_onScanResult);
    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [kBleService]));
    } catch (e) {
      _scanning = false;
      bleError = '${t('No se pudo buscar por Bluetooth', 'Could not scan over Bluetooth')}: $e';
      _notify();
      _retryLater();
    }
  }

  Future<void> _onScanResult(BleDevice d) async {
    if (_connecting || _bleDevice != null) return;
    // Por si la plataforma ignora el filtro: aceptar solo si anuncia nuestro servicio
    final services = d.services.map((s) => s.toLowerCase()).toList();
    if (services.isNotEmpty && !services.contains(kBleService)) return;
    _connecting = true;
    bleStatus = BleStatus.connecting;
    bleDeviceName = (d.name == null || d.name!.isEmpty) ? 'iPhone' : d.name;
    _notify();
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    _scanning = false;
    try {
      await d.connect(timeout: const Duration(seconds: 12));
      final ch = await d.getCharacteristic(kBleCommandChar, service: kBleService);
      await _valueSub?.cancel();
      _valueSub = ch.onValueReceived.listen((v) => _onBleValue(Uint8List.fromList(v)));
      await ch.notifications.subscribe();
      await _connSub?.cancel();
      _connSub = d.connectionStream.listen((connected) {
        if (!connected) _onBleLost();
      });
      _bleDevice = d;
      bleStatus = BleStatus.connected;
      bleError = null;
    } catch (e) {
      bleError = '${t('No se pudo conectar', 'Could not connect')}: $e';
      try {
        await d.disconnect();
      } catch (_) {}
      _bleDevice = null;
      bleStatus = BleStatus.searching;
      _retryLater();
    } finally {
      _connecting = false;
      _notify();
    }
  }

  void _onBleValue(Uint8List v) {
    if (v.length < 2) return;
    final seq = v[0], cmd = v[1];
    if (cmd == 0) return; // lectura inicial
    // Ignorar duplicados del mismo paquete
    final now = DateTime.now();
    if (seq == _lastSeq && now.difference(_lastSeqAt) < const Duration(seconds: 2)) return;
    _lastSeq = seq;
    _lastSeqAt = now;
    if (cmd == Cmd.goTo) {
      if (v.length >= 4) _goTo((v[2] << 8) | v[3], 'Bluetooth');
      return;
    }
    _press(cmd, 'Bluetooth');
  }

  void _onBleLost() {
    _resetBle();
    bleStatus = BleStatus.searching;
    _notify();
    _retryLater(const Duration(milliseconds: 800));
  }

  void _resetBle() {
    _valueSub?.cancel();
    _valueSub = null;
    _connSub?.cancel();
    _connSub = null;
    _bleDevice = null;
  }

  void _retryLater([Duration delay = const Duration(seconds: 3)]) {
    Future<void>.delayed(delay, () {
      if (!_disposed && bleStatus != BleStatus.off) _scan();
    });
  }

  static String _niceHostName() {
    var h = Platform.localHostname;
    if (h.endsWith('.local')) h = h.substring(0, h.length - 6);
    return h.isEmpty ? 'Mi PC' : h;
  }
}
