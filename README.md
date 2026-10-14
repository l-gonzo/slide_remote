# Slide Remote (Flutter)

Cambia las diapositivas con los botones de volumen del teléfono. Es un solo proyecto de Flutter:

- en **Android y iPhone** es el control remoto;
- en **Windows, macOS y Linux** es el receptor (“app de escritorio”) que presiona las teclas.

## Modos

| Teléfono | Bluetooth | WiFi | Navegador |
|---|---|---|---|
| **Android** | ✅ Nada que instalar en la PC: el teléfono funciona como **teclado Bluetooth** | App de escritorio | ✅ Nada que instalar en la PC |
| **iPhone** | App de escritorio (Bluetooth LE) | App de escritorio | ✅ Nada que instalar en la PC |

- **Bluetooth (Android):** la PC empareja el teléfono como un teclado y recibe AvPág/RePág. Funciona con PowerPoint, Keynote, Impress, Google Slides, visores de PDF…
- **Bluetooth (iPhone):** iOS no permite que una app actúe como teclado Bluetooth. El iPhone anuncia un servicio Bluetooth LE y la app de escritorio se conecta sola.
- **WiFi:** la app de escritorio se anuncia en la red (mDNS/Bonjour) y el teléfono la encuentra sin escribir IPs. Si la red bloquea mDNS, se puede agregar por IP.
- **Navegador:** el teléfono sirve una página web. En la PC abres la dirección que muestra la app (por ejemplo `192.168.1.23:8080`) en cualquier navegador y ahí se proyecta tu presentación **exportada a PDF**. No controla PowerPoint; muestra el PDF.

## Requisitos

- Flutter **3.35 o más reciente** (`flutter --version`) y Python 3.
- Android: el SDK que ya tienes.
- Linux (app de escritorio): `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev`
- Windows (app de escritorio): Visual Studio 2022 con “Desarrollo para el escritorio con C++”.
- macOS e iPhone: una Mac con Xcode y CocoaPods (`brew install cocoapods`).

## Preparar el proyecto (una vez)

```bash
cd slide_remote
python3 tool/configure.py
```

El script ejecuta `flutter create` (solo agrega las carpetas `android/`, `ios/`, `macos/`, `windows/` y `linux/`, sin tocar `lib/`), aplica permisos y ajustes de cada plataforma, descarga los paquetes y genera los íconos. Se puede volver a correr cuando quieras. En Windows ejecútalo con `py tool\configure.py`.

## Compilar

### Android (APK)

```bash
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
flutter install            # o instálalo con el teléfono conectado por USB/WiFi
```

### App de escritorio

| Sistema | Comando | Resultado |
|---|---|---|
| Linux | `flutter build linux --release` | `build/linux/x64/release/bundle/slide_remote` |
| Windows | `flutter build windows --release` | `build\windows\x64\runner\Release\` (copia la carpeta entera) |
| macOS | `flutter build macos --release` | `build/macos/Build/Products/Release/Slide Remote.app` |

Cada una se compila en su propio sistema (no se puede compilar la de Windows desde Linux).

### iPhone

En la Mac: `open ios/Runner.xcworkspace` → *Runner* → *Signing & Capabilities* → elige tu equipo (sirve un Apple ID gratuito). Luego, con el iPhone conectado:

```bash
flutter run --release -d <tu-iphone>
```

Con un Apple ID gratuito, la app deja de abrir a los 7 días y hay que volver a instalarla. Con la cuenta de desarrollador (US$99/año) dura un año o se publica en TestFlight/App Store.

## Permisos por sistema (app de escritorio)

- **macOS:** la primera vez pide **Accesibilidad** (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad → activa Slide Remote) y **Bluetooth**. La app trae un botón que abre el ajuste.
- **Linux:** para presionar teclas usa `/dev/uinput` (funciona en Wayland y X11). Si falta el permiso, la app muestra el comando para arreglarlo; ejecútalo una vez y cierra/abre sesión.
- **Windows:** al abrirla, el firewall pregunta si permite la red: acepta en **Redes privadas**.

## Uso

1. Abre la app en el teléfono y elige el modo.
2. **Bluetooth Android:** “Emparejar nueva” → en la PC, Configuración → Bluetooth → agrega el teléfono. Después solo toca “Conectar”; al volver a la app se reconecta sola.
3. **Bluetooth iPhone / WiFi:** abre la app de escritorio en la PC (puede quedar minimizada) y pon tu presentación al frente.
4. **Navegador:** elige el PDF, abre la dirección en la PC y presiona “Pantalla completa”.
5. Volumen + = siguiente, Volumen − = anterior (se puede invertir en Ajustes). Los botones grandes de la pantalla hacen lo mismo.

## Limitaciones

- La app del teléfono debe estar **abierta y en primer plano**. Al salir, el teléfono suelta los botones de volumen (y en Android desconecta el teclado Bluetooth) para no interferir con otras apps; al volver, se reconecta sola.
- **iPhone:** iOS no da acceso directo a los botones de volumen. La app detecta el cambio de volumen y lo regresa a 50 % en cada pulsación (al salir restaura tu volumen). Funciona bien, pero Apple podría objetarlo si se publica en la App Store.
- Los modos WiFi y Navegador no tienen contraseña: cualquiera en la misma red podría cambiar la diapositiva. En la red de un salón no suele importar.
- En redes que aíslan a los clientes (algunas redes de universidad u hotel), WiFi y Navegador no funcionan. Usa Bluetooth o activa el punto de acceso del teléfono y conecta la PC a él.

## Estructura

```
lib/
  main.dart                    elige control remoto (teléfono) o receptor (PC)
  common/protocol.dart         puertos, UUIDs BLE, comandos
  common/theme.dart            colores y componentes de la interfaz
  mobile/remote_page.dart      pantalla del teléfono
  mobile/remote_controller.dart  lógica de modos, reconexión, ajustes
  mobile/wifi_client.dart      descubrimiento mDNS + UDP
  mobile/browser_server.dart   servidor web + WebSocket del modo Navegador
  mobile/native_bridge.dart    canal hacia el código nativo
  desktop/receiver_page.dart   ventana de la PC
  desktop/receiver_controller.dart  UDP + mDNS + Bluetooth LE
  desktop/key_injector.dart    teclas: SendInput / CGEventPost / uinput (dart:ffi)
packages/slide_native/         plugin propio
  android/…/BtHidKeyboard.java teclado Bluetooth HID
  android/…/SlideNativePlugin.java  volumen, permisos
  ios/Classes/SlideNativePlugin.swift  BLE periférico, volumen
assets/web/                    página del modo Navegador + pdf.js 4.10 (licencia Apache 2.0)
tool/configure.py              prepara las plataformas
```
