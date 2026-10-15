import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import 'office.dart';

/// Modo WiFi → "Proyectar en esta PC": la app de escritorio abre la presentación (convertida a
/// PDF) en el navegador de la PC, a pantalla completa, con la misma página del modo Navegador.
///
/// Como la presentación la muestra la propia app, todo va sincronizado y sin permisos especiales:
///  - el teléfono cambia de diapositiva por WiFi o Bluetooth (sin simular teclas);
///  - lo que se dibuja en el teléfono aparece al instante encima de la diapositiva;
///  - el teléfono sabe la página exacta (notas sincronizadas) y descarga el PDF para verla.
///
/// Rutas (en el servidor de notas, puerto 50506):
///   /  /index.html  /pdf.min.mjs  /pdf.worker.min.mjs  /deck.pdf   → la página (solo esta PC)
///   /ws     → WebSocket de la página (mismo protocolo que el modo Navegador)
///   /phone  → WebSocket del teléfono: `{t:'present', on, ver, page, total}`, dibujos, `{t:'page'}`
class PresentHost extends ChangeNotifier {
  PresentHost({required this.port});

  /// Puerto del servidor (el de notas).
  final int Function() port;

  /// Para avisar al teléfono por UDP en cuanto cambia la página (también va en cada PONG).
  void Function()? onPageChanged;

  /// El teléfono pidió proyectar (desde la vista de dibujo) la presentación elegida en la PC.
  Future<void> Function()? onPhoneStart;

  bool active = false;
  bool converting = false;
  String? error;
  String? name;

  File? _pdf;
  String? _source; // archivo original
  DateTime? _sourceTime;
  int version = 0; // cambia con cada PDF (el teléfono vuelve a descargarlo)

  int page = 1;
  int total = 0;
  String lang = 'en';

  final Set<WebSocket> _pages = {}; // navegadores con la presentación
  final Set<WebSocket> _phones = {}; // teléfonos en la vista de dibujo
  final Map<String, Uint8List> _assets = {};

  /// Dibujos por página (JSON tal cual los manda el teléfono), para los navegadores que se conecten.
  final Map<int, List<Map<String, Object?>>> _ink = {};

  int get viewers => _pages.length;
  String get url => 'http://127.0.0.1:${port()}/';

  // ---------------------------------------------------------------- iniciar / detener

  /// Convierte (si hace falta) y abre la presentación en el navegador de la PC.
  Future<void> start(String sourcePath, String displayName, {bool openBrowser = true}) async {
    error = null;
    final src = File(sourcePath);
    final mtime = await src.lastModified();
    if (_pdf == null || _source != sourcePath || _sourceTime != mtime) {
      converting = true;
      notifyListeners();
      _sendPhones(_presentState());
      try {
        _pdf = await _toPdf(src);
        _source = sourcePath;
        _sourceTime = mtime;
        version = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
        page = 1;
        total = 0;
        _ink.clear();
        _broadcastPages({'t': 'reload'});
        _broadcastPages({'t': 'ink', 'op': 'clearAll'});
      } on FormatException catch (e) {
        error = e.message;
      } catch (e) {
        error = '${t('No se pudo preparar la presentación', 'Could not prepare the presentation')}: $e';
      } finally {
        converting = false;
        _sendPhones(_presentState());
      }
      if (_pdf == null) {
        notifyListeners();
        return;
      }
    }
    name = displayName;
    final wasActive = active;
    active = true;
    notifyListeners();
    if (!wasActive) _broadcastPages({'t': 'reload'}); // las páginas ya abiertas vuelven a cargar
    _sendPhones(_presentState());
    if (openBrowser) await openInBrowser();
  }

  void stop() {
    if (!active) return;
    active = false;
    notifyListeners();
    _broadcastPages({'t': 'reload'}); // la página mostrará "elige una presentación"
    _sendPhones(_presentState());
  }

