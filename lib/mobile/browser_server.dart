import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/protocol.dart';
import 'ink.dart';

/// Modo Navegador: el teléfono sirve una página web en la red local. La PC abre la URL en
/// cualquier navegador (sin instalar nada) y ahí se proyecta el PDF, controlado por WebSocket.
class BrowserServer extends ChangeNotifier {
  /// Idioma de la página (el de la app): 'es' o 'en'.
  String lang = 'en';

  void setLanguage(String l) {
    if (l == lang) return;
    lang = l;
    _broadcast({'t': 'lang', 'lang': l});
  }

  /// Dibujos sobre las diapositivas (vista de dibujo del teléfono).
  late final InkBoard ink = InkBoard(_broadcast);

  HttpServer? _server;
  final Set<WebSocket> _clients = {};
  final Map<String, Uint8List> _assets = {};

  File? pdfFile;
  String? pdfName;
  int page = 0;
  int total = 0;
  int port = 0;
  List<String> urls = const [];
  String? error;

  int get viewers => _clients.length;
  bool get running => _server != null;
  bool get hasPdf => pdfFile != null;

  Future<void> start() async {
    if (_server != null) return;
    error = null;
    for (var p = kHttpPort; p < kHttpPort + 10; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: false);
        port = p;
        break;
      } on SocketException {
        continue;
      }
    }
    final server = _server;
    if (server == null) {
      error = t('No se pudo abrir el servidor web', 'Could not start the web server');
      notifyListeners();
      return;
    }
    server.listen(_handle, onError: (Object e) => debugPrint('HTTP: $e'));
    await refreshUrls();
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      await c.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    notifyListeners();
  }

  /// En iOS el socket puede invalidarse al suspender la app: reiniciar al volver.
  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> refreshUrls() async {
    urls = await _localUrls(port);
    notifyListeners();
  }

  Future<void> setPdf(File file, String name) async {
    pdfFile = file;
    pdfName = name;
    page = 0;
    total = 0;
    ink.clearAll();
    _broadcast({'t': 'reload'});
    notifyListeners();
  }

  /// Avanza (+1) o retrocede (-1). false si no hay ningún navegador conectado.
  bool go(int delta) {
    if (_clients.isEmpty) return false;
    _broadcast({'t': 'go', 'd': delta});
    return true;
  }

  // ------------------------------------------------------------------ HTTP

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/ws':
          if (!WebSocketTransformer.isUpgradeRequest(req)) {
            res.statusCode = HttpStatus.badRequest;
            break;
          }
          final ws = await WebSocketTransformer.upgrade(req);
          _addClient(ws);
          return;
        case '/':
        case '/index.html':
          await _sendAsset(res, 'index.html', 'text/html; charset=utf-8');
          return;
        case '/pdf.min.mjs':
          await _sendAsset(res, 'pdf.min.mjs', 'text/javascript; charset=utf-8');
          return;
        case '/pdf.worker.min.mjs':
          await _sendAsset(res, 'pdf.worker.min.mjs', 'text/javascript; charset=utf-8');
          return;
        case '/deck.pdf':
          final f = pdfFile;
          if (f == null || !await f.exists()) {
            res.statusCode = HttpStatus.notFound;
            break;
          }
          res.headers
            ..contentType = ContentType('application', 'pdf')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..contentLength = await f.length();
          await res.addStream(f.openRead());
          break;
        default:
          res.statusCode = HttpStatus.notFound;
      }
    } catch (e) {
      debugPrint('HTTP ${req.uri.path}: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    }
    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _sendAsset(HttpResponse res, String name, String type) async {
    var bytes = _assets[name] ??= (await rootBundle.load('assets/web/$name')).buffer.asUint8List();
    if (name == 'index.html') {
      // La página toma el idioma de <html lang="…">
      bytes = Uint8List.fromList(utf8.encode(utf8.decode(bytes).replaceFirst('<html lang="es">', '<html lang="$lang">')));
    }
    res.headers
      ..set(HttpHeaders.contentTypeHeader, type)
      ..set(HttpHeaders.cacheControlHeader, name == 'index.html' ? 'no-store' : 'max-age=3600')
      ..contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  void _addClient(WebSocket ws) {
    _clients.add(ws);
    ws.pingInterval = const Duration(seconds: 5);
    ws.add(jsonEncode({'t': 'hello', 'hasPdf': hasPdf, 'name': pdfName, 'lang': lang}));
    ws.add(jsonEncode(ink.snapshot()));
    ws.listen(
      (data) {
        if (data is! String) return;
        try {
          final msg = jsonDecode(data);
          if (msg is Map && msg['t'] == 'state') {
            page = (msg['page'] as num?)?.toInt() ?? 0;
            total = (msg['total'] as num?)?.toInt() ?? 0;
            notifyListeners();
          }
        } catch (_) {}
      },
      onDone: () {
        _clients.remove(ws);
        notifyListeners();
      },
      onError: (Object _) {
        _clients.remove(ws);
        notifyListeners();
      },
      cancelOnError: true,
    );
    notifyListeners();
  }

  void _broadcast(Map<String, Object?> msg) {
    final text = jsonEncode(msg);
    for (final c in _clients.toList()) {
      try {
        c.add(text);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  /// IPs locales ordenadas: WiFi primero, luego punto de acceso, el resto al final.
  /// Se omiten las interfaces de datos móviles y VPN.
  static Future<List<String>> _localUrls(int port) async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      int rank(String n) {
        n = n.toLowerCase();
        if (n.startsWith('wlan') || n == 'en0' || n.startsWith('wl')) return 0;
        if (n.startsWith('ap') || n.startsWith('swlan') || n.startsWith('bridge')) return 1;
        if (n.startsWith('en') || n.startsWith('eth')) return 2;
        return 3;
      }

      bool skip(String n) {
        n = n.toLowerCase();
        return n.startsWith('rmnet') || n.startsWith('pdp') || n.startsWith('ccmni') ||
            n.startsWith('tun') || n.startsWith('utun') || n.startsWith('ipsec') || n.startsWith('dummy');
      }

      final list = ifaces.where((i) => !skip(i.name)).toList()
        ..sort((a, b) => rank(a.name).compareTo(rank(b.name)));
      return [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLinkLocal) 'http://${a.address}${port == 80 ? '' : ':$port'}',
      ];
    } catch (_) {
      return const [];
    }
  }
}
