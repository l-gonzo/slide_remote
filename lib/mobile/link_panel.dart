import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'draw_source.dart';

/// Controles del enlace abierto en la PC (va en lugar de la diapositiva en la vista de dibujo):
///  - página: deslizar para desplazarla, sus enlaces visibles, atrás, inicio;
///  - video de YouTube: reproducir, pausar, adelantar, regresar, silenciar;
///  - ventana aparte: solo cerrarla.
/// "Cerrar" (o "siguiente") regresa a la presentación.
class LinkPanel extends StatelessWidget {
  const LinkPanel({super.key, required this.src, required this.link});
  final DrawSource src;
  final Map<String, Object?> link;

  String get _kind => link['kind'] as String? ?? 'page';
  String get _url => link['url'] as String? ?? '';

  String get _host {
    final h = Uri.tryParse(_url)?.host ?? '';
    return h.isEmpty ? _url : h.replaceFirst('www.', '');
  }

  void _ctl(Map<String, Object?> op) {
    HapticFeedback.selectionClick();
    src.linkCtl(op);
  }

  @override
  Widget build(BuildContext context) {
    final title = (link['title'] as String? ?? '').trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Pal.raise,
        borderRadius: BorderRadius.circular(Rad.m),
        border: Border.all(color: Pal.accent, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Sp.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(switch (_kind) {
                  'video' => Icons.smart_display_rounded,
                  'window' => Icons.open_in_new_rounded,
                  _ => Icons.public_rounded,
                }, color: Pal.accent),
                const SizedBox(width: Sp.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isEmpty ? _host : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Txt.text(15, weight: FontWeight.w700, height: 1.25),
                      ),
                      Text(
                        title.isEmpty ? t('Abierto en la PC', 'Open on the computer') : _host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Txt.text(12.5, color: Pal.muted, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Sp.s),
                FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    src.closeLink();
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(t('Cerrar', 'Close')),
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
            const SizedBox(height: Sp.m),
            Expanded(
              child: switch (_kind) {
                'video' => _video(),
                'window' => Center(
                  child: Text(
                    t(
                      'Se abrió en una ventana en la PC. Ciérrala aquí para volver a la presentación.',
                      'It opened in a window on the computer. Close it here to return to the presentation.',
                    ),
                    textAlign: TextAlign.center,
                    style: Txt.text(14, color: Pal.muted),
                  ),
                ),
                _ => _page(),
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- página

  Widget _page() {
    final links = [
      for (final l in (link['links'] as List? ?? const []))
        if (l is Map && l['text'] is String) (i: (l['i'] as num).toInt(), text: l['text'] as String),
    ];
    final canBack = link['canBack'] == true;
    Widget btn(IconData icon, String tip, VoidCallback? onTap) =>
        IconButton.filledTonal(onPressed: onTap, icon: Icon(icon), tooltip: tip);
    // Botones en una fila debajo del área para deslizar: en una columna al lado, con poca
    // altura, se encimaban con los enlaces de la página
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _Touchpad(onScroll: (dy, smooth) => src.linkCtl({'op': 'scroll', 'dy': dy, 'smooth': smooth}))),
        const SizedBox(height: Sp.s),
        Row(
          children: [
            btn(Icons.arrow_back_rounded, t('Atrás', 'Back'), canBack ? () => _ctl({'op': 'back'}) : null),
            const SizedBox(width: Sp.s),
            btn(Icons.vertical_align_top_rounded, t('Al inicio', 'To the top'), () => _ctl({'op': 'top'})),
            const Spacer(),
            btn(
              Icons.keyboard_arrow_up_rounded,
              t('Subir', 'Up'),
              () => _ctl({'op': 'scroll', 'dy': -0.8, 'smooth': true}),
            ),
            const SizedBox(width: Sp.s),
            btn(
              Icons.keyboard_arrow_down_rounded,
              t('Bajar', 'Down'),
              () => _ctl({'op': 'scroll', 'dy': 0.8, 'smooth': true}),
            ),
          ],
        ),
        const SizedBox(height: Sp.s),
        SizedBox(
          height: 38,
          child: links.isEmpty
              ? Center(
                  child: Text(t('Sin enlaces a la vista', 'No links in view'), style: Txt.text(12.5, color: Pal.muted)),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: links.length,
                  separatorBuilder: (_, _) => const SizedBox(width: Sp.s),
                  itemBuilder: (_, k) => ActionChip(
                    avatar: Icon(Icons.link_rounded, size: 16, color: Pal.accent),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(links[k].text, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    labelStyle: Txt.text(13, weight: FontWeight.w600, color: Pal.ink, height: 1.2),
                    backgroundColor: Pal.raiseHi,
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    onPressed: () => _ctl({'op': 'follow', 'i': links[k].i}),
                  ),
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- video

  Widget _video() {
    final v = link['video'] is Map ? link['video'] as Map : const {};
    final playing = v['playing'] == true;
    final muted = v['muted'] == true;
    final time = (v['time'] as num?)?.toDouble() ?? 0;
    final dur = (v['dur'] as num?)?.toDouble() ?? 0;
    String fmt(double s) {
      final n = s.round();
      final h = n ~/ 3600, m = (n % 3600) ~/ 60, sec = n % 60;
      final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
      return '${h > 0 ? '$h:' : ''}$mm:${sec.toString().padLeft(2, '0')}';
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              onPressed: () => _ctl({'op': 'seek', 's': -10}),
              icon: const Icon(Icons.replay_10_rounded),
              tooltip: t('10 s atrás', '10 s back'),
            ),
            const SizedBox(width: Sp.l),
            IconButton.filled(
              onPressed: () => _ctl({'op': playing ? 'pause' : 'play'}),
              iconSize: 40,
              padding: const EdgeInsets.all(Sp.m),
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              tooltip: playing ? t('Pausar', 'Pause') : t('Reproducir', 'Play'),
            ),
            const SizedBox(width: Sp.l),
            IconButton.filledTonal(
              onPressed: () => _ctl({'op': 'seek', 's': 10}),
              icon: const Icon(Icons.forward_10_rounded),
              tooltip: t('10 s adelante', '10 s forward'),
            ),
          ],
        ),
        const SizedBox(height: Sp.m),
        Row(
          children: [
            Text(fmt(time), style: Txt.digits(12.5, color: Pal.muted)),
            const SizedBox(width: Sp.s),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(value: dur > 0 ? (time / dur).clamp(0.0, 1.0) : 0, minHeight: 5),
              ),
            ),
            const SizedBox(width: Sp.s),
            Text(dur > 0 ? fmt(dur) : '--:--', style: Txt.digits(12.5, color: Pal.muted)),
          ],
        ),
        const SizedBox(height: Sp.s),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () => _ctl({'op': 'restart'}),
              icon: const Icon(Icons.replay_rounded, size: 18),
              label: Text(t('Desde el inicio', 'From the start')),
            ),
            TextButton.icon(
              onPressed: () => _ctl({'op': 'mute'}),
              icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 18),
              label: Text(muted ? t('Activar sonido', 'Unmute') : t('Silenciar', 'Mute')),
            ),
          ],
        ),
      ],
    );
  }
}

