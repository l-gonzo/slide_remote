import 'dart:async';
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';

/// Herramientas de la vista de dibujo.
enum InkTool { pen, highlighter, laser }

/// Un trazo sobre una diapositiva. Las coordenadas van de 0 a 1 respecto a la página
/// (así se ve igual en el teléfono y en la pantalla de la PC, del tamaño que sea).
class InkStroke {
  InkStroke({required this.id, required this.tool, required this.color, required this.width, List<Offset>? points})
      : points = points ?? [];

  final int id;
  final InkTool tool;
  final Color color;

  /// Grosor como fracción del ancho de la página.
  final double width;
  final List<Offset> points;

  static String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Map<String, Object> toJson() => {
        'id': id,
        'tool': tool == InkTool.highlighter ? 'hl' : 'pen',
        'color': hex(color),
        'w': width,
        'pts': _pts(points),
      };

  static List<double> _pts(Iterable<Offset> p) => [
        for (final o in p) ...[_r(o.dx), _r(o.dy)],
      ];

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;
}

/// Avisa al pintor que hay que redibujar, sin reconstruir la pantalla.
class _Repaint extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Dibujos por página del PDF del modo Navegador. Se mandan al navegador de la PC en vivo
/// (por el WebSocket del modo Navegador) y se conservan hasta borrarlos o cambiar de PDF.
///
/// Avisa a sus oyentes solo cuando cambia qué hay en una página (trazo nuevo, deshacer, borrar);
/// lo que pasa mientras el dedo se mueve llega por [repaint], para no reconstruir la pantalla
/// en cada punto.
class InkBoard extends ChangeNotifier {
  InkBoard(this._send);

  /// Mensajes al navegador: como mucho uno cada tanto por trazo/láser; el último punto
  /// siempre se manda (a la espera de lo que falte).
  static const _sendGap = Duration(milliseconds: 12);

  /// Reloj para `ts` (ms): cuándo se tocó cada punto. Con eso el navegador reproduce el
  /// movimiento con su ritmo original aunque la red entregue los mensajes a tirones.
  /// Campo opcional: las páginas anteriores lo ignoran.
  static final Stopwatch _clock = Stopwatch()..start();
  static double _now() => _clock.elapsedMicroseconds / 1000;

  /// Manda un mensaje a todos los navegadores conectados.
  final void Function(Map<String, Object?> msg) _send;

  final Map<int, List<InkStroke>> pages = {};
  int _nextId = 1;

  /// Puntero láser actual (coordenadas 0..1) o null.
  Offset? laser;
  int laserPage = 0;

  /// Tamaño del puntero láser (1 = normal).
  double laserScale = 1;

  InkStroke? _current;
  int _currentPage = 0;
  final List<Offset> _pending = [];
  double _pendingTs = 0;
  double _laserTs = 0;
  Timer? _flush;
  final Stopwatch _sincePts = Stopwatch();
  Timer? _laserTimer;
  final Stopwatch _sinceLaser = Stopwatch();
  final _Repaint _repaint = _Repaint();

  /// Para el pintor: cambia en cada punto o movimiento del láser (y con todo lo demás).
  late final Listenable repaint = Listenable.merge([this, _repaint]);

  List<InkStroke> strokes(int page) => pages[page] ?? const [];

  bool hasInk(int page) => pages[page]?.isNotEmpty ?? false;

  // ---------------------------------------------------------------- trazos

  /// [width]: grosor como fracción del ancho de la página; con el láser, su tamaño (1 = normal).
  void begin(int page, Offset p, {required InkTool tool, required Color color, required double width}) {
    if (tool == InkTool.laser) {
      laserScale = width;
      _moveLaser(page, p, force: true);
      return;
    }
    end();
    final s = InkStroke(id: _nextId++, tool: tool, color: color, width: width, points: [p]);
    (pages[page] ??= []).add(s);
    _current = s;
    _currentPage = page;
    _send({'t': 'ink', 'op': 'add', 'page': page, 's': s.toJson(), 'ts': _r1(_now())});
    _sincePts
      ..reset()
      ..start();
    notifyListeners();
  }

  void move(int page, Offset p, InkTool tool) {
    if (tool == InkTool.laser) {
      _moveLaser(page, p);
      return;
    }
    final s = _current;
    if (s == null) return;
    // Ignorar movimientos mínimos (menos datos y trazos más limpios)
    if ((s.points.last - p).distance < 0.0015) return;
    s.points.add(p);
    _pending.add(p);
    _pendingTs = _now();
    _repaint.ping();
    if (_sincePts.elapsed >= _sendGap) {
      _flushPending();
    } else {
      _flush ??= Timer(_sendGap - _sincePts.elapsed, _flushPending);
    }
  }

  void end() {
    _laserTimer?.cancel();
    _laserTimer = null;
    if (laser != null) {
      laser = null;
      _send({'t': 'laser', 'off': true, 'ts': _r1(_now())});
      _repaint.ping();
    }
    if (_current == null) return;
    _flushPending();
    _current = null;
  }

  void _flushPending() {
    _flush?.cancel();
    _flush = null;
    final s = _current;
    if (s == null || _pending.isEmpty) return;
    _send({
      't': 'ink',
      'op': 'pts',
      'page': _currentPage,
      'id': s.id,
      'pts': InkStroke._pts(_pending),
      'ts': _r1(_pendingTs),
    });
    _pending.clear();
    _sincePts
      ..reset()
      ..start();
  }

  void _moveLaser(int page, Offset p, {bool force = false}) {
    laser = p;
    laserPage = page;
    _laserTs = _now();
    _repaint.ping();
    if (force || !_sinceLaser.isRunning || _sinceLaser.elapsed >= _sendGap) {
      _sendLaser();
    } else {
      // Sin esto, si el dedo se detiene justo después, la PC se queda con una posición vieja
      _laserTimer ??= Timer(_sendGap - _sinceLaser.elapsed, _sendLaser);
    }
  }

  void _sendLaser() {
    _laserTimer?.cancel();
    _laserTimer = null;
    final p = laser;
    if (p == null) return;
    _sinceLaser
      ..reset()
      ..start();
    _send({
      't': 'laser',
      'page': laserPage,
      'x': InkStroke._r(p.dx),
      'y': InkStroke._r(p.dy),
      's': InkStroke._r(laserScale),
      'ts': _r1(_laserTs),
    });
  }

  static double _r1(double v) => (v * 10).roundToDouble() / 10;

  void undo(int page) {
    end();
    final list = pages[page];
    if (list == null || list.isEmpty) return;
    list.removeLast();
    _send({'t': 'ink', 'op': 'undo', 'page': page});
    notifyListeners();
  }

  void clearPage(int page) {
    end();
    pages.remove(page);
    _send({'t': 'ink', 'op': 'clear', 'page': page});
    notifyListeners();
  }

  /// Al cambiar de PDF.
  void clearAll() {
    end();
    pages.clear();
    _send({'t': 'ink', 'op': 'clearAll'});
    notifyListeners();
  }

  /// Todo lo dibujado, para un navegador que se acaba de conectar.
  Map<String, Object?> snapshot() => {
        't': 'inkAll',
        'pages': {
          for (final e in pages.entries)
            if (e.value.isNotEmpty) '${e.key}': [for (final s in e.value) s.toJson()],
        },
      };

  @override
  void dispose() {
    _flush?.cancel();
    _laserTimer?.cancel();
    _repaint.dispose();
    super.dispose();
  }
}
