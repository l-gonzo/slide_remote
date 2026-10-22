/// Constantes compartidas entre la app del teléfono y la de escritorio.
library;

import 'i18n.dart';

/// Puerto UDP donde escucha la app de escritorio.
const int kUdpPort = 50505;

/// Puerto TCP (HTTP) donde la app de escritorio sirve las notas de la presentación.
/// Si está ocupado se usa otro; el puerto real se anuncia en el mensaje NOTES.
const int kNotesPort = 50506;

/// Tipo de servicio Bonjour/mDNS que anuncia la app de escritorio.
/// Debe coincidir con NSBonjourServices en los Info.plist.
const String kServiceType = '_slideremote._udp';

/// Puerto (inicial) del servidor web del modo Navegador.
const int kHttpPort = 8080;

/// Servicio y característica BLE (iPhone → app de escritorio). 128 bits, minúsculas.
/// Deben coincidir con SlideNativePlugin.swift.
const String kBleService = '7b1d0001-5c3f-4e8a-9d7a-2f6b1c0e5a10';
const String kBleCommandChar = '7b1d0002-5c3f-4e8a-9d7a-2f6b1c0e5a10';

/// Comandos que viajan por WiFi y BLE. El teléfono decide qué tecla se presiona.
abstract final class Cmd {
  static const int next = 1; // AvPág
  static const int prev = 2; // RePág
  static const int right = 3; // →
  static const int left = 4; // ←

  static int of({required bool forward, required bool arrows}) =>
      arrows ? (forward ? right : left) : (forward ? next : prev);

  static bool isForward(int cmd) => cmd == next || cmd == right;

  static bool isValid(int cmd) => cmd >= next && cmd <= left;

  /// Ir a una diapositiva (por BLE viaja con el número en 2 bytes más). No es una tecla:
  /// la PC escribe el número y Enter, o cambia la página si está proyectando.
  static const int goTo = 5;

  static String label(int cmd) => switch (cmd) {
        Cmd.next => t('AvPág', 'Page Down'),
        Cmd.prev => t('RePág', 'Page Up'),
        Cmd.right => '→',
        Cmd.left => '←',
        _ => '?',
      };
}

/// Códigos de uso HID (teclado) para el modo Bluetooth de Android.
int hidUsageFor(int cmd) => switch (cmd) {
      Cmd.next => 0x4E, // Page Down
      Cmd.prev => 0x4B, // Page Up
      Cmd.right => 0x4F,
      Cmd.left => 0x50,
      _ => 0,
    };

/// Teclas HID para "ir a la diapositiva N": los dígitos y Enter (PowerPoint, Impress y Keynote
/// lo entienden así durante la presentación).
List<int> hidUsagesForNumber(int n) => [
      for (final ch in '$n'.codeUnits) ch == 0x30 ? 0x27 : 0x1E + (ch - 0x31), // 1–9 → 0x1E–0x26, 0 → 0x27
      0x28, // Enter
    ];

/// Mensajes UDP (texto ASCII).
abstract final class Udp {
  static const String prefix = 'SR1';
  static String command(int cmd) => '$prefix C $cmd';

  /// Ir a la diapositiva [n]: si la PC proyecta es la página del PDF; si no, escribe n y Enter.
  static String goTo(int n) => '$prefix G $n';
  static const String ping = '$prefix PING';
  static String pong(String name) => '$prefix PONG $name';

  /// La PC avisa qué notas tiene: versión (0 = ninguna) y puerto HTTP para pedirlas
  /// en GET /notes. Se manda junto con cada PONG; el teléfono solo descarga si cambió.
  static String notes(int version, int port) => '$prefix NOTES $version $port';

  /// "Proyectar en esta PC": página actual, total (0 0 = no está proyectando) y versión del PDF
  /// (cambia con cada presentación; el teléfono lo descarga para las miniaturas).
  static String page(int page, int total, [int version = 0]) => '$prefix PAGE $page $total $version';
}
