/// Constantes compartidas entre la app del teléfono y la de escritorio.
library;

/// Puerto UDP donde escucha la app de escritorio.
const int kUdpPort = 50505;

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

  static String label(int cmd) => switch (cmd) {
        Cmd.next => 'AvPág',
        Cmd.prev => 'RePág',
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

/// Mensajes UDP (texto ASCII).
abstract final class Udp {
  static const String prefix = 'SR1';
  static String command(int cmd) => '$prefix C $cmd';
  static const String ping = '$prefix PING';
  static String pong(String name) => '$prefix PONG $name';
}
