package dev.lgonzo.slide_native;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothHidDevice;
import android.bluetooth.BluetoothHidDeviceAppSdpSettings;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;

/**
 * Convierte el teléfono en un teclado Bluetooth (perfil HID Device, Android 9+).
 * La PC (Windows, macOS, Linux) lo ve como un teclado normal: no necesita software.
 *
 * Ciclo de vida: start() al entrar a la app, pause() al salir (suelta la PC para que el
 * volumen funcione normal en otras apps), stop() al destruir.
 * Todos los métodos se llaman desde el hilo principal y asumen permisos concedidos.
 */
@TargetApi(28)
@SuppressLint("MissingPermission")
final class BtHidKeyboard {

    enum State { UNAVAILABLE, OFF, IDLE, CONNECTING, CONNECTED }

    interface Listener {
        void onHidState(State state, BluetoothDevice device, String message);
    }

    private static final int REPORT_ID = 1;
    private static final int MAX_RETRIES = 2;
    private static final long RETRY_DELAY_MS = 1500;

    // Descriptor de teclado estándar: 1 byte de modificadores, 1 reservado, 6 teclas.
    private static final byte[] DESCRIPTOR = new byte[]{
            0x05, 0x01,                     // Usage Page (Generic Desktop)
            0x09, 0x06,                     // Usage (Keyboard)
            (byte) 0xA1, 0x01,              // Collection (Application)
            (byte) 0x85, REPORT_ID,         //   Report ID (1)
            0x05, 0x07,                     //   Usage Page (Key Codes)
            0x19, (byte) 0xE0,              //   Usage Minimum (224)
            0x29, (byte) 0xE7,              //   Usage Maximum (231)
            0x15, 0x00,                     //   Logical Minimum (0)
            0x25, 0x01,                     //   Logical Maximum (1)
            0x75, 0x01,                     //   Report Size (1)
            (byte) 0x95, 0x08,              //   Report Count (8)
            (byte) 0x81, 0x02,              //   Input (Data, Variable, Absolute) ; modificadores
            (byte) 0x95, 0x01,              //   Report Count (1)
            0x75, 0x08,                     //   Report Size (8)
            (byte) 0x81, 0x01,              //   Input (Constant) ; reservado
            (byte) 0x95, 0x06,              //   Report Count (6)
            0x75, 0x08,                     //   Report Size (8)
            0x15, 0x00,                     //   Logical Minimum (0)
            0x25, 0x65,                     //   Logical Maximum (101)
            0x05, 0x07,                     //   Usage Page (Key Codes)
            0x19, 0x00,                     //   Usage Minimum (0)
            0x29, 0x65,                     //   Usage Maximum (101)
            (byte) 0x81, 0x00,              //   Input (Data, Array) ; teclas
            (byte) 0xC0                     // End Collection
    };

    private final Context ctx;
    private final Listener listener;
    private final BluetoothAdapter adapter;
    private final Executor executor = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    private BluetoothHidDevice hid;
    private boolean proxyRequested = false;
    private boolean registered = false;
    private boolean active = false;
    private BluetoothDevice host;      // PC conectada ahora
    private BluetoothDevice target;    // PC a la que queremos estar conectados
    private int retriesLeft = MAX_RETRIES;

    BtHidKeyboard(Context ctx, Listener listener) {
        this.ctx = ctx.getApplicationContext();
        this.listener = listener;
        BluetoothManager bm = (BluetoothManager) this.ctx.getSystemService(Context.BLUETOOTH_SERVICE);
        this.adapter = bm != null ? bm.getAdapter() : null;
    }

    boolean isAvailable() { return adapter != null; }
    boolean isEnabled() { return adapter != null && adapter.isEnabled(); }
    BluetoothDevice getHost() { return host; }

    private void emit(State s, BluetoothDevice d, String msg) {
        main.post(() -> listener.onHidState(s, d, msg));
    }

    /** Activa el teclado. Si autoConnect no es null intenta conectarse a esa PC. */
    void start(BluetoothDevice autoConnect) {
        if (adapter == null) { emit(State.UNAVAILABLE, null, Lang.t("Este teléfono no tiene Bluetooth", "This phone has no Bluetooth")); return; }
        if (!adapter.isEnabled()) { emit(State.OFF, null, null); return; }
        active = true;
        if (autoConnect != null) { target = autoConnect; retriesLeft = MAX_RETRIES; }
        if (hid == null) {
            if (!proxyRequested) {
                proxyRequested = true;
                if (!adapter.getProfileProxy(ctx, serviceListener, BluetoothProfile.HID_DEVICE)) {
                    proxyRequested = false;
                    emit(State.UNAVAILABLE, null, Lang.t("Este teléfono no soporta el modo teclado Bluetooth", "This phone does not support Bluetooth keyboard mode"));
                }
            }
        } else if (!registered) {
            register(hid);
        } else if (host == null) {
            connectTarget();
        } else {
            emit(State.CONNECTED, host, null);
        }
    }

    /** Al salir de la app: soltar la PC y dar de baja el teclado (se conserva el proxy). */
    void pause() {
        active = false;
        main.removeCallbacksAndMessages(null);
        if (hid == null) return;
        if (host != null) hid.disconnect(host);
        host = null;
        if (registered) { hid.unregisterApp(); registered = false; }
    }

    void stop() {
        pause();
        if (hid != null && adapter != null) adapter.closeProfileProxy(BluetoothProfile.HID_DEVICE, hid);
        hid = null;
        proxyRequested = false;
    }

