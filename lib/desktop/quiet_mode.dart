import 'dart:convert';
import 'dart:io';

/// Silencia los avisos de la PC mientras se presenta (los vería el público en el proyector).
///
/// - Linux: GNOME/Ubuntu (gsettings `show-banners`) y XFCE (xfconf `do-not-disturb`). Se guarda
///   cómo estaba en ~/.config/zlide/quiet.json y se restaura al terminar; si la app se cerró de
///   golpe, se restaura al volver a abrirla.
/// - Windows y macOS no dejan que una app active No molestar / Concentración: ellos mismos lo
///   activan al duplicar la pantalla o en pantalla completa (si está configurado así).
abstract final class QuietMode {
  /// Este sistema permite silenciar desde la app.
  static bool get supported => Platform.isLinux;

  static bool _on = false;
  static bool get active => _on;

  static File? get _state {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return File('$base/zlide/quiet.json');
  }

  /// Silenciar. true si se pudo en al menos un escritorio.
  static Future<bool> enable() async {
    if (!supported || _on) return _on;
    final saved = <String, String>{};
    // GNOME, Ubuntu, Budgie…
    final gnome = await _run('gsettings', ['get', 'org.gnome.desktop.notifications', 'show-banners']);
    if (gnome != null && gnome == 'true') {
      if (await _run('gsettings', ['set', 'org.gnome.desktop.notifications', 'show-banners', 'false']) != null) {
        saved['gnome'] = gnome;
      }
    }
    // XFCE
    final xfce = await _run('xfconf-query', ['-c', 'xfce4-notifyd', '-p', '/do-not-disturb']);
    if (xfce != null && xfce != 'true') {
      if (await _run('xfconf-query', ['-c', 'xfce4-notifyd', '-p', '/do-not-disturb', '-n', '-t', 'bool', '-s', 'true']) != null) {
        saved['xfce'] = xfce.isEmpty ? 'false' : xfce;
      }
    }
    // Ya estaban en silencio: no hay nada que restaurar, pero cuenta como silenciado
    _on = saved.isNotEmpty || gnome == 'false' || xfce == 'true';
    if (saved.isNotEmpty) {
      try {
        final f = _state!;
        await f.parent.create(recursive: true);
        await f.writeAsString(jsonEncode(saved), flush: true);
      } catch (_) {}
    }
    return _on;
  }

  /// Dejar los avisos como estaban (también al abrir la app, si quedó pendiente).
  static Future<void> restore() async {
    _on = false;
    if (!supported) return;
    final f = _state;
    if (f == null || !await f.exists()) return;
    try {
      final saved = Map<String, Object?>.from(jsonDecode(await f.readAsString()) as Map);
      if (saved['gnome'] case final String v) {
        await _run('gsettings', ['set', 'org.gnome.desktop.notifications', 'show-banners', v]);
      }
      if (saved['xfce'] case final String v) {
        await _run('xfconf-query', ['-c', 'xfce4-notifyd', '-p', '/do-not-disturb', '-n', '-t', 'bool', '-s', v]);
      }
    } catch (_) {}
    try {
      await f.delete();
    } catch (_) {}
  }

  /// Salida del comando (sin espacios), o null si no existe o falló.
  static Future<String?> _run(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args).timeout(const Duration(seconds: 3));
      return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
    } catch (_) {
      return null;
    }
  }
}
