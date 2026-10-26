import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =====================================================================================
// Sistema de diseño de Zlide — dirección "Foco"
//
// Zlide se usa de pie, frente a un público, en salas con poca luz, mirando el teléfono de reojo:
//  - Neutros fríos (grafito con un toque azul): no deslumbran a oscuras y dejan que el contenido
//    (notas, diapositiva) sea lo más claro de la pantalla.
//  - Índigo "foco": la marca y la única acción principal de cada pantalla (siguiente, empezar,
//    lo elegido). Se usa poco para que siempre signifique "esto".
//  - Contenedores tonales (índigo muy suave) para lo seleccionado; superficies neutras para lo
//    demás. Sin bordes ni sombras salvo donde aclaran qué se puede tocar.
//  - Las notas son lo principal: texto grande y muy legible (Atkinson Hyperlegible) sobre el
//    fondo, sin tarjetas. Los números (diapositiva, tiempo) en tipografías de un vistazo.
//  - Grupos como en iOS (listas redondeadas con divisores interiores) y controles con
//    estados claros como en Material 3. Áreas táctiles de 48 px o más.
// =====================================================================================

/// Colores de un tema (claro u oscuro).
class Palette {
  const Palette({
    required this.dark,
    required this.bg,
    required this.raise,
    required this.raiseHi,
    required this.rule,
    required this.faint,
    required this.ink,
    required this.mute,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.thumb,
    required this.ok,
    required this.busy,
    required this.error,
  });

  final bool dark;

  /// Fondo de la app ("papel" o "tinta").
  final Color bg;

  /// Superficie apenas elevada: botones secundarios, pistas de selectores, hojas.
  final Color raise;
  final Color raiseHi;

  /// Líneas divisorias y pistas vacías.
  final Color rule;

  /// Elementos inactivos (bordes de radios, interruptores apagados, texto deshabilitado).
  final Color faint;

  /// Texto principal y texto secundario.
  final Color ink, mute;

  /// Índigo de la marca (acción principal) y el texto que va encima.
  final Color accent, onAccent;

  /// Contenedor tonal: lo elegido, lo activo (índigo muy suave) y su texto.
  final Color accentSoft, onAccentSoft;

  /// Pastilla de lo elegido en un selector segmentado (como en iOS).
  final Color thumb;

  /// Estados.
  final Color ok, busy, error;

  // Contrastes (WCAG): texto ≥ 16:1, secundario ≥ 5.5:1, acento sobre fondo ≥ 5.8:1,
  // texto sobre el acento ≥ 6.3:1, estados ≥ 4.5:1.
  static const darkPalette = Palette(
    dark: true,
    bg: Color(0xFF0B0D12),
    raise: Color(0xFF151821),
    raiseHi: Color(0xFF1E222D),
    rule: Color(0xFF262A36),
    faint: Color(0xFF474D5E),
    ink: Color(0xFFECEEF4),
    mute: Color(0xFF969CAE),
    accent: Color(0xFF8F8EFF),
    onAccent: Color(0xFF0E0D33),
    accentSoft: Color(0xFF25244F),
    onAccentSoft: Color(0xFFDCDBFF),
    thumb: Color(0xFF343949),
    ok: Color(0xFF4ADE80),
    busy: Color(0xFFFBBF24),
    error: Color(0xFFFF6B6B),
  );

  static const lightPalette = Palette(
    dark: false,
    bg: Color(0xFFF3F4F8),
    raise: Color(0xFFFFFFFF),
    raiseHi: Color(0xFFE9EBF1),
    rule: Color(0xFFE2E5EC),
    faint: Color(0xFFB9BECB),
    ink: Color(0xFF11131A),
    mute: Color(0xFF5C6273),
    accent: Color(0xFF4D47E0),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE4E3FF),
    onAccentSoft: Color(0xFF1F1A7A),
    thumb: Color(0xFFFFFFFF),
    ok: Color(0xFF0F7F44),
    busy: Color(0xFFB25E09),
    error: Color(0xFFD3263A),
  );
}

