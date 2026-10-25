import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';

/// Herramientas de la vista de dibujo. El borrador quita trazos completos (como en PowerPoint).
enum InkTool { pen, highlighter, laser, eraser }

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

/// Un paso que se puede deshacer: un trazo nuevo, o los que quitó el borrador (o "borrar todo").
sealed class _InkAction {}

class _Added extends _InkAction {
  _Added(this.id);
  final int id;
}

class _Erased extends _InkAction {
  /// (posición en la lista, trazo), en el orden en que estaban.
  final List<(int, InkStroke)> items = [];
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
  final Map<int, List<_InkAction>> _history = {};
  int _nextId = 1;

  /// false = las anotaciones están ocultas en la pantalla de la PC (se conservan).
  bool visible = true;

  /// Borrador en curso: lo que va quitando el dedo (se deshace de una vez).
  _Erased? _erasing;
  int _erasePage = 0;
  Offset? _eraseLast;

  /// Posición del borrador en pantalla (0..1), para dibujar su círculo.
  Offset? eraser;

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

  bool canUndo(int page) => _history[page]?.isNotEmpty ?? false;

  /// Alguna página tiene dibujos.
  bool get hasAnyInk => pages.values.any((l) => l.isNotEmpty);

  /// Mostrar u ocultar las anotaciones en la PC (el teléfono las sigue mostrando, tenues).
  void setVisible(bool v) {
    if (v == visible) return;
    visible = v;
    _send({'t': 'inkVis', 'on': v});
    notifyListeners();
  }

  // ---------------------------------------------------------------- trazos

  /// [width]: grosor como fracción del ancho de la página; con el láser, su tamaño (1 = normal).
  void begin(int page, Offset p, {required InkTool tool, required Color color, required double width}) {
    if (tool == InkTool.eraser) return; // el borrador va por [erase]
    if (tool == InkTool.laser) {
      laserScale = width;
      _moveLaser(page, p, force: true);
      return;
    }
    end();
    // Dibujar con las anotaciones ocultas las vuelve a mostrar: si no, el público no vería nada
    if (!visible) setVisible(true);
    final s = InkStroke(id: _nextId++, tool: tool, color: color, width: width, points: [p]);
    (pages[page] ??= []).add(s);
    (_history[page] ??= []).add(_Added(s.id));
    _current = s;
    _currentPage = page;
    _send({'t': 'ink', 'op': 'add', 'page': page, 's': s.toJson(), 'ts': _r1(_now())});
    _sincePts
      ..reset()
      ..start();
    notifyListeners();
  }

  void move(int page, Offset p, InkTool tool) {
    if (tool == InkTool.eraser) return;
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
    _endErase();
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

  // ---------------------------------------------------------------- borrador

  /// El borrador toca [p] con radio [radius] (fracción del ancho). [aspect] = ancho / alto de la
  /// página: las coordenadas van de 0 a 1 en cada eje y hay que medir en la misma unidad.
  void erase(int page, Offset p, {required double radius, required double aspect}) {
    if (_erasing == null || _erasePage != page) {
      end();
      _erasing = _Erased();
      _erasePage = page;
      _eraseLast = null;
    }
    eraser = p;
    _repaint.ping();
    final list = pages[page];
    if (list == null || list.isEmpty) {
      _eraseLast = p;
      return;
    }
    // Recorrer el camino desde el punto anterior: un movimiento rápido no se salta trazos
    final from = _eraseLast ?? p;
    _eraseLast = p;
    Offset u(Offset o) => Offset(o.dx, o.dy / aspect); // en unidades del ancho
    final a = u(from), b = u(p);
    final steps = math.max(1, ((b - a).distance / (radius * 0.5)).ceil());
    final removed = <int>[];
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      final reach = radius + s.width / 2;
      var hit = false;
      for (var k = 0; k <= steps && !hit; k++) {
        final q = Offset.lerp(a, b, k / steps)!;
        hit = _near(s, q, reach, u);
      }
      if (hit) removed.add(i);
    }
    if (removed.isEmpty) return;
    for (final i in removed.reversed) {
      final s = list.removeAt(i);
      _erasing!.items.add((i, s));
      _send({'t': 'ink', 'op': 'del', 'page': page, 'id': s.id});
    }
    notifyListeners();
  }

  static bool _near(InkStroke s, Offset q, double reach, Offset Function(Offset) u) {
    final pts = s.points;
    if (pts.isEmpty) return false;
    if (pts.length == 1) return (u(pts.first) - q).distance <= reach;
    for (var i = 1; i < pts.length; i++) {
      if (_segDist(q, u(pts[i - 1]), u(pts[i])) <= reach) return true;
    }
    return false;
  }

  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  void _endErase() {
    final e = _erasing;
    if (e == null) return;
    _erasing = null;
    _eraseLast = null;
    if (eraser != null) {
      eraser = null;
      _repaint.ping();
    }
    if (e.items.isEmpty) return;
    // Al deshacer se vuelven a poner en su lugar: guardarlos en el orden original
    e.items.sort((x, y) => x.$1.compareTo(y.$1));
    (_history[_erasePage] ??= []).add(e);
  }

  // ---------------------------------------------------------------- deshacer, borrar

  void undo(int page) {
    end();
    final h = _history[page];
    if (h == null || h.isEmpty) return;
    final list = pages[page] ??= [];
    switch (h.removeLast()) {
      case _Added(:final id):
        final i = list.lastIndexWhere((s) => s.id == id);
        if (i >= 0) list.removeAt(i);
        _send({'t': 'ink', 'op': 'del', 'page': page, 'id': id});
      case final _Erased e:
        for (final (i, s) in e.items) {
          list.insert(i.clamp(0, list.length), s);
        }
        _sendPage(page);
    }
    notifyListeners();
  }

  /// Borra la página; se puede deshacer.
  void clearPage(int page) {
    end();
    final list = pages.remove(page);
    if (list == null || list.isEmpty) return;
    final e = _Erased();
    for (var i = 0; i < list.length; i++) {
      e.items.add((i, list[i]));
    }
    (_history[page] ??= []).add(e);
    _send({'t': 'ink', 'op': 'clear', 'page': page});
    notifyListeners();
  }

  /// Al cambiar de PDF, o "borrar todas las diapositivas".
  void clearAll() {
    end();
    pages.clear();
    _history.clear();
    _send({'t': 'ink', 'op': 'clearAll'});
    notifyListeners();
  }

  void _sendPage(int page) => _send({
        't': 'ink',
        'op': 'set',
        'page': page,
        'strokes': [for (final s in pages[page] ?? const <InkStroke>[]) s.toJson()],
      });

  /// Todo lo dibujado, para un navegador que se acaba de conectar.
  Map<String, Object?> snapshot() => {
        't': 'inkAll',
        'vis': visible,
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
