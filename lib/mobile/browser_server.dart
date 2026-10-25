import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/deck_media.dart';
import '../common/i18n.dart';
import '../common/link_view.dart';
import '../common/protocol.dart';
import '../common/web_page.dart';
import 'ink.dart';

/// Modo Navegador: el teléfono sirve una página web en la red local. La PC abre la URL en
/// cualquier navegador (sin instalar nada) y ahí se proyecta el PDF, controlado por WebSocket.
/// Si la conversión dejó también un SVG (LibreOffice en Android), el navegador lo muestra
/// encima del PDF con sus animaciones y transiciones; entonces él da los pasos y avisa en qué
/// diapositiva quedó (`{t:'at'}`).
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
  final Set<WebSocket> _animClients = {}; // ya muestran deck.svg (ellos deciden la diapositiva)
  final Map<String, Uint8List> _assets = {};

  File? pdfFile;
  String? pdfName;
  File? svgFile; // con animaciones y transiciones (null: solo PDF)

  /// Videos y audios del archivo original (se ponen encima del PDF en el navegador).
  DeckMediaSet _media = DeckMediaSet.empty;

  /// Enlaces de cada página (los informa el navegador) y videos de la página actual.
  final Map<int, List<String>> links = {};
  int mediaCount = 0;
  bool mediaPlaying = false;
  List<bool> mediaItems = const []; // cuál suena, de cada video de la página

  /// Enlace abierto en el navegador (panel encima de la presentación), tal como lo informa la
  /// página: `{url, kind, title, canBack, links, video}`. null si no hay.
  Map<String, Object?>? linkState;
  bool get linkOpen => linkState != null;
  int _mediaPage = 0;

  /// Página actual (empieza en 1). La decide el TELÉFONO y todos los navegadores conectados la
  /// siguen: así varias pantallas (y la app) muestran siempre la misma diapositiva.
  int page = 0;

  /// En qué animación va la página [fxPage]: [fxStep] de [fxSteps] (-1: no se sabe; la informa
  /// el navegador con animaciones).
  int fxPage = 0, fxStep = 0, fxSteps = -1;

  /// Páginas del PDF (lo informa el primer navegador que lo abre, o la vista de dibujo).
  int total = 0;
  int port = 0;
  List<String> urls = const [];
  String? error;

  int get viewers => _clients.length;
  bool get running => _server != null;
  bool get hasPdf => pdfFile != null;
  bool get hasAnim => svgFile != null;

  String _build = ''; // huella de la página (ver web_page.dart)

  Future<void> start() async {
    if (_server != null) return;
    error = null;
    _build = await webPageBuild();
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

  Future<void> setPdf(File file, String name, {File? svg, DeckMediaSet media = DeckMediaSet.empty}) async {
    pdfFile = file;
    pdfName = name;
    svgFile = svg;
    _animClients.clear();
    fxSteps = -1;
    page = 1;
    total = 0;
    _media = media;
    links.clear();
    mediaCount = 0;
    mediaItems = const [];
    mediaPlaying = false;
    ink.clearAll();
    _broadcast({'t': 'reload', 'anim': hasAnim});
    notifyListeners();
  }

  /// Avanza (+1) o retrocede (-1). Cambia la página aunque no haya navegadores (la vista de
  /// dibujo la usa); devuelve false si no hay ninguno conectado. Con animaciones el paso lo da
  /// el navegador (la siguiente animación o diapositiva) y la página llega después.
  bool go(int delta) {
    if (linkOpen) {
      closeLink(); // con un enlace abierto, "siguiente" o "anterior" primero lo cierra
      return true;
    }
    if (hasAnim && _animClients.isNotEmpty) {
      _broadcast({'t': 'step', 'd': delta.sign}, only: _animClients);
      return true;
    }
    goTo((page < 1 ? 1 : page) + delta);
    return _clients.isNotEmpty;
  }

  /// Ir a una página y mandarla a TODOS los navegadores.
  void goTo(int p) {
    if (!hasPdf) return;
    final n = total > 0 ? p.clamp(1, total) : (p < 1 ? 1 : p);
    if (n == page) {
      _broadcast({'t': 'page', 'page': page}); // por si alguno se había desfasado
      return;
    }
    page = n;
    _broadcast({'t': 'page', 'page': page});
    notifyListeners();
  }

  /// Videos del archivo, cuando se terminan de extraer (después de [setPdf]).
  void setMedia(DeckMediaSet media) {
    _media = media;
    if (total > 0) _broadcast(_mediaMessage());
  }

  Map<String, Object?> _mediaMessage() => _media.message(total, (i) => '/media/$i');

  /// Enlaces de la página [p], si el navegador ya los informó.
  List<String> linksOf(int p) => links[p] ?? const [];

  /// Videos de la página actual (los informa el navegador).
  int get pageMedia => _mediaPage == page ? mediaCount : 0;

  /// Abrir un enlace en el navegador de la PC, sin salir de la presentación: en un panel encima
  /// de ella o, si el sitio no lo permite, en una ventana aparte. Se cierra con [closeLink].
  void openLink(String url) {
    final target = linkTarget(url);
    _broadcast({'t': 'open', 'url': target.url, 'kind': target.kind, 'orig': url});
  }

  void closeLink() => _broadcast({'t': 'closeLink'});

  /// Manejar el enlace abierto: `{op:'scroll', dy}`, `{op:'follow', i}`, `{op:'back'}`, video…
  void linkCtl(Map<String, Object?> op) => _broadcast({...op, 't': 'linkCtl'});

  /// Reproducir o pausar un video de la diapositiva ('toggle', 'play', 'pause', 'restart');
  /// [index]: cuál (sin él, el que suena o el primero).
  void mediaCtl(String op, {int? index}) => _broadcast({'t': 'mediaCtl', 'op': op, 'i': index});

  /// Número de páginas si aún no se sabe (lo calcula la vista de dibujo del teléfono).
  void setTotalIfUnknown(int n) {
    if (total > 0 || n <= 0) return;
    total = n;
    if (page > total) goTo(total);
    notifyListeners();
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
        case '/link':
          // Páginas de los enlaces, servidas para mostrarlas en el panel (ver link_view.dart)
          await serveLinkProxy(req);
          return;
        case final p when p.startsWith('/media/'):
          final i = int.tryParse(p.substring(7)) ?? -1;
          if (i < 0 || i >= _media.items.length) {
            res.statusCode = HttpStatus.notFound;
            break;
          }
          final m = _media.items[i];
          await serveFileWithRange(req, File(m.file), m.mime);
          return;
        case '/deck.svg':
          final f = svgFile;
          if (f == null || !await f.exists()) {
            res.statusCode = HttpStatus.notFound;
            break;
          }
          res.headers
            ..contentType = ContentType('image', 'svg+xml', charset: 'utf-8')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..contentLength = await f.length();
          await res.addStream(f.openRead());
          break;
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
      bytes = Uint8List.fromList(utf8.encode(
          utf8.decode(bytes).replaceFirst('<html lang="es">', '<html lang="$lang" data-build="${await webPageBuild()}">')));
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
    ws.add(jsonEncode({
      't': 'hello', 'hasPdf': hasPdf, 'anim': hasAnim, 'name': pdfName, 'lang': lang, 'page': page < 1 ? 1 : page,
      'build': _build, // una pestaña con la página anterior se recarga sola
    }));
    ws.add(jsonEncode(ink.snapshot()));
    if (total > 0 && !_media.isEmpty) ws.add(jsonEncode(_mediaMessage()));
    ws.listen(
      (data) {
        if (data is! String) return;
        try {
          final msg = jsonDecode(data);
          if (msg is! Map) return;
          switch (msg['t']) {
            case 'state':
              // El navegador cargó el PDF: de él sale el número de páginas
              final n = (msg['total'] as num?)?.toInt() ?? 0;
              if (n > 0 && n != total) {
                total = n;
                if (page > total) page = total;
                if (!_media.isEmpty) _broadcast(_mediaMessage());
                notifyListeners();
              }
              // Si muestra otra página que la del teléfono, corregirlo
              final shown = (msg['page'] as num?)?.toInt() ?? 0;
              if (shown > 0 && page > 0 && shown != page) ws.add(jsonEncode({'t': 'page', 'page': page}));
            case 'anim':
              if (msg['on'] == true && hasAnim) {
                _animClients.add(ws);
              } else {
                _animClients.remove(ws);
              }
            case 'fx':
              fxPage = (msg['page'] as num?)?.toInt() ?? 0;
              fxStep = (msg['step'] as num?)?.toInt() ?? 0;
              fxSteps = (msg['steps'] as num?)?.toInt() ?? -1;
              notifyListeners();
            case 'at':
              // El navegador con animaciones cambió de diapositiva (un paso, o sola por tiempo)
              final p = (msg['page'] as num?)?.toInt() ?? 0;
              if (hasPdf && p > 0 && p != page) {
                page = total > 0 ? p.clamp(1, total) : p;
                _broadcast({'t': 'page', 'page': page}, except: _animClients);
                notifyListeners();
              }
            case 'nav':
              // Teclado o clic en un navegador: lo decide el teléfono y se replica en todos
              final to = (msg['page'] as num?)?.toInt();
              if (to != null) {
                goTo(to);
              } else {
                go((msg['d'] as num?)?.toInt() ?? 0);
              }
            case 'links':
              final p = (msg['page'] as num?)?.toInt() ?? 0;
              links[p] = [for (final l in (msg['links'] as List? ?? const [])) if (l is String) l];
              notifyListeners();
            case 'openReq':
              // Clic en un enlace de la diapositiva, en la PC
              final url = msg['url'];
              if (url is String) openLink(url);
            case 'linkState':
              linkState = msg['open'] == true ? Map<String, Object?>.from(msg) : null;
              notifyListeners();
            case 'mediaState':
              _mediaPage = (msg['page'] as num?)?.toInt() ?? 0;
              mediaCount = (msg['count'] as num?)?.toInt() ?? 0;
              mediaPlaying = msg['playing'] == true;
              mediaItems = [
                for (final it in (msg['items'] as List? ?? const [])) it is Map && it['playing'] == true,
              ];
              notifyListeners();
          }
        } catch (_) {}
      },
      onDone: () => _removeClient(ws),
      onError: (Object _) => _removeClient(ws),
      cancelOnError: true,
    );
    notifyListeners();
  }

  void _removeClient(WebSocket ws) {
    _clients.remove(ws);
    _animClients.remove(ws);
    if (_clients.isEmpty) linkState = null; // se cerró la pestaña (y su panel)
    notifyListeners();
  }

  void _broadcast(Map<String, Object?> msg, {Set<WebSocket>? only, Set<WebSocket> except = const {}}) {
    final text = jsonEncode(msg);
    for (final c in (only ?? _clients).toList()) {
      if (except.contains(c)) continue;
      try {
        c.add(text);
      } catch (_) {
        _clients.remove(c);
        _animClients.remove(c);
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
