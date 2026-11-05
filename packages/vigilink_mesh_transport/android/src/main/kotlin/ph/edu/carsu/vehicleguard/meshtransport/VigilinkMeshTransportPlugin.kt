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
 * Ties [BleMeshBeacon] (discovery/signaling) and [WifiDirectManager] +
 * [MeshSocketServer]/[MeshSocketClient] (connection + data transfer)
 * together behind the same method/event shape `nearby_mesh_service.dart`
 * already expects from `package:nearby_connections`, so that file's own
 * public API and watchdog logic don't need to change — only what it calls
 * into underneath. See the plan this was built from for the full design.
 *
 * The endpoint id used everywhere here — in events to Dart, and in
 * `requestConnection`/`sendBytesPayload` calls from Dart — is always the
 * peer's BLE beacon TOKEN (see `BleMeshBeacon`'s class doc for why: a BLE
 * device's advertising address rotates, the token doesn't). There used to
 * be a separate address↔token translation layer here because Dart's
 * endpoint id was the (rotating) address; that was the root cause of a real
 * bug — ghost duplicate "devices" and messages going to a stale, no-longer-
 * valid connection — so it's gone now, not just patched.
 */
class VigilinkMeshTransportPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var ble: BleMeshBeacon
    private lateinit var wifiDirect: WifiDirectManager

    private var meshSocketServer: MeshSocketServer? = null
    private var meshSocketClient: MeshSocketClient? = null

    private var myDisplayName: String = "VIGILINK User"
    private var serviceId: String = ""
    private var isActive = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        ble = BleMeshBeacon(context).also { it.listener = bleListener }
        wifiDirect = WifiDirectManager(context).also { it.listener = wifiListener }

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
                    result.success(ensureStarted(force = false))
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
                // The socket handshake already fully establishes the
                // connection by the time Dart sees onConnectionInitiated —
                // there is no separate accept step to perform natively.
                result.success(true)
            }
            "sendBytesPayload" -> {
                val id = call.argument<String>("endpointId")
                val bytes = call.argument<ByteArray>("bytes")
                result.success(if (id != null && bytes != null) sendTo(id, bytes) else false)
            }
            else -> result.notImplemented()
        }
    }

    // Dart's own restart pattern (watchdog refresh, the background
    // hand-off timer, "Restart Scan") always calls stop-then-immediately-
    // start as one pair. Actually tearing down and recreating the BLE
    // radios on every one of those pairs is what was silently throttling
    // scanning: Android has an undocumented limit on how often an app can
    // restart BLE scanning before it starts delivering degraded/delayed
    // results with no error at all — which looks exactly like "Found 0"
    // forever despite every call reporting success. Real test logs showed
    // exactly this churn pattern (several full restarts within seconds,
    // from switching apps during testing). Debouncing the actual teardown
    // means a stop immediately followed by a start just resumes the
    // already-running radios untouched; only a stop with no start
    // within [TEARDOWN_DEBOUNCE_MS] actually tears anything down.
    private var teardownPending = false
    private var teardownRunnable: Runnable? = null

    private fun ensureStarted(force: Boolean): Boolean {
        if (isActive) return true
        if (teardownPending) {
            teardownRunnable?.let { mainHandler.removeCallbacks(it) }
            teardownRunnable = null
            teardownPending = false
            isActive = true
            return true
        }
        if (!ble.start()) return false
        wifiDirect.start()
        isActive = true
        return true
    }

    /**
     * A genuine user-requested hard reset (Dart's "Restart Scan", and the
     * watchdog's 90s stale-radio refresh) always really tears down and
     * rebuilds — see `NearbyMeshService.restart` for why this must not be
     * debounced like the routine stop-then-start pattern. Confirmed by real
     * testing that stopping and restarting BLE in the very same instant is
     * itself a bug: Android's Bluetooth stack doesn't always finish
     * releasing the previous advertise/scan session that fast, so the
     * restart collided with its own shutdown and failed with "already
     * started" — every single time, forever, since nothing ever recovered.
     * [HARD_RESET_DELAY_MS] gives the OS a moment to actually finish
     * stopping before this starts again.
     */
    private fun forceRestart(result: Result) {
        teardownRunnable?.let { mainHandler.removeCallbacks(it) }
        teardownRunnable = null
        teardownPending = false
        if (isActive) {
            meshSocketServer?.stop()
            meshSocketServer = null
            meshSocketClient?.stop()
            meshSocketClient = null
            wifiDirect.stop()
            ble.stop()
            isActive = false
        }
        mainHandler.postDelayed({
            val started = ble.start()
            if (started) wifiDirect.start()
            isActive = started
            result.success(started)
        }, HARD_RESET_DELAY_MS)
    }

    private fun ensureStopped() {
        if (!isActive) {
            return
        }
        isActive = false
        teardownPending = true
        val r = Runnable {
            teardownPending = false
            teardownRunnable = null
            meshSocketServer?.stop()
            meshSocketServer = null
            meshSocketClient?.stop()
            meshSocketClient = null
            wifiDirect.stop()
            ble.stop()
        }
        teardownRunnable = r
        mainHandler.postDelayed(r, TEARDOWN_DEBOUNCE_MS)
    }

    companion object {
        private const val TEARDOWN_DEBOUNCE_MS = 6_000L
        // 500ms was too short a gap for Android's Bluetooth stack to
        // reliably finish releasing the previous BLE advertiser slot before
        // a new one is requested — over many restart cycles in a long real
        // test session (every "Restart Scan" tap, every watchdog refresh),
        // a slot that didn't fully release in time can be left orphaned,
        // and enough of those piling up is what produces "too many
        // advertisers already running" even though this app only ever
        // intends to run one at a time. 1500ms gives real margin.
        private const val HARD_RESET_DELAY_MS = 1_500L
    }

    private fun requestConnectionTo(endpointId: String): Boolean {
        // There's no reliable way to match this specific BLE-discovered
        // token to one exact WifiP2pDevice (see
        // WifiDirectManager.pickConnectTarget) — endpointId still drives
        // Dart's own jitter/dedup bookkeeping, but the actual Wi-Fi Direct
        // target is just the best available peer. wifiDirect.isBusy
        // (checked inside connectTo) already covers "already negotiating or
        // grouped" — including a Group Owner, which has no need to call
        // connectTo itself since new peers join it on their own.
        if (wifiDirect.isBusy) {
            sendEvent(
                mapOf(
                    "event" to "onTransportInfo",
                    "message" to "requestConnection($endpointId) skipped — already busy/grouped"
                )
            )
            return false
        }
        // This used to fail completely silently — no log on either side —
        // which, combined with a 20s pending-request lockout before any
        // retry, could leave a request looking "stuck" for up to 50s with
        // zero visibility into why. The real cause is almost always timing:
        // Android's own Wi-Fi Direct peer discovery is a separate, slower
        // process than BLE's, so this device's native peer list can still
        // be empty even though BLE already found the peer moments ago.
        val device = wifiDirect.pickConnectTarget(excluding = emptySet())
        if (device == null) {
            sendEvent(
                mapOf(
                    "event" to "onTransportInfo",
                    "message" to "requestConnection($endpointId) failed — no Wi-Fi Direct peer discovered yet on this device (native discovery still catching up)"
                )
            )
            return false
        }
        wifiDirect.connectTo(device)
        return true
    }

    /**
     * "No socket found" used to mean two genuinely different things with
     * one indistinguishable message: the endpoint was never registered at
     * all, or it WAS registered and the write itself threw. A real test
     * showed the identical failure recurring even after a connection had
     * been stable for seconds, with a retry also failing — which of those
     * two cases this actually is could not be told from the log alone.
     * Every path below now reports which one it is, and the current
     * registered state, so the next failure is diagnosable instead of
     * another guess.
     */
    private fun sendTo(endpointId: String, bytes: ByteArray): Boolean {
        val server = meshSocketServer
        val client = meshSocketClient

        if (server != null && server.connectedIds().contains(endpointId)) {
            if (server.send(endpointId, bytes)) return true
            reportSendFailure(
                endpointId,
                "registered as a server-side socket for this endpoint, but the write itself failed (socket likely broken, not missing)"
            )
            return false
        }
        if (client != null) {
            val currentToken = client.currentEndpointToken()
            if (currentToken == endpointId) {
                if (client.send(bytes)) return true
                reportSendFailure(
                    endpointId,
                    "this device's client socket matches this endpoint, but the write itself failed (socket likely broken, not missing)"
                )
                return false
            }
            reportSendFailure(
                endpointId,
                "this device is acting as a Wi-Fi Direct client, but its only connected peer's token is '${currentToken ?: "none"}', not this one"
            )
            return false
        }
        reportSendFailure(
            endpointId,
            "no socket registered for this endpoint at all (server registry=${server?.connectedIds() ?: "no server role"}, client role=${if (client == null) "none" else "present but checked above"})"
        )
        return false
    }

    private fun reportSendFailure(endpointId: String, detail: String) {
        // The caller also gets `false` back directly from sendTo, so it can
        // correct its own "sent"/"relayed" bookkeeping instead of only
        // hearing about this as an untargeted log line.
        sendEvent(
            mapOf(
                "event" to "onTransportError",
                "message" to "sendBytesPayload: no usable socket for endpoint $endpointId — $detail"
            )
        )
    }

    // ── BLE: presence/signaling → Dart's onEndpointFound/onEndpointLost ──
    private val bleListener = object : BleMeshBeacon.Listener {
        override fun onBeaconSeen(token: String, isGroupOwner: Boolean, deviceName: String?) {
            sendEvent(
                mapOf(
                    "event" to "onEndpointFound",
                    "endpointId" to token,
                    // The real Bluetooth device name if Android exposes one
                    // for this scan result, otherwise a generic placeholder
                    // until the socket handshake reveals the app's own
                    // display name on actual connection.
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

    // ── Wi-Fi Direct: group formation → start the right socket role ──
    private val wifiListener = object : WifiDirectManager.Listener {
        override fun onGroupFormed(isGroupOwner: Boolean, groupOwnerAddress: String?) {
            if (isGroupOwner) {
                ble.updateRole(true)
                if (meshSocketServer == null) {
                    meshSocketServer = MeshSocketServer(
                        myDisplayName,
                        ble.myCurrentToken,
                        onConnected = { peerToken, name -> handleConnected(peerToken, name, incoming = true) },
                        onPayload = { peerToken, bytes -> handlePayload(peerToken, bytes) },
                        onDisconnected = { peerToken -> handleDisconnected(peerToken) }
                    ).also { it.start() }
                }
            } else {
                val goAddress = groupOwnerAddress ?: return
                if (meshSocketClient == null) {
                    meshSocketClient = MeshSocketClient(
                        myDisplayName,
                        ble.myCurrentToken,
                        onConnected = { peerToken, name -> handleConnected(peerToken, name, incoming = false) },
                        onPayload = { peerToken, bytes -> handlePayload(peerToken, bytes) },
                        onDisconnected = { peerToken -> handleDisconnected(peerToken) }
                    ).also { it.connect(goAddress) }
                }
            }
        }

        override fun onGroupLost() {
            meshSocketServer?.stop()
            meshSocketServer = null
            meshSocketClient?.stop()
            meshSocketClient = null
            ble.updateRole(false)
        }

        override fun onConnectFailed(deviceAddress: String) {
            // deviceAddress is the Wi-Fi Direct device's own address — a
            // different id namespace than the BLE token "endpointId" used
            // everywhere else, and there's no reliable way to map one to
            // the other (see WifiDirectManager.pickConnectTarget's doc).
            // Routing this through onConnectionResult as if it were a
            // result for a specific BLE-tracked endpoint was a real,
            // confirmed bug: Dart's discoveredEndpoints lookup (keyed by
            // BLE token) always missed, producing a misleading "Unknown
            // Device" error, AND the real pending BLE-token request never
            // actually got cleared (removing a key that was never there is
            // a no-op) — delaying recovery by up to the full 20s pending-
            // timeout instead of being immediate. A plain transport-level
            // message is the honest representation of what's actually
            // known here.
            sendEvent(
                mapOf(
                    "event" to "onTransportError",
                    "message" to "Wi-Fi Direct connection attempt to $deviceAddress failed"
                )
            )
        }

        override fun onWifiDirectError(message: String) {
            // "busy" just means a connect/discover attempt overlapped with
            // one already in flight or with an existing group — expected
            // and harmless while connecting/connected, not something the
            // user needs to see as an error toast. Still worth keeping out
            // of the error channel entirely rather than spamming it.
            if (message.contains("busy", ignoreCase = true)) return
            sendEvent(mapOf("event" to "onTransportError", "message" to message))
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

    private fun handleDisconnected(peerToken: String) {
        sendEvent(mapOf("event" to "onDisconnected", "endpointId" to peerToken))
    }

    private fun sendEvent(map: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(map) }
    }
}