/// Área para deslizar: mueve la página de la PC al ritmo del dedo (como en el teléfono).
class _Touchpad extends StatelessWidget {
  const _Touchpad({required this.onScroll});

  /// [dy]: fracción de la altura visible en la PC (positivo: bajar).
  final void Function(double dy, bool smooth) onScroll;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Arrastrar hacia arriba muestra lo de abajo, igual que al leer en el teléfono
      onVerticalDragUpdate: (d) => onScroll(-d.delta.dy / box.maxHeight * 1.3, false),
      onVerticalDragEnd: (d) {
        // Un deslizamiento rápido sigue un poco más
        final v = d.velocity.pixelsPerSecond.dy;
        if (v.abs() > 600) onScroll(-v / box.maxHeight * 0.25, true);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Pal.bg.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(Rad.s),
          border: Border.all(color: Pal.rule),
        ),
        // Poco alto: ícono y texto en una línea
        child: Center(
          child: Flex(
            direction: box.maxHeight < 84 ? Axis.horizontal : Axis.vertical,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.swipe_vertical_rounded, size: box.maxHeight < 84 ? 22 : 30, color: Pal.muted),
              const SizedBox(width: Sp.s, height: Sp.xs),
              Flexible(
                child: Text(
                  t('Desliza para desplazar la página', 'Swipe to scroll the page'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Txt.text(13, color: Pal.muted, height: 1.3),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
