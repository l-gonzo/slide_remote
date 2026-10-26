import 'package:flutter/material.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'remote_controller.dart';
import 'stage_widgets.dart';
import 'timer_chip.dart';

/// Versión que se muestra en "Acerca de" (la misma de pubspec.yaml).
const kAppVersion = '2.6.0';

/// Ajustes: una pantalla completa con grupos, de lo que más se usa al presentar a lo menos.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.c, required this.modeName});
  final RemoteController c;

  /// Nombre del modo actual (las notas son de cada modo).
  final String modeName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t('Ajustes', 'Settings'), style: Txt.title(22)),
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: t('Volver', 'Back'),
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([c, c.timer, I18n.current]),
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.xxl + MediaQuery.paddingOf(context).bottom),
              children: [
                _presenting(context),
                const SizedBox(height: Sp.xl),
                _buttons(context),
                const SizedBox(height: Sp.xl),
                _notes(context),
                const SizedBox(height: Sp.xl),
                _timer(context),
                const SizedBox(height: Sp.xl),
                _appearance(),
                const SizedBox(height: Sp.xl),
                _about(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- al presentar

  Widget _presenting(BuildContext context) {
    final dndRow = switch (c.dndState) {
      DndState.unsupported => SettingRow(
          icon: Icons.do_not_disturb_on_outlined,
          title: t('Sin notificaciones', 'No notifications'),
          subtitle: t('En iPhone, activa Concentración › No molestar desde el Centro de control antes de presentar.',
              'On iPhone, turn on Focus › Do Not Disturb from Control Center before presenting.'),
        ),
      DndState.needsAccess when c.dnd => SettingRow(
          icon: Icons.do_not_disturb_on_outlined,
          title: t('No molestar al presentar', 'Do not disturb while presenting'),
          subtitle: t('Falta permitir el acceso a “No molestar” para Zlide.', 'Zlide needs access to “Do Not Disturb”.'),
          trailing: TextButton(onPressed: c.openDndSettings, child: Text(t('Permitir', 'Allow'))),
          onTap: c.openDndSettings,
        ),
      _ => SwitchRow(
          icon: Icons.do_not_disturb_on_outlined,
          title: t('No molestar al presentar', 'Do not disturb while presenting'),
          subtitle: c.dndState == DndState.on
              ? t('Activo: notificaciones y llamadas en silencio (las alarmas sí suenan).',
                  'On: notifications and calls are silenced (alarms still ring).')
              : t('Silencia notificaciones y llamadas mientras estás conectado; al salir de Zlide todo vuelve a como estaba.',
                  'Silences notifications and calls while connected; leaving Zlide restores everything.'),
          value: c.dnd,
          onChanged: c.setDnd,
        ),
    };
    return Panel(
      title: t('Al presentar', 'While presenting'),
      footer: t('«Bloquear», en la barra de acciones: la pantalla deja de responder a toques y gestos; los botones de '
          'volumen siguen cambiando de diapositiva. Mantén presionado para desbloquear.',
          '“Lock”, in the action bar: the screen ignores touches and gestures; the volume buttons still change '
          'slides. Press and hold to unlock.'),
      children: [
        SettingRow(
          icon: Icons.back_hand_outlined,
          title: t('Mano dominante', 'Dominant hand'),
          subtitle: t('Los botones y acciones se acomodan de ese lado.', 'Buttons and actions are placed on that side.'),
          below: Segmented<Hand>(
            values: Hand.values,
            labels: [t('Derecha', 'Right'), t('Izquierda', 'Left')],
            selected: c.hand,
            onChanged: c.setHand,
            accent: true,
          ),
        ),
        SwitchRow(
          icon: Icons.touch_app_outlined,
          title: t('Modo una mano', 'One-handed mode'),
          subtitle: t('Todo lo que se toca queda abajo, al alcance del pulgar.', 'Everything you tap stays at the bottom, within thumb reach.'),
          value: c.oneHand,
          onChanged: c.setOneHand,
        ),
        SwitchRow(
          icon: Icons.gesture_rounded,
          title: t('Evitar toques accidentales', 'Prevent accidental taps'),
          subtitle: t('Ignora un segundo toque muy seguido en los botones de la pantalla.',
              'Ignores a second tap in quick succession on the on-screen buttons.'),
          value: c.tapGuard,
          onChanged: c.setTapGuard,
        ),
        dndRow,
      ],
    );
  }

  Widget _buttons(BuildContext context) => Panel(
        title: t('Botones de volumen', 'Volume buttons'),
        footer: t('Con una acción al mantener presionado, ese botón cambia de diapositiva al soltarlo.',
            'With a hold action, that button changes the slide when you release it.'),
        children: [
          SwitchRow(
            icon: Icons.swap_vert_rounded,
            title: t('Invertir', 'Swap'),
            subtitle: t('Volumen − avanza.', 'Volume − goes forward.'),
            value: c.invert,
            onChanged: c.setInvert,
          ),
          SwitchRow(
            icon: Icons.keyboard_alt_outlined,
            title: t('Usar teclas de flecha', 'Use arrow keys'),
            subtitle: t('Si tu programa no responde a AvPág/RePág.', 'If your app ignores Page Down/Page Up.'),
            value: c.arrows,
            onChanged: c.setArrows,
          ),
          _holdRow(context, up: true),
          _holdRow(context, up: false),
          if (c.holdUp.aim != null || c.holdDown.aim != null) _aimRow(),
        ],
      );

  /// Sensibilidad al apuntar moviendo el teléfono (solo si algún botón apunta).
  Widget _aimRow() => SettingRow(
        icon: Icons.screen_rotation_alt_rounded,
        title: t('Sensibilidad al apuntar', 'Pointing sensitivity'),
        subtitle: t('Cuánto se mueve el puntero al girar el teléfono.', 'How far the pointer moves when you turn the phone.'),
        trailing: Text('${(c.aimSensitivity * 100).round()} %', style: Txt.digits(15, color: Pal.muted)),
        below: Row(children: [
          Icon(Icons.slow_motion_video_rounded, size: 18, color: Pal.muted),
          Expanded(
            child: Slider(
              value: c.aimSensitivity,
              min: 0.4,
              max: 2.5,
              divisions: 21,
              label: '${(c.aimSensitivity * 100).round()} %',
              onChanged: c.setAimSensitivity,
            ),
          ),
          Icon(Icons.speed_rounded, size: 18, color: Pal.muted),
        ]),
      );

  static String _holdName(HoldAction a) => switch (a) {
        HoldAction.none => t('Nada', 'Nothing'),
        HoldAction.first => t('Ir a la primera diapositiva', 'Go to the first slide'),
        HoldAction.last => t('Ir a la última diapositiva', 'Go to the last slide'),
        HoldAction.timer => t('Iniciar o pausar el cronómetro', 'Start or pause the timer'),
        HoldAction.lock => t('Bloquear o desbloquear la pantalla', 'Lock or unlock the screen'),
        HoldAction.ink => t('Ocultar o mostrar las anotaciones', 'Hide or show annotations'),
        HoldAction.aimLaser => t('Apuntar con el láser moviendo el teléfono', 'Point with the laser by moving the phone'),
        HoldAction.aimSpot => t('Apuntar con el foco moviendo el teléfono', 'Point with the spotlight by moving the phone'),
        HoldAction.aimZoom => t('Apuntar con la lupa moviendo el teléfono', 'Point with the magnifier by moving the phone'),
      };

  static IconData _holdIcon(HoldAction a) => switch (a) {
        HoldAction.none => Icons.block_rounded,
        HoldAction.first => Icons.first_page_rounded,
        HoldAction.last => Icons.last_page_rounded,
        HoldAction.timer => Icons.timer_outlined,
        HoldAction.lock => Icons.lock_outline_rounded,
        HoldAction.ink => Icons.visibility_off_outlined,
        HoldAction.aimLaser => Icons.adjust_rounded,
        HoldAction.aimSpot => Icons.highlight_rounded,
        HoldAction.aimZoom => Icons.zoom_in_rounded,
      };

  /// Acción al mantener presionado volumen + ([up]) o volumen −.
  Widget _holdRow(BuildContext context, {required bool up}) {
    final title = up
        ? t('Mantener presionado volumen +', 'Hold volume +')
        : t('Mantener presionado volumen −', 'Hold volume −');
    final current = up ? c.holdUp : c.holdDown;
    return SettingRow(
      icon: up ? Icons.volume_up_outlined : Icons.volume_down_outlined,
      title: title,
      subtitle: _holdName(current),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: Sp.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.page, 0, Sp.page, Sp.s),
                child: Text(title, style: Txt.title(24)),
              ),
              for (final a in HoldAction.values)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: Sp.page),
                  leading: Icon(_holdIcon(a), color: a == current ? Pal.accent : Pal.muted),
                  title: Text(_holdName(a)),
                  trailing: a == current ? Icon(Icons.check_rounded, color: Pal.accent) : null,
                  selected: a == current,
                  onTap: () {
                    Navigator.pop(ctx);
                    c.setHold(up: up, action: a);
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- notas

  Widget _notes(BuildContext context) {
    final size = SettingRow(
      icon: Icons.format_size_rounded,
      title: t('Tamaño del texto', 'Text size'),
      trailing: Text('${c.notesFont.round()}', style: Txt.digits(15, color: Pal.muted)),
      below: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('A', style: Txt.text(14, color: Pal.muted)),
          Expanded(
            child: Slider(
              value: c.notesFont,
              min: 15,
              max: 34,
              divisions: 19,
              label: '${c.notesFont.round()}',
              onChanged: c.setNotesFont,
            ),
          ),
          Text('A', style: Txt.text(24, color: Pal.muted)),
        ]),
        Container(
          padding: const EdgeInsets.all(Sp.m),
          decoration: BoxDecoration(color: Pal.bg, borderRadius: BorderRadius.circular(Rad.m)),
          child: Text(t('Así se ven tus notas.', 'This is how your notes look.'), style: Txt.text(c.notesFont, height: 1.4)),
        ),
      ]),
    );
    if (c.deck == null) {
      return Panel(
        title: '${t('Notas del presentador', 'Speaker notes')} · $modeName',
        footer: t('Cada modo guarda sus propias notas.', 'Each mode keeps its own notes.'),
        children: [
          SettingRow(
            icon: Icons.sticky_note_2_outlined,
            title: t('Agregar notas', 'Add notes'),
            subtitle: c.mode == Mode.wifi
                ? t('Elige la presentación en la app de la PC, o un archivo aquí (.pptx, .odp).',
                    'Choose the presentation in the desktop app, or a file here (.pptx, .odp).')
                : t('Elige el archivo de tu presentación (.pptx, .odp).', 'Choose your presentation file (.pptx, .odp).'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.pop(context);
              c.pickNotes();
            },
          ),
          size,
        ],
      );
    }
    return Panel(
      title: '${t('Notas del presentador', 'Speaker notes')} · $modeName',
      footer: t('Con PowerPoint o Impress el teléfono cuenta las pulsaciones (incluidas las animaciones); si se desfasa, '
          'corrígelo desde “Ir a”. Al transmitir (desde la PC o desde el móvil) se sincroniza solo.',
          'With PowerPoint or Impress the phone counts the presses (animations included); if it gets out of step, '
          'fix it from “Go to”. When streaming (from the PC or the phone) it syncs by itself.'),
      children: [
        SettingRow(
          icon: c.notesFromPc ? Icons.computer_rounded : Icons.description_outlined,
          title: c.deckName ?? t('presentación', 'presentation'),
          subtitle: c.notesFromPc
              ? t('Vienen de la app de la PC. Para cambiarlas, elige otra presentación allá.',
                  'They come from the desktop app. To change them, choose another presentation there.')
              : t('${c.deck!.length} diapositivas', '${c.deck!.length} slides'),
          trailing: c.notesFromPc
              ? null
              : TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    c.pickNotes();
                  },
                  child: Text(t('Cambiar', 'Change')),
                ),
        ),
        size,
        SettingRow(
          icon: Icons.first_page_rounded,
          title: t('Volver a la diapositiva 1', 'Back to slide 1'),
          subtitle: t('Solo en las notas; no cambia nada en la PC.', 'Only in the notes; nothing changes on the computer.'),
          onTap: c.restartNotes,
        ),
        if (!c.notesFromPc)
          SettingRow(
            icon: Icons.delete_outline_rounded,
            title: t('Quitar notas', 'Remove notes'),
            onTap: () {
              Navigator.pop(context);
              c.clearNotes();
            },
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- cronómetro

  Widget _timer(BuildContext context) {
    final tm = c.timer;
    return Panel(
      title: t('Cronómetro', 'Timer'),
      footer: t('Cuándo vibra y cuántas veces. El cronómetro pasa a ámbar en el primer aviso y a rojo en el segundo.',
          'When it vibrates and how many times. The timer turns amber at the first alert and red at the second.'),
      children: [
        SettingRow(
          icon: Icons.flag_outlined,
          title: t('Tiempo objetivo', 'Target time'),
          subtitle: tm.target == null
              ? t('Sin objetivo · también manteniendo presionado el cronómetro', 'No target · also by holding down the timer')
              : '${tm.target!.inMinutes} min · ${tm.alertsSummary()}',
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showTargetPicker(context, tm),
        ),
        SettingRow(
          icon: Icons.vibration_rounded,
          title: t('Fuerza de la vibración', 'Vibration strength'),
          below: Row(children: [
            Text(t('Suave', 'Soft'), style: Txt.text(14, color: Pal.muted)),
            Expanded(child: Slider(value: tm.vibe, onChanged: tm.setVibe, onChangeEnd: (_) => tm.previewVibe())),
            Text(t('Fuerte', 'Strong'), style: Txt.text(14, color: Pal.muted)),
          ]),
        ),
        for (var i = 0; i < tm.alerts.length; i++) _alertRow(i),
        SettingRow(
          icon: Icons.restart_alt_rounded,
          title: t('Restablecer avisos', 'Reset alerts'),
          onTap: tm.resetAlerts,
        ),
      ],
    );
  }

  /// Aviso [i] del cronómetro: minutos antes del final (el último es al terminar) y vibraciones.
  Widget _alertRow(int i) {
    final tm = c.timer;
    final a = tm.alerts[i];
    final last = i == tm.alerts.length - 1;
    final m = a.left.inMinutes;
    final (lo, hi) = tm.alertRange(i);
    return SettingRow(
      icon: last ? Icons.alarm_rounded : Icons.notifications_none_rounded,
      title: last ? t('Al terminar', 'When time is up') : t('Quedan $m min', '$m min left'),
      trailing: last
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: m > lo ? () => tm.setAlert(i, minutes: m - 1) : null,
                tooltip: t('Un minuto menos', 'One minute less'),
                icon: const Icon(Icons.remove_rounded),
              ),
              IconButton(
                onPressed: m < hi ? () => tm.setAlert(i, minutes: m + 1) : null,
                tooltip: t('Un minuto más', 'One minute more'),
                icon: const Icon(Icons.add_rounded),
              ),
            ]),
      below: Segmented<int>(
        values: const [0, 1, 2, 3],
        labels: [t('No vibra', 'Off'), t('1 vez', 'Once'), t('2 veces', 'Twice'), t('3 veces', '3 times')],
        selected: a.pulses,
        onChanged: (n) {
          tm.setAlert(i, pulses: n);
          tm.previewVibe(n);
        },
        accent: true,
      ),
    );
  }

  // ---------------------------------------------------------------- apariencia y acerca de

  Widget _appearance() => Panel(
        title: t('Apariencia', 'Appearance'),
        children: [
          SettingRow(
            icon: Icons.contrast_rounded,
            title: t('Tema', 'Theme'),
            below: Segmented<ThemePref>(
              values: ThemePref.values,
              labels: [t('Sistema', 'System'), t('Claro', 'Light'), t('Oscuro', 'Dark')],
              selected: AppTheme.pref,
              onChanged: AppTheme.setPref,
              accent: true,
            ),
          ),
          SettingRow(
            icon: Icons.translate_rounded,
            title: t('Idioma', 'Language'),
            below: Segmented<LangPref>(
              values: LangPref.values,
              labels: [t('Sistema', 'System'), 'Español', 'English'],
              selected: I18n.pref,
              onChanged: (p) {
                I18n.setPref(p);
                c.languageChanged();
              },
              accent: true,
            ),
          ),
        ],
      );

  Widget _about(BuildContext context) => Panel(
        title: t('Acerca de', 'About'),
        children: [
          SettingRow(
            icon: Icons.info_outline_rounded,
            title: 'Zlide $kAppVersion',
            subtitle: t('Control remoto y notas del presentador.', 'Remote control and speaker notes.'),
          ),
          SettingRow(
            icon: Icons.gavel_rounded,
            title: t('Licencias', 'Licenses'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showLicensePage(context: context, applicationName: 'Zlide', applicationVersion: kAppVersion),
          ),
        ],
      );
}
