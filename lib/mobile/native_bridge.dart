import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/i18n.dart';

/// Acceso al plugin nativo (packages/slide_native).
abstract final class NativeBridge {
  static const _methods = MethodChannel('slide_native');
  static const _events = EventChannel('slide_native/events');

  static Stream<Map<String, Object?>>? _stream;

  /// Eventos: {type: volume, dir: up|down, phase: down|up} (al presionar y al soltar), {type: hid, state, name, address, message},
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

  /// Hay una acción al mantener presionado un botón de volumen: iOS empieza a medir cuánto se
  /// mantiene (no avisa al soltar; lo deduce). Android siempre avisa al soltar.
  static Future<void> setVolumeHold(bool on) => call('setVolumeHold', {'enabled': on});

  /// Android: WiFi sin ahorro de energía mientras se dibuja (si no, los paquetes salen a tirones).
  static Future<void> setLowLatencyWifi(bool on) => call('setLowLatencyWifi', {'enabled': on});

  /// Idioma de los mensajes que genera la parte nativa ('es' o 'en').
  static Future<void> setLanguage(String lang) => call('setLanguage', {'lang': lang});

  // ---------------------------------------------------------------- No molestar

  /// 'granted', 'denied' (falta dar el acceso en Ajustes) o 'unsupported' (iOS).
  static Future<String> dndStatus() async => await call<String>('dndStatus') ?? 'unsupported';

  /// Activa (solo pasan las alarmas) o restaura el modo anterior. Devuelve 'on', 'off' o el estado.
  static Future<String> setDnd(bool on) async => await call<String>('setDnd', {'enabled': on}) ?? 'unsupported';

  static Future<bool> openDndSettings() async => await call<bool>('openDndSettings') ?? false;

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
      return (false, t('la parte nativa de la app no tiene el convertidor (recompila con flutter clean)',
          'the native part of the app has no converter (rebuild with flutter clean)'));
    } on PlatformException catch (e) {
      return (false, e.message ?? e.code);
    }
  }

  /// Convierte una presentación a PDF dentro del teléfono. Con [svgOutput], si se puede
  /// (Android), también a SVG con animaciones; si no, ese archivo no se crea.
  /// Lanza [PlatformException] con un mensaje legible si falla.
  static Future<void> convertToPdf({
    required String input,
    required String output,
    String? svgOutput,
    double? aspect,
    int? expected,
  }) =>
      _methods.invokeMethod<void>('convertToPdf', {
        'input': input,
        'output': output,
        'svgOutput': svgOutput,
        'aspect': aspect,
        'expected': expected,
      });

  // ---------------------------------------------------------------- vista de dibujo

  /// Una página del PDF como imagen JPEG ([page] empieza en 1; [width] en píxeles).
  static Future<PdfPageImage?> renderPdfPage(String path, int page, int width) async {
    try {
      final m = await _methods.invokeMethod<Map<Object?, Object?>>(
          'renderPdfPage', {'path': path, 'page': page, 'width': width});
      final bytes = m?['bytes'];
      if (bytes is! Uint8List) return null;
      return PdfPageImage(
        bytes: bytes,
        width: (m!['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        pages: (m['pages'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('renderPdfPage: ${e.message}');
      return null;
    }
  }

  // ---------------------------------------------------------------- iOS: BLE periférico

  static Future<void> bleStart() => call('bleStart');
  static Future<void> bleStop() => call('bleStop');
  static Future<bool> bleSend(int cmd, {int? arg}) async =>
      await call<bool>('bleSend', {'cmd': cmd, 'arg': arg}) ?? false;

  // ---------------------------------------------------------------- vibración

  /// [count] pulsos de [ms] con intensidad [strength] (0–1) (avisos del tiempo objetivo).
  /// Sin la parte nativa, vibración háptica.
  static Future<void> vibrate(int count, {int ms = 550, double strength = 1}) async {
    try {
      await _methods.invokeMethod<void>('vibrate', {'count': count, 'ms': ms, 'strength': strength});
    } on MissingPluginException {
      for (var i = 0; i < count; i++) {
        if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 260));
        await (strength < 0.6
            ? HapticFeedback.lightImpact()
            : strength < 0.9
                ? HapticFeedback.mediumImpact()
                : HapticFeedback.heavyImpact());
      }
    } on PlatformException catch (e) {
      debugPrint('slide_native.vibrate: ${e.code} ${e.message}');
    }
  }
}

@immutable
class PdfPageImage {
  const PdfPageImage({required this.bytes, required this.width, required this.height, required this.pages});
  final Uint8List bytes;
  final int width;
  final int height;
  final int pages;
}

@immutable
class BtDevice {
  const BtDevice({required this.name, required this.address});
  final String name;
  final String address;
}
