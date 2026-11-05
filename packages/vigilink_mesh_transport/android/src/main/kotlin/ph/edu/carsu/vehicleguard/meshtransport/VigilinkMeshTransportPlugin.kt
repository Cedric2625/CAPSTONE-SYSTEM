package ph.edu.carsu.vehicleguard.meshtransport

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * BLE-TRANSPORT BRANCH (ble-transport-test) — replaces Wi-Fi Direct +
 * TCP sockets with BLE GATT for both discovery (unchanged, via
 * [BleMeshBeacon]) and actual alert data transfer (new: [BleGattServer]/
 * [BleGattClient]). See those classes' doc comments for why: real device
 * testing on the Wi-Fi Direct branch repeatedly showed a connection
 * forming and then dying within under a second, during Wi-Fi Direct's own
 * group-formation negotiation stage — a stage BLE GATT connections don't
 * have an equivalent of. This is an untested hypothesis, not a confirmed
 * fix; see Progress.md for the honest status.
 *
 * The Dart-facing method/event contract is unchanged from the Wi-Fi
 * Direct branch on purpose, so nothing above this plugin
 * (`nearby_mesh_service.dart` and everything built on it) needed to
 * change at all. The endpoint id used everywhere is still the peer's BLE
 * beacon TOKEN — now also literally the value embedded in every BLE GATT
 * message's header (see `BleFraming`), not just the advertisement.
 */
class VigilinkMeshTransportPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var ble: BleMeshBeacon
    private lateinit var gattServer: BleGattServer

    private var myDisplayName: String = "VIGILINK User"
    private var serviceId: String = ""
    private var isActive = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        ble = BleMeshBeacon(context).also { it.listener = bleListener }
        gattServer = BleGattServer(context).also { it.listener = gattServerListener }

        methodChannel = MethodChannel(binding.binaryMessenger, "vigilink_mesh_transport/methods")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "vigilink_mesh_transport/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        ensureStopped()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startAdvertising", "startDiscovery" -> {
                myDisplayName = call.argument<String>("userNickName") ?: myDisplayName
                serviceId = call.argument<String>("serviceId") ?: serviceId
                call.argument<String>("deviceToken")?.let { ble.setToken(it) }
                ble.setDisplayName(myDisplayName)
                val force = call.argument<Boolean>("force") ?: false
                if (force) {
                    forceRestart(result)
                } else {
                    result.success(ensureStarted())
                }
            }
            "stopAdvertising", "stopDiscovery", "stopAllEndpoints" -> {
                ensureStopped()
                result.success(null)
            }
            "requestConnection" -> {
                val id = call.argument<String>("endpointId")
                if (id == null) {
                    result.success(false)
                    return
                }
                result.success(requestConnectionTo(id))
            }
            "acceptConnection" -> {
                // Same as the Wi-Fi Direct branch: nothing separate to
                // accept — a complete incoming GATT write already IS the
                // connection as far as this transport is concerned.
                result.success(true)
            }
            "sendBytesPayload" -> {
                val id = call.argument<String>("endpointId")
                val bytes = call.argument<ByteArray>("bytes")
                if (id == null || bytes == null) {
                    result.success(false)
                    return
                }
                sendTo(id, bytes, result)
            }
            else -> result.notImplemented()
        }
    }

    // Same debounce reasoning as the Wi-Fi Direct branch — see that
    // version's doc comment. Routine stop-then-start (the watchdog,
    // the background hand-off timer) just resumes the already-running
    // radios; only a genuine "Restart Scan" tears anything down for real.
    private var teardownPending = false
    private var teardownRunnable: Runnable? = null

    private fun ensureStarted(): Boolean {
        if (isActive) return true
        if (teardownPending) {
            teardownRunnable?.let { mainHandler.removeCallbacks(it) }
            teardownRunnable = null
            teardownPending = false
            isActive = true
            return true
        }
        if (!ble.start()) return false
        val serverStarted = gattServer.start()
        isActive = serverStarted
        return serverStarted
    }

    private fun forceRestart(result: Result) {
        teardownRunnable?.let { mainHandler.removeCallbacks(it) }
        teardownRunnable = null
        teardownPending = false
        if (isActive) {
            gattServer.stop()
            ble.stop()
            isActive = false
        }
        gattQueue.clear()
        gattBusyAddresses.clear()
        mainHandler.postDelayed({
            val bleStarted = ble.start()
            val started = bleStarted && gattServer.start()
            isActive = started
            result.success(started)
        }, HARD_RESET_DELAY_MS)
    }

    private fun ensureStopped() {
        if (!isActive) return
        isActive = false
        teardownPending = true
        val r = Runnable {
            teardownPending = false
            teardownRunnable = null
            gattServer.stop()
            ble.stop()
            gattQueue.clear()
            gattBusyAddresses.clear()
        }
        teardownRunnable = r
        mainHandler.postDelayed(r, TEARDOWN_DEBOUNCE_MS)
    }

    companion object {
        private const val TEARDOWN_DEBOUNCE_MS = 6_000L
        private const val HARD_RESET_DELAY_MS = 1_500L

        // Real test confirmed this: a connect-probe and the catch-up
        // loop's several sendTo calls (one per currently-stored alert) all
        // fired at once, each opening its OWN connectGatt() to the SAME
        // peer address — overlapping GATT connections to one remote
        // device is a well-known real cause of Android's generic BLE
        // error 133 ("disconnected before send completed"), which is
        // exactly what the logs showed. A short gap between releasing one
        // queued operation and starting the next gives the BLE stack time
        // to actually finish releasing the previous connection first.
        private const val GATT_QUEUE_GAP_MS = 400L
    }

    // Serializes every BLE GATT operation (the connection probe AND every
    // real send) by target device address, so this device never has two
    // overlapping connectGatt() calls to the same peer in flight — see
    // GATT_QUEUE_GAP_MS above for why that matters.
    private val gattQueue = mutableMapOf<String, ArrayDeque<() -> Unit>>()
    private val gattBusyAddresses = mutableSetOf<String>()

    private fun runSerializedOnAddress(address: String, action: () -> Unit) {
        val queue = gattQueue.getOrPut(address) { ArrayDeque() }
        queue.addLast(action)
        if (gattBusyAddresses.add(address)) {
            runNextQueued(address)
        }
    }

    private fun runNextQueued(address: String) {
        val next = gattQueue[address]?.removeFirstOrNull()
        if (next == null) {
            gattBusyAddresses.remove(address)
            return
        }
        next()
    }

    private fun releaseAddressAfterDelay(address: String) {
        mainHandler.postDelayed({ runNextQueued(address) }, GATT_QUEUE_GAP_MS)
    }

    /**
     * A GATT connect-probe to confirm this peer is actually reachable —
     * there is no separate "group formation" step the way Wi-Fi Direct
     * had, so a successful empty-payload send IS the connection check.
     * Returns quickly (true once the attempt has genuinely started, not
     * once it resolves) to match what Dart's retry logic already expects
     * from the Wi-Fi Direct branch — the real result arrives later via
     * [handleConnected]/[onTransportError], same as before.
     */
    private fun requestConnectionTo(endpointId: String): Boolean {
        val device = ble.deviceForToken(endpointId)
        if (device == null) {
            sendEvent(
                mapOf(
                    "event" to "onTransportInfo",
                    "message" to "requestConnection($endpointId) failed — BLE hasn't discovered this peer's device yet (or its advertising address has since rotated)"
                )
            )
            return false
        }
        runSerializedOnAddress(device.address) {
            val client = BleGattClient(context)
            client.listener = object : BleGattClient.Listener {
                override fun onResult(success: Boolean, detail: String) {
                    if (success) {
                        handleConnected(endpointId, "VIGILINK User", incoming = false)
                    } else {
                        sendEvent(
                            mapOf(
                                "event" to "onTransportError",
                                "message" to "BLE GATT connection attempt to $endpointId failed: $detail"
                            )
                        )
                    }
                    releaseAddressAfterDelay(device.address)
                }
            }
            client.send(device, ble.myCurrentToken, ByteArray(0))
        }
        return true
    }

    private fun sendTo(endpointId: String, bytes: ByteArray, result: Result) {
        val device = ble.deviceForToken(endpointId)
        if (device == null) {
            sendEvent(
                mapOf(
                    "event" to "onTransportError",
                    "message" to "sendBytesPayload: no BLE device known for endpoint $endpointId (not discovered, or its address rotated since)"
                )
            )
            result.success(false)
            return
        }
        runSerializedOnAddress(device.address) {
            val client = BleGattClient(context)
            client.listener = object : BleGattClient.Listener {
                override fun onResult(success: Boolean, detail: String) {
                    if (!success) {
                        sendEvent(
                            mapOf(
                                "event" to "onTransportError",
                                "message" to "sendBytesPayload to $endpointId failed: $detail"
                            )
                        )
                    }
                    result.success(success)
                    releaseAddressAfterDelay(device.address)
                }
            }
            client.send(device, ble.myCurrentToken, bytes)
        }
    }

    // ── BLE: presence/signaling → Dart's onEndpointFound/onEndpointLost ──
    private val bleListener = object : BleMeshBeacon.Listener {
        override fun onBeaconSeen(token: String, isGroupOwner: Boolean, deviceName: String?) {
            sendEvent(
                mapOf(
                    "event" to "onEndpointFound",
                    "endpointId" to token,
                    "endpointName" to (deviceName ?: "VIGILINK User"),
                    "serviceId" to serviceId
                )
            )
        }

        override fun onBeaconLost(token: String) {
            sendEvent(mapOf("event" to "onEndpointLost", "endpointId" to token))
        }

        override fun onBleError(message: String) {
            sendEvent(mapOf("event" to "onTransportError", "message" to message))
        }

        override fun onBleInfo(message: String) {
            sendEvent(mapOf("event" to "onTransportInfo", "message" to message))
        }
    }

    // ── BLE GATT server: incoming writes from peers acting as Central ──
    private val gattServerListener = object : BleGattServer.Listener {
        override fun onPeerConnected(senderToken: String) {
            handleConnected(senderToken, "VIGILINK User", incoming = true)
        }

        override fun onMessageReceived(senderToken: String, payload: ByteArray) {
            handlePayload(senderToken, payload)
        }

        override fun onError(message: String) {
            sendEvent(mapOf("event" to "onTransportError", "message" to "BLE GATT server: $message"))
        }
    }

    private fun handleConnected(peerToken: String, name: String, incoming: Boolean) {
        sendEvent(
            mapOf(
                "event" to "onConnectionInitiated",
                "endpointId" to peerToken,
                "endpointName" to name,
                "isIncomingConnection" to incoming
            )
        )
        sendEvent(mapOf("event" to "onConnectionResult", "endpointId" to peerToken, "statusCode" to 0))
    }

    private fun handlePayload(peerToken: String, bytes: ByteArray) {
        sendEvent(mapOf("event" to "onPayloadReceived", "endpointId" to peerToken, "bytes" to bytes))
    }

    private fun sendEvent(map: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(map) }
    }
}
