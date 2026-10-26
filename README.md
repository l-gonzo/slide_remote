# Zlide

<img src="assets/icon/icon.png" width="120" align="right" alt="Ícono de Zlide">

*(Antes se llamaba Slide Remote.)*

Cambia las diapositivas de tu presentación con los **botones de volumen del teléfono** y ve tus **notas del presentador** en la pantalla del teléfono.

Es un solo proyecto de Flutter que se compila en dos papeles:

| Dónde | Papel |
|---|---|
| **Android y iPhone** | Control remoto: botones de volumen, botones en pantalla y notas |
| **Windows, macOS y Linux** | Receptor (“app de escritorio”): presiona AvPág/RePág en la PC y le manda las notas al teléfono |

---

## Contenido

1. [Funciones](#funciones)
2. [Modos de conexión](#modos-de-conexión)
3. [Uso](#uso)
4. [Notas del presentador](#notas-del-presentador)
5. [Empezar rápido: compilar en Linux, Mac o Windows](#empezar-rápido-compilar-en-linux-mac-o-windows)
6. [Instalación manual (lo que hacen los scripts)](#instalación-manual-lo-que-hacen-los-scripts)
7. [Preparar el proyecto](#preparar-el-proyecto)
8. [Compilar e instalar / crear instaladores](#compilar-e-instalar--crear-instaladores)
9. [Compilar en GitHub (todos los sistemas a la vez)](#compilar-en-github-todos-los-sistemas-a-la-vez)
10. [Convertidor a PDF en Android (LibreOffice)](#convertidor-a-pdf-en-android-libreoffice)
11. [Permisos y red](#permisos-y-red)
12. [Limitaciones](#limitaciones)
13. [Solución de problemas](#solución-de-problemas)
14. [Estructura del proyecto](#estructura-del-proyecto)
15. [Licencias](#licencias)

---

## Funciones

Todo lo que hace Zlide, agrupado por dónde se usa. Los modos (**Control Bluetooth**, **Transmitir desde PC** y **Transmitir desde móvil**) se explican en [Modos de conexión](#modos-de-conexión).

### Cambiar de diapositiva

- **Botones de volumen:** Volumen + = siguiente, Volumen − = anterior (se puede invertir en *Ajustes*).
- **Botones en pantalla:** “Siguiente” ancho y “Anterior” a su lado, siempre en el mismo lugar, con “Siguiente” del lado de la mano.
- **Ir a cualquier diapositiva:** con **Ir a** o tocando el número aparece la lista con títulos (y cuáles tienen notas); al transmitir el salto es exacto, sin transmitir el teléfono escribe el número y Enter como en PowerPoint o Impress.
- **Corregir la cuenta** sin mover la PC (**− / +** en *Ir a*) cuando las notas se desfasan en Bluetooth o WiFi.
- **Flechas o AvPág/RePág:** *Ajustes → Usar teclas de flecha* para programas que no aceptan AvPág.
- **Evitar toques accidentales:** ignora un segundo toque muy seguido (un roce no salta dos diapositivas).
- **Reconexión sola:** al salir de la app suelta el volumen y la conexión; al volver se reconecta.

### Notas del presentador

- **Notas grandes** con número, título de la diapositiva y “Sigue → …” (con la **miniatura de la siguiente** al transmitir).
- **Notas a pantalla completa** con **Notas** en la barra de acciones (o “atrás” para volver).
- **Tamaño de letra** en *Ajustes → Notas*, recordado.
- **Contador de animaciones** (por ejemplo “2/5”): al transmitir es exacto; con Bluetooth y WiFi el teléfono cuenta los clics como PowerPoint.
- **Lee** `.pptx`, `.ppsx` y `.odp` de PowerPoint, LibreOffice, OnlyOffice, WPS, Keynote y Google Slides exportados; la app de escritorio lee además `.ppt`, `.key` y otros con LibreOffice (ver [Notas del presentador](#notas-del-presentador)).
- **Por WiFi las notas llegan desde la PC** y se actualizan solas si guardas cambios en el archivo.
- Las diapositivas ocultas se saltan.

### Diapositiva en vivo y dibujo (al transmitir)

Al transmitir desde el móvil, o desde la PC con *Proyectar en esta PC*, la pantalla principal muestra **la diapositiva actual arriba de las notas**, todo en la misma pantalla:

- **Herramientas:** pluma, marcatextos, puntero (láser, foco que oscurece todo lo demás o lupa que agranda) y borrador. Lo que dibujas aparece al instante sobre la presentación que ve el público.
- **Tomar y guardar la herramienta:** tocarla la toma (la diapositiva se agranda y aparecen colores y grosores); tocarla otra vez, o “atrás”, la guarda y el espacio vuelve a las notas. Sin herramienta en la mano un roce no dibuja nada; el borde de la diapositiva se ilumina cuando lo que toques se verá en la PC.
- **Apuntar moviendo el teléfono:** en *Ajustes → Botones de volumen* se puede elegir, al mantener presionado volumen + o −, *Apuntar con el láser*, *con el foco* o *con la lupa*. Mientras lo mantienes, el puntero aparece en el centro de la diapositiva y sigue el movimiento del teléfono (como un apuntador de verdad); al soltarlo desaparece y no cambia de diapositiva. Usa el giroscopio y el tamaño de puntero elegido en la vista de dibujo.
- **Seis colores y cuatro grosores** (fino, normal, grueso, muy grueso); cada herramienta recuerda el suyo.
- **Borrador** de trazos completos (toca o arrastra encima), **deshacer**, **borrar esta diapositiva** y **borrar todas** (con confirmación).
- **Ocultar anotaciones** (*⋯*): el público deja de verlas sin borrarlas; en el teléfono se ven tenues y la etiqueta *Ocultas en la PC* las vuelve a mostrar.
- Los dibujos se quedan en cada diapositiva y sobreviven a que la PC recargue o a que guardes cambios en la presentación.
- **Girar** (*⋯ → Girar*): el teléfono se acuesta con la diapositiva a un lado, las notas en medio y, en el borde donde cae el pulgar, un riel con las acciones y los botones de cambiar diapositiva. *Notas* esconde la diapositiva sin volver a vertical.

### Enlaces y videos

- **Enlaces de la diapositiva:** aparecen como botones debajo de ella; al tocarlos se abren **en la misma pantalla de la PC**, en una ventana encima de la presentación.
- **Manejar la página desde el teléfono:** deslizar para desplazarla, atrás, al inicio, subir/bajar y botones con los enlaces visibles para seguirlos. **Cerrar** (o “siguiente”) regresa a la presentación.
- **YouTube** se reproduce ahí mismo: reproducir/pausar, ±10 s, desde el inicio, silenciar y barra de progreso, todo desde el teléfono.
- **Videos y audios insertados** en el `.pptx`/`.odp` se reproducen en su lugar; con **varios videos** en la diapositiva hay un botón para cada uno. Formatos: mp4, m4v, webm, mov (según el navegador), mp3, m4a, wav, ogg.

### Animaciones y transiciones

- **En el navegador:** al proyectar con Zlide, las presentaciones se convierten a SVG y conservan **animaciones y transiciones**; los botones de volumen avanzan clic por clic. Desde el móvil la conversión se hace en el teléfono (Android); desde la PC, con LibreOffice. Sin LibreOffice la app de escritorio avisa y proyecta como PDF (cada diapositiva completa).
- **En su programa:** *Presentar en su programa* abre el archivo en PowerPoint, Keynote o LibreOffice Impress a pantalla completa, con todo tal cual, y el teléfono lo controla con teclas.

### Al presentar

- **Bloquear la pantalla:** deja de responder a toques y oculta las barras del sistema; los **botones de volumen siguen funcionando** y las notas se pueden desplazar. Se desbloquea manteniendo presionado.
- **Mano dominante:** para zurdos, botones, barra de acciones, herramientas de dibujo y riel pasan al otro lado.
- **Modo una mano:** todo lo que se toca queda abajo; conexión, cronómetro y ajustes van en **Más**.
- **Cronómetro** solo visible en el teléfono, con **tiempo objetivo** y aviso por vibración; sigue contando aunque salgas de la app o bloquees el teléfono.
- **Vibración** configurable (intensidad y avisos).
- **No molestar:** en Android se activa al conectar y se restaura al salir (pasan las alarmas). En la **PC con Linux** (GNOME/Ubuntu y XFCE) la app de escritorio silencia los avisos mientras presenta y los deja como estaban al terminar; en Windows y macOS indica cómo activar *No molestar* / *Concentración*.
- **Un solo teléfono manda:** mientras la PC presenta, solo la controla el teléfono que empezó; los demás ven “PC ocupada”. Se libera al terminar, con **Liberar**, o si ese teléfono no da señales en 90 s.
- La pantalla del teléfono no se apaga mientras la app está abierta.

### La página que ve el público

- **Sin instalar nada** en la PC (modo *Transmitir desde móvil*): se abre una dirección en el navegador y se presiona *Pantalla completa*. También sirve en una tablet.
- **Varias pantallas sincronizadas:** todos los navegadores abiertos muestran la misma diapositiva; si alguien avanza con el teclado o el mouse en una, se replica en todas y en las notas.
- **Conversión en el teléfono:** `.pptx`, `.odp` y `.ppt` a PDF/SVG dentro del teléfono, sin internet (Android; en iPhone a PDF).
- **Se actualiza sola:** si guardas cambios en la presentación se vuelve a convertir en la misma diapositiva, y una pestaña que quedó abierta con una versión vieja de Zlide se recarga sola.
- Funciona en Windows, macOS y Linux (también Wayland) sin permisos especiales.

### App de escritorio

- **Receptor** para WiFi y Bluetooth del iPhone: presiona AvPág/RePág (o flechas) en la presentación que esté al frente.
- **Notas para el teléfono:** eliges la presentación en la PC y llegan solas.
- **Proyectar en esta PC** (en el navegador, con dibujo, enlaces y animaciones) o **Presentar en su programa**.
- Errores técnicos detrás de **Ver detalles**, para que la pantalla quede limpia.

### General

- **Tema claro y oscuro** (sigue al sistema); se cambia en *Ajustes → Tema* o con ☀/☾ en la app de escritorio.
- **Español e inglés** (sigue al sistema); se cambia en *Ajustes → Idioma* o con 🌐 en la app de escritorio. La página del público usa el idioma del teléfono.
- **Android, iPhone, Windows, macOS y Linux** desde un solo proyecto.

## Modos de conexión

En la app los modos se llaman **Control Bluetooth**, **Transmitir desde PC** (por WiFi, con la app de escritorio) y **Transmitir desde móvil** (la página que sirve el teléfono). Abajo, “WiFi” y “Navegador” se refieren a los dos últimos.

| Teléfono → | **Control Bluetooth** | **Transmitir desde PC** (WiFi) | **Transmitir desde móvil** (navegador) |
|---|---|---|---|
| **Android** | ✅ Sin instalar nada en la PC: el teléfono es un **teclado Bluetooth** | App de escritorio | ✅ Sin instalar nada en la PC |
| **iPhone** | App de escritorio (Bluetooth LE) | App de escritorio | ✅ Sin instalar nada en la PC |
| Notas en el teléfono | Elige el archivo en el teléfono | **Desde la PC** (o desde el teléfono) | Del mismo archivo que proyectas |
| Sincronía de notas | Cuenta pulsaciones | Cuenta pulsaciones | Exacta |

- **Bluetooth (Android):** la PC empareja el teléfono como teclado y recibe AvPág/RePág. Sirve con PowerPoint, Keynote, Impress, Google Slides, visores de PDF… en Windows, Mac, Linux, **y también en tablets Android y iPad** (cualquier equipo que acepte un teclado Bluetooth).
- **Bluetooth (iPhone):** iOS no deja que una app sea teclado Bluetooth; el iPhone anuncia un servicio Bluetooth LE y la app de escritorio se conecta sola.
- **WiFi:** la app de escritorio se anuncia en la red (mDNS/Bonjour) y el teléfono la encuentra sin escribir IPs. Si la red bloquea mDNS, se agrega por IP.
- **Navegador:** el teléfono sirve una página web; en la PC (o en una **tablet**) abres la dirección que muestra la app, por ejemplo `192.168.1.23:8080`, y ahí se proyecta. Se puede elegir PDF, `.pptx`, `.ppsx`, `.odp`, `.ppt` (y `.key` en iPhone).

### Presentar desde una tablet

En una tablet (Android o iPad) no se puede instalar el receptor: los sistemas no permiten que una app presione teclas en otra. Usa:

- **Teléfono Android en modo Bluetooth:** la tablet lo ve como teclado Bluetooth.
- **Modo “Transmitir desde móvil”:** abre la dirección del teléfono en Safari/Chrome de la tablet.

## Uso

1. Abre la app en el teléfono y elige el modo.
2. **Bluetooth Android:** “Emparejar nueva” → en la PC, Configuración → Bluetooth → agregar dispositivo → elige el teléfono. Las siguientes veces solo “Conectar” (o se conecta sola al abrir la app).
3. **Bluetooth iPhone / WiFi:** abre la app de escritorio en la PC (puede quedar minimizada), pon tu presentación al frente y en el teléfono elige tu PC.
4. **Navegador:** “Elegir presentación” → abre en la PC la dirección que aparece → “Pantalla completa”. La diapositiva aparece arriba de las notas: toma la pluma o el puntero (láser, foco o lupa) para dibujar o señalar.
5. **Ajustes** (icono arriba a la derecha): invertir botones, usar flechas ← → en vez de AvPág/RePág, tamaño de letra de las notas.

## Notas del presentador

| Modo | De dónde salen |
|---|---|
| **WiFi** | En la app de escritorio, recuadro **“Notas en el teléfono” → Elegir presentación**. Llegan solas al teléfono; si guardas cambios en el archivo se actualizan sin perder la diapositiva actual. La app de escritorio recuerda el archivo. |
| **Navegador** | Del mismo archivo que eliges para proyectar. |
| **Bluetooth** (o WiFi sin archivo en la PC) | **Ver notas del presentador** en el teléfono y eliges el archivo ahí. |

- **Notas** (barra de acciones): las notas ocupan casi toda la pantalla y los botones se hacen compactos. Se regresa con el mismo botón o con “atrás”. El tamaño del texto se elige en *Ajustes → Notas* y se recuerda.
- **Sincronía:** en Navegador es exacta. En Bluetooth y WiFi el teléfono **cuenta las pulsaciones**, incluidas las animaciones “al hacer clic” (igual que PowerPoint). Si se desfasa —por ejemplo, si cambiaste de diapositiva con el mouse— corrígelo con **− / +** en **Ir a** (no mueve nada en la PC).
- **Cada modo tiene sus propias notas:** las que eliges en “Control Bluetooth” no aparecen en “Transmitir desde móvil”, y viceversa. En “Transmitir desde PC” mandan las de la app de escritorio (si no hay, las que elijas en el teléfono para ese modo).
- Las diapositivas ocultas se saltan.

**Formatos con notas**

| Formato | Programas | Teléfono | App de escritorio |
|---|---|---|---|
| `.pptx` `.ppsx` | PowerPoint, OnlyOffice, WPS, Google Slides, Keynote (exportado) | ✅ | ✅ |
| `.pptm` `.ppsm` `.potx` `.potm` | PowerPoint | — | ✅ |
| `.odp` | LibreOffice, OpenOffice, OnlyOffice | ✅ | ✅ |
| `.otp` `.fodp` | LibreOffice | — | ✅ |
| `.ppt` `.pps` `.pot` `.key` `.dps` | PowerPoint 97–2003, Keynote, WPS | — | ✅ si la PC tiene **LibreOffice** instalado (los convierte en segundo plano) |
| `.pdf` | — | No trae notas | No trae notas |

## Empezar rápido: compilar en Linux, Mac o Windows

Tres pasos en cualquier sistema: **descargar el código → preparar la computadora → compilar**. Los scripts de preparación instalan todo (Flutter, compiladores, SDK de Android) y se pueden volver a correr sin problema.

**Linux (Ubuntu/Debian)**

```bash
sudo apt install -y git
git clone https://github.com/l-gonzo/slide_remote.git && cd slide_remote
bash tool/setup_linux.sh              # Flutter, compilador de Linux, Java 17, SDK de Android
source ~/.bashrc
python3 tool/build.py                 # → dist/: APK, .deb y .tar.gz
```

**macOS** (antes instala **Xcode** desde la App Store y ábrelo una vez)

```bash
git clone https://github.com/l-gonzo/slide_remote.git && cd slide_remote
bash tool/setup_macos.sh --android    # Xcode, Homebrew, CocoaPods, Flutter (+ Java y SDK de Android)
source ~/.zshrc
python3 tool/build.py                 # → dist/: APK, .dmg (y .ipa si configuraste la firma de Apple)
```

**Windows 10/11** (PowerShell)

```powershell
winget install -e --id Git.Git
# cierra y abre PowerShell
git clone https://github.com/l-gonzo/slide_remote.git; cd slide_remote
powershell -ExecutionPolicy Bypass -File tool\setup_windows.ps1 -Android   # VS 2022, Flutter, Inno Setup (+ Java y SDK de Android)
# cierra y abre PowerShell
py tool\build.py                      # → dist\: APK, instalador .exe y .zip
```

**`tool/build.py`** es igual en los tres sistemas:

| Comando | Qué hace | Dónde se puede |
|---|---|---|
| `python3 tool/build.py` | Todo lo que se puede compilar en esa computadora | todos |
| `python3 tool/build.py android` | APK (`dist/Zlide-<versión>-android-arm64.apk`, etc.) | todos |
| `python3 tool/build.py linux` | `.deb` + `.tar.gz` | Linux |
| `python3 tool/build.py windows` | Instalador `.exe` + `.zip` | Windows |
| `python3 tool/build.py macos` | `.dmg` | Mac |
| `python3 tool/build.py ios` | `.ipa` (con cuenta de Apple) | Mac |
| `python3 tool/build.py doctor` | Revisa qué falta | todos |

(En Windows escribe `py` en lugar de `python3`.)

**El convertidor a PDF de Android** (LibreOffice) solo se puede *compilar* en Linux, pero se sube una vez a GitHub y luego cualquier computadora lo descarga con `python3 tool/libreoffice_android.py fetch` antes de compilar el APK. Ver [Convertidor a PDF en Android](#convertidor-a-pdf-en-android-libreoffice).

## Instalación manual (lo que hacen los scripts)

Si prefieres instalar a mano, o un script falla en tu sistema. Necesitas **Flutter 3.35 o más reciente**. Cada app de escritorio se compila en su propio sistema; Android se compila desde cualquiera; iPhone y Mac solo desde una Mac.

| Quieres compilar | Desde |
|---|---|
| Android (APK) | Linux, Windows o Mac |
| Linux (.deb) | Linux |
| Windows (.exe) | Windows |
| macOS (.dmg) e iPhone | Mac |
| Convertidor LibreOffice para Android | Linux (~40 GB libres) |

### Ubuntu / Debian (Linux y Android)

```bash
# Herramientas, compilador para la app de Linux y Java para Android
sudo apt update
sudo apt install -y git curl unzip xz-utils zip python3 \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev build-essential \
  openjdk-17-jdk

# Flutter
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter --version

# SDK de Android (sin Android Studio)
# Descarga "Command line tools only" para Linux de https://developer.android.com/studio#command-tools
mkdir -p ~/Android/Sdk/cmdline-tools
unzip ~/Downloads/commandlinetools-linux-*_latest.zip -d ~/Android/Sdk/cmdline-tools
mv ~/Android/Sdk/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
cat >> ~/.bashrc <<'EOF'
export ANDROID_HOME=$HOME/Android/Sdk
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
EOF
source ~/.bashrc
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
flutter config --android-sdk "$ANDROID_HOME"
flutter doctor --android-licenses     # acepta todo con "y"

flutter doctor                        # Android toolchain y Linux toolchain en verde
```

(Si prefieres Android Studio: `sudo snap install android-studio --classic`, ábrelo una vez y deja que instale el SDK.)

### Windows 10/11 (app de Windows y Android)

En **PowerShell**:

```powershell
winget install -e --id Git.Git
winget install -e --id Python.Python.3.12
winget install -e --id Microsoft.VisualStudio.2022.Community --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive --wait"
winget install -e --id JRSoftware.InnoSetup          # para crear el instalador .exe

git clone https://github.com/flutter/flutter.git -b stable C:\src\flutter
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\src\flutter\bin', 'User')

start ms-settings:developers      # activa "Modo de desarrollador" (Flutter lo necesita para los plugins)
```

Cierra y abre PowerShell, y luego:

```powershell
flutter doctor                    # "Visual Studio - develop Windows apps" en verde
```

Para compilar también Android desde Windows: `winget install -e --id Google.AndroidStudio`, ábrelo una vez y luego `flutter doctor --android-licenses`.

### macOS (app de Mac e iPhone)

```bash
# 1. Instala Xcode desde la App Store y ábrelo una vez. Luego:
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
xcodebuild -downloadPlatform iOS          # simulador/SDK de iOS

# 2. Homebrew y CocoaPods
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git python cocoapods

# 3. Flutter
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

flutter doctor                            # Xcode y CocoaPods en verde
```

## Preparar el proyecto

Los scripts de `tool/setup_*` y `tool/build.py` ya lo hacen; a mano es:

```bash
python3 tool/configure.py        # en Windows: py tool\configure.py
```

`configure.py` ejecuta `flutter create` (solo agrega `android/`, `ios/`, `macos/`, `windows/` y `linux/`, sin tocar `lib/`), aplica permisos y ajustes de cada plataforma (Bluetooth, red local, entitlements de Mac, firma de Android, empaquetado de LibreOffice), descarga los paquetes y genera los íconos. Se puede correr cuantas veces quieras; córrelo otra vez después de actualizar el código.

> Esas carpetas generadas sí se suben a git (son parte del proyecto); `build/` y los archivos de LibreOffice no (están en `.gitignore`).

La versión de la app está en `pubspec.yaml` (`version: 2.6.0+8` → nombre `2.6.0`, número de compilación `8`). Súbela antes de publicar una actualización.

## Compilar e instalar / crear instaladores

`python3 tool/build.py <sistema>` hace todo lo de esta sección. Los instaladores quedan en **`dist/`**. Abajo están los detalles y los comandos sueltos.

### Android

```bash
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   ← este es para casi todos los teléfonos
#   (app-armeabi-v7a: teléfonos viejos de 32 bits; app-x86_64: emuladores)

adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk   # con el teléfono por USB
```

O copia el `.apk` al teléfono y ábrelo (permite “instalar apps desconocidas”).

- **Convertidor a PDF:** solo viene si antes compilaste LibreOffice (ver [abajo](#convertidor-a-pdf-en-android-libreoffice)). Sin él todo funciona menos convertir presentaciones en el modo “Transmitir desde móvil”.
- **Un solo APK para todos:** `flutter build apk --release` (más pesado).
- **Google Play:** `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab`.

**Firma propia (recomendado si vas a distribuir).** Sin ella se usa la llave de depuración de tu PC y otra PC no podría instalar actualizaciones encima. Una sola vez:

```bash
keytool -genkey -v -keystore ~/zlide.jks -keyalg RSA -keysize 2048 -validity 10000 -alias slideremote
cat > android/key.properties <<EOF
storeFile=$HOME/zlide.jks
storePassword=LA_CONTRASEÑA
keyAlias=slideremote
keyPassword=LA_CONTRASEÑA
EOF
python3 tool/configure.py       # activa la firma si existe android/key.properties
```

Guarda el `.jks` y la contraseña en un lugar seguro (sin ellos no puedes actualizar la app en Play). `key.properties` y `*.jks` no se suben a git. Si el teléfono tenía una versión firmada con otra llave, desinstálala antes.

### Linux (app de escritorio)

```bash
tool/package_linux.sh
# → dist/zlide_2.6.0_amd64.deb            (Ubuntu, Debian, Mint, Pop!_OS…)
# → dist/zlide_2.6.0_linux-amd64.tar.gz   (cualquier distribución)

sudo apt install ./dist/zlide_2.6.0_amd64.deb
```

El `.deb` agrega Zlide al menú de aplicaciones e instala la regla de udev para `/dev/uinput` (el permiso para presionar teclas). Si la app dice que falta el permiso, cierra y abre sesión una vez. Desinstalar: `sudo apt remove zlide`.

Solo probar sin instalar: `flutter run -d linux --release`.

### Windows (app de escritorio)

En PowerShell, dentro del proyecto:

```powershell
powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
# → dist\Zlide-Setup-2.6.0.exe            (instalador)
# → dist\Zlide-2.6.0-windows-x64.zip      (portátil: descomprimir y abrir slide_remote.exe)
```

El instalador crea el acceso en el menú Inicio y agrega la regla del firewall para redes privadas. Incluye las bibliotecas de Visual C++, así que funciona en PCs sin nada extra. Como no está firmado, SmartScreen puede avisar: **Más información → Ejecutar de todas formas**.

### macOS (app de escritorio)

```bash
tool/package_macos.sh
# → dist/Zlide-2.6.0-macos.dmg   (abrir y arrastrar a Aplicaciones)
```

Sin cuenta de desarrollador de Apple la app va firmada “ad hoc”: la primera vez ábrela con **clic derecho → Abrir** (o `xattr -dr com.apple.quarantine "/Applications/Zlide.app"`). Con cuenta de pago puedes firmarla con tu certificado: `SIGN_ID="Developer ID Application: Tu Nombre (EQUIPO)" tool/package_macos.sh` (y notarizarla con `xcrun notarytool` para que abra sin avisos).

### iPhone (y iPad como control remoto)

1. En la Mac: `open ios/Runner.xcworkspace` → *Runner* → *Signing & Capabilities* → elige tu equipo (sirve un Apple ID gratuito).
2. Con el iPhone conectado por cable (y el **Modo de desarrollador** activado en Ajustes → Privacidad y seguridad):

   ```bash
   flutter devices                       # copia el id del iPhone
   flutter run --release -d <id>
   ```

- **Apple ID gratuito:** la app deja de abrir a los 7 días; vuelve a correr el comando.
- **Cuenta de desarrollador (US$99/año):** se puede crear un instalador:

  ```bash
  flutter build ipa --release --export-method ad-hoc     # → build/ios/ipa/*.ipa (iPhones registrados)
  flutter build ipa --release                            # App Store / TestFlight
  ```

  Para TestFlight/App Store sube el `.ipa` con la app **Transporter** o desde Xcode (*Window → Organizer → Distribute App*).

### Publicar en GitHub los instaladores que ya compilaste

```bash
python3 tool/release.py --dry-run   # muestra qué encontró (en dist/ y build/)
python3 tool/release.py             # crea el release v<versión> y sube los que haya
```

Sube los que encuentre (APK, `.deb`, `.tar.gz`, `.exe`, `.zip`, `.dmg`, `.ipa`) más un `SHA256SUMS.txt`. Si el release ya existe, agrega o reemplaza archivos, así puedes correrlo en cada computadora (Linux, luego Windows, luego Mac) y se van juntando. Opciones: `--tag v2.0.1`, `--draft`, `--prerelease`, `--notes "…"`.

## Compilar en GitHub (todos los sistemas a la vez)

El proyecto trae `.github/workflows/build.yml`: GitHub compila en sus servidores con Linux, Windows y Mac, así no necesitas tener las tres computadoras.

- En cada `git push` a `main`: compila todo y deja los archivos en la pestaña **Actions** → la ejecución → **Artifacts**.
- Para publicar una versión:

  ```bash
  git tag v2.6.0
  git push --tags
  ```

  GitHub crea un **Release** con el APK, `.deb`, `.tar.gz`, `.exe`, `.zip` y `.dmg`, listos para descargar.

- El APK incluye el convertidor si antes subiste LibreOffice con `python3 tool/libreoffice_android.py upload`.
- **Firma de Android (opcional):** en el repositorio, *Settings → Secrets and variables → Actions*, agrega `ANDROID_KEYSTORE_BASE64` (sale de `base64 -w0 ~/zlide.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` y `ANDROID_KEY_PASSWORD`.
- La de iPhone solo se comprueba que compile (firmarla requiere tu cuenta de Apple; hazlo desde tu Mac).

## Convertidor a PDF en Android (LibreOffice)

El modo “Transmitir desde móvil” convierte presentaciones a PDF dentro del teléfono:

- **iPhone:** usa el visor de documentos de iOS. No hay que hacer nada.
- **Android:** usa LibreOffice compilado dentro de la app. No viene en el repositorio (pesa ~100 MB); se compila **una vez** en Linux:

```bash
tool/build_libreoffice_android.sh --deps    # la primera vez (instala paquetes con apt; pide sudo)
tool/build_libreoffice_android.sh           # las siguientes veces
```

Necesita ~40 GB libres y tarda de 1 a 4 horas (se puede cancelar con Ctrl+C y volver a correr; continúa donde iba). Descarga LibreOffice 26.8 en `~/libreoffice-android`, lo compila para arm64 y copia el resultado a `packages/slide_native/android/src/main/jniLibs` y `assets`. Después:

```bash
python3 tool/configure.py
flutter build apk --release --split-per-abi    # el convertidor va en app-arm64-v8a-release.apk
```

Si ya lo compilaste en otra carpeta del proyecto: `tool/build_libreoffice_android.sh --copy-only`.

**Usarlo en Mac, Windows u otra PC sin recompilar.** Después de compilarlo en Linux, súbelo una vez a un *release* de tu repositorio de GitHub (necesita `gh` con sesión iniciada: `gh auth login`):

```bash
python3 tool/libreoffice_android.py upload     # en la PC donde se compiló
```

Desde entonces, en cualquier computadora (y en GitHub Actions):

```bash
python3 tool/libreoffice_android.py fetch      # descarga ~100 MB y lo instala en el plugin
python3 tool/libreoffice_android.py status     # ¿está instalado?
python3 tool/build.py android
```

La primera conversión tarda unos segundos más (desempaca los archivos de LibreOffice). Además del PDF se genera un SVG con las animaciones y transiciones, que es lo que proyecta el navegador; las diapositivas ocultas no se exportan.

## Permisos y red

**App de escritorio**

- **macOS:** la primera vez pide **Accesibilidad** (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad → activa Zlide) y **Bluetooth**. La app trae un botón que abre el ajuste. Si actualizas la app y deja de presionar teclas, quítala de la lista de Accesibilidad y vuelve a agregarla.
- **Linux:** usa `/dev/uinput` (funciona en Wayland y X11). El `.deb` ya lo configura; si no usaste el `.deb`, la app muestra el comando para arreglarlo.
- **Windows:** el instalador agrega la regla del firewall. Con el `.zip`, al abrirla acepta en **Redes privadas**.

**Teléfono**

- **Android:** “Dispositivos cercanos” (Bluetooth). El teléfono necesita Android 9 o más reciente para el modo teclado.
- **iPhone:** Bluetooth y “Red local” (se piden al usarlos por primera vez).

**Puertos** (red local)

| Puerto | Uso |
|---|---|
| UDP 50505 | Comandos del teléfono a la app de escritorio |
| TCP 50506 | Notas de la PC al teléfono, “Proyectar en esta PC” (página en `http://127.0.0.1:50506/`) y dibujo (WebSocket `/phone`); solo responde a teléfonos que ya se conectaron y a esta misma PC |
| TCP 8080 (o el siguiente libre) | Página del modo “Transmitir desde móvil”, servida por el teléfono |

## Limitaciones

- La app del teléfono debe estar **abierta y al frente**. Al salir suelta el volumen y la conexión (para no interferir con otras apps); al volver se reconecta.
- **iPhone:** iOS no da acceso directo a los botones de volumen; la app detecta el cambio y regresa el volumen a 50 % en cada pulsación (al salir restaura tu volumen). Apple podría objetarlo si se publica en la App Store.
- WiFi y Navegador no tienen contraseña: alguien en la misma red podría cambiar la diapositiva (al presentar desde la PC solo obedece al teléfono que empezó). En la red de un salón no suele importar.
- Al proyectar con Zlide, las animaciones y transiciones necesitan la conversión a SVG: en la PC hace falta LibreOffice, y en iPhone el teléfono solo convierte a PDF (cada diapositiva completa). Para verlas siempre está “Presentar en su programa”. Los videos vinculados a un archivo externo (no insertados) y los formatos que el navegador no reproduce (wmv, avi) no aparecen.
- En redes que aíslan a los equipos (algunas de universidad u hotel), WiFi y Navegador no funcionan. Usa Bluetooth, o activa el punto de acceso del teléfono y conecta la PC a él.
- Las notas por WiFi solo viajan por WiFi (no por Bluetooth del iPhone).

## Solución de problemas

| Problema | Qué hacer |
|---|---|
| “Esta versión no incluye el convertidor” | Compilaste sin LibreOffice o instalaste el APK equivocado. Corre `tool/build_libreoffice_android.sh --copy-only`, luego `flutter clean` y compila; instala el `arm64-v8a`. |
| La app se cierra al convertir | Ver el error: `adb logcat \| grep -E "Zlide\|LibreOfficeKit\|lo-bootstrap\|DEBUG"`. |
| El APK pesa más de 200 MB | Vuelve a correr `python3 tool/configure.py` (quita una opción vieja que guardaba todo sin comprimir). |
| El teléfono no encuentra la PC por WiFi | Misma red; firewall en “Redes privadas”; o “Agregar por IP” con la IP que muestra la app de escritorio. |
| La app de escritorio recibe pero no cambia la diapositiva | Permiso de Accesibilidad (Mac) o `/dev/uinput` (Linux); la presentación debe estar al frente; prueba “Usar flechas ← →” en Ajustes. |
| Bluetooth Android no reconecta | Quita el teléfono de los dispositivos Bluetooth de la PC y empareja de nuevo con “Emparejar nueva”. |
| Windows: error de symlinks al compilar | Activa el Modo de desarrollador (`start ms-settings:developers`). |
| `bash\r: No such file or directory` o `$'\r'` al correr un `.sh` | El archivo se guardó con finales de línea de Windows. Con el `.gitattributes` del proyecto no pasa; si ya pasó, arréglalo con `sed -i 's/\r$//' tool/*.sh` (o vuelve a clonar). |
| PowerShell: “la ejecución de scripts está deshabilitada” | Usa `powershell -ExecutionPolicy Bypass -File …` como en los ejemplos. |
| `python3 tool/libreoffice_android.py fetch` da 404 | Aún no se sube: en la PC con Linux donde se compiló, `python3 tool/libreoffice_android.py upload`. Si el repo es privado, instala `gh` y `gh auth login`. |
| Después del cambio de nombre a Zlide | Android/iPhone se actualizan encima (mismo id). En **Linux** el `.deb` de Zlide reemplaza al de Slide Remote. En **Windows** el instalador actualiza la misma instalación. En **Mac** borra `Slide Remote.app` de Aplicaciones y vuelve a activar **Zlide** en Accesibilidad. Si el ícono viejo sigue apareciendo, reinicia el lanzador (o el teléfono). |
| `SDK XML version 4` (aviso) | No afecta. Se quita actualizando: `sdkmanager --update`. |

## Estructura del proyecto

```
lib/
  main.dart                       control remoto (teléfono) o receptor (PC)
  common/protocol.dart            puertos, UUIDs BLE, comandos
  common/theme.dart               colores y componentes de la interfaz
  common/i18n.dart                idioma (español/inglés): t('Texto', 'Text')
  common/pptx_notes.dart          lee notas, títulos y animaciones de .pptx y .odp
  common/deck_media.dart          videos y audios de .pptx/.odp (se ponen encima del PDF)
  common/link_view.dart           enlaces abiertos en la misma pantalla: proxy de páginas, YouTube
  common/web_page.dart            huella de la página web (recarga las pestañas viejas)
  mobile/remote_page.dart         pantalla del teléfono (presentar)
  mobile/connection_view.dart     elegir modo y conectar (hoja “Conexión”)
  mobile/settings_page.dart       ajustes
  mobile/stage_widgets.dart       botones, barra de acciones, bloqueo
  mobile/remote_controller.dart   modos, reconexión, notas (del teléfono o de la PC)
  mobile/wifi_client.dart         descubrimiento mDNS + UDP
  mobile/browser_server.dart      servidor web + WebSocket del modo “Transmitir desde móvil”
  mobile/slide_stage.dart         diapositiva en vivo: imagen, dibujo, herramientas, enlaces y videos
  mobile/link_panel.dart          controles del enlace abierto en la PC (página o YouTube)
  mobile/draw_source.dart         de dónde sale la diapositiva: PDF del teléfono (Navegador) o de la PC (WiFi)
  mobile/ink.dart                 trazos y puntero (láser, foco, lupa), enviados al navegador
  mobile/talk_timer.dart          cronómetro (guarda la hora de inicio)
  mobile/timer_chip.dart          botón del cronómetro
  mobile/native_bridge.dart       canal hacia el código nativo
  desktop/receiver_page.dart      ventana de la PC
  desktop/receiver_controller.dart  UDP + mDNS + Bluetooth LE
  desktop/notes_host.dart         notas para el teléfono (HTTP), conversión con LibreOffice
  desktop/key_injector.dart       teclas: SendInput / CGEventPost / uinput (dart:ffi)
  desktop/present_host.dart       “Proyectar en esta PC”: presentación en el navegador + dibujo
  desktop/office.dart             conversión con LibreOffice (o PowerPoint en Windows), a PDF y SVG
  desktop/quiet_mode.dart         avisos de la PC en silencio al presentar (Linux)
packages/slide_native/            plugin propio
  android/…/BtHidKeyboard.java    teclado Bluetooth HID
  android/…/SlideNativePlugin.java  volumen, permisos, “No molestar”
  android/…/PptxConverter.java    presentación → PDF con LibreOfficeKit
  android/…/PdfPageRenderer.java  página del PDF como imagen (diapositiva en vivo)
  android/…/org/libreoffice/kit/  clases JNI de LibreOffice (MPL 2.0)
  ios/Classes/SlideNativePlugin.swift      BLE periférico, volumen
  ios/Classes/PresentationConverter.swift  presentación → PDF con WebKit
assets/web/                       página del modo “Transmitir desde móvil” + pdf.js 4.10
tool/setup_linux.sh               prepara una PC con Linux desde cero
tool/setup_macos.sh               prepara una Mac desde cero
tool/setup_windows.ps1            prepara una PC con Windows desde cero
tool/build.py                     compila y crea instaladores (igual en los 3 sistemas)
tool/configure.py                 prepara las plataformas
tool/build_libreoffice_android.sh compila LibreOffice para el convertidor de Android (Linux)
tool/libreoffice_android.py       sube/descarga ese convertidor (release de GitHub)
tool/release.py                   sube los instaladores ya compilados a un release de GitHub
tool/package_linux.sh             crea .deb y .tar.gz
tool/package_windows.ps1          crea instalador .exe y .zip
tool/windows/slide_remote.iss     receta del instalador (Inno Setup)
tool/package_macos.sh             crea .dmg
.github/workflows/build.yml       compila todo en GitHub y publica los instaladores
.gitattributes                    finales de línea correctos en Linux, Mac y Windows
```

## Licencias

- **pdf.js** (modo “Transmitir desde móvil”): Apache 2.0.
- **LibreOffice** (convertidor de Android): MPL 2.0; el script copia su licencia dentro de la app.
- **Tipografías** (incluidas en la app, `assets/fonts/`): Atkinson Hyperlegible Next y Mono (Braille Institute) y Bricolage Grotesque (Mathieu Triay), las tres con SIL Open Font License 1.1. Se guardan como instancias estáticas de las fuentes variables; las licencias aparecen en la pantalla de licencias de la app.

## Diseño

Zlide sigue la dirección **“Foco”**, pensada para presentar de pie, en salas con poca luz, mirando el teléfono de reojo:

- **Neutros fríos** (grafito con un toque azul): no deslumbran a oscuras y dejan que lo más claro de la pantalla sean las notas.
- **Índigo “foco”** para la marca y la única acción principal de cada pantalla (Siguiente, empezar, lo elegido). El **contenedor tonal** (índigo muy suave) marca lo seleccionado o activo: el modo de conexión, el cronómetro en marcha, el contador de animaciones, los íconos de Ajustes.
- **Notas como en un atril:** directamente sobre el fondo, con letra grande (Atkinson Hyperlegible, hecha para leerse con facilidad).
- **Lo mejor de iOS y Material 3:** grupos redondeados con divisores interiores y selector segmentado con pastilla deslizable (iOS); botones tonales, estados claros y áreas táctiles de 48 px (Material 3). Contrastes WCAG AA en claro y oscuro.
- **El pulgar encuentra todo en el mismo lugar:** “anterior” y “siguiente” siempre lado a lado, con “siguiente” del lado de la mano, con o sin notas.
- El mismo sistema en las tres piezas: app del teléfono, app de escritorio y la página que ve el público. El ícono (`assets/icon/icon.svg`) se genera para todas las plataformas con `dart run flutter_launcher_icons`.

- **Tres estados** en la pantalla principal: *Preparar* (sin conexión: eliges modo y conectas), *Listo* (conectado y sin notas: indicaciones y cómo agregar notas) y *Presentar* (con notas). Si la conexión se cae con notas en pantalla, las notas se quedan y aparece un aviso para reconectar.
- **Una sola pantalla para presentar:** al transmitir, la diapositiva en vivo (dibujo, enlaces, videos) va arriba de las notas en lugar de una pantalla aparte. El espacio se reparte según lo que haces: tomar una herramienta agranda la diapositiva, *Notas* la esconde, y acostado el teléfono reparte diapositiva, notas y un riel de botones en el borde del pulgar.
- **La conexión está siempre a un toque:** la pastilla de estado de arriba abre la hoja *Conexión* (modo, PC, dirección).
- Todo el estilo está en `lib/common/theme.dart`: colores claro/oscuro (`Palette`), espaciado (`Sp`), radios (`Rad`), movimiento (`Mo`, respeta “reducir animaciones”) y tipografía (`Txt`).