    List<BluetoothDevice> bondedDevices() {
        if (adapter == null) return Collections.emptyList();
        Set<BluetoothDevice> set = adapter.getBondedDevices();
        List<BluetoothDevice> out = set != null ? new ArrayList<>(set) : new ArrayList<>();
        Collections.sort(out, (a, b) -> label(a).compareToIgnoreCase(label(b)));
        return out;
    }

    BluetoothDevice deviceFor(String address) {
        if (adapter == null || address == null || !BluetoothAdapter.checkBluetoothAddress(address)) return null;
        return adapter.getRemoteDevice(address);
    }

    static String label(BluetoothDevice d) {
        String n = d.getName();
        return n != null ? n : d.getAddress();
    }

    void connect(BluetoothDevice d) {
        target = d;
        retriesLeft = MAX_RETRIES;
        if (registered) connectTarget(); else start(null);
    }

    /** Reintento rápido (p. ej. al presionar volumen sin conexión). */
    boolean reconnect() {
        if (target == null || host != null) return false;
        retriesLeft = MAX_RETRIES;
        if (registered) connectTarget(); else start(null);
        return true;
    }

    /** Desconexión pedida por el usuario: no se reintenta. */
    void disconnect() {
        target = null;
        main.removeCallbacksAndMessages(null);
        if (hid != null && host != null) hid.disconnect(host);
    }

    /** Pulsa y suelta una tecla (código de uso HID). false si no hay PC conectada. */
    boolean tap(final byte usage) {
        final BluetoothHidDevice h = hid;
        final BluetoothDevice d = host;
        if (h == null || d == null) return false;
        final byte[] down = new byte[]{0, 0, usage, 0, 0, 0, 0, 0};
        final byte[] up = new byte[8];
        executor.execute(() -> {
            h.sendReport(d, REPORT_ID, down);
            h.sendReport(d, REPORT_ID, up);
        });
        return true;
    }

    // ------------------------------------------------------------------ interno

    private void register(BluetoothHidDevice h) {
        BluetoothHidDeviceAppSdpSettings sdp = new BluetoothHidDeviceAppSdpSettings(
                "Slide Remote", "Slide remote control", "l-gonzo",
                BluetoothHidDevice.SUBCLASS1_KEYBOARD, DESCRIPTOR);
        if (!h.registerApp(sdp, null, null, executor, hidCallback)) {
            emit(State.IDLE, null, Lang.t("No se pudo activar el teclado Bluetooth", "Could not start the Bluetooth keyboard"));
        }
    }

    private void connectTarget() {
        if (hid == null || !active) return;
        if (target == null) { emit(State.IDLE, null, null); return; }
        emit(State.CONNECTING, target, null);
        if (!hid.connect(target)) scheduleRetryOrGiveUp(target);
    }

    private void scheduleRetryOrGiveUp(BluetoothDevice d) {
        boolean same = target != null && target.getAddress().equals(d.getAddress());
        if (active && same && retriesLeft > 0) {
            retriesLeft--;
            emit(State.CONNECTING, d, null);
            main.postDelayed(this::connectTarget, RETRY_DELAY_MS);
        } else {
            emit(State.IDLE, d, Lang.t("No se pudo conectar. ¿La PC está encendida y con Bluetooth?", "Could not connect. Is the computer on, with Bluetooth enabled?"));
        }
    }

    private final BluetoothProfile.ServiceListener serviceListener = new BluetoothProfile.ServiceListener() {
        @Override
        public void onServiceConnected(int profile, BluetoothProfile proxy) {
            if (profile != BluetoothProfile.HID_DEVICE) return;
            hid = (BluetoothHidDevice) proxy;
            if (active) register(hid);
        }

        @Override
        public void onServiceDisconnected(int profile) {
            hid = null;
            proxyRequested = false;
            registered = false;
            host = null;
            emit(State.IDLE, null, Lang.t("Servicio Bluetooth detenido", "Bluetooth service stopped"));
        }
    };

    // Los callbacks llegan en el executor; los cambios de estado se pasan al hilo principal.
    private final BluetoothHidDevice.Callback hidCallback = new BluetoothHidDevice.Callback() {
        @Override
        public void onAppStatusChanged(BluetoothDevice pluggedDevice, boolean isRegistered) {
            main.post(() -> {
                registered = isRegistered;
                if (!isRegistered) { host = null; return; }
                if (!active) return;
                if (target == null && pluggedDevice != null) target = pluggedDevice;
                if (target != null) connectTarget(); else emit(State.IDLE, null, null);
            });
        }

        @Override
        public void onConnectionStateChanged(BluetoothDevice device, int state) {
            main.post(() -> {
                boolean isTarget = target != null && target.getAddress().equals(device.getAddress());
                switch (state) {
                    case BluetoothProfile.STATE_CONNECTED:
                        host = device;
                        target = device;
                        retriesLeft = MAX_RETRIES;
                        emit(State.CONNECTED, device, null);
                        break;
                    case BluetoothProfile.STATE_CONNECTING:
                        emit(State.CONNECTING, device, null);
                        break;
                    case BluetoothProfile.STATE_DISCONNECTED: {
                        boolean wasConnected = host != null && host.getAddress().equals(device.getAddress());
                        if (wasConnected) host = null;
                        if (!active) return;
                        if (isTarget) {
                            if (wasConnected) retriesLeft = MAX_RETRIES; // se cayó: intentar recuperar
                            scheduleRetryOrGiveUp(device);
                        } else {
                            emit(State.IDLE, device, null);
                        }
                        break;
                    }
                    default:
                        break;
                }
            });
        }
    };
}
