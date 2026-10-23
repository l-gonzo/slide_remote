import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/i18n.dart';
import 'native_bridge.dart';

/// Qué tan cerca está el tiempo objetivo (define el color del cronómetro).
enum TimerPhase {
  /// Sin objetivo, o aún no llega el primer aviso.
  normal,

  /// Ya pasó el primer aviso.
  warn,

  /// Ya pasó el segundo aviso, o se acabó el tiempo.
  last,
}

/// Un aviso del tiempo objetivo: cuando falta [left], el teléfono vibra [pulses] veces
/// (0 = no vibra; el color del cronómetro cambia igual).
@immutable
class TimerAlert {
  const TimerAlert(this.left, this.pulses);
  final Duration left;
  final int pulses;

  static const maxPulses = 3;
}

/// Cronómetro de la presentación. Solo se ve en el teléfono.
///
/// Guarda la hora de inicio, no un contador: sigue contando bien aunque salgas de la app,
/// bloquees el teléfono o el sistema la cierre.
///
/// Con un tiempo objetivo cuenta hacia atrás y vibra (discreto) en cada aviso: de fábrica
/// cuando quedan 5 minutos, en 1 y al terminar, con 1, 2 y 3 pulsos. Los minutos, los pulsos
/// y la fuerza de la vibración se eligen en Ajustes.
class TalkTimer extends ChangeNotifier {
  static const _kStart = 'timer_start'; // ms desde época cuando se reanudó; 0 = en pausa
  static const _kAcc = 'timer_acc'; // ms acumulados antes de la última reanudación
  static const _kTarget = 'timer_target'; // ms; 0 = sin objetivo
  static const _kVibe = 'timer_vibe_level'; // 0–1
  static const _kAlerts = 'timer_alerts'; // "segundos:pulsos,…", de mayor a menor tiempo

  /// Avisos de fábrica. Siempre son tres y el último es al terminar (falta 0).
  static const defaultAlerts = [
    TimerAlert(Duration(minutes: 5), 1),
    TimerAlert(Duration(minutes: 1), 2),
    TimerAlert(Duration.zero, 3),
  ];

  /// Lo más lejos del final que puede ir un aviso.
  static const maxAlertMinutes = 180;

  /// Un aviso que pasó hace más de esto (p. ej. con la app cerrada) ya no vibra.
  static const _stale = Duration(seconds: 10);

  SharedPreferences? _prefs;
  int _startedAt = 0;
  int _accumulated = 0;
  Duration? _target;
  double _vibe = 1;
  List<TimerAlert> _alerts = defaultAlerts;

  /// Avisos ya dados (0–3), para no repetirlos.
  int _stage = 0;
  Timer? _watch;

  bool get running => _startedAt > 0;
  bool get isZero => !running && _accumulated == 0;

  Duration? get target => _target;

  /// Fuerza de la vibración, 0 (suave) a 1 (fuerte).
  double get vibe => _vibe;

  List<TimerAlert> get alerts => _alerts;

  Duration get elapsed {
    final live = running ? DateTime.now().millisecondsSinceEpoch - _startedAt : 0;
    return Duration(milliseconds: _accumulated + (live < 0 ? 0 : live));
  }

  /// Lo que falta para el objetivo (negativo si ya pasó), o null sin objetivo.
  Duration? get remaining => _target == null ? null : _target! - elapsed;

