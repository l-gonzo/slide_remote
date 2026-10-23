import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'talk_timer.dart';

/// Cronómetro compacto: toca para iniciar o pausar; con el cronómetro en pausa aparece ↺ para
/// reiniciarlo. Mantén presionado para elegir el tiempo objetivo.
class TimerChip extends StatefulWidget {
  const TimerChip(this.timer, {super.key, this.big = false});
  final TalkTimer timer;
  final bool big;

  @override
  State<TimerChip> createState() => _TimerChipState();
}

class _TimerChipState extends State<TimerChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.timer.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(TimerChip old) {
    super.didUpdateWidget(old);
    if (old.timer != widget.timer) {
      old.timer.removeListener(_sync);
      widget.timer.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.timer.removeListener(_sync);
    _tick?.cancel();
    super.dispose();
  }

  void _sync() {
    if (widget.timer.running) {
      _tick ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tm = widget.timer;
    final running = tm.running;
    // En marcha: naranja con su punto ("al aire"). Detenido: tinta tenue.
    // Con objetivo: ámbar en los últimos 5 minutos y rojo en el último.
    final fg = switch (tm.phase) {
      TimerPhase.last when !tm.isZero => Pal.error,
      TimerPhase.warn when !tm.isZero => Pal.busy,
      _ => running ? Pal.accent : (tm.isZero ? Pal.muted : Pal.ink),
    };
    final size = widget.big ? 20.0 : 17.0;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        button: true,
        label: running ? t('Pausar cronómetro', 'Pause timer') : t('Iniciar cronómetro', 'Start timer'),
        onLongPressHint: t('Tiempo objetivo', 'Target time'),
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s),
          onTap: () {
            HapticFeedback.selectionClick();
            tm.toggle();
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            showTargetPicker(context, tm);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.s),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AnimatedContainer(
                  duration: Mo.of(context, Mo.fast),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: running ? fg : Colors.transparent,
                    border: Border.all(color: running ? fg : Pal.faint, width: 1.5),
                  ),
                ),
                const SizedBox(width: Sp.s),
                AnimatedDefaultTextStyle(
                  duration: Mo.of(context, Mo.med),
                  style: Txt.digits(size, color: fg),
                  child: Text(tm.label),
                ),
              ]),
            ),
          ),
        ),
      ),
      if (!running && !tm.isZero)
        IconButton(
          onPressed: () {
            HapticFeedback.mediumImpact();
            tm.reset();
          },
          tooltip: t('Reiniciar cronómetro', 'Reset timer'),
          icon: Icon(Icons.restart_alt_rounded, size: size + 2, color: Pal.muted),
        ),
    ]);
  }
}

/// Hoja para elegir el tiempo objetivo (mantener presionado el cronómetro, o desde Ajustes).
Future<void> showTargetPicker(BuildContext context, TalkTimer tm) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true, // si no, en teléfonos chicos el botón "Usar" queda fuera de vista
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.88),
        child: _TargetSheet(tm),
      ),
    );

class _TargetSheet extends StatefulWidget {
  const _TargetSheet(this.tm);
  final TalkTimer tm;

  @override
  State<_TargetSheet> createState() => _TargetSheetState();
}

class _TargetSheetState extends State<_TargetSheet> {
  static const _presets = [5, 10, 15, 20, 30, 45, 60];
  late int _min = widget.tm.target?.inMinutes ?? 15;

  void _set(int m) {
    HapticFeedback.selectionClick();
    setState(() => _min = m.clamp(1, 180));
  }

  @override
  Widget build(BuildContext context) {
    final tm = widget.tm;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t('Tiempo objetivo', 'Target time'), style: Txt.title(26)),
          const SizedBox(height: Sp.s),
          Text(
            t('El cronómetro cuenta hacia atrás y pasa a ámbar y luego a rojo. El teléfono ${tm.alertsSummary()} '
                '(se cambia en Ajustes).',
                'The timer counts down and turns amber, then red. The phone ${tm.alertsSummary()} '
                '(change it in Settings).'),
            style: Txt.text(15, color: Pal.muted),
          ),
          const SizedBox(height: Sp.l),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton.filledTonal(
              onPressed: () => _set(_min - 1),
              tooltip: t('Un minuto menos', 'One minute less'),
              icon: const Icon(Icons.remove_rounded),
            ),
            // Una sola línea aunque el texto del sistema sea grande
            Flexible(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.l),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('$_min min', maxLines: 1, style: Txt.digits(34, color: Pal.accent)),
                ),
              ),
            ),
            IconButton.filledTonal(
              onPressed: () => _set(_min + 1),
              tooltip: t('Un minuto más', 'One minute more'),
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          const SizedBox(height: Sp.l),
          Wrap(spacing: Sp.s, runSpacing: Sp.s, alignment: WrapAlignment.center, children: [
            for (final m in _presets)
              ChoiceChip(label: Text('$m min'), selected: _min == m, onSelected: (_) => _set(m)),
          ]),
          const SizedBox(height: Sp.xl),
          PillButton(t('Usar $_min min', 'Use $_min min'), primary: true, onTap: () {
            tm.setTarget(Duration(minutes: _min));
            Navigator.pop(context);
          }),
          if (tm.target != null) ...[
            const SizedBox(height: Sp.s),
            PillButton(t('Sin objetivo', 'No target'), onTap: () {
              tm.setTarget(null);
              Navigator.pop(context);
            }),
          ],
        ]),
      ),
    );
  }
}
