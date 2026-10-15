import 'package:flutter/material.dart';

/// Paleta "medianoche": azul marino profundo, acento coral para las acciones y verde menta
/// para "conectado".
abstract final class Pal {
  static const bg = Color(0xFF0D1020);
  static const card = Color(0xFF161A2E);
  static const cardHi = Color(0xFF20253D);
  static const stroke = Color(0xFF2C3252);
  static const text = Color(0xFFEEF0FA);
  static const muted = Color(0xFF9097B8);
  static const accent = Color(0xFFFF7A59); // coral
  static const onAccent = Color(0xFF1E0B05);
  static const ok = Color(0xFF3DDC97); // menta
  static const busy = Color(0xFFFFC24B);
  static const error = Color(0xFFFF5C7A);
  static const off = Color(0xFF5A6185);
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
  const scheme = ColorScheme.dark(
    primary: Pal.accent,
    onPrimary: Pal.onAccent,
    secondary: Pal.accent,
    onSecondary: Pal.onAccent,
    surface: Pal.card,
    onSurface: Pal.text,
    error: Pal.error,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: Pal.stroke),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Pal.bg,
    canvasColor: Pal.cardHi,
    splashFactory: InkRipple.splashFactory,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Pal.cardHi,
      contentTextStyle: const TextStyle(color: Pal.text, fontSize: 15),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Pal.stroke),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Pal.cardHi,
      hintStyle: const TextStyle(color: Pal.off),
      labelStyle: const TextStyle(color: Pal.muted),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: const BorderSide(color: Pal.accent)),
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
          style: const TextStyle(
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
                style: const TextStyle(color: Pal.muted, fontSize: 12),
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
        side: primary ? BorderSide.none : const BorderSide(color: Pal.stroke),
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
