import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'talk_timer.dart';

/// Cronómetro compacto: toca para iniciar o pausar; con el cronómetro en pausa aparece ↺ para
/// reiniciarlo.
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
    final fg = running ? Pal.accent : (tm.isZero ? Pal.muted : Pal.ink);
    final size = widget.big ? 20.0 : 17.0;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        button: true,
        label: running ? t('Pausar cronómetro', 'Pause timer') : t('Iniciar cronómetro', 'Start timer'),
        child: InkWell(
          borderRadius: BorderRadius.circular(Rad.s),
          onTap: () {
            HapticFeedback.selectionClick();
            tm.toggle();
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
                    color: running ? Pal.accent : Colors.transparent,
                    border: Border.all(color: running ? Pal.accent : Pal.faint, width: 1.5),
                  ),
                ),
                const SizedBox(width: Sp.s),
                Text(TalkTimer.format(tm.elapsed), style: Txt.digits(size, color: fg)),
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
