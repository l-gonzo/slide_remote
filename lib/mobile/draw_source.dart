import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import 'ink.dart';
import 'native_bridge.dart';
import 'remote_controller.dart';

/// De dónde salen la diapositiva y a dónde van los dibujos de la vista "Dibujar".
///  - [BrowserDrawSource]: modo Navegador (el PDF está en el teléfono).
///  - [WifiDrawSource]: modo WiFi (la presentación corre en la PC; la app de escritorio manda
///    capturas de la pantalla y muestra los dibujos encima).
abstract class DrawSource extends ChangeNotifier {
  /// Posición actual (página del PDF, o número de diapositiva contado en WiFi).
  int get page;

  /// Texto para mostrar la posición ("3 / 18"), o null.
  String? get pageLabel;

  InkBoard get ink;

  /// Imagen de [page] si ya está lista.
  PdfPageImage? image(int page);

  /// Pedir la imagen de [page] con [widthPx] píxeles de ancho (puede no hacer nada).
  void request(int page, int widthPx);

  /// true si la imagen de [page] no se pudo obtener.
  bool failed(int page);

  /// Si es false, [offlineHint] explica qué falta.
  bool get connected;
  String? get offlineHint;

  void go(bool forward);

  /// Volver a pedir la imagen (WiFi: nueva captura de la PC).
  bool get canRefresh => false;
  void refresh() {}

  Future<void> close();
}

// ============================================================ modo Navegador

class BrowserDrawSource extends DrawSource {
  BrowserDrawSource(this.c) {
    c.browser.addListener(notifyListeners);
    c.browser.ink.addListener(notifyListeners);
  }

  final RemoteController c;
  final Map<int, PdfPageImage> _images = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};
  String? _pdfPath;

  @override
  int get page => c.browser.page < 1 ? 1 : c.browser.page;

  @override
  String? get pageLabel => c.browser.total > 0 ? '$page / ${c.browser.total}' : '$page';

  @override
  InkBoard get ink => c.browser.ink;

  @override
  bool get connected => c.browser.viewers > 0;

  @override
  String? get offlineHint => t('Abre la dirección en el navegador de la PC', 'Open the address in the computer’s browser');

  @override
  PdfPageImage? image(int page) => _images[page];

  @override
  bool failed(int page) => _failed.contains(page);

  @override
  void request(int page, int widthPx) {
    final path = c.browser.pdfFile?.path;
    if (path == null) return;
    if (path != _pdfPath) {
      _pdfPath = path; // cambió el PDF
      _images.clear();
      _failed.clear();
    }
    final total = c.browser.total;
    for (final p in [page, page + 1]) {
      if (p < 1 || (total > 0 && p > total)) continue;
      if (_images.containsKey(p) || _loading.contains(p) || _failed.contains(p)) continue;
      _loading.add(p);
      NativeBridge.renderPdfPage(path, p, widthPx).then((img) {
        _loading.remove(p);
        if (path != _pdfPath) return;
        if (img == null) {
          _failed.add(p);
        } else {
          _images[p] = img;
          if (img.pages > 0) c.browser.setTotalIfUnknown(img.pages);
          if (_images.length > 6) {
            final far = _images.keys.toList()..sort((a, b) => (a - this.page).abs().compareTo((b - this.page).abs()));
            for (final k in far.skip(6)) {
              _images.remove(k);
            }
          }
        }
        notifyListeners();
      });
    }
  }

  @override
  void go(bool forward) {
    if (connected) {
      c.send(forward: forward); // igual que los botones de volumen
    } else {
      HapticFeedback.selectionClick(); // sin navegador también se puede recorrer y dibujar
      c.browser.go(forward ? 1 : -1);
    }
  }

  @override
  Future<void> close() async {
    ink.end();
    c.browser.removeListener(notifyListeners);
    c.browser.ink.removeListener(notifyListeners);
    dispose();
  }
}

// ============================================================ modo WiFi

/// Modo WiFi con "Proyectar en esta PC": la app de escritorio muestra la presentación (como PDF)
/// en el navegador de la PC. El teléfono descarga ese mismo PDF para verlo y manda los dibujos.
///
/// WebSocket `ws://<pc>:<puerto>/phone`:
///  - PC → teléfono: `{t:'present', on, ver, page, total, converting, error}` y `{t:'page', page, total}`
///  - teléfono → PC: los mensajes de dibujo del modo Navegador (ink / laser / inkAll) y
///    `{t:'present', on: true}` para pedir que empiece a proyectar.
class WifiDrawSource extends DrawSource {
  WifiDrawSource(this.c, this.uri) {
    // Los dibujos viven en el controlador: siguen ahí si sales y vuelves a entrar
    c.wifiInkSink = _send;
    ink.addListener(notifyListeners);
    c.addListener(notifyListeners);
    _connect();
  }

  final RemoteController c;
  final Uri uri;

  @override
  InkBoard get ink => c.wifiInk;

  WebSocket? _ws;
  bool _closed = false;
  bool _connecting = false;
  String? _error;
  Timer? _retry;

  // estado de la proyección en la PC
  bool _presenting = false;
  bool _converting = false;
  String? _pcError;
  int _ver = 0;
  int _page = 1;
  int _total = 0;

  // PDF descargado y páginas ya dibujadas
  String? _pdfPath;
  bool _downloading = false;
  final Map<int, PdfPageImage> _images = {};
  final Set<int> _loading = {};
  final Set<int> _failed = {};

