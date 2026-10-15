import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../common/protocol.dart';

@immutable
class PcEntry {
  const PcEntry({required this.name, required this.host, required this.port, this.manual = false});
  final String name;
  final String host;
  final int port;
  final bool manual;

  String get key => '$host:$port';
}

/// Modo WiFi del teléfono: encuentra las PCs con la app de escritorio (Bonjour/mDNS)
/// y les manda los comandos por UDP.
class WifiClient extends ChangeNotifier {
  final Map<String, PcEntry> _found = {}; // por nombre del servicio
  List<PcEntry> get found => _found.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  PcEntry? target;
  bool online = false;
  int? latencyMs;
  bool searching = false;
  String? error;

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  RawDatagramSocket? _socket;
  Timer? _pingTimer;
  DateTime? _pingSentAt;
  DateTime? _lastPong;
  InternetAddress? _targetAddress;
  bool _running = false;

  /// Se llama cuando aparece de nuevo la última PC usada (para reconectar sola).
  String? preferredName;

  /// La PC anunció sus notas: (versión, puerto HTTP). Versión 0 = la PC no tiene notas.
  void Function(int version, int port)? onNotes;

  /// Dirección de la PC elegida (para pedirle las notas).
  InternetAddress? get targetAddress => _targetAddress;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    error = null;
    await _openSocket();
    await _startDiscovery();
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    _tick();
    notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    await _discoverySub?.cancel();
    _discoverySub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    _socket?.close();
    _socket = null;
    searching = false;
    online = false;
    notifyListeners();
  }

  Future<void> select(PcEntry? pc) async {
    target = pc;
    online = false;
    latencyMs = null;
    _lastPong = null;
    _targetAddress = null;
    if (pc != null) {
      preferredName = pc.name;
      _targetAddress = await _resolve(pc.host);
      _ping();
    }
    notifyListeners();
  }

  /// true si el datagrama se pudo enviar (no garantiza que llegue: es UDP).
  bool send(int cmd) {
    final s = _socket;
    final addr = _targetAddress;
    final pc = target;
    if (s == null || addr == null || pc == null) return false;
    return s.send(ascii.encode(Udp.command(cmd)), addr, pc.port) > 0;
  }

  // ------------------------------------------------------------------ interno

  Future<void> _openSocket() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        final msg = ascii.decode(d.data, allowInvalid: true).trim();
        if (_targetAddress == null || d.address.address != _targetAddress!.address) return;
        if (msg.startsWith('${Udp.prefix} NOTES ')) {
          final p = msg.split(' ');
          final v = p.length > 2 ? int.tryParse(p[2]) : null;
          final port = p.length > 3 ? int.tryParse(p[3]) : null;
          if (v != null && port != null) onNotes?.call(v, port);
          return;
        }
        if (!msg.startsWith('${Udp.prefix} PONG')) return;
        final sent = _pingSentAt;
        latencyMs = sent == null ? null : DateTime.now().difference(sent).inMilliseconds;
        _lastPong = DateTime.now();
        if (!online) {
          online = true;
          notifyListeners();
        }
      });
      _socket = s;
    } catch (e) {
      error = 'No se pudo abrir el socket UDP: $e';
    }
  }

  Future<void> _startDiscovery() async {
    try {
      final d = BonsoirDiscovery(type: kServiceType);
      await d.initialize();
      _discoverySub = d.eventStream?.listen((event) => _onDiscovery(d, event));
      await d.start();
      _discovery = d;
      searching = true;
    } catch (e) {
      searching = false;
      debugPrint('Bonsoir: $e');
    }
  }

  void _onDiscovery(BonsoirDiscovery d, BonsoirDiscoveryEvent event) {
    // `service` se lee de forma dinámica: su nulabilidad cambió entre versiones de bonsoir.
    // Los eventos de inicio/fin de búsqueda no tienen `service`.
    BonsoirService? service;
    try {
      service = (event as dynamic).service as BonsoirService?;
    } catch (_) {
      return;
    }
    if (service == null) return;
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      service.resolve(d.serviceResolver);
    } else if (event is BonsoirDiscoveryServiceResolvedEvent ||
        event is BonsoirDiscoveryServiceUpdatedEvent) {
      final host = _pickAddress(service);
      if (host == null) return;
      final pc = PcEntry(name: service.name, host: host, port: service.port);
      _found[service.name] = pc;
      // Reconectar sola a la última PC usada (aunque haya cambiado de IP)
      if (preferredName == service.name && (target == null || target!.host != host)) {
        select(pc);
      }
      notifyListeners();
    } else if (event is BonsoirDiscoveryServiceLostEvent) {
      _found.remove(service.name);
      notifyListeners();
    }
  }

  static String? _pickAddress(BonsoirService s) {
    final all = [...s.hostAddresses, if (s.hostAddress != null) s.hostAddress!];
    for (final a in all) {
      final ip = InternetAddress.tryParse(a);
      if (ip != null && ip.type == InternetAddressType.IPv4) return a;
    }
    return all.isNotEmpty ? all.first : null;
  }

  Future<InternetAddress?> _resolve(String host) async {
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return ip;
    try {
      final list = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
      return list.isNotEmpty ? list.first : null;
    } catch (_) {
      return null;
    }
  }

  void _ping() {
    final s = _socket;
    final addr = _targetAddress;
    final pc = target;
    if (s == null || addr == null || pc == null) return;
    _pingSentAt = DateTime.now();
    s.send(ascii.encode(Udp.ping), addr, pc.port);
  }

  void _tick() {
    if (!_running) return;
    _ping();
    final last = _lastPong;
    final stillOnline = last != null && DateTime.now().difference(last) < const Duration(seconds: 5);
    if (stillOnline != online) {
      online = stillOnline;
      notifyListeners();
    }
  }
}
