package ph.edu.carsu.vehicleguard.meshtransport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper

/**
 * BLE-transport branch, Central/client role. One instance handles exactly
 * one send: connect to the target's GATT server, write the framed message
 * (chunked to whatever MTU actually gets negotiated — defaulting to the
 * guaranteed-safe minimum until/unless a larger one is confirmed), then
 * disconnect. A fresh instance is created per send rather than keeping a
 * persistent connection, trading a little latency for not depending on a
 * long-lived connection staying healthy — the exact assumption that broke
 * down repeatedly with Wi-Fi Direct's persistent sockets.
 */
class BleGattClient(private val context: Context) {

    interface Listener {
        fun onResult(success: Boolean, detail: String)
    }

    companion object {
        // ATT_MTU defaults to 23 bytes, 3 of which are protocol overhead —
        // 20 is the one chunk size guaranteed to fit without negotiating
        // anything. Upgraded automatically if onMtuChanged reports more
        // before writing begins.
        private const val SAFE_CHUNK_BYTES = 20
        private const val OPERATION_TIMEOUT_MS = 15_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var chunks: List<ByteArray> = emptyList()
    private var nextChunkIndex = 0
    private var chunkBytes = SAFE_CHUNK_BYTES
    private var timeoutRunnable: Runnable? = null
    private var finished = false
    var listener: Listener? = null

    @SuppressLint("MissingPermission")
    fun send(device: BluetoothDevice, myToken: String, payload: ByteArray) {
        val frame = BleFraming.encode(myToken, payload)
        chunks = frame.toList().chunked(chunkBytes).map { it.toByteArray() }
        val timeout = Runnable {
            finish(false, "BLE GATT send to ${device.address} timed out after ${OPERATION_TIMEOUT_MS / 1000}s")
        }
        timeoutRunnable = timeout
        mainHandler.postDelayed(timeout, OPERATION_TIMEOUT_MS)
        gatt = try {
            device.connectGatt(context, false, gattCallback)
        } catch (e: Exception) {
            finish(false, "connectGatt threw: ${e.message}")
            return
        }
        if (gatt == null) finish(false, "connectGatt returned null")
    }

    @SuppressLint("MissingPermission")
    fun close() {
        try {
            gatt?.disconnect()
        } catch (_: Exception) {
        }
        try {
            gatt?.close()
        } catch (_: Exception) {
        }
        gatt = null
    }

    private fun finish(success: Boolean, detail: String) {
        if (finished) return
        finished = true
        timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        timeoutRunnable = null
        close()
        listener?.onResult(success, detail)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (finished) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                try {
                    g.requestMtu(517)
                } catch (_: Exception) {
                }
                try {
                    g.discoverServices()
                } catch (e: Exception) {
                    finish(false, "discoverServices threw: ${e.message}")
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (!finished) finish(false, "disconnected before send completed (status=$status)")
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && mtu > chunkBytes + 3) {
                // Re-chunk the still-unsent remainder at the larger size —
                // only matters if writing hasn't started yet, which is the
                // common case since discoverServices/onMtuChanged usually
                // resolve close together.
                if (nextChunkIndex == 0) {
                    chunkBytes = mtu - 3
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (finished) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                finish(false, "discoverServices failed (status=$status)")
                return
            }
            val service = g.getService(BleGattServer.SERVICE_UUID)
            val characteristic = service?.getCharacteristic(BleGattServer.ALERT_CHARACTERISTIC_UUID)
            if (characteristic == null) {
                finish(false, "VIGILINK alert characteristic not found on peer — it may not be running this BLE transport branch")
                return
            }
            // Re-slice at the (possibly now-larger) negotiated chunk size
            // before the first write, if onMtuChanged already landed.
            val fullBytes = chunks.flatMap { it.toList() }
            chunks = fullBytes.chunked(chunkBytes).map { it.toByteArray() }
            nextChunkIndex = 0
            writeNextChunk(g, characteristic)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (finished) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                finish(false, "characteristic write failed at chunk $nextChunkIndex (status=$status)")
                return
            }
            if (nextChunkIndex >= chunks.size) {
                finish(true, "sent ${chunks.size} chunk(s)")
                return
            }
            writeNextChunk(g, characteristic)
        }

        // setValue+writeCharacteristic(characteristic) is deprecated in
        // favor of writeCharacteristic(characteristic, value, writeType)
        // starting API 33, but that newer overload doesn't exist on this
        // module's minSdk 29 — the deprecated form still works correctly
        // on every API level up through current Android, which is why
        // it's kept here rather than branching on SDK version for a
        // cosmetic lint warning.
        @Suppress("DEPRECATION")
        @SuppressLint("MissingPermission")
        private fun writeNextChunk(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (nextChunkIndex >= chunks.size) {
                finish(true, "sent ${chunks.size} chunk(s)")
                return
            }
            val chunk = chunks[nextChunkIndex]
            nextChunkIndex++
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            characteristic.value = chunk
            val started = try {
                g.writeCharacteristic(characteristic)
            } catch (e: Exception) {
                finish(false, "writeCharacteristic threw: ${e.message}")
                return
            }
            if (!started) {
                finish(false, "writeCharacteristic returned false at chunk ${nextChunkIndex - 1}")
            }
        }
    }
}
