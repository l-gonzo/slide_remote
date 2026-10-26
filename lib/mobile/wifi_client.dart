import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../common/i18n.dart';
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

/// Modo WiFi del teléfono: encuentra las PCs con la app de escritorio (Bonjour/mDNS y, si la
/// red no lo deja pasar, preguntando por broadcast) y les manda los comandos por UDP.
class WifiClient extends ChangeNotifier {
  final Map<String, PcEntry> _found = {}; // por nombre del servicio
  List<PcEntry> get found => _found.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  PcEntry? target;
  bool online = false;

  /// La PC está presentando con otro teléfono: no acepta los comandos de este.
  bool get busy => _busyAt != null && DateTime.now().difference(_busyAt!) < const Duration(seconds: 5);
  DateTime? _busyAt;

  /// La PC tiene una presentación elegida, y cómo la presenta ([DeckMode]).
  bool pcHasDeck = false;
  int pcDeckMode = 0;
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

  /// La PC proyecta con Zlide: (página, total). 0 0 = no está proyectando.
  /// [version] identifica el PDF que proyecta la PC (0 si la app de escritorio no lo manda).
  /// [step] de [steps]: animación en la que va la diapositiva (steps -1: no se sabe).
  void Function(int page, int total, int version, int step, int steps)? onPage;

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
    _busyAt = null;
    pcHasDeck = false;
    pcDeckMode = 0;
    if (pc != null) {
      preferredName = pc.name;
      _targetAddress = await _resolve(pc.host);
      _ping();
    }
    notifyListeners();
  }

  /// true si el datagrama se pudo enviar (no garantiza que llegue: es UDP).
  bool send(int cmd) => _sendRaw(Udp.command(cmd));

  /// Pedir a la PC que empiece a presentar (o que termine).
  bool sendStart({required bool native}) => _sendRaw(Udp.start(native: native));
  bool sendStop() => _sendRaw(Udp.stop);

  /// Ir a la diapositiva [n] (ver [Udp.goTo]).
  bool sendGoTo(int n) => _sendRaw(Udp.goTo(n));

  bool _sendRaw(String msg) {
    final s = _socket;
    final addr = _targetAddress;
    final pc = target;
    if (s == null || addr == null || pc == null) return false;
    return s.send(ascii.encode(msg), addr, pc.port) > 0;
  }

  // ------------------------------------------------------------------ interno

  Future<void> _openSocket() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)..broadcastEnabled = true;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        final msg = ascii.decode(d.data, allowInvalid: true).trim();
        if (msg.startsWith('${Udp.prefix} HERE ')) return _onHere(msg.substring(Udp.prefix.length + 6), d);
        if (_targetAddress == null || d.address.address != _targetAddress!.address) return;
        if (msg.startsWith('${Udp.prefix} PAGE ')) {
          final p = msg.split(' ');
          final page = p.length > 2 ? int.tryParse(p[2]) : null;
          final total = p.length > 3 ? int.tryParse(p[3]) : null;
          final version = p.length > 4 ? int.tryParse(p[4]) ?? 0 : 0;
          final step = p.length > 5 ? int.tryParse(p[5]) ?? 0 : 0;
          final steps = p.length > 6 ? int.tryParse(p[6]) ?? -1 : -1; // versión anterior: no lo manda
          if (page != null && total != null) onPage?.call(page, total, version, step, steps);
          return;
        }
        if (msg == Udp.busy) {
          final was = busy;
          _busyAt = DateTime.now();
          if (!was) notifyListeners();
          return;
        }
        if (msg.startsWith('${Udp.prefix} DECK ')) {
          final p = msg.split(' ');
          final has = p.length > 2 && p[2] == '1';
          final mode = p.length > 3 ? int.tryParse(p[3]) ?? 0 : 0;
          _busyAt = null;
          if (has != pcHasDeck || mode != pcDeckMode) {
            pcHasDeck = has;
            pcDeckMode = mode;
            notifyListeners();
          }
          return;
        }
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
      error = '${t('No se pudo abrir el socket UDP', 'Could not open the UDP socket')}: $e';
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

  /// Una PC respondió a la búsqueda por broadcast.
  void _onHere(String name, Datagram d) {
    final host = d.address.address;
    if (name.isEmpty || _found[name]?.host == host) return;
    // Si mDNS ya la encontró con otra dirección, se queda esa
    if (_found.containsKey(name) && !_foundByFind.contains(name)) return;
    _foundByFind.add(name);
    final pc = PcEntry(name: name, host: host, port: d.port);
    _found[name] = pc;
    if (preferredName == name && (target == null || target!.host != host)) select(pc);
    notifyListeners();
  }

  final Set<String> _foundByFind = {};
  int _ticks = 0;

  /// Preguntar a toda la red quién tiene la app de escritorio: a la dirección de broadcast
  /// general y a la de la subred de cada interfaz (algunas redes solo dejan pasar esa).
  Future<void> _find() async {
    final s = _socket;
    if (s == null) return;
    final targets = {'255.255.255.255'};
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.isLinkLocal) continue;
          final b = a.rawAddress;
          targets.add('${b[0]}.${b[1]}.${b[2]}.255'); // la máscara no se sabe: la más común
        }
      }
    } catch (_) {}
    for (final t in targets) {
      try {
        s.send(ascii.encode(Udp.find), InternetAddress(t), kUdpPort);
      } catch (_) {}
    }
  }

  void _tick() {
    if (!_running) return;
    // Mientras no haya PC conectada, buscar también por broadcast (cada 4 s)
    if (!online && _ticks++ % 2 == 0) _find();
    _ping();
    final last = _lastPong;
    final stillOnline = last != null && DateTime.now().difference(last) < const Duration(seconds: 5);
    if (stillOnline != online) {
      online = stillOnline;
      notifyListeners();
    } else if (_busyAt != null && !busy) {
      _busyAt = null; // la PC se liberó
      notifyListeners();
    }
  }
}
