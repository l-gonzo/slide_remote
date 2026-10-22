import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_bridge.dart';

/// Qué tan cerca está el tiempo objetivo (define el color del cronómetro).
enum TimerPhase {
  /// Sin objetivo, o faltan más de 5 minutos.
  normal,

  /// Quedan 5 minutos o menos.
  warn,

  /// Queda 1 minuto o menos, o ya se acabó.
  last,
}

/// Cronómetro de la presentación. Solo se ve en el teléfono.
///
/// Guarda la hora de inicio, no un contador: sigue contando bien aunque salgas de la app,
/// bloquees el teléfono o el sistema la cierre.
///
/// Con un tiempo objetivo cuenta hacia atrás y vibra (discreto) cuando quedan 5 minutos,
/// otra vez en 1 y al terminar: 1, 2 y 3 pulsos.
class TalkTimer extends ChangeNotifier {
  static const _kStart = 'timer_start'; // ms desde época cuando se reanudó; 0 = en pausa
  static const _kAcc = 'timer_acc'; // ms acumulados antes de la última reanudación
  static const _kTarget = 'timer_target'; // ms; 0 = sin objetivo

  /// Avisos: lo que falta cuando vibra.
  static const _marks = [Duration(minutes: 5), Duration(minutes: 1), Duration.zero];

  /// Un aviso que pasó hace más de esto (p. ej. con la app cerrada) ya no vibra.
  static const _stale = Duration(seconds: 10);

  SharedPreferences? _prefs;
  int _startedAt = 0;
  int _accumulated = 0;
  Duration? _target;

  /// Avisos ya dados (0–3), para no repetirlos.
  int _stage = 0;
  Timer? _watch;

  bool get running => _startedAt > 0;
  bool get isZero => !running && _accumulated == 0;

  Duration? get target => _target;

  Duration get elapsed {
    final live = running ? DateTime.now().millisecondsSinceEpoch - _startedAt : 0;
    return Duration(milliseconds: _accumulated + (live < 0 ? 0 : live));
  }

  /// Lo que falta para el objetivo (negativo si ya pasó), o null sin objetivo.
  Duration? get remaining => _target == null ? null : _target! - elapsed;

  TimerPhase get phase {
    final r = remaining;
    if (r == null || r > _marks[0]) return TimerPhase.normal;
    if (r > _marks[1]) return TimerPhase.warn;
    return TimerPhase.last;
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _startedAt = _prefs!.getInt(_kStart) ?? 0;
    _accumulated = _prefs!.getInt(_kAcc) ?? 0;
    final ms = _prefs!.getInt(_kTarget) ?? 0;
    _target = ms > 0 ? Duration(milliseconds: ms) : null;
    _stage = _stageNow();
    _syncWatch();
    notifyListeners();
  }

  void start() {
    if (running) return;
    _startedAt = DateTime.now().millisecondsSinceEpoch;
    _save();
  }

  void pause() {
    if (!running) return;
    _accumulated = elapsed.inMilliseconds;
    _startedAt = 0;
    _save();
  }

  void toggle() => running ? pause() : start();

  void reset() {
    _startedAt = 0;
    _accumulated = 0;
    _save();
  }

  /// null quita el objetivo.
  void setTarget(Duration? d) {
    _target = (d == null || d <= Duration.zero) ? null : d;
    _prefs?.setInt(_kTarget, _target?.inMilliseconds ?? 0);
    _save();
  }

  void _save() {
    _prefs?.setInt(_kStart, _startedAt);
    _prefs?.setInt(_kAcc, _accumulated);
    // Cambió el estado a mano: los avisos que ya quedaron atrás no vibran
    _stage = _stageNow();
    _syncWatch();
    notifyListeners();
  }

  /// Cuántos avisos ya quedaron atrás con el tiempo actual.
  int _stageNow() {
    final r = remaining;
    if (r == null) return 0;
    return _marks.where((m) => r <= m).length;
  }

  void _syncWatch() {
    if (running && _target != null) {
      _watch ??= Timer.periodic(const Duration(seconds: 1), (_) => _check());
    } else {
      _watch?.cancel();
      _watch = null;
    }
  }

  void _check() {
    final r = remaining;
    if (r == null) return;
    final now = _stageNow();
    if (now <= _stage) return;
    _stage = now;
    // Solo si acaba de pasar: al volver a la app tras un rato no vibra tarde
    if (_marks[now - 1] - r < _stale) NativeBridge.vibrate(now);
    notifyListeners();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  /// 7:05 · 1:02:09
  static String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  /// Lo que se muestra: el tiempo que va o, con objetivo, lo que falta (+0:30 si ya pasó).
  String get label {
    final r = remaining;
    if (r == null) return format(elapsed);
    if (r.isNegative) return '+${format(-r)}';
    // Hacia arriba: con 0:00.4 restantes se ve 0:01, y 0:00 justo al terminar
    return format(Duration(seconds: (r.inMilliseconds / 1000).ceil()));
  }
}
