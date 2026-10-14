import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../common/protocol.dart';
import 'key_injector.dart';

enum BleStatus { unknown, off, unauthorized, unsupported, searching, connecting, connected }

/// Un comando recibido, para mostrarlo en pantalla.
@immutable
class Received {
  const Received(this.cmd, this.source, this.at);
  final int cmd;
  final String source; // "WiFi" o "Bluetooth"
  final DateTime at;
}

/// App de escritorio: recibe comandos del teléfono (WiFi/UDP y Bluetooth LE) y presiona teclas.
class ReceiverController extends ChangeNotifier {
  final KeyInjector injector = KeyInjector.create();
  final String hostName = _niceHostName();

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
    injector.init();
    await _startWifi();
    await _startBle();
    // Refresca estados que dependen del tiempo (teléfono visto hace poco, permisos)
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _notify());
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _udp?.close();
    _broadcast?.stop();
    _scanSub?.cancel();
    _valueSub?.cancel();
    _connSub?.cancel();
    _bleDevice?.disconnect();
    injector.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Reintentar permisos (tras activar Accesibilidad o arreglar /dev/uinput).
  void retryInjector() {
    injector.init();
    _notify();
  }

  void _press(int cmd, String source) {
    if (!Cmd.isValid(cmd)) return;
    injector.press(cmd);
    last = Received(cmd, source, DateTime.now());
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
      wifiError = 'El puerto $kUdpPort está ocupado (¿hay otra copia abierta?): ${e.message}';
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
    switch (parts[1]) {
      case 'PING':
        s.send(ascii.encode(Udp.pong(hostName)), d.address, d.port);
        _notify();
      case 'C':
        if (parts.length >= 3) _press(int.tryParse(parts[2]) ?? 0, 'WiFi');
    }
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
      bleError = 'No se pudo buscar por Bluetooth: $e';
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
      bleError = 'No se pudo conectar: $e';
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
