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
    final fg = running ? Pal.accent : (tm.isZero ? Pal.muted : Pal.text);
    final size = widget.big ? 20.0 : 16.0;
    return Material(
      color: running ? Pal.accent.withValues(alpha: 0.12) : Pal.card,
      shape: StadiumBorder(side: BorderSide(color: running ? Pal.accent.withValues(alpha: 0.55) : Pal.stroke)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            tm.toggle();
          },
          child: Tooltip(
            message: running ? t('Pausar cronómetro', 'Pause timer') : t('Iniciar cronómetro', 'Start timer'),
            child: Padding(
              padding: EdgeInsets.fromLTRB(10, widget.big ? 9 : 7, tm.isZero || running ? 14 : 6, widget.big ? 9 : 7),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(running ? Icons.pause_rounded : Icons.timer_outlined, size: size + 2, color: fg),
                const SizedBox(width: 6),
                Text(
                  TalkTimer.format(tm.elapsed),
                  style: monoStyle.copyWith(
                    color: fg,
                    fontSize: size,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ]),
            ),
          ),
        ),
        if (!running && !tm.isZero)
          InkWell(
            onTap: () {
              HapticFeedback.mediumImpact();
              tm.reset();
            },
            child: Tooltip(
              message: t('Reiniciar cronómetro', 'Reset timer'),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
                child: Icon(Icons.restart_alt_rounded, size: size + 2, color: Pal.muted),
              ),
            ),
          ),
      ]),
    );
  }
}
