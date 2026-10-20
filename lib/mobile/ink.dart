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

/// Dibujos por página del PDF del modo Navegador. Se mandan al navegador de la PC en vivo
/// (por el WebSocket del modo Navegador) y se conservan hasta borrarlos o cambiar de PDF.
class InkBoard extends ChangeNotifier {
  InkBoard(this._send);

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
  Timer? _flush;
  DateTime _lastLaser = DateTime.fromMillisecondsSinceEpoch(0);

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
    _send({'t': 'ink', 'op': 'add', 'page': page, 's': s.toJson()});
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
    _flush ??= Timer(const Duration(milliseconds: 24), _flushPending);
    notifyListeners();
  }

  void end() {
    if (laser != null) {
      laser = null;
      _send({'t': 'laser', 'off': true});
      notifyListeners();
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
    _send({'t': 'ink', 'op': 'pts', 'page': _currentPage, 'id': s.id, 'pts': InkStroke._pts(_pending)});
    _pending.clear();
  }

  void _moveLaser(int page, Offset p, {bool force = false}) {
    laser = p;
    laserPage = page;
    notifyListeners();
    final now = DateTime.now();
    if (!force && now.difference(_lastLaser) < const Duration(milliseconds: 20)) return;
    _lastLaser = now;
    _send({'t': 'laser', 'page': page, 'x': InkStroke._r(p.dx), 'y': InkStroke._r(p.dy), 's': InkStroke._r(laserScale)});
  }

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
    super.dispose();
  }
}