/// Colores del tema en uso. Cambian al elegir claro/oscuro (la app se redibuja completa).
///
/// Los nombres antiguos (card, cardHi, stroke, text, muted, off) se conservan para las
/// pantallas que todavía no se rediseñan.
abstract final class Pal {
  static Palette p = Palette.darkPalette;
  static Color get bg => p.bg;
  static Color get raise => p.raise;
  static Color get raiseHi => p.raiseHi;
  static Color get rule => p.rule;
  static Color get faint => p.faint;
  static Color get ink => p.ink;
  static Color get accent => p.accent;
  static Color get onAccent => p.onAccent;
  static Color get accentSoft => p.accentSoft;
  static Color get onAccentSoft => p.onAccentSoft;
  static Color get thumb => p.thumb;
  static Color get ok => p.ok;
  static Color get busy => p.busy;
  static Color get error => p.error;

  static Color get card => p.raise;
  static Color get cardHi => p.raiseHi;
  static Color get stroke => p.rule;
  static Color get text => p.ink;
  static Color get muted => p.mute;
  static Color get off => p.faint;
}

/// Espaciado (múltiplos de 4).
abstract final class Sp {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;

  /// Margen lateral de las pantallas del teléfono.
  static const page = 20.0;
}

/// Puntos de quiebre por ancho disponible (px lógicos), los de Material 3.
abstract final class Bp {
  /// Desde aquí: tableta vertical o ventana mediana.
  static const medium = 600.0;

  /// Desde aquí: tableta horizontal, laptop. Hay espacio para dos paneles.
  static const expanded = 840.0;

  /// Ancho máximo de una columna: más ancha, los renglones y botones se estiran de más.
  static const column = 720.0;
}

/// Limita el ancho de [child] y lo centra arriba (pantallas anchas).
class MaxWidth extends StatelessWidget {
  const MaxWidth({super.key, required this.child, this.max = Bp.column});
  final Widget child;
  final double max;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: max), child: child),
      );
}

/// Dos botones lado a lado; uno debajo del otro si así no caben (pantalla angosta o texto grande).
class ButtonPair extends StatelessWidget {
  const ButtonPair(this.first, this.second, {super.key, this.minEach = 150});
  final Widget first, second;

  /// Ancho mínimo de cada botón (con texto al 100 %) para ir lado a lado.
  final double minEach;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final need = MediaQuery.textScalerOf(context).scale(minEach) * 2 + Sp.s + 2;
        if (box.maxWidth >= need) {
          return Row(children: [Expanded(child: first), const SizedBox(width: Sp.s + 2), Expanded(child: second)]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [first, const SizedBox(height: Sp.s), second]);
      });
}

/// Radios de las formas.
abstract final class Rad {
  static const s = 10.0; // chips, campos pequeños
  static const m = 16.0; // botones, selectores, campos
  static const l = 22.0; // hojas, superficies grandes
  static const xl = 28.0; // botones de cambiar diapositiva
}

/// Movimiento: corto y funcional. Respeta "reducir animaciones" del sistema.
abstract final class Mo {
  static const fast = Duration(milliseconds: 140);
  static const med = Duration(milliseconds: 240);
  static const curve = Curves.easeOutCubic;

  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;
}

/// Tipografías (incluidas en la app, licencia OFL):
///  - Bricolage Grotesque condensada: número de diapositiva, títulos y botones.
///  - Atkinson Hyperlegible Next: texto y notas (diseñada para leerse con facilidad).
///  - Atkinson Hyperlegible Mono: tiempo, direcciones IP y contadores.
abstract final class Txt {
  static const display = 'ZlideDisplay';
  static const headline = 'ZlideHeadline';
  static const body = 'Atkinson';
  static const mono = 'AtkinsonMono';

  static const _tabular = [FontFeature.tabularFigures()];

  /// Número grande de la diapositiva.
  static TextStyle number(double size) =>
      TextStyle(fontFamily: display, fontSize: size, height: 0.9, letterSpacing: -size * 0.03, color: Pal.ink);

  /// Títulos de pantalla y de diapositiva.
  static TextStyle title(double size, {Color? color}) =>
      TextStyle(fontFamily: headline, fontSize: size, height: 1.12, letterSpacing: -size * 0.01, color: color ?? Pal.ink);

