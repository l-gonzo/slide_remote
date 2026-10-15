import 'dart:io';

import '../common/i18n.dart';

/// Conversión de presentaciones con los programas que haya en la PC:
/// LibreOffice (Windows, macOS, Linux) y, en Windows, también PowerPoint.
abstract final class Office {
  static Future<String?> findSoffice() async {
    final candidates = <String>[
      if (Platform.isMacOS) '/Applications/LibreOffice.app/Contents/MacOS/soffice',
      if (Platform.isWindows) ...[
        r'C:\Program Files\LibreOffice\program\soffice.exe',
        r'C:\Program Files (x86)\LibreOffice\program\soffice.exe',
      ],
      if (Platform.isLinux) ...['/usr/bin/soffice', '/usr/bin/libreoffice', '/snap/bin/libreoffice',
        '/var/lib/flatpak/exports/bin/org.libreoffice.LibreOffice'],
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', ['soffice']);
      final p = '${r.stdout}'.trim().split('\n').first.trim();
      if (r.exitCode == 0 && p.isNotEmpty) return p;
    } catch (_) {}
    return null;
  }

  /// Convierte [input] a [format] ('pdf', 'odp'…) dentro de [outDir]. Devuelve el archivo.
  /// Lanza [FormatException] con un mensaje para el usuario si no se puede.
  static Future<File> convert(File input, String format, Directory outDir) async {
    final soffice = await findSoffice();
    if (soffice != null) {
      // Perfil propio: así funciona aunque LibreOffice ya esté abierto
      final profile = Uri.directory('${outDir.path}/perfil').toString();
      final r = await Process.run(soffice, [
        '-env:UserInstallation=$profile',
        '--headless',
        '--norestore',
        '--convert-to',
        format,
        '--outdir',
        outDir.path,
        input.path,
      ]).timeout(const Duration(minutes: 3));
      final out = outDir
          .listSync()
          .whereType<File>()
          .where((x) => x.path.toLowerCase().endsWith('.$format'))
          .firstOrNull;
      if (out != null) return out;
      throw FormatException('${t('LibreOffice no pudo convertir el archivo', 'LibreOffice could not convert the file')} '
          '(${'${r.stderr}'.trim()})');
    }
    if (Platform.isWindows && format == 'pdf') {
      final out = File('${outDir.path}\\presentacion.pdf');
      if (await _powerPointToPdf(input, out)) return out;
    }
    throw FormatException(t(
        'Para proyectar o leer este archivo instala LibreOffice en esta PC (gratis), o elige la presentación en PDF.',
        'To present or read this file install LibreOffice on this computer (free), or choose the presentation as PDF.'));
  }

  /// Windows con PowerPoint instalado: exportar a PDF por automatización (sin abrir ventanas).
  static Future<bool> _powerPointToPdf(File input, File out) async {
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final script = r'$ErrorActionPreference = "Stop"; '
        r'$ppt = New-Object -ComObject PowerPoint.Application; '
        '\$p = \$ppt.Presentations.Open(${q(input.path)}, \$true, \$false, \$false); '
        '\$p.SaveAs(${q(out.path)}, 32); '
        r'$p.Close(); $ppt.Quit()';
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script])
          .timeout(const Duration(minutes: 3));
      return r.exitCode == 0 && await out.exists();
    } catch (_) {
      return false;
    }
  }
}
