import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/deck_media.dart';
import '../common/i18n.dart';
import '../common/link_view.dart';
import '../common/web_page.dart';
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
///   /deck.svg → la misma presentación exportada por LibreOffice con su reproductor: ahí sí se
///               ven las animaciones y transiciones (el PDF queda debajo para enlaces, videos y
///               dibujos, y para el teléfono)
///   /ws     → WebSocket de la página (mismo protocolo que el modo Navegador)
///   /media/N → videos y audios de la presentación (encima del PDF, en su lugar)
///   /phone  → WebSocket del teléfono: `{t:'present', on, ver, page, total}`, dibujos, `{t:'page'}`,
///             enlaces de la diapositiva (`{t:'links'}`, el teléfono pide `{t:'open', url}`) y
///             videos (`{t:'mediaState'}`, el teléfono pide `{t:'mediaCtl', op}`)
class PresentHost extends ChangeNotifier {
  PresentHost({required this.port}) {
    webPageBuild().then((b) => _build = b);
  }

  String _build = ''; // huella de la página (ver web_page.dart)

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
  File? _svg; // con animaciones y transiciones (null: solo PDF)
  String? _source; // archivo original
  DateTime? _sourceTime;
  int version = 0; // cambia con cada PDF (el teléfono vuelve a descargarlo)
  bool _keepInk = false; // la última versión es el mismo archivo con cambios (no borrar dibujos)
  DateTime? _pendingTime; // cambio visto en el archivo, esperando a que termine de guardarse

  int page = 1;
  int total = 0;

  /// Animación en la que va la diapositiva (la informa la página con animaciones; -1: no se sabe).
  int fxStep = 0;
  int fxSteps = -1;
  String lang = 'en';

  final Set<WebSocket> _pages = {}; // navegadores con la presentación
  final Set<WebSocket> _animPages = {}; // los que ya cargaron deck.svg (ellos deciden la diapositiva)
  final Set<WebSocket> _phones = {}; // teléfonos en la vista de dibujo
  final Map<String, Uint8List> _assets = {};

  /// Dibujos por página (JSON tal cual los manda el teléfono), para los navegadores que se conecten.
  final Map<int, List<Map<String, Object?>>> _ink = {};
  bool _inkVisible = true;

  /// Videos y audios del archivo original (extraídos a una carpeta temporal).
  DeckMediaSet _media = DeckMediaSet.empty;
  Directory? _mediaDir;

  /// Enlaces de cada página (los informa el navegador) y si hay un video sonando.
  final Map<int, List<String>> _links = {};
  Map<String, Object?>? _mediaState;
  Map<String, Object?>? _linkState; // enlace abierto encima de la presentación (tal cual lo informa la página)
  bool get _linkOpen => _linkState != null;

  int get viewers => _pages.length;

  /// Proyectando una presentación (no un PDF) sin el SVG: falta LibreOffice para las animaciones.
  bool get animMissing => active && _svg == null && !(_source?.toLowerCase().endsWith('.pdf') ?? true);
  String get url => 'http://127.0.0.1:${port()}/';

  // ---------------------------------------------------------------- iniciar / detener