  /// Texto corrido.
  static TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color? color, double height = 1.45}) =>
      TextStyle(fontFamily: body, fontSize: size, fontWeight: weight, height: height, color: color ?? Pal.ink);

  /// Números y direcciones.
  static TextStyle digits(double size, {FontWeight weight = FontWeight.w700, Color? color}) =>
      TextStyle(fontFamily: mono, fontSize: size, fontWeight: weight, color: color ?? Pal.ink, fontFeatures: _tabular);

  /// Rótulos de sección en mayúsculas.
  static TextStyle get caption =>
      TextStyle(fontFamily: body, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.0, color: Pal.muted);
}

/// Compatibilidad: estilo de ancho fijo para pantallas antiguas.
const monoStyle = TextStyle(
  fontFamily: Txt.mono,
  fontFamilyFallback: ['monospace', 'Menlo', 'Consolas', 'Courier'],
  fontFeatures: [FontFeature.tabularFigures()],
);

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
      Conn.off => Pal.faint,
    };

/// Estado de la conexión que se muestra arriba.
class ConnView {
  const ConnView(this.conn, this.title, [this.subtitle]);
  final Conn conn;
  final String title;
  final String? subtitle;
}

ThemeData buildTheme() {
  final p = Pal.p;
  final scheme = (p.dark ? const ColorScheme.dark() : const ColorScheme.light()).copyWith(
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.onAccentSoft,
    // Botones tonales y chips elegidos: índigo suave de la marca (no el verde azulado por defecto)
    secondaryContainer: p.accentSoft,
    onSecondaryContainer: p.onAccentSoft,
    surface: p.bg,
    onSurface: p.ink,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.raise,
    surfaceContainer: p.raise,
    surfaceContainerHigh: p.raiseHi,
    surfaceContainerHighest: p.raiseHi,
    onSurfaceVariant: p.mute,
    outline: p.faint,
    outlineVariant: p.rule,
    error: p.error,
  );
  final base = ThemeData(useMaterial3: true, brightness: p.dark ? Brightness.dark : Brightness.light);
  final textTheme = base.textTheme
      .apply(fontFamily: Txt.body, bodyColor: p.ink, displayColor: p.ink)
      .copyWith(
        displayLarge: Txt.number(76),
        headlineMedium: Txt.title(28),
        headlineSmall: Txt.title(24),
        titleLarge: Txt.title(21),
        titleMedium: Txt.text(16, weight: FontWeight.w600, height: 1.3),
        titleSmall: Txt.text(14, weight: FontWeight.w600, height: 1.3),
        bodyLarge: Txt.text(17),
        bodyMedium: Txt.text(15),
        bodySmall: Txt.text(13, color: p.mute),
        labelLarge: Txt.title(17),
        labelMedium: Txt.text(13, weight: FontWeight.w600),
      );
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Rad.m),
    borderSide: BorderSide.none,
  );
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.m));
  return ThemeData(
    useMaterial3: true,
    brightness: p.dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    fontFamily: Txt.body,
    textTheme: textTheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: p.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    dividerTheme: DividerThemeData(color: p.rule, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.ink),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: p.rule),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: Txt.title(17),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        minimumSize: const Size(48, 48),
        textStyle: Txt.text(15, weight: FontWeight.w600),
        shape: buttonShape,
      ),
    ),
    // Sin color fijo: los normales usan onSurfaceVariant (tenue) y los rellenos/tonales el suyo
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.mute),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.raiseHi),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.faint),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.faint),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: Sp.m,
      titleTextStyle: Txt.text(16, weight: FontWeight.w600, height: 1.3),
      subtitleTextStyle: Txt.text(13, color: p.mute, height: 1.35),
      iconColor: p.mute,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      modalBackgroundColor: p.bg,
      dragHandleColor: p.faint,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Rad.l))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.l)),
      titleTextStyle: Txt.title(22),
      contentTextStyle: Txt.text(15, color: p.mute),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.raise,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.m)),
      textStyle: Txt.text(15),
      // Material 3 toma el texto de aquí (si no, usa labelLarge, la tipografía de títulos)
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => Txt.text(15, color: s.contains(WidgetState.disabled) ? p.faint : p.ink),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(Rad.s)),
      textStyle: Txt.text(13, color: p.bg, height: 1.3),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: Txt.text(15, color: p.bg, height: 1.35),
      actionTextColor: p.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.m)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.raise,
      hintStyle: Txt.text(16, color: p.faint),
      labelStyle: Txt.text(15, color: p.mute),
      floatingLabelStyle: Txt.text(15, color: p.accent),
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(borderSide: BorderSide(color: p.accent, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.l),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(textStyle: Txt.text(16)),
  );
}