  Future<void> openInBrowser() async {
    final u = url;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', u]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [u]);
      } else {
        await Process.run('xdg-open', [u]);
      }
    } catch (e) {
      error = '${t('Abre en el navegador', 'Open in the browser')}: $u';
      notifyListeners();
    }
  }

  static Future<File> _toPdf(File src) async {
    if (src.path.toLowerCase().endsWith('.pdf')) return src;
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}slideremote-present');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    return Office.convert(src, 'pdf', dir);
  }

  // ---------------------------------------------------------------- navegación (la decide la app)

  void go(int delta) => goTo(page + delta);

  void goTo(int p) {
    if (!active) return;
    final n = total > 0 ? p.clamp(1, total) : (p < 1 ? 1 : p);
    if (n != page) {
      page = n;
      notifyListeners();
      onPageChanged?.call();
    }
    _broadcastPages({'t': 'page', 'page': page});
    _sendPhones({'t': 'page', 'page': page, 'total': total});
  }

  void setLanguage(String l) {
    lang = l;
    _broadcastPages({'t': 'lang', 'lang': l});
  }

  // ---------------------------------------------------------------- servidor

  Future<bool> handle(HttpRequest req, {required bool phone, required bool local}) async {
    final path = req.uri.path;
    final res = req.response;
    switch (path) {
      case '/phone':
        if (!phone || !WebSocketTransformer.isUpgradeRequest(req)) return false;
        _addPhone(await WebSocketTransformer.upgrade(req));
        return true;
      case '/ws':
        if (!local || !WebSocketTransformer.isUpgradeRequest(req)) return false;
        _addPage(await WebSocketTransformer.upgrade(req));
        return true;
      case '/' || '/index.html':
        if (!local) return false;
        await _asset(res, 'index.html', 'text/html; charset=utf-8');
        return true;
      case '/pdf.min.mjs' || '/pdf.worker.min.mjs':
        if (!local) return false;
        await _asset(res, path.substring(1), 'text/javascript; charset=utf-8');
        return true;
      case '/deck.pdf':
        // La página de esta PC y el teléfono (para verla en la vista de dibujo)
        if (!local && !phone) return false;
        final f = _pdf;
        if (!active || f == null || !await f.exists()) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers
            ..contentType = ContentType('application', 'pdf')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..contentLength = await f.length();
          await res.addStream(f.openRead());
        }
        await res.close();
        return true;
    }
    return false;
  }

  Future<void> _asset(HttpResponse res, String name, String type) async {
    var bytes = _assets[name] ??= (await rootBundle.load('assets/web/$name')).buffer.asUint8List();
    if (name == 'index.html') {
      bytes = Uint8List.fromList(utf8.encode(utf8.decode(bytes).replaceFirst('<html lang="es">', '<html lang="$lang">')));
    }
    res.headers
      ..set(HttpHeaders.contentTypeHeader, type)
      ..set(HttpHeaders.cacheControlHeader, name == 'index.html' ? 'no-store' : 'max-age=3600')
      ..contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  // ---------------------------------------------------------------- navegadores (la página)

  void _addPage(WebSocket ws) {
    _pages.add(ws);
    ws.pingInterval = const Duration(seconds: 5);
    ws.add(jsonEncode({'t': 'hello', 'hasPdf': active, 'lang': lang, 'page': page, 'src': 'pc'}));
    ws.add(jsonEncode(_inkSnapshot()));
    ws.listen(
      (data) {
        if (data is! String) return;
        try {
          final m = jsonDecode(data);
          if (m is! Map) return;
          switch (m['t']) {
            case 'state':
              final n = (m['total'] as num?)?.toInt() ?? 0;
              if (n > 0 && n != total) {
                total = n;
                if (page > total) page = total;
                notifyListeners();
                _sendPhones({'t': 'page', 'page': page, 'total': total});
              }
              final shown = (m['page'] as num?)?.toInt() ?? 0;
              if (shown > 0 && shown != page) ws.add(jsonEncode({'t': 'page', 'page': page}));
            case 'nav':
              // Teclado o clic en la página: lo decide la app y se replica en todo
              final to = (m['page'] as num?)?.toInt();
              if (to != null) {
                goTo(to);
              } else {
                go((m['d'] as num?)?.toInt() ?? 0);
              }
          }
        } catch (_) {}
      },
      onDone: () => _removePage(ws),
      onError: (Object _) => _removePage(ws),
      cancelOnError: true,
    );
    notifyListeners();
  }

  void _removePage(WebSocket ws) {
    _pages.remove(ws);
    notifyListeners();
  }

  void _broadcastPages(Map<String, Object?> msg) {
    final text = jsonEncode(msg);
    for (final c in _pages.toList()) {
      try {
        c.add(text);
      } catch (_) {
        _pages.remove(c);
      }
    }
  }

  // ---------------------------------------------------------------- teléfono (vista de dibujo)

  Map<String, Object?> _presentState() => {
        't': 'present',
        'on': active,
        'ver': version,
        'page': page,
        'total': total,
        'name': name,
        'converting': converting,
        'error': error,
      };

  void _addPhone(WebSocket ws) {
    _phones.add(ws);
    ws.pingInterval = const Duration(seconds: 5);
    ws.add(jsonEncode(_presentState()));
    ws.listen(
      (data) {
        if (data is! String) return;
        try {
          final m = jsonDecode(data);
          if (m is! Map) return;
          final msg = Map<String, Object?>.from(m);
          switch (msg['t']) {
            case 'ink':
              _applyInk(msg);
              _broadcastPages(msg);
            case 'inkAll':
              _ink.clear();
              final p = msg['pages'];
              if (p is Map) {
                for (final e in p.entries) {
                  final k = int.tryParse('${e.key}');
                  if (k != null && e.value is List) {
                    _ink[k] = [for (final s in e.value as List) if (s is Map) Map<String, Object?>.from(s)];
                  }
                }
              }
              _broadcastPages(_inkSnapshot());
            case 'laser':
              _broadcastPages(msg);
            case 'goto':
              goTo((msg['page'] as num?)?.toInt() ?? page);
            case 'present':
              if (msg['on'] == true) {
                onPhoneStart?.call();
              } else {
                stop();
              }
          }
        } catch (_) {}
      },
      onDone: () => _phones.remove(ws),
      onError: (Object _) => _phones.remove(ws),
      cancelOnError: true,
    );
  }

  void _sendPhones(Map<String, Object?> msg) {
    final text = jsonEncode(msg);
    for (final c in _phones.toList()) {
      try {
        c.add(text);
      } catch (_) {
        _phones.remove(c);
      }
    }
  }

  void _applyInk(Map<String, Object?> m) {
    final p = (m['page'] as num?)?.toInt() ?? page;
    final list = _ink[p] ??= [];
    switch (m['op']) {
      case 'add':
        final s = m['s'];
        if (s is Map) list.add(Map<String, Object?>.from(s));
      case 'pts':
        final id = m['id'];
        for (final s in list.reversed) {
          if (s['id'] == id) {
            s['pts'] = [...(s['pts'] as List? ?? const []), ...(m['pts'] as List? ?? const [])];
            break;
          }
        }
      case 'undo':
        if (list.isNotEmpty) list.removeLast();
      case 'clear':
        _ink.remove(p);
      case 'clearAll':
        _ink.clear();
    }
  }

  Map<String, Object?> _inkSnapshot() => {
        't': 'inkAll',
        'pages': {
          for (final e in _ink.entries)
            if (e.value.isNotEmpty) '${e.key}': e.value,
        },
      };

  @override
  void dispose() {
    for (final c in [..._pages, ..._phones]) {
      c.close();
    }
    super.dispose();
  }
}
