import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/i18n.dart';
import '../common/theme.dart';
import 'privacy_page.dart';
import 'remote_controller.dart';
import 'stage_widgets.dart';
import 'timer_chip.dart';

/// Versión que se muestra en "Acerca de" (la misma de pubspec.yaml).
const kAppVersion = '2.6.3';

/// Dónde se descarga Zlide para escritorio (Windows, macOS y Linux).
const kDesktopUrl = 'https://github.com/l-gonzo/zlide_desktop';

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
                for (final (i, section) in [
                  _presentation(context),
                  _presenting(context),
                  _buttons(context),
                  _notes(context),
                  _timer(context),
                  _appearance(),
                  _desktop(context),
                  _about(context),
                ].indexed) ...[
                  if (i > 0) const SizedBox(height: Sp.m),
                  section,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Sección plegable [id]: abierta o cerrada según lo último que eligió quien la usa.
  Panel _section(String id,
          {required IconData icon, required String title, String? summary, String? footer, required List<Widget> children}) =>
      Panel(
        icon: icon,
        title: title,
        summary: summary,
        footer: footer,
        open: c.sectionOpen(id),
        onToggle: () => c.toggleSection(id),
        children: children,
      );

  // ---------------------------------------------------------------- presentación

  /// La presentación elegida y cómo cambiarla, en todos los modos.
  Widget _presentation(BuildContext context) {
    final name = c.presentationName;
    final browser = c.mode == Mode.browser;
    void change() {
      Navigator.pop(context);
      c.changePresentation();
    }

    final String subtitle;
    if (c.notesFromPc) {
      subtitle = t('Viene de la app de la PC. Para cambiarla, elige otra presentación allá.',
          'It comes from the desktop app. To change it, choose another presentation there.');
    } else if (name == null) {
      subtitle = browser
          ? t('PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} o PDF.', 'PowerPoint, LibreOffice${c.isIOS ? ', Keynote' : ''} or PDF.')
          : c.mode == Mode.wifi
              ? t('Elige un archivo aquí (.pptx, .odp) para ver tus notas, o la presentación en la app de la PC.',
                  'Choose a file here (.pptx, .odp) to see your notes, or the presentation in the desktop app.')
              : t('Elige el archivo (.pptx, .odp) para ver tus notas.', 'Choose the file (.pptx, .odp) to see your notes.');
    } else {
      final total = browser && c.browser.total > 0 ? c.browser.total : c.deck?.length ?? 0;
      subtitle = [
        if (total > 0) t('$total diapositivas', '$total slides'),
        c.deck != null ? t('con notas', 'with notes') : t('sin notas', 'no notes'),
      ].join(' · ');
    }
    return _section(
      'presentation',
      icon: Icons.slideshow_rounded,
      title: '${t('Presentación', 'Presentation')} · $modeName',
      summary: name ?? t('Ninguna elegida', 'None chosen'),
      footer: t('También puedes cambiarla desde «Ir a», en la pantalla principal.',
          'You can also change it from “Go to”, on the main screen.'),
      children: [
        SettingRow(
          icon: c.notesFromPc ? Icons.computer_rounded : Icons.slideshow_rounded,
          title: name ?? t('Sin presentación', 'No presentation'),
          subtitle: subtitle,
          trailing: c.canChangePresentation
              ? TextButton(onPressed: change, child: Text(name == null ? t('Elegir', 'Choose') : t('Cambiar', 'Change')))
              : null,
          onTap: c.canChangePresentation ? change : null,
        ),
      ],
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
    return _section(
      'presenting',
      icon: Icons.co_present_outlined,
      title: t('Al presentar', 'While presenting'),
      summary: [
        c.hand == Hand.left ? t('Mano izquierda', 'Left hand') : t('Mano derecha', 'Right hand'),
        if (c.oneHand) t('una mano', 'one-handed'),
        if (c.dnd && c.dndState != DndState.unsupported) t('no molestar', 'do not disturb'),
      ].join(' · '),
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

  Widget _buttons(BuildContext context) => _section(
        'buttons',
        icon: Icons.volume_up_outlined,
        title: t('Botones de volumen', 'Volume buttons'),
        summary: [
          c.invert ? t('Invertidos', 'Swapped') : t('Volumen + avanza', 'Volume + goes forward'),
          if (c.arrows) t('flechas', 'arrow keys'),
          if (c.holdUp != HoldAction.none || c.holdDown != HoldAction.none) t('con acciones al mantener', 'with hold actions'),
        ].join(' · '),
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
          if (c.holdUp == HoldAction.aim || c.holdDown == HoldAction.aim) _aimRow(),
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
        HoldAction.aim => t('Apuntar moviendo el teléfono (con el puntero elegido en la vista de dibujo)',
            'Point by moving the phone (with the pointer chosen in the drawing view)'),
      };

  static IconData _holdIcon(HoldAction a) => switch (a) {
        HoldAction.none => Icons.block_rounded,
        HoldAction.first => Icons.first_page_rounded,
        HoldAction.last => Icons.last_page_rounded,
        HoldAction.timer => Icons.timer_outlined,
        HoldAction.lock => Icons.lock_outline_rounded,
        HoldAction.ink => Icons.visibility_off_outlined,
        HoldAction.aim => Icons.adjust_rounded,
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
    return _section(
      'notes',
      icon: Icons.sticky_note_2_outlined,
      title: '${t('Notas del presentador', 'Speaker notes')} · $modeName',
      summary: [
        c.deck == null ? t('Sin notas', 'No notes') : t('${c.deck!.length} diapositivas', '${c.deck!.length} slides'),
        t('texto ${c.notesFont.round()}', 'text ${c.notesFont.round()}'),
      ].join(' · '),
      footer: c.deck == null
          ? t('Las notas salen del archivo de la presentación (sección «Presentación»). Cada modo guarda las suyas.',
              'Notes come from the presentation file (“Presentation” section). Each mode keeps its own.')
          : t('Con PowerPoint o Impress el teléfono cuenta las pulsaciones (incluidas las animaciones); si se desfasa, '
              'corrígelo desde “Ir a”. Al transmitir (desde la PC o desde el móvil) se sincroniza solo.',
              'With PowerPoint or Impress the phone counts the presses (animations included); if it gets out of step, '
              'fix it from “Go to”. When streaming (from the PC or the phone) it syncs by itself.'),
      children: [
        size,
        if (c.deck != null)
          SettingRow(
            icon: Icons.first_page_rounded,
            title: t('Volver a la diapositiva 1', 'Back to slide 1'),
            subtitle: t('Solo en las notas; no cambia nada en la PC.', 'Only in the notes; nothing changes on the computer.'),
            onTap: c.restartNotes,
          ),
        if (c.deck != null && !c.notesFromPc)
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
    return _section(
      'timer',
      icon: Icons.timer_outlined,
      title: t('Cronómetro', 'Timer'),
      summary: tm.target == null ? t('Sin tiempo objetivo', 'No target time') : '${tm.target!.inMinutes} min · ${tm.alertsSummary()}',
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
        ...timerAlertRows(tm),
      ],
    );
  }

  // ---------------------------------------------------------------- apariencia y acerca de

  Widget _appearance() => _section(
        'appearance',
        icon: Icons.palette_outlined,
        title: t('Apariencia', 'Appearance'),
        summary: [
          switch (AppTheme.pref) {
            ThemePref.system => t('Tema del sistema', 'System theme'),
            ThemePref.light => t('Claro', 'Light'),
            ThemePref.dark => t('Oscuro', 'Dark'),
          },
          switch (I18n.pref) {
            LangPref.system => t('idioma del sistema', 'system language'),
            LangPref.es => 'Español',
            LangPref.en => 'English',
          },
        ].join(' · '),
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

  // ---------------------------------------------------------------- app de escritorio

  /// Abre [url] en el navegador; si no se puede, la copia (para abrirla en otro lado).
  static Future<void> _open(BuildContext context, String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (ok || !context.mounted) return;
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t('No se pudo abrir; enlace copiado', 'Couldn’t open it; link copied'))));
  }

  /// Enlace para descargar Zlide para escritorio: se abre aquí o se copia para abrirlo en la PC.
  Widget _desktop(BuildContext context) {
    void say(String msg) => ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
    void copy() {
      Clipboard.setData(const ClipboardData(text: kDesktopUrl));
      say(t('Enlace copiado', 'Link copied'));
    }

    return _section(
      'desktop',
      icon: Icons.computer_rounded,
      title: t('App para PC', 'Desktop app'),
      summary: 'Windows · macOS · Linux',
      children: [
        SettingRow(
          icon: Icons.computer_rounded,
          title: t('Zlide para escritorio', 'Zlide for desktop'),
          subtitle: t(
            'Necesaria para «Transmitir desde PC» y para el Bluetooth del iPhone. Descárgala en tu computadora '
                '(Windows, macOS o Linux).',
            'Needed for “Stream from PC” and for iPhone Bluetooth. Download it on your computer '
                '(Windows, macOS or Linux).',
          ),
        ),
        SettingRow(
          icon: Icons.download_rounded,
          title: kDesktopUrl.replaceFirst('https://', ''),
          subtitle: t('Abrir la página de descarga', 'Open the download page'),
          trailing: const Icon(Icons.open_in_new_rounded, size: 20),
          onTap: () => _open(context, kDesktopUrl),
        ),
        SettingRow(
          icon: Icons.copy_rounded,
          title: t('Copiar enlace', 'Copy link'),
          subtitle: t('Para abrirlo en la PC.', 'To open it on the computer.'),
          onTap: copy,
        ),
      ],
    );
  }

  Widget _about(BuildContext context) => _section(
        'about',
        icon: Icons.info_outline_rounded,
        title: t('Acerca de', 'About'),
        summary: 'Zlide $kAppVersion',
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
          SettingRow(
            icon: Icons.privacy_tip_outlined,
            title: t('Política de privacidad', 'Privacy policy'),
            subtitle: t('Zlide no recopila datos personales.', 'Zlide doesn’t collect personal data.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPage())),
          ),
        ],
      );
}
