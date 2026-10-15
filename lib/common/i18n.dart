import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Idioma elegido en Ajustes. [system] = el del sistema (si no es español, inglés).
enum LangPref { system, es, en }

/// Idiomas de la app: español e inglés.
///
/// Los textos se escriben en los dos idiomas donde se usan: `t('Conectar', 'Connect')`.
/// Así no hay archivos de traducción que mantener aparte y se ve qué dice cada texto.
abstract final class I18n {
  static const _key = 'lang';

  /// Idioma en uso: 'es' o 'en'. La interfaz escucha este valor para redibujarse.
  static final ValueNotifier<String> current = ValueNotifier(_fromSystem());

  static LangPref pref = LangPref.system;

  static bool get es => current.value == 'es';

  /// Leer la preferencia guardada (llamar antes de runApp).
  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      pref = LangPref.values.firstWhere((v) => v.name == p.getString(_key), orElse: () => LangPref.system);
    } catch (_) {
      pref = LangPref.system;
    }
    _apply();
  }

  static Future<void> setPref(LangPref p) async {
    pref = p;
    _apply();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, p.name);
    } catch (_) {}
  }

  /// El usuario cambió el idioma del sistema mientras la app estaba abierta.
  static void systemChanged() {
    if (pref == LangPref.system) _apply();
  }

  static void _apply() {
    current.value = switch (pref) {
      LangPref.es => 'es',
      LangPref.en => 'en',
      LangPref.system => _fromSystem(),
    };
  }

  static String _fromSystem() {
    try {
      return PlatformDispatcher.instance.locale.languageCode.toLowerCase() == 'es' ? 'es' : 'en';
    } catch (_) {
      return 'en';
    }
  }
}

/// Texto en el idioma actual: `t('Siguiente', 'Next')`.
String t(String es, String en) => I18n.es ? es : en;
