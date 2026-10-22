import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../common/i18n.dart';
import '../common/protocol.dart';

/// Simula pulsaciones de teclado en la PC, sin dependencias externas (dart:ffi).
///  - Windows: SendInput (user32)
///  - macOS: CGEventPost (CoreGraphics). Requiere permiso de Accesibilidad.
///  - Linux: /dev/uinput (funciona en Wayland y X11). Requiere permiso sobre /dev/uinput.
abstract class KeyInjector {
  factory KeyInjector.create() {
    if (Platform.isWindows) return _WindowsInjector();
    if (Platform.isMacOS) return _MacInjector();
    return _LinuxInjector();
  }

  /// Prepara el inyector. Se puede volver a llamar (p. ej. tras dar permisos).
  void init();

  /// null si todo está bien; si no, una explicación para el usuario.
  String? get problem;

  /// Presiona y suelta la tecla del comando ([Cmd]).
  void press(int cmd);

  /// Escribe [n] y Enter: "ir a la diapositiva n" en PowerPoint, Impress y Keynote.
  void typeNumber(int n);

  void dispose();
}

// ============================================================ Windows

class _WindowsInjector implements KeyInjector {
  static const _inputKeyboard = 1;
  static const _keyUp = 0x0002;
  static const _extended = 0x0001;
  static const _sizeOfInput = 40; // sizeof(INPUT) en 64 bits

  late int Function(int, Pointer<Uint8>, int) _sendInput;
  bool _loaded = false;
  String? _problem;

  @override
  String? get problem => _problem;

  @override
  void init() {
    if (_loaded) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      _sendInput = user32.lookupFunction<Uint32 Function(Uint32, Pointer<Uint8>, Int32),
          int Function(int, Pointer<Uint8>, int)>('SendInput');
      _loaded = true;
      _problem = null;
    } catch (e) {
      _problem = '${t('No se pudo cargar', 'Could not load')} user32.dll: $e';
    }
  }

  static int _vk(int cmd) => switch (cmd) {
        Cmd.next => 0x22, // VK_NEXT
        Cmd.prev => 0x21, // VK_PRIOR
        Cmd.right => 0x27, // VK_RIGHT
        Cmd.left => 0x25, // VK_LEFT
        _ => 0,
      };

  @override
  void press(int cmd) {
    final vk = _vk(cmd);
    if (vk != 0) _tap(vk, _extended);
  }

  @override
  void typeNumber(int n) {
    for (final ch in '$n'.codeUnits) {
      _tap(ch, 0); // VK_0–VK_9 = '0'–'9'
    }
    _tap(0x0D, 0); // VK_RETURN
  }

  void _tap(int vk, int flags) {
    if (!_loaded) return;
    final buf = calloc<Uint8>(_sizeOfInput * 2);
    try {
      final b = ByteData.sublistView(buf.asTypedList(_sizeOfInput * 2));
      // Disposición de INPUT (x64): type@0 (DWORD), union@8 → KEYBDINPUT:
      //   wVk@8 (WORD), wScan@10 (WORD), dwFlags@12 (DWORD), time@16 (DWORD), dwExtraInfo@24 (ULONG_PTR)
      for (var i = 0; i < 2; i++) {
        final o = i * _sizeOfInput;
        b.setUint32(o + 0, _inputKeyboard, Endian.little);
        b.setUint16(o + 8, vk, Endian.little);
        b.setUint32(o + 12, flags | (i == 1 ? _keyUp : 0), Endian.little);
      }
      _sendInput(2, buf, _sizeOfInput);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void dispose() {}
}

// ============================================================ macOS

class _MacInjector implements KeyInjector {
  late final Pointer<Void> Function(Pointer<Void>, int, bool) _create;
  late final void Function(int, Pointer<Void>) _post;
  late final void Function(Pointer<Void>) _release;
  late final int Function() _isTrusted;
  bool _loaded = false;
  String? _loadError;

  @override
  void init() {
    if (_loaded) return;
    try {
      final cg = DynamicLibrary.open('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
      final cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
      final ax = DynamicLibrary.open('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices');
      _create = cg.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint16, Bool),
          Pointer<Void> Function(Pointer<Void>, int, bool)>('CGEventCreateKeyboardEvent');
      _post = cg.lookupFunction<Void Function(Uint32, Pointer<Void>), void Function(int, Pointer<Void>)>('CGEventPost');
      _release = cf.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
      _isTrusted = ax.lookupFunction<Uint8 Function(), int Function()>('AXIsProcessTrusted');
      _loaded = true;
    } catch (e) {
      _loadError = '${t('No se pudo cargar', 'Could not load')} CoreGraphics: $e';
    }
  }

  bool get trusted => _loaded && _isTrusted() != 0;

  @override
  String? get problem {
    if (_loadError != null) return _loadError;
    if (!trusted) {
      return t('macOS necesita permiso de Accesibilidad para presionar teclas. '
          'Actívalo para Zlide y vuelve a abrir la app.',
          'macOS needs the Accessibility permission to press keys. '
          'Turn it on for Zlide and reopen the app.');
    }
    return null;
  }

  static int _keyCode(int cmd) => switch (cmd) {
        Cmd.next => 0x79, // kVK_PageDown
        Cmd.prev => 0x74, // kVK_PageUp
        Cmd.right => 0x7C, // kVK_RightArrow
        Cmd.left => 0x7B, // kVK_LeftArrow
        _ => -1,
      };

  // kVK_ANSI_0 … kVK_ANSI_9 (no son consecutivos)
  static const _digits = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19];

  @override
  void press(int cmd) {
    final code = _keyCode(cmd);
    if (code >= 0) _tap(code);
  }

  @override
  void typeNumber(int n) {
    for (final ch in '$n'.codeUnits) {
      _tap(_digits[ch - 0x30]);
    }
    _tap(0x24); // kVK_Return
  }

  void _tap(int code) {
    if (!_loaded) return;
    for (final down in [true, false]) {
      final ev = _create(nullptr, code, down);
      if (ev == nullptr) return;
      _post(0 /* kCGHIDEventTap */, ev);
      _release(ev);
    }
  }

  @override
  void dispose() {}

  /// Abre Ajustes del Sistema → Privacidad y seguridad → Accesibilidad.
  static Future<void> openAccessibilitySettings() => Process.run(
      'open', ['x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility']);
}

