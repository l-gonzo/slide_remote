import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Acceso al plugin nativo (packages/slide_native).
abstract final class NativeBridge {
  static const _methods = MethodChannel('slide_native');
  static const _events = EventChannel('slide_native/events');

  static Stream<Map<String, Object?>>? _stream;

  /// Eventos: {type: volume, dir: up|down}, {type: hid, state, name, address, message},
  /// {type: ble, state, centrals}, {type: discoverable, ok}.
  static Stream<Map<String, Object?>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => Map<String, Object?>.from(e as Map));

  static Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('slide_native.$method: ${e.code} ${e.message}');
      return null;
    }
  }

  static Future<void> setVolumeCapture(bool on) => call('setVolumeCapture', {'enabled': on});

  // ---------------------------------------------------------------- Android: teclado HID

  static Future<bool> hidSupported() async => await call<bool>('hidSupported') ?? false;
  static Future<bool> btEnabled() async => await call<bool>('btEnabled') ?? false;
  static Future<bool> requestBtPermissions() async => await call<bool>('requestBtPermissions') ?? false;
  static Future<void> makeDiscoverable() => call('makeDiscoverable');
  static Future<void> hidStart(String? autoAddress) => call('hidStart', {'address': autoAddress});
  static Future<void> hidPause() => call('hidPause');
  static Future<bool> hidConnect(String address) async =>
      await call<bool>('hidConnect', {'address': address}) ?? false;
  static Future<void> hidDisconnect() => call('hidDisconnect');
  static Future<bool> hidReconnect() async => await call<bool>('hidReconnect') ?? false;
  static Future<bool> hidSend(int usage) async => await call<bool>('hidSend', {'key': usage}) ?? false;

  static Future<List<BtDevice>> hidBonded() async {
    final list = await call<List<Object?>>('hidBonded') ?? const [];
    return [
      for (final item in list)
        if (item is Map)
          BtDevice(
            name: (item['name'] as String?) ?? '?',
            address: (item['address'] as String?) ?? '',
          ),
    ];
  }

  // ---------------------------------------------------------------- conversión a PDF

  /// Android: true si la app se compiló con LibreOffice. iOS: siempre true.
  static Future<bool> converterAvailable() async => (await converterStatus()).$1;

  /// (disponible, motivo si no lo está). El motivo distingue "no viene LibreOffice",
  /// "no cargó" y "la parte nativa de la app está desactualizada".
  static Future<(bool, String?)> converterStatus() async {
    try {
      final m = await _methods.invokeMethod<Map<Object?, Object?>>('converterStatus');
      return ((m?['available'] as bool?) ?? false, m?['reason'] as String?);
    } on MissingPluginException {
      return (false, 'la parte nativa de la app no tiene el convertidor (recompila con flutter clean)');
    } on PlatformException catch (e) {
      return (false, e.message ?? e.code);
    }
  }

  /// Convierte una presentación a PDF dentro del teléfono.
  /// Lanza [PlatformException] con un mensaje legible si falla.
  static Future<void> convertToPdf({
    required String input,
    required String output,
    double? aspect,
    int? expected,
  }) =>
      _methods.invokeMethod<void>('convertToPdf', {
        'input': input,
        'output': output,
        'aspect': aspect,
        'expected': expected,
      });

  // ---------------------------------------------------------------- iOS: BLE periférico

  static Future<void> bleStart() => call('bleStart');
  static Future<void> bleStop() => call('bleStop');
  static Future<bool> bleSend(int cmd) async => await call<bool>('bleSend', {'cmd': cmd}) ?? false;
}

@immutable
class BtDevice {
  const BtDevice({required this.name, required this.address});
  final String name;
  final String address;
}
