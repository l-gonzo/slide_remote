import 'package:flutter/material.dart';

import '../common/i18n.dart';
import '../common/theme.dart';

/// Política de privacidad, dentro de la app (sin abrir el navegador ni necesitar internet).
/// Es el mismo texto que la página pública que se da en Google Play ([kPrivacyUrl]).
const kPrivacyUrl = 'https://l-gonzo.github.io/zlide-legal/';

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = <(String, List<String>)>[
      (
        t('Qué hace la app con tu información', 'What the app does with your information'),
        [
          t(
            'Presentaciones que eliges (.pptx, .odp, PDF…): se leen y se convierten dentro del teléfono, sin internet, '
                'para mostrar tus notas y la diapositiva. No salen del teléfono, salvo en el modo «Transmitir desde móvil»: '
                'ahí el teléfono las sirve por tu red local (WiFi o punto de acceso) al navegador de la computadora donde las '
                'abres. Cualquier equipo de esa misma red que abra la dirección que muestra la app puede verlas mientras presentas.',
            'Presentations you choose (.pptx, .odp, PDF…): they are read and converted on the phone, offline, to show your '
                'notes and the slide. They don’t leave the phone, except in “Stream from phone” mode: there the phone serves '
                'them over your local network (WiFi or hotspot) to the browser of the computer where you open them. Any device '
                'on that same network that opens the address shown in the app can see them while you present.',
          ),
          t(
            'Bluetooth: en Android el teléfono funciona como teclado Bluetooth de la computadora que emparejes; en iPhone se '
                'comunica por Bluetooth LE con Zlide para escritorio. Solo se envían las teclas para cambiar de diapositiva.',
            'Bluetooth: on Android the phone acts as a Bluetooth keyboard for the computer you pair; on iPhone it talks over '
                'Bluetooth LE to Zlide for desktop. Only the keys to change slides are sent.',
          ),
          t(
            'Red local: en «Transmitir desde PC» la app busca Zlide para escritorio en tu red (mDNS/Bonjour) y se comunica '
                'solo con esa computadora.',
            'Local network: in “Stream from PC” the app looks for Zlide for desktop on your network (mDNS/Bonjour) and only '
                'talks to that computer.',
          ),
          t(
            'Sensores de movimiento: al apuntar moviendo el teléfono se usa el giroscopio para mover el puntero en ese '
                'momento; no se guarda nada.',
            'Motion sensors: when pointing by moving the phone, the gyroscope moves the pointer in real time; nothing is stored.',
          ),
          t(
            'No molestar (Android): si lo permites, la app activa «No molestar» mientras presentas y lo deja como estaba al '
                'salir. No lee tus notificaciones.',
            'Do not disturb (Android): if you allow it, the app turns on “Do not disturb” while you present and restores it '
                'when you leave. It doesn’t read your notifications.',
          ),
          t(
            'Ajustes: tus preferencias (tema, tamaño de letra, presentación elegida…) se guardan solo en el teléfono y se '
                'borran al desinstalar la app.',
            'Settings: your preferences (theme, text size, chosen presentation…) are stored only on the phone and are deleted '
                'when you uninstall the app.',
          ),
        ],
      ),
      (
        t('Servicios de terceros', 'Third-party services'),
        [
          t(
            'Si una diapositiva tiene un enlace o un video de YouTube y lo abres, se carga en el navegador de la computadora '
                'donde presentas, y ese sitio aplica su propia política de privacidad.',
            'If a slide has a link or a YouTube video and you open it, it loads in the browser of the computer you present '
                'on, and that site’s own privacy policy applies.',
          ),
        ],
      ),
      (
        t('Niños', 'Children'),
        [t('Zlide no está dirigida a niños y no recopila datos de nadie.', 'Zlide is not directed at children and collects no data from anyone.')],
      ),
      (
        t('Cambios', 'Changes'),
        [
          t('Si esta política cambia, se publicará con su fecha en $kPrivacyUrl',
              'If this policy changes, it will be posted with its date at $kPrivacyUrl'),
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(t('Política de privacidad', 'Privacy policy'), style: Txt.title(22)),
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: t('Volver', 'Back'),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SelectionArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(Sp.page, Sp.s, Sp.page, Sp.xxl + MediaQuery.paddingOf(context).bottom),
              children: [
                Text(t('Última actualización: 11 de noviembre de 2026', 'Last updated: November 11, 2026'),
                    style: Txt.text(13, color: Pal.muted)),
                const SizedBox(height: Sp.l),
                Container(
                  padding: const EdgeInsets.all(Sp.l),
                  decoration: BoxDecoration(color: Pal.accentSoft, borderRadius: BorderRadius.circular(Rad.l)),
                  child: Text(
                    t(
                      'Zlide no recopila, no guarda en servidores ni comparte datos personales. No tiene cuentas, publicidad, '
                          'analíticas ni rastreadores, y no se comunica con servidores del desarrollador.',
                      'Zlide does not collect, store on servers or share personal data. It has no accounts, ads, analytics or '
                          'trackers, and it doesn’t talk to the developer’s servers.',
                    ),
                    style: Txt.text(16, weight: FontWeight.w600, color: Pal.onAccentSoft),
                  ),
                ),
                for (final (title, paragraphs) in sections) ...[
                  const SizedBox(height: Sp.xl),
                  Text(title, style: Txt.title(19)),
                  for (final p in paragraphs) ...[
                    const SizedBox(height: Sp.m),
                    Text(p, style: Txt.text(15.5)),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