  /// Convierte (si hace falta) y abre la presentación en el navegador de la PC.
  Future<void> start(String sourcePath, String displayName, {bool openBrowser = true}) async {
    error = null;
    final src = File(sourcePath);
    final mtime = await src.lastModified();
    if (_pdf == null || _source != sourcePath || _sourceTime != mtime) {
      // Mismo archivo, solo con cambios guardados: conservar la página y los dibujos
      final sameFile = _pdf != null && _source == sourcePath;
      converting = true;
      notifyListeners();
      _sendPhones(_presentState());
      try {
        final old = _pdf;
        final (pdf, svg) = await _convert(src);
        _pdf = pdf;
        _svg = svg;
        if (old != null && old.path != _pdf!.path && old.path != sourcePath) {
          try {
            await old.parent.delete(recursive: true); // conversión anterior
          } catch (_) {}
        }
        _source = sourcePath;
        _sourceTime = mtime;
        _pendingTime = null;
        await _loadMedia(src);
        version = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
        _keepInk = sameFile;
        if (!sameFile) {
          page = 1;
          _ink.clear();
          _inkVisible = true;
          _broadcastPages({'t': 'ink', 'op': 'clearAll'});
        }
        _links.clear();
        total = 0; // lo vuelve a informar el navegador (pudo cambiar)
        _reloadPages();
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
    if (!wasActive) _reloadPages(); // las páginas ya abiertas vuelven a cargar
    _sendPhones(_presentState());
    if (openBrowser) await openInBrowser();
  }

  void stop() {
    if (!active) return;
    active = false;
    notifyListeners();
    _reloadPages(); // la página mostrará "elige una presentación"
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

  /// Videos y audios de un .pptx/.odp, para ponerlos encima del PDF.
  Future<void> _loadMedia(File src) async {
    final old = _mediaDir;
    _media = DeckMediaSet.empty;
    _mediaDir = null;
    if (old != null) {
      try {
        await old.delete(recursive: true);
      } catch (_) {}
    }
    final lower = src.path.toLowerCase();
    if (!['.pptx', '.pptm', '.ppsx', '.ppsm', '.potx', '.odp', '.otp'].any(lower.endsWith)) return;
    try {
      final dir = await Directory.systemTemp.createTemp('slideremote-media');
      _media = await DeckMediaSet.extract(await src.readAsBytes(), dir.path);
      _mediaDir = dir;
    } catch (e) {
      debugPrint('Videos de la presentación: $e');
    }
  }

  Map<String, Object?> _mediaMessage() => _media.message(total, (i) => '/media/$i');

  /// Abrir un enlace de la diapositiva (lo pide el teléfono o un clic en la página): dentro de
  /// la presentación, en un panel o ventana que se cierra desde el teléfono. Sin la página
  /// abierta, con el navegador de la PC.
  Future<void> openLink(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || !['http', 'https', 'mailto'].contains(u.scheme)) return;
    if (_pages.isNotEmpty) {
      final target = linkTarget(url);
      _broadcastPages({'t': 'open', 'url': target.url, 'kind': target.kind, 'orig': url});
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  /// PDF y, si LibreOffice puede, SVG con animaciones (en la misma carpeta).
  static Future<(File, File?)> _convert(File src) async {
    if (src.path.toLowerCase().endsWith('.pdf')) return (src, null);
    // Carpeta nueva cada vez: si la conversión falla, la presentación anterior sigue en pantalla
    final dir = await Directory.systemTemp.createTemp('slideremote-present');
    try {
      final pdf = await Office.convert(src, 'pdf', dir);
      File? svg;
      try {
        svg = await Office.convert(src, 'svg', dir, filter: 'impress_svg_Export');
      } catch (e) {
        debugPrint('Sin animaciones (SVG): $e'); // se proyecta el PDF, sin animaciones
      }
      return (pdf, svg);
    } catch (_) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// Se llama cada ~2 s: si guardaste cambios en la presentación mientras se proyecta, se vuelve
  /// a convertir y el navegador (y el teléfono) se actualizan solos, en la misma diapositiva.
  Future<void> checkSourceModified() async {
    final src = _source;
    if (!active || converting || src == null) return;
    try {
      final m = await File(src).lastModified();
      if (m == _sourceTime) return;
      // Esperar a que el archivo deje de cambiar (los programas guardan en varios pasos)
      if (_pendingTime != m) {
        _pendingTime = m;
        return;
      }
      await start(src, name ?? '', openBrowser: false);
    } catch (_) {
      // El archivo se movió o se está escribiendo: se intenta en la siguiente vuelta
    }
  }

  // ---------------------------------------------------------------- navegación (la decide la app)

  /// Siguiente / anterior. Con animaciones, la página da el paso (la siguiente animación o
  /// diapositiva) y avisa con `{t:'at'}` en qué diapositiva quedó.
  void go(int delta) {
    if (_linkOpen) {
      closeLink(); // con un enlace abierto, "siguiente" o "anterior" primero lo cierra
      return;
    }
    if (active && _animPages.isNotEmpty) {
      _broadcastPages({'t': 'step', 'd': delta.sign}, only: _animPages);
    } else {
      goTo(page + delta);
    }
  }

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

  void closeLink() => _broadcastPages({'t': 'closeLink'});

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
      case '/link':
        // Páginas de los enlaces, servidas para mostrarlas en el panel (ver link_view.dart)
        if (!local) return false;
        await serveLinkProxy(req);
        return true;
      case '/' || '/index.html':
        if (!local) return false;
        await _asset(res, 'index.html', 'text/html; charset=utf-8');
        return true;
      case '/pdf.min.mjs' || '/pdf.worker.min.mjs':
        if (!local) return false;
        await _asset(res, path.substring(1), 'text/javascript; charset=utf-8');
        return true;
      case _ when path.startsWith('/media/'):
        if (!local) return false;
        final i = int.tryParse(path.substring(7)) ?? -1;
        if (!active || i < 0 || i >= _media.items.length) {
          res.statusCode = HttpStatus.notFound;
          await res.close();
        } else {
          final m = _media.items[i];
          await serveFileWithRange(req, File(m.file), m.mime);
        }
        return true;
      case '/deck.svg':
        if (!local) return false;
        final f = _svg;
        if (!active || f == null || !await f.exists()) {
          res.statusCode = HttpStatus.notFound;
        } else {
          res.headers
            ..contentType = ContentType('image', 'svg+xml', charset: 'utf-8')
            ..set(HttpHeaders.cacheControlHeader, 'no-store')
            ..contentLength = await f.length();
          await res.addStream(f.openRead());
        }
        await res.close();
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

  // ---------------------------------------------------------------- navegadores (la página)

  void _addPage(WebSocket ws) {
    _pages.add(ws);
    ws.pingInterval = const Duration(seconds: 5);
    ws.add(jsonEncode({'t': 'hello', 'hasPdf': active, 'anim': active && _svg != null, 'lang': lang, 'page': page, 'src': 'pc', 'build': _build}));
    ws.add(jsonEncode(_inkSnapshot()));
    if (active && total > 0 && !_media.isEmpty) ws.add(jsonEncode(_mediaMessage()));
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
                if (!_media.isEmpty) _broadcastPages(_mediaMessage());
              }
              final shown = (m['page'] as num?)?.toInt() ?? 0;
              if (shown > 0 && shown != page) ws.add(jsonEncode({'t': 'page', 'page': page}));
            case 'anim':
              // La página ya muestra deck.svg: desde ahora ella da los pasos
              if (m['on'] == true) {
                _animPages.add(ws);
              } else {
                _animPages.remove(ws);
              }
            case 'fx':
              // En qué animación va (para el contador del teléfono)
              final p = (m['page'] as num?)?.toInt() ?? 0;
              final step = (m['step'] as num?)?.toInt() ?? 0, steps = (m['steps'] as num?)?.toInt() ?? -1;
              if (p == page && (step != fxStep || steps != fxSteps)) {
                fxStep = step;
                fxSteps = steps;
                onPageChanged?.call();
              }
            case 'at':
              // La página con animaciones cambió de diapositiva (por un paso o sola, por tiempo)
              final p = (m['page'] as num?)?.toInt() ?? 0;
              if (active && p > 0 && p != page) {
                page = total > 0 ? p.clamp(1, total) : p;
                notifyListeners();
                onPageChanged?.call();
                _broadcastPages({'t': 'page', 'page': page}, except: _animPages);
                _sendPhones({'t': 'page', 'page': page, 'total': total});
              }
            case 'nav':
              // Teclado o clic en la página: lo decide la app y se replica en todo
              final to = (m['page'] as num?)?.toInt();
              if (to != null) {
                goTo(to);
              } else {
                go((m['d'] as num?)?.toInt() ?? 0);
              }
            case 'links':
              final p = (m['page'] as num?)?.toInt() ?? 0;
              _links[p] = [for (final l in (m['links'] as List? ?? const [])) if (l is String) l];
              _sendPhones({'t': 'links', 'page': p, 'links': _links[p]});
            case 'openReq':
              final url = m['url'];
              if (url is String) openLink(url);
            case 'linkState':
              _linkState = m['open'] == true ? Map<String, Object?>.from(m) : null;
              _sendPhones(_linkState ?? {'t': 'linkState', 'open': false});
            case 'mediaState':
              _mediaState = {'t': 'mediaState', 'page': m['page'], 'count': m['count'], 'playing': m['playing'], 'items': m['items']};
              _sendPhones(_mediaState!);
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
    _animPages.remove(ws);
    if (_pages.isEmpty && _linkOpen) {
      _linkState = null; // se cerró la pestaña (y su panel)
      _sendPhones({'t': 'linkState', 'open': false});
    }
    notifyListeners();
  }

  void _broadcastPages(Map<String, Object?> msg, {Set<WebSocket>? only, Set<WebSocket> except = const {}}) {
    final text = jsonEncode(msg);
    for (final c in (only ?? _pages).toList()) {
      if (except.contains(c)) continue;
      try {
        c.add(text);
      } catch (_) {
        _pages.remove(c);
        _animPages.remove(c);
      }
    }
  }

  /// Las páginas vuelven a cargar la presentación (y avisan otra vez si tienen animaciones).
  void _reloadPages() {
    _animPages.clear();
    fxStep = 0;
    fxSteps = -1;
    _broadcastPages({'t': 'reload', 'anim': active && _svg != null});
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
        'keep': _keepInk,
      };

  void _addPhone(WebSocket ws) {
    _phones.add(ws);
    ws.pingInterval = const Duration(seconds: 5);
    ws.add(jsonEncode(_presentState()));
    if (_links[page] case final l?) ws.add(jsonEncode({'t': 'links', 'page': page, 'links': l}));
    if (_mediaState case final ms?) ws.add(jsonEncode(ms));
    if (_linkState case final l?) ws.add(jsonEncode(l));
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
            case 'inkVis':
              _inkVisible = msg['on'] != false;
              _broadcastPages(msg);
            case 'open':
              final url = msg['url'];
              if (url is String) openLink(url);
            case 'closeLink':
              closeLink();
            case 'linkCtl':
              _broadcastPages(msg); // desplazar, seguir un enlace, atrás, controles del video
            case 'mediaCtl':
              _broadcastPages({'t': 'mediaCtl', 'op': msg['op'], 'i': msg['i']});
            case 'inkAll':
              if (msg['vis'] is bool) _inkVisible = msg['vis'] as bool;
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
            // Agregar en el lugar: copiar la lista entera en cada mensaje crece con el trazo
            final pts = s['pts'];
            final add = m['pts'] as List? ?? const [];
            if (pts is List) {
              pts.addAll(add);
            } else {
              s['pts'] = [...add];
            }
            break;
          }
        }
      case 'del':
        list.removeWhere((s) => s['id'] == m['id']);
      case 'set':
        _ink[p] = [for (final s in (m['strokes'] as List? ?? const [])) if (s is Map) Map<String, Object?>.from(s)];
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
        'vis': _inkVisible,
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
    _mediaDir?.delete(recursive: true).ignore();
    super.dispose();
  }
}