// ============================================================ componentes

/// Superficie apenas elevada, sin borde. Para agrupar cuando el espacio no basta.
class SrCard extends StatelessWidget {
  const SrCard({super.key, required this.child, this.padding = const EdgeInsets.all(Sp.l)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(color: Pal.raise, borderRadius: BorderRadius.circular(Rad.l)),
        child: child,
      );
}

/// Rótulo de sección.
class Caption extends StatelessWidget {
  const Caption(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Sp.s),
        child: Text(text.toUpperCase(), style: Txt.caption),
      );
}

/// Punto de estado con un halo suave.
class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: Mo.of(context, Mo.med),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.22), spreadRadius: size * 0.5)],
        ),
      );
}

/// Botón de acción. [primary]: índigo (la acción principal); si no, superficie neutra.
class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, required this.onTap, this.primary = false, this.icon, this.dense = false});
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = primary ? Pal.onAccent : Pal.ink;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        // raiseHi y no raise: se distingue tanto sobre el fondo como dentro de un grupo
        color: primary ? Pal.accent : Pal.raiseHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Rad.m)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: dense ? 44 : 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: Sp.s)],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Txt.title(dense ? 15.5 : 17, color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Selector de opciones en una pista, como el control segmentado de iOS: la opción elegida es
/// una pastilla que se desliza. [accent]: la pastilla va en índigo suave (ajustes que cambian
/// algo de la presentación); si no, neutra.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.accent = false,
  });
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final index = values.indexOf(selected);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Pal.raiseHi, borderRadius: BorderRadius.circular(Rad.m)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / values.length;
        return Stack(children: [
          // Pastilla de la opción elegida: se desliza al cambiar
          if (index >= 0)
            AnimatedPositioned(
              duration: Mo.of(context, Mo.med),
              curve: Curves.easeOutBack,
              left: w * index,
              top: 0,
              bottom: 0,
              width: w,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: accent ? Pal.accentSoft : Pal.thumb,
                  borderRadius: BorderRadius.circular(Rad.m - 3),
                  boxShadow: Pal.p.dark || accent
                      ? null
                      : [BoxShadow(color: Pal.ink.withValues(alpha: 0.10), blurRadius: 6, offset: const Offset(0, 1))],
                ),
              ),
            ),
          Row(children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == index,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (i != index) HapticFeedback.selectionClick();
                      onChanged(values[i]);
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: Sp.s, horizontal: Sp.xs),
                      child: AnimatedDefaultTextStyle(
                        duration: Mo.of(context, Mo.fast),
                        style: Txt.text(
                          14,
                          weight: i == index ? FontWeight.w700 : FontWeight.w600,
                          height: 1.2,
                          color: i == index ? (accent ? Pal.onAccentSoft : Pal.ink) : Pal.muted,
                        ),
                        child: Text(labels[i], textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

/// Grupo de filas (ajustes, listas): un rótulo y una superficie redondeada con líneas entre filas.
class Panel extends StatelessWidget {
  const Panel({super.key, this.title, required this.children, this.footer});
  final String? title;
  final List<Widget> children;

  /// Nota debajo del grupo.
  final String? footer;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.xs, 0, Sp.xs, Sp.s),
            child: Text(title!.toUpperCase(), style: Txt.caption),
          ),
        Material(
          color: Pal.raise,
          borderRadius: BorderRadius.circular(Rad.l),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: Sp.l, endIndent: Sp.l, color: Pal.bg.withValues(alpha: 0.9)),
              children[i],
            ],
          ]),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.xs, 0),
            child: Text(footer!, style: Txt.text(13, color: Pal.muted, height: 1.4)),
          ),
      ]);
}