  bool get presenting => _presenting;

  @override
  int get page => _page;

  @override
  String? get pageLabel => _presenting ? (_total > 0 ? '$_page / $_total' : '$_page') : null;

  @override
  bool get connected => _ws != null && _presenting && _pdfPath != null;

  @override
  String? get offlineHint {
    if (_ws == null) {
      return _error ??
          (_connecting
              ? t('Conectando con la PC…', 'Connecting to the computer…')
              : t('Abre Slide Remote en la PC', 'Open Slide Remote on the computer'));
    }
    if (_pcError != null) return _pcError;
    if (_converting) return t('La PC está preparando la presentación…', 'The computer is preparing the presentation…');
    if (!_presenting) {
      return t('Para dibujar, la PC proyecta la presentación con Slide Remote. Toca “Proyectar en la PC” '
          '(antes elige la presentación en la app de escritorio).',
          'To draw, the computer presents with Slide Remote. Tap “Present on the computer” '
          '(choose the presentation in the desktop app first).');
    }
    if (_downloading || _pdfPath == null) return t('Recibiendo la presentación…', 'Receiving the presentation…');
    return null;
  }

  /// Botón que ofrece la vista cuando la PC aún no proyecta.
  bool get canStart => _ws != null && !_presenting && !_converting;
  void startPresenting() => _send({'t': 'present', 'on': true});

  @override
  PdfPageImage? image(int page) => _images[page];

  @override
  bool failed(int page) => _failed.contains(page);

  @override
  void request(int page, int widthPx) {
    final path = _pdfPath;
    if (path == null) return;
    for (final p in [page, page + 1]) {
      if (p < 1 || (_total > 0 && p > _total)) continue;
      if (_images.containsKey(p) || _loading.contains(p) || _failed.contains(p)) continue;
      _loading.add(p);
      NativeBridge.renderPdfPage(path, p, widthPx).then((img) {
        _loading.remove(p);
        if (path != _pdfPath) return;
        if (img == null) {
          _failed.add(p);
        } else {
          _images[p] = img;
          if (_images.length > 6) {
            final far = _images.keys.toList()..sort((a, b) => (a - _page).abs().compareTo((b - _page).abs()));
            for (final k in far.skip(6)) {
              _images.remove(k);
            }
          }
        }
        notifyListeners();
      });
    }
  }

  @override
  void go(bool forward) => c.send(forward: forward); // por WiFi; la PC cambia la página

  void _send(Map<String, Object?> msg) {
    try {
      _ws?.add(jsonEncode(msg));
    } catch (_) {}
  }

  Future<void> _connect() async {
    if (_closed || _connecting || _ws != null) return;
    _connecting = true;
    notifyListeners();
    try {
      final ws = await WebSocket.connect(uri.toString()).timeout(const Duration(seconds: 5));
      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _error = null;
      ws.pingInterval = const Duration(seconds: 5);
      ws.listen(_onData, onDone: _onLost, onError: (Object _) => _onLost(), cancelOnError: true);
    } catch (e) {
      _error = t('No se pudo conectar con la PC. ¿Está actualizada la app de escritorio?',
          'Could not connect to the computer. Is the desktop app up to date?');
      _retry = Timer(const Duration(seconds: 3), _connect);
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  void _onLost() {
    _ws = null;
    notifyListeners();
    if (!_closed) _retry = Timer(const Duration(seconds: 2), _connect);
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Map<Object?, Object?> m;
    try {
      final d = jsonDecode(data);
      if (d is! Map) return;
      m = d;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'present':
        _presenting = m['on'] == true;
        _converting = m['converting'] == true;
        _pcError = m['error'] as String?;
        _page = (m['page'] as num?)?.toInt() ?? _page;
        _total = (m['total'] as num?)?.toInt() ?? _total;
        final ver = (m['ver'] as num?)?.toInt() ?? 0;
        if (_presenting && ver != 0 && ver != _ver) {
          // Otra presentación: los dibujos viejos ya no aplican (si solo se editó, se conservan)
          if (_ver != 0 && m['keep'] != true) ink.clearAll();
          _ver = ver;
          _download(ver);
        } else if (_presenting) {
          _send(ink.snapshot()); // la PC pudo reiniciarse: volver a mandar lo dibujado
        }
        notifyListeners();
      case 'page':
        _page = (m['page'] as num?)?.toInt() ?? _page;
        _total = (m['total'] as num?)?.toInt() ?? _total;
        notifyListeners();
    }
  }

  Future<void> _download(int ver) async {
    _downloading = true;
    _pdfPath = null;
    _images.clear();
    _failed.clear();
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final httpUri = uri.replace(scheme: 'http', path: '/deck.pdf');
      final res = await (await client.getUrl(httpUri)).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final file = File('${Directory.systemTemp.path}/slideremote_pc_$ver.pdf');
      final sink = file.openWrite();
      await res.pipe(sink);
      if (ver != _ver || _closed) return;
      _pdfPath = file.path;
      _send(ink.snapshot());
    } catch (e) {
      _pcError = t('No se pudo recibir la presentación de la PC', 'Could not receive the presentation from the computer');
    } finally {
      client.close(force: true);
      _downloading = false;
      notifyListeners();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    ink.end();
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    if (c.wifiInkSink == _send) c.wifiInkSink = null;
    ink.removeListener(notifyListeners);
    c.removeListener(notifyListeners);
    dispose();
  }
}
