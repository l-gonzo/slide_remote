import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/theme.dart';

// =====================================================================================
// Piezas de la pantalla de presentar: botones de cambiar diapositiva, barra de acciones,
// barra de pantalla bloqueada y progreso. Todas se acomodan según la mano dominante.
// =====================================================================================

/// Una acción de la barra (ícono y rótulo corto).
class StageAction {
  const StageAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Encendida (p. ej. notas expandidas): va en el contenedor tonal de la marca.
  final bool active;
  final String? tooltip;
}

/// Barra de acciones encima de los botones de cambiar diapositiva. [leftHanded] invierte el
/// orden: lo primero de [actions] queda más cerca del pulgar.
class ActionBar extends StatelessWidget {
  const ActionBar({
    super.key,
    required this.actions,
    required this.leftHanded,
    this.dense = false,
    this.vertical = false,
  });
  final List<StageAction> actions;
  final bool leftHanded;

  /// Solo íconos (poca altura).
  final bool dense;

  /// En columna (riel del teléfono acostado): lo primero de [actions] queda abajo, junto a
  /// los botones de cambiar diapositiva.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    // Lo más usado, del lado de la mano: a la derecha para diestros
    final ordered = vertical || !leftHanded ? actions.reversed.toList() : actions;
    return Container(
      padding: const EdgeInsets.all(Sp.xs),
      decoration: BoxDecoration(
        color: Pal.raise,
        borderRadius: BorderRadius.circular(Rad.l),
      ),
      child: vertical
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final a in ordered) _ActionButton(a, dense: dense),
            ])
          : Row(children: [
              for (final a in ordered) Expanded(child: _ActionButton(a, dense: dense)),
            ]),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton(this.a, {required this.dense});
  final StageAction a;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final enabled = a.onTap != null;
    final fg = !enabled ? Pal.faint : (a.active ? Pal.onAccentSoft : Pal.ink);
    return Semantics(
      button: true,
      selected: a.active,
      label: a.tooltip ?? a.label,
      excludeSemantics: true,
      child: Tooltip(
        message: a.tooltip ?? a.label,
        child: Material(
          color: a.active ? Pal.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(Rad.l - Sp.xs),
          child: InkWell(
            borderRadius: BorderRadius.circular(Rad.l - Sp.xs),
            onTap: enabled
                ? () {
                    HapticFeedback.selectionClick();
                    a.onTap!();
                  }
                : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: dense ? 44 : 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: Sp.xs),
                child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(a.icon, size: 22, color: fg),
                  if (!dense) ...[
                    const SizedBox(height: 3),
                    Text(
                      a.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Txt.text(11.5, weight: FontWeight.w600, color: fg, height: 1.1),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Con la pantalla bloqueada: aviso y desbloqueo manteniendo presionado (un roce no basta).
class LockBar extends StatefulWidget {
  const LockBar({super.key, required this.onUnlock, this.dense = false});
  final VoidCallback onUnlock;
  final bool dense;

  @override
  State<LockBar> createState() => _LockBarState();
}

class _LockBarState extends State<LockBar> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onUnlock();
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _down() {
    HapticFeedback.selectionClick();
    _hold.forward(from: 0);
  }

  void _up() {
    if (_hold.status != AnimationStatus.completed) _hold.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: t('Pantalla bloqueada. Mantén presionado para desbloquear', 'Screen locked. Press and hold to unlock'),
      excludeSemantics: true,
      onLongPress: widget.onUnlock,
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) => Container(
            constraints: BoxConstraints(minHeight: widget.dense ? 44 : 64),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Rad.l),
              color: Pal.raise,
              border: Border.all(color: Color.lerp(Pal.rule, Pal.accent, _hold.value)!, width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              // Se llena mientras se mantiene presionado
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _hold.value,
                  child: ColoredBox(color: Pal.accent.withValues(alpha: 0.16)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
                child: Row(children: [
                  Icon(_hold.value > 0.5 ? Icons.lock_open_rounded : Icons.lock_rounded, color: Pal.accent, size: 22),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(t('Pantalla bloqueada', 'Screen locked'), style: Txt.text(15, weight: FontWeight.w700, height: 1.2)),
                      if (!widget.dense)
                        Text(
                          t('Usa los botones de volumen · mantén presionado aquí para desbloquear',
                              'Use the volume buttons · press and hold here to unlock'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Txt.text(12.5, color: Pal.muted, height: 1.3),
                        ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Progreso de la presentación: un segmento por diapositiva (o una barra si son muchas).
class SlideProgress extends StatelessWidget {
  const SlideProgress({super.key, required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox(height: 4);
    if (total > 40) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: (current + 1) / total, minHeight: 4),
      );
    }
    return Semantics(
      label: t('Diapositiva ${current + 1} de $total', 'Slide ${current + 1} of $total'),
      child: Row(children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: AnimatedContainer(
              duration: Mo.of(context, Mo.med),
              height: i == current ? 5 : 4,
              decoration: BoxDecoration(
                color: i <= current ? Pal.accent : Pal.rule,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// ==================================================================== botones de navegación

enum PadLayout {
  /// Solo el ícono (botón "anterior" junto a "siguiente").
  icon,

  /// Una línea: ícono y texto.
  compact,

  /// Texto a un lado, flecha al otro (debajo de las notas).
  wide,

  /// Grande (sin notas).
  big,

  /// Angosto y alto (riel del teléfono acostado): flecha grande y el texto debajo.
  rail,
}

/// Botones "anterior" y "siguiente". En fila (debajo de las notas) "siguiente" es ancho y queda
/// del lado de la mano; en columna (sin notas o en tableta) "siguiente" va arriba y es más alto.
class NavPads extends StatelessWidget {
  const NavPads({
    super.key,
    required this.onPrev,
    required this.onNext,
    required this.prevPulse,
    required this.nextPulse,
    required this.prevHint,
    required this.nextHint,
    required this.leftHanded,
    this.vertical = false,
    this.compact = false,
    this.rail = false,
    this.enabled = true,
    this.dim = false,
  });

  final VoidCallback onPrev, onNext;
  final ValueNotifier<int> prevPulse, nextPulse;
  final String prevHint, nextHint;
  final bool leftHanded;
  final bool vertical;
  final bool compact;

  /// En columna angosta (riel del teléfono acostado).
  final bool rail;

  /// false = no responden (pantalla bloqueada).
  final bool enabled;

  /// Atenuados (sin conexión).
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final prev = NavPad(
      primary: false,
      label: t('Anterior', 'Previous'),
      icon: Icons.chevron_left_rounded,
      hint: prevHint,
      pulse: prevPulse,
      layout: rail ? PadLayout.icon : (vertical ? PadLayout.compact : PadLayout.icon),
      onTap: onPrev,
    );
    final next = NavPad(
      primary: true,
      label: t('Siguiente', 'Next'),
      icon: Icons.arrow_forward_rounded,
      hint: nextHint,
      pulse: nextPulse,
      layout: rail ? PadLayout.rail : (vertical ? PadLayout.big : (compact ? PadLayout.compact : PadLayout.wide)),
      onTap: onNext,
    );
    final Widget body = vertical || rail
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 2, child: next),
            const SizedBox(height: Sp.s + 2),
            Expanded(child: prev),
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!leftHanded) ...[SizedBox(width: compact ? 72 : 92, child: prev), const SizedBox(width: Sp.s + 2)],
            Expanded(child: next),
            if (leftHanded) ...[const SizedBox(width: Sp.s + 2), SizedBox(width: compact ? 72 : 92, child: prev)],
          ]);
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        duration: Mo.of(context, Mo.med),
        opacity: dim || !enabled ? 0.45 : 1,
        child: body,
      ),
    );
  }
}

/// Botón de cambiar diapositiva. También se anima cuando la pulsación viene del botón de volumen.
class NavPad extends StatefulWidget {
  const NavPad({
    super.key,
    required this.primary,
    required this.label,
    required this.icon,
    required this.hint,
    required this.pulse,
    required this.onTap,
    required this.layout,
  });

  final bool primary;
  final String label;
  final IconData icon;
  final String hint;
  final ValueNotifier<int> pulse;
  final VoidCallback onTap;
  final PadLayout layout;

  @override
  State<NavPad> createState() => _NavPadState();
}

class _NavPadState extends State<NavPad> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void initState() {
    super.initState();
    widget.pulse.addListener(_onPulse);
  }

  @override
  void didUpdateWidget(NavPad old) {
    super.didUpdateWidget(old);
    if (old.pulse != widget.pulse) {
      old.pulse.removeListener(_onPulse);
      widget.pulse.addListener(_onPulse);
    }
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_onPulse);
    _anim.dispose();
    super.dispose();
  }

  void _onPulse() {
    HapticFeedback.selectionClick();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return;
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.primary ? Pal.onAccent : Pal.ink;
    final bg = widget.primary ? Pal.accent : Pal.raise;
    final radius = BorderRadius.circular(widget.layout == PadLayout.big ? Rad.xl + 4 : Rad.xl - 2);
    return Semantics(
      button: true,
      label: '${widget.label} (${widget.hint})',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          // 0 → 1: se hunde un poco y regresa, con un destello
          final v = _anim.value;
          final k = v < 0.35 ? v / 0.35 : (1 - v) / 0.65;
          return Transform.scale(
            scale: 1 - 0.035 * k,
            child: Stack(fit: StackFit.expand, children: [
              child!,
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: (widget.primary ? Colors.black : Pal.ink).withValues(alpha: 0.16 * k),
                    borderRadius: radius,
                  ),
                ),
              ),
            ]),
          );
        },
        child: Material(
          color: bg,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: widget.onTap, child: _content(fg)),
        ),
      ),
    );
  }

  Widget _content(Color fg) {
    final hint = Text(widget.hint, style: Txt.digits(12, color: fg.withValues(alpha: 0.75), weight: FontWeight.w500));
    switch (widget.layout) {
      case PadLayout.rail:
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(Sp.s),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.icon, size: 40, color: fg),
                const SizedBox(height: Sp.xs),
                Text(widget.label, style: Txt.title(17, color: fg)),
                hint,
              ]),
            ),
          ),
        );
      case PadLayout.icon:
        return Center(child: Icon(widget.icon, size: 34, color: fg));
      case PadLayout.compact:
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.icon, size: 26, color: fg),
                const SizedBox(width: Sp.s),
                Text(widget.label, style: Txt.title(19, color: fg)),
              ]),
            ),
          ),
        );
      case PadLayout.wide:
      case PadLayout.big:
        final big = widget.layout == PadLayout.big;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: big ? Sp.xxl - 4 : Sp.xl),
          child: Row(children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.label, style: Txt.title(big ? 36 : 26, color: fg)),
                  const SizedBox(height: 2),
                  hint,
                ]),
              ),
            ),
            Icon(widget.icon, size: big ? 48 : 36, color: fg),
          ]),
        );
    }
  }
}

/// Fila de ajuste: título, descripción y lo que va a la derecha (interruptor, flecha…).
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.below,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Contenido debajo del texto (selector, deslizador).
  final Widget? below;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m + 2),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (icon != null) ...[
                // Mosaico tonal de la marca, como los íconos de Ajustes en iOS
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: Pal.accentSoft, borderRadius: BorderRadius.circular(Rad.s)),
                  child: Icon(icon, size: 19, color: Pal.onAccentSoft),
                ),
                const SizedBox(width: Sp.m + 2),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Txt.text(16, weight: FontWeight.w600, height: 1.3)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: Txt.text(13.5, color: Pal.muted, height: 1.35)),
                  ],
                ]),
              ),
              if (trailing != null) ...[const SizedBox(width: Sp.m), trailing!],
            ]),
            if (below != null) ...[const SizedBox(height: Sp.m), below!],
          ]),
        ),
      );
}

/// Interruptor con el estilo de las filas de ajuste.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.subtitle, this.icon, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: SettingRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          onTap: onChanged == null ? null : () => onChanged!(!value),
          trailing: Switch(value: value, onChanged: onChanged),
        ),
      );
}
