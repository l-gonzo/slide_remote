import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'common/i18n.dart';
import 'common/theme.dart';
import 'desktop/receiver_page.dart';
import 'mobile/remote_page.dart';

/// Un solo proyecto, dos apps:
///  - en el teléfono (Android/iOS): el control remoto
///  - en la PC (Windows/macOS/Linux): el receptor que presiona las teclas
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Licencias de las tipografías incluidas (SIL Open Font License 1.1)
  LicenseRegistry.addLicense(() async* {
    for (final (pkg, file) in [
      ('Atkinson Hyperlegible Next', 'OFL-Atkinson.txt'),
      ('Atkinson Hyperlegible Mono', 'OFL-AtkinsonMono.txt'),
      ('Bricolage Grotesque', 'OFL-Bricolage.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([pkg], await rootBundle.loadString('assets/fonts/$file'));
    }
  });
  await I18n.load();
  await AppTheme.load();
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (!desktop) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _systemBars();
  }
  runApp(ZlideApp(desktop: desktop));
}

/// Barra de estado y de navegación del teléfono con los colores del tema.
void _systemBars() {
  final dark = Pal.p.dark;
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light, // iOS
    systemNavigationBarColor: Pal.bg,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
  ));
}

class ZlideApp extends StatefulWidget {
  const ZlideApp({super.key, required this.desktop});
  final bool desktop;

  @override
  State<ZlideApp> createState() => _ZlideAppState();
}

class _ZlideAppState extends State<ZlideApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppTheme.state.addListener(_themeChanged);
  }

  @override
  void dispose() {
    AppTheme.state.removeListener(_themeChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => I18n.systemChanged();

  @override
  void didChangePlatformBrightness() => AppTheme.systemChanged();

  /// Claro ↔ oscuro: los colores se leen de [Pal], así que se redibuja toda la interfaz
  /// (sin perder el estado de las pantallas).
  void _themeChanged() {
    if (!widget.desktop) _systemBars();
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([I18n.current, AppTheme.state]),
        builder: (context, _) => MaterialApp(
          title: 'Zlide',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          // Textos propios de Flutter (menús, "copiar", accesibilidad) en el mismo idioma
          locale: Locale(I18n.current.value),
          supportedLocales: const [Locale('es'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: widget.desktop ? const ReceiverPage() : const RemotePage(),
        ),
      );
}
