import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colores de un tema. Naranja de software de presentación como acento, con tonos cálidos
/// claros (tema claro) u oscuros (tema oscuro).
class Palette {
  const Palette({
    required this.dark,
    required this.bg,
    required this.card,
    required this.cardHi,
    required this.stroke,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.ok,
    required this.busy,
    required this.error,
    required this.off,
  });
  final bool dark;
  final Color bg, card, cardHi, stroke, text, muted, accent, onAccent, ok, busy, error, off;

  static const darkPalette = Palette(
    dark: true,
    bg: Color(0xFF141110),
    card: Color(0xFF1F1A18),
    cardHi: Color(0xFF2B2421),
    stroke: Color(0xFF3B322E),
    text: Color(0xFFF7F1ED),
    muted: Color(0xFFB4A69E),
    accent: Color(0xFFF26522), // naranja
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF3FD48A),
    busy: Color(0xFFFFC24B),
    error: Color(0xFFFF5E6C),
    off: Color(0xFF6F635C),
  );

  static const lightPalette = Palette(
    dark: false,
    bg: Color(0xFFFFF7F2),
    card: Color(0xFFFFFFFF),
    cardHi: Color(0xFFFCEBE1),
    stroke: Color(0xFFF0D9CC),
    text: Color(0xFF2B1A12),
    muted: Color(0xFF7C665A),
    accent: Color(0xFFD9480F), // naranja (más profundo para que se lea sobre blanco)
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF16955A),
    busy: Color(0xFFB97800),
    error: Color(0xFFD42A3C),
    off: Color(0xFFB3A196),
  );
}

/// Colores del tema en uso. Cambian al elegir claro/oscuro (la app se redibuja completa).
abstract final class Pal {
  static Palette p = Palette.darkPalette;
  static Color get bg => p.bg;
  static Color get card => p.card;
  static Color get cardHi => p.cardHi;
  static Color get stroke => p.stroke;
  static Color get text => p.text;
  static Color get muted => p.muted;
  static Color get accent => p.accent;
  static Color get onAccent => p.onAccent;
  static Color get ok => p.ok;
  static Color get busy => p.busy;
  static Color get error => p.error;
  static Color get off => p.off;
}

/// Tema elegido en Ajustes. [system] = claro u oscuro según el sistema.
enum ThemePref { system, light, dark }

abstract final class AppTheme {
  static const _key = 'theme';
  static ThemePref pref = ThemePref.system;

  /// (preferencia, ¿oscuro?). La interfaz escucha este valor para redibujarse.
  static final ValueNotifier<(ThemePref, bool)> state = ValueNotifier((ThemePref.system, true));

  static bool get dark => state.value.$2;

  static Future<void> load() async {
    try {
      // Con límite de tiempo: si las preferencias fallan, la app abre igual con lo predeterminado
      final p = await SharedPreferences.getInstance().timeout(const Duration(seconds: 2));
      pref = ThemePref.values.firstWhere((v) => v.name == p.getString(_key), orElse: () => ThemePref.system);
    } catch (_) {
      pref = ThemePref.system;
    }
    _apply();
  }

  static Future<void> setPref(ThemePref p) async {
    pref = p;
    _apply();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, p.name);
    } catch (_) {}
  }

  /// El sistema cambió entre claro y oscuro.
  static void systemChanged() {
    if (pref == ThemePref.system) _apply();
  }

  static void _apply() {
    final d = switch (pref) {
      ThemePref.light => false,
      ThemePref.dark => true,
      ThemePref.system => PlatformDispatcher.instance.platformBrightness == Brightness.dark,
    };
    Pal.p = d ? Palette.darkPalette : Palette.lightPalette;
    state.value = (pref, d);
  }
}

enum Conn { off, busy, on, error }

Color connColor(Conn c) => switch (c) {
      Conn.on => Pal.ok,
      Conn.busy => Pal.busy,
      Conn.error => Pal.error,
      Conn.off => Pal.off,
    };

/// Estado que se muestra en la pastilla de arriba.
class ConnView {
  const ConnView(this.conn, this.title, [this.subtitle]);
  final Conn conn;
  final String title;
  final String? subtitle;
}

ThemeData buildTheme() {
  final scheme = (Pal.p.dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
    primary: Pal.accent,
    onPrimary: Pal.onAccent,
    secondary: Pal.accent,
    onSecondary: Pal.onAccent,
    surface: Pal.card,
    onSurface: Pal.text,
    onSurfaceVariant: Pal.muted,
    outline: Pal.stroke,
    error: Pal.error,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: Pal.stroke),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Pal.p.dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: Pal.bg,
    canvasColor: Pal.cardHi,
    splashFactory: InkRipple.splashFactory,
    // Sin color fijo en las llamadas: así la hoja de Ajustes cambia al momento de tema
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: Pal.card,
      modalBackgroundColor: Pal.card,
      dragHandleColor: Pal.off,
    ),
    popupMenuTheme: PopupMenuThemeData(color: Pal.cardHi),
    iconTheme: IconThemeData(color: Pal.text),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Pal.cardHi,
      contentTextStyle: TextStyle(color: Pal.text, fontSize: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Pal.stroke),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Pal.cardHi,
      hintStyle: TextStyle(color: Pal.off),
      labelStyle: TextStyle(color: Pal.muted),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: Pal.accent)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
  );
}

// ============================================================ componentes

class SrCard extends StatelessWidget {
  const SrCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Pal.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Pal.stroke),
        ),
        child: child,
      );
}

class Caption extends StatelessWidget {
  const Caption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            color: Pal.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.3,
          ),
        ),
      );
}

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 9});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 8)],
        ),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.view, {super.key, this.maxWidth = 210});
  final ConnView view;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final sub = view.subtitle;
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Pal.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Pal.stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Dot(connColor(view.conn)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                view.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: view.conn == Conn.on ? Pal.ok : Pal.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ]),
          if (sub != null && sub.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 17, top: 4),
              child: Text(
                sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Pal.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, required this.onTap, this.primary = false, this.icon, this.dense = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Pal.onAccent : Pal.text;
    return Material(
      color: primary ? Pal.accent : Pal.cardHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: primary ? BorderSide.none : BorderSide(color: Pal.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 10 : 13),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selector tipo pestañas.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.values, required this.labels, required this.selected, required this.onChanged});
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Pal.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Pal.stroke),
        ),
        child: Row(children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(values[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: values[i] == selected ? Pal.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: values[i] == selected ? Pal.onAccent : Pal.muted,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}

const monoStyle = TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Menlo', 'Consolas', 'Courier']);