Future<void> openMacAccessibilitySettings() => _MacInjector.openAccessibilitySettings();

// ============================================================ Linux

class _LinuxInjector implements KeyInjector {
  // ioctl de uinput (linux/uinput.h)
  static const _uiSetEvBit = 0x40045564;
  static const _uiSetKeyBit = 0x40045565;
  static const _uiDevCreate = 0x5501;
  static const _uiDevDestroy = 0x5502;
  static const _oWronly = 1;
  static const _oNonblock = 2048;
  static const _evSyn = 0, _evKey = 1, _synReport = 0;
  static const _keys = {
    Cmd.next: 109, // KEY_PAGEDOWN
    Cmd.prev: 104, // KEY_PAGEUP
    Cmd.right: 106, // KEY_RIGHT
    Cmd.left: 105, // KEY_LEFT
  };
  // KEY_0 … KEY_9 (KEY_1 = 2 … KEY_9 = 10, KEY_0 = 11) y KEY_ENTER
  static const _digits = [11, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  static const _enter = 28;

  final _libc = DynamicLibrary.process();
  late final int Function(Pointer<Utf8>, int) _open =
      _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>('open');
  late final int Function(int, int) _ioctl0 =
      _libc.lookupFunction<Int32 Function(Int32, UnsignedLong), int Function(int, int)>('ioctl');
  late final int Function(int, int, int) _ioctl1 = _libc.lookupFunction<
      Int32 Function(Int32, UnsignedLong, VarArgs<(Int32,)>), int Function(int, int, int)>('ioctl');
  late final int Function(int, Pointer<Uint8>, int) _write =
      _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
  late final int Function(int) _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  int _fd = -1;
  String? _problem;

  @override
  String? get problem => _problem;

  static const fixCommand =
      'echo \'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"\' '
      '| sudo tee /etc/udev/rules.d/99-zlide.rules >/dev/null '
      '&& echo uinput | sudo tee /etc/modules-load.d/zlide.conf >/dev/null '
      '&& sudo modprobe uinput && sudo udevadm control --reload-rules '
      '&& sudo udevadm trigger --name-match=uinput';

  @override
  void init() {
    if (_fd >= 0) return;
    final path = '/dev/uinput'.toNativeUtf8();
    try {
      final fd = _open(path, _oWronly | _oNonblock);
      if (fd < 0) {
        _problem = t('Sin permiso para /dev/uinput, así que no se pueden presionar teclas. '
            'Ejecuta este comando una vez y cierra/abre sesión:',
            'No permission for /dev/uinput, so keys can’t be pressed. '
            'Run this command once and log out and back in:');
        return;
      }
      _ioctl1(fd, _uiSetEvBit, _evKey);
      for (final k in [..._keys.values, ..._digits, _enter]) {
        _ioctl1(fd, _uiSetKeyBit, k);
      }
      // struct uinput_user_dev: name[80], input_id{bustype,vendor,product,version}, ff_effects_max,
      // absmax/absmin/absfuzz/absflat[64] → 1116 bytes
      const size = 1116;
      final dev = calloc<Uint8>(size);
      try {
        final bytes = dev.asTypedList(size);
        final name = 'Zlide'.codeUnits;
        bytes.setRange(0, name.length, name);
        final bd = ByteData.sublistView(bytes);
        bd.setUint16(80, 0x03, Endian.little); // BUS_USB
        bd.setUint16(82, 0x1209, Endian.little);
        bd.setUint16(84, 0x5352, Endian.little);
        bd.setUint16(86, 1, Endian.little);
        if (_write(fd, dev, size) != size) {
          _close(fd);
          _problem = t('No se pudo crear el teclado virtual (uinput).', 'Could not create the virtual keyboard (uinput).');
          return;
        }
      } finally {
        calloc.free(dev);
      }
      if (_ioctl0(fd, _uiDevCreate) < 0) {
        _close(fd);
        _problem = t('No se pudo crear el teclado virtual (uinput).', 'Could not create the virtual keyboard (uinput).');
        return;
      }
      _fd = fd;
      _problem = null;
    } finally {
      calloc.free(path);
    }
  }

  @override
  void press(int cmd) {
    final code = _keys[cmd];
    if (code != null) _tap(code);
  }

  @override
  void typeNumber(int n) {
    for (final ch in '$n'.codeUnits) {
      _tap(_digits[ch - 0x30]);
    }
    _tap(_enter);
  }

  void _tap(int code) {
    if (_fd < 0) return;
    // 4 eventos input_event (24 bytes en 64 bits: timeval 16, type u16, code u16, value s32)
    const evSize = 24;
    final buf = calloc<Uint8>(evSize * 4);
    try {
      final bd = ByteData.sublistView(buf.asTypedList(evSize * 4));
      void put(int i, int type, int code, int value) {
        bd.setUint16(i * evSize + 16, type, Endian.little);
        bd.setUint16(i * evSize + 18, code, Endian.little);
        bd.setInt32(i * evSize + 20, value, Endian.little);
      }

      put(0, _evKey, code, 1);
      put(1, _evSyn, _synReport, 0);
      put(2, _evKey, code, 0);
      put(3, _evSyn, _synReport, 0);
      _write(_fd, buf, evSize * 4);
    } finally {
      calloc.free(buf);
    }
  }

  @override
  void dispose() {
    if (_fd >= 0) {
      _ioctl0(_fd, _uiDevDestroy);
      _close(_fd);
      _fd = -1;
    }
  }
}

const linuxUinputFixCommand = _LinuxInjector.fixCommand;