  TimerPhase get phase {
    final r = remaining;
    if (r == null || r > _alerts[0].left) return TimerPhase.normal;
    if (r > _alerts[1].left) return TimerPhase.warn;
    return TimerPhase.last;
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _startedAt = _prefs!.getInt(_kStart) ?? 0;
    _accumulated = _prefs!.getInt(_kAcc) ?? 0;
    final ms = _prefs!.getInt(_kTarget) ?? 0;
    _target = ms > 0 ? Duration(milliseconds: ms) : null;
    _vibe = (_prefs!.getDouble(_kVibe) ?? 1).clamp(0.0, 1.0);
    _alerts = _parseAlerts(_prefs!.getString(_kAlerts)) ?? defaultAlerts;
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

  /// Mientras se arrastra la barra; al soltarla, [previewVibe].
  void setVibe(double v) {
    _vibe = v.clamp(0.0, 1.0);
    _prefs?.setDouble(_kVibe, _vibe);
    notifyListeners();
  }

  /// Para sentir cómo vibra un aviso de [count] pulsos.
  void previewVibe([int count = 1]) => _vibrate(count);

  /// Suave: pulsos de 150 ms al 40 %. Fuerte: 700 ms al máximo, como una notificación.
  void _vibrate(int count) {
    if (count < 1) return;
    NativeBridge.vibrate(count, ms: (150 + 550 * _vibe).round(), strength: 0.4 + 0.6 * _vibe);
  }

  /// Minutos que puede tener el aviso [i] sin pasar a sus vecinos (el último es fijo en 0).
  (int, int) alertRange(int i) {
    if (i == _alerts.length - 1) return (0, 0);
    final lo = _alerts[i + 1].left.inMinutes + 1;
    final hi = i == 0 ? maxAlertMinutes : _alerts[i - 1].left.inMinutes - 1;
    return (lo, hi);
  }

  /// Cambia cuándo suena el aviso [i] (en minutos antes del final) o cuántas veces vibra.
  void setAlert(int i, {int? minutes, int? pulses}) {
    final a = _alerts[i];
    final (lo, hi) = alertRange(i);
    final list = [..._alerts];
    list[i] = TimerAlert(
      minutes == null ? a.left : Duration(minutes: minutes.clamp(lo, hi)),
      (pulses ?? a.pulses).clamp(0, TimerAlert.maxPulses),
    );
    _alerts = List.unmodifiable(list);
    _prefs?.setString(_kAlerts, _alerts.map((a) => '${a.left.inSeconds}:${a.pulses}').join(','));
    _save(); // los avisos que ya quedaron atrás con el cambio no vibran
  }

  void resetAlerts() {
    _alerts = defaultAlerts;
    _prefs?.remove(_kAlerts);
    _save();
  }

  static List<TimerAlert>? _parseAlerts(String? s) {
    if (s == null) return null;
    final out = <TimerAlert>[];
    for (final part in s.split(',')) {
      final p = part.split(':');
      final sec = p.isNotEmpty ? int.tryParse(p[0]) : null;
      final n = p.length > 1 ? int.tryParse(p[1]) : null;
      if (sec == null || n == null) return null;
      out.add(TimerAlert(Duration(seconds: sec), n.clamp(0, TimerAlert.maxPulses)));
    }
    // Tres avisos, de mayor a menor, el último al terminar
    if (out.length != defaultAlerts.length || out.last.left != Duration.zero) return null;
    for (var i = 1; i < out.length; i++) {
      if (out[i].left >= out[i - 1].left) return null;
    }
    return List.unmodifiable(out);
  }

  /// "vibra con 5 min restantes, con 1 min restantes y al terminar".
  String alertsSummary() {
    final parts = [
      for (final a in _alerts)
        if (a.pulses > 0)
          a.left == Duration.zero
              ? t('al terminar', 'when time is up')
              : t('con ${a.left.inMinutes} min restantes', 'with ${a.left.inMinutes} min left'),
    ];
    if (parts.isEmpty) return t('no vibra', 'does not vibrate');
    final and = t(' y ', ' and ');
    final list = parts.length == 1 ? parts.first : '${parts.take(parts.length - 1).join(', ')}$and${parts.last}';
    return '${t('vibra', 'vibrates')} $list';
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
    return _alerts.where((a) => r <= a.left).length;
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
    if (_alerts[now - 1].left - r < _stale) _vibrate(_alerts[now - 1].pulses);
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
