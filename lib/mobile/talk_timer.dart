import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cronómetro de la presentación. Solo se ve en el teléfono.
///
/// Guarda la hora de inicio, no un contador: sigue contando bien aunque salgas de la app,
/// bloquees el teléfono o el sistema la cierre.
class TalkTimer extends ChangeNotifier {
  static const _kStart = 'timer_start'; // ms desde época cuando se reanudó; 0 = en pausa
  static const _kAcc = 'timer_acc'; // ms acumulados antes de la última reanudación

  SharedPreferences? _prefs;
  int _startedAt = 0;
  int _accumulated = 0;

  bool get running => _startedAt > 0;
  bool get isZero => !running && _accumulated == 0;

  Duration get elapsed {
    final live = running ? DateTime.now().millisecondsSinceEpoch - _startedAt : 0;
    return Duration(milliseconds: _accumulated + (live < 0 ? 0 : live));
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _startedAt = _prefs!.getInt(_kStart) ?? 0;
    _accumulated = _prefs!.getInt(_kAcc) ?? 0;
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

  void _save() {
    _prefs?.setInt(_kStart, _startedAt);
    _prefs?.setInt(_kAcc, _accumulated);
    notifyListeners();
  }

  /// 7:05 · 1:02:09
  static String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }
}
