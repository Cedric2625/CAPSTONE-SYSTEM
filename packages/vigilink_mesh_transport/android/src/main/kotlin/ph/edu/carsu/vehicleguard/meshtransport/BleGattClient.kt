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

    /**
     * Fired at each GATT stage milestone so System Logs show real progress
     * ("connected, discovering services" / "characteristic found, sending
     * N chunk(s)") instead of only a final success/failure line — requested
     * explicitly so a future failure can be diagnosed from logs alone
     * instead of guessed at.
     */
    var onStageInfo: ((String) -> Unit)? = null

    companion object {
        // ATT_MTU defaults to 23 bytes, 3 of which are protocol overhead —
        // 20 is the one chunk size guaranteed to fit without negotiating
        // anything. Upgraded automatically if onMtuChanged reports more
        // before writing begins.
        private const val SAFE_CHUNK_BYTES = 20

        // If onMtuChanged never arrives at all (the same class of stalled-
        // GATT-callback bug that motivated sequencing discoverServices()
        // after it in the first place), this fallback still moves on to
        // discoverServices() instead of silently consuming the entire
        // operation timeout waiting for a callback that may never come.
        private const val MTU_FALLBACK_MS = 2_000L

        // Raised from 15s: real-device testing kept hitting this timeout
        // even with retries, with no onStageInfo milestone (connected /
        // characteristic found) appearing first in some cases — meaning
        // the connection itself was still negotiating, not stuck on a slow
        // write. More patience per attempt, combined with
        // VigilinkMeshTransportPlugin's own retries, trades speed for a
        // real chance to ride out radio contention — bounded, not infinite,
        // so this can't hang forever the way the old Wi-Fi Direct connect()
        // did before it got a timeout at all.
        private const val OPERATION_TIMEOUT_MS = 30_000L
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

    /**
     * Abandons this operation WITHOUT calling the listener — for when the
     * mesh itself is restarting/stopping while this send is still
     * in-flight. A plain close() leaves [finished] false, so the native
     * gattCallback (e.g. onConnectionStateChange firing DISCONNECTED once
     * the restart tears down the radio underneath this orphaned operation)
     * would still call finish(false, "disconnected before send completed
     * (status=133)") afterward — a confusing, misleading failure for a
     * send that was never really trying anymore, and a stray retry
     * scheduled on a mesh that's already moved on. Marking finished first
     * makes every later callback a no-op (they all already check it).
     */
    @SuppressLint("MissingPermission")
    fun cancel() {
        if (finished) return
        finished = true
        timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        timeoutRunnable = null
        close()
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

    // Set once discoverServices() has actually been called, so it's only
    // ever invoked exactly once per connection (from whichever of
    // onMtuChanged / the fallback timer gets there first).
    private var discoverServicesCalled = false

    @SuppressLint("MissingPermission")
    private fun callDiscoverServices(g: BluetoothGatt) {
        if (finished || discoverServicesCalled) return
        discoverServicesCalled = true
        try {
            g.discoverServices()
        } catch (e: Exception) {
            finish(false, "discoverServices threw: ${e.message}")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (finished) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                onStageInfo?.invoke("BLE GATT connected to ${g.device.address} — negotiating MTU")
                // discoverServices() used to fire in the SAME tick as
                // requestMtu() here. Android's GATT stack generally only
                // handles one outstanding operation per connection at a
                // time — firing a second one before the first resolves is
                // a documented real cause of onServicesDiscovered simply
                // never firing at all (not failing — never calling back),
                // which is exactly what real-device logs showed: "connected,
                // discovering services" logged, then nothing until the
                // whole operation timed out. Now strictly sequenced:
                // discoverServices() only runs once onMtuChanged reports
                // back (success OR failure) below. A short fallback timer
                // covers the case where onMtuChanged itself never fires
                // either, which this same class of bug could also cause.
                try {
                    g.requestMtu(517)
                } catch (_: Exception) {
                    callDiscoverServices(g)
                    return
                }
                mainHandler.postDelayed({
                    if (!discoverServicesCalled) {
                        onStageInfo?.invoke("BLE GATT: MTU negotiation callback never arrived — discovering services anyway")
                    }
                    callDiscoverServices(g)
                }, MTU_FALLBACK_MS)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (!finished) finish(false, "disconnected before send completed (status=$status)")
            }
        }

        @SuppressLint("MissingPermission")
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
            onStageInfo?.invoke("BLE GATT: MTU negotiation resolved (status=$status) — discovering services")
            callDiscoverServices(g)
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
            onStageInfo?.invoke(
                "BLE GATT alert characteristic found on ${g.device.address} — sending ${chunks.size} chunk(s)"
            )
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
                onStageInfo?.invoke("BLE GATT alert write completed to ${g.device.address} (${chunks.size} chunk(s))")
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
