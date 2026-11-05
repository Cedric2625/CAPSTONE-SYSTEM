package ph.edu.carsu.vehicleguard.meshtransport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.UUID

/**
 * BLE-transport branch: every device runs this (there is no separate
 * "Group Owner" concept the way Wi-Fi Direct had — every phone is
 * simultaneously a GATT Peripheral/server for receiving, and can act as a
 * GATT Central/client (see [BleGattClient]) to send to a specific peer).
 * This sidesteps Wi-Fi Direct's group-formation negotiation stage entirely
 * — the exact stage real-device testing showed failing or dying within
 * under a second — since a BLE GATT connection has no equivalent
 * multi-step group negotiation; a Central either connects to a Peripheral
 * or it doesn't, with no separate "group" to form first.
 */
class BleGattServer(private val context: Context) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("8e35f9c2-7b1a-4e42-9c3a-6a1d9f2b7c41")
        val ALERT_CHARACTERISTIC_UUID: UUID = UUID.fromString("8e35f9c2-7b1a-4e42-9c3a-6a1d9f2b7c42")
    }

    interface Listener {
        /**
         * Fired once per sender token the first time it's heard from in
         * this session (including an empty-payload connection probe —
         * see [BleGattClient]/`requestConnectionTo`, which has no separate
         * "connected" step beyond a successfully decoded frame).
         */
        fun onPeerConnected(senderToken: String)

        /** A complete, non-empty framed message was received and decoded. */
        fun onMessageReceived(senderToken: String, payload: ByteArray)
        fun onError(message: String)

        /** Non-error diagnostic info — stage milestones for System Logs. */
        fun onInfo(message: String) {}
    }

    var listener: Listener? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var gattServer: BluetoothGattServer? = null

    // One accumulator per currently-connected device address — a GATT
    // write's chunks must never be mixed between two different peers'
    // in-flight messages.
    private val accumulators = mutableMapOf<String, BleFraming.Accumulator>()

    // Tracked by TOKEN (not device address, which can rotate) so a peer is
    // only ever reported "connected" once per mesh session, matching how
    // the Wi-Fi Direct branch's onPeerConnected only fired once per actual
    // connection rather than once per message.
    private val knownSenderTokens = mutableSetOf<String>()

    // addService() is asynchronous — Android confirms registration later via
    // onServiceAdded, not at the addService() call site. Real-device testing
    // showed peers seeing "characteristic not found" when they connected and
    // called discoverServices() before this device's service had actually
    // finished registering (most likely after a mesh restart, which tears
    // down and recreates the GATT server). This flag reflects the real,
    // confirmed state rather than assuming addService() succeeded instantly.
    @Volatile
    private var serviceReady = false

    fun isServiceReady(): Boolean = serviceReady

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        serviceReady = false
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (manager == null) {
            listener?.onError("BLUETOOTH_SERVICE unavailable on this device")
            return false
        }
        val server = try {
            manager.openGattServer(context, serverCallback)
        } catch (e: Exception) {
            listener?.onError("openGattServer failed: ${e.message}")
            return false
        }
        if (server == null) {
            listener?.onError("openGattServer returned null — this device's chipset may not support the GATT server (Peripheral) role")
            return false
        }
        gattServer = server

        val characteristic = BluetoothGattCharacteristic(
            ALERT_CHARACTERISTIC_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        try {
            server.addService(service)
        } catch (e: Exception) {
            listener?.onError("addService failed: ${e.message}")
            return false
        }
        return true
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        accumulators.clear()
        knownSenderTokens.clear()
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                accumulators.remove(device.address)
            }
        }

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                serviceReady = true
                mainHandler.post { listener?.onInfo("BLE GATT server: alert service registered and ready") }
            } else {
                mainHandler.post {
                    listener?.onError(
                        "BLE GATT server: alert service failed to register (status=$status) — " +
                            "incoming connections from peers will see \"characteristic not found\" " +
                            "until this device's mesh restarts"
                    )
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value
                    )
                } catch (_: Exception) {
                }
            }
            if (characteristic.uuid != ALERT_CHARACTERISTIC_UUID) return
            val accumulator = accumulators.getOrPut(device.address) { BleFraming.Accumulator() }
            val decoded = try {
                accumulator.feed(value)
            } catch (e: Exception) {
                listener?.onError("Malformed BLE write from ${device.address}: ${e.message}")
                accumulator.reset()
                null
            }
            if (decoded != null) {
                if (knownSenderTokens.add(decoded.senderToken)) {
                    listener?.onPeerConnected(decoded.senderToken)
                }
                // An empty payload is a connection probe only (see
                // requestConnectionTo) — not a real alert, so it must not
                // reach Dart's onPayloadReceived/alert-ingest path at all.
                if (decoded.payload.isNotEmpty()) {
                    listener?.onInfo(
                        "BLE GATT server: received alert payload (${decoded.payload.size} bytes) " +
                            "from ${decoded.senderToken}"
                    )
                    listener?.onMessageReceived(decoded.senderToken, decoded.payload)
                }
            }
        }
    }
}
