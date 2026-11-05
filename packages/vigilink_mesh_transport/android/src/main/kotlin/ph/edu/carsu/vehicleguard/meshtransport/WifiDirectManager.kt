package ph.edu.carsu.vehicleguard.meshtransport

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.net.wifi.WpsInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Handler
import android.os.Looper

/**
 * Wraps `WifiP2pManager` directly — real Wi-Fi Direct, no Play Services
 * involved — for group formation and as the data-plane for the mesh. BLE
 * ([BleMeshBeacon]) decides *when* and *which* peer to connect to; this
 * class only forms/tracks the group and reports the resulting
 * Group-Owner-or-Client role and address.
 */
class WifiDirectManager(private val context: Context) {

    companion object {
        const val SOCKET_PORT = 57341

        // Android's own discoverPeers() scan runs for about 12s each time
        // it's triggered; re-triggering it before that window closes is a
        // common, real cause of BUSY/ERROR from the very next call — a
        // shorter interval here (10s) guaranteed that overlap on every
        // single cycle. 20s gives real margin.
        private const val DISCOVERY_INTERVAL_MS = 20_000L

        // A real test showed Android's WPS-based connect() negotiation can
        // hang with no callback at all — neither a group-formed broadcast
        // nor onFailure — leaving isBusy stuck true forever with no way to
        // recover. This bounds how long a single connect attempt is
        // trusted before it's treated as failed.
        //
        // Originally 15s — a real test then showed THAT was itself a bug:
        // on some Android/OEM combinations this negotiation surfaces a
        // system "Invitation to connect" dialog that needs a human to
        // notice and tap Accept, which routinely takes longer than 15s
        // during real two-phone testing. 15s was cancelling the attempt
        // (manager.cancelConnect()) before the person even finished
        // responding to their own phone's prompt — the connection then
        // failed not because the negotiation itself was broken, but
        // because this app gave up on it first. 60s gives real response
        // time while still recovering from a genuinely hung negotiation.
        private const val CONNECT_TIMEOUT_MS = 60_000L
    }

    interface Listener {
        fun onGroupFormed(isGroupOwner: Boolean, groupOwnerAddress: String?)
        fun onGroupLost()
        fun onConnectFailed(deviceAddress: String)

        /** Surfaces `discoverPeers`/`connect` failures, including
         * P2P_UNSUPPORTED — a device genuinely lacking Wi-Fi Direct
         * support, which a null-check alone can't detect since `initialize`
         * still returns a channel either way. */
        fun onWifiDirectError(message: String)
    }

    private fun reasonText(reason: Int): String = when (reason) {
        WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct not supported on this device"
        WifiP2pManager.BUSY -> "busy (another request already in flight)"
        WifiP2pManager.ERROR -> "internal error"
        else -> "error code $reason"
    }

    var listener: Listener? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var discoveryRunnable: Runnable? = null
    private var groupFormed = false

    /**
     * True while a connect negotiation is in flight, or while already part
     * of a group (as either Group Owner or Client). A single Wi-Fi Direct
     * radio can only really do one negotiation — or be in one group — at a
     * time; without this gate, 2+ phones in range at once can each fire
     * several overlapping `connect()` calls before any of them resolve. A
     * Group Owner with clients already joined has no need to call
     * `connectTo` itself — new peers connect TO it on their own — so
     * staying "busy" while grouped stops it from trying to initiate
     * anything further, until this device later moves out of range and
     * `handleConnectionChanged` clears it again, letting it discover/connect
     * afresh — this is what lets a moving device carry an alert from one
     * group to the next over time (store-carry-forward), even though it can
     * only belong to one group at any single moment.
     */
    @Volatile
    var isBusy = false
        private set

    @Volatile
    var peers: List<WifiP2pDevice> = emptyList()
        private set

    // Android's own Wi-Fi power-saving is a well-known, real cause of a
    // freshly-formed Wi-Fi Direct link dying within a second or two — a
    // pattern confirmed repeatedly across several real device tests this
    // session (connects, then "Device disconnected" moments later, with no
    // app-level send even having succeeded yet). Holding a high-performance
    // lock for as long as the mesh is active tells Android not to let the
    // Wi-Fi radio drop into a power-save state that would do that.
    private var wifiLock: WifiManager.WifiLock? = null

    @SuppressLint("MissingPermission")
    fun start() {
        val mgr = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        if (mgr == null) {
            listener?.onWifiDirectError("WIFI_P2P_SERVICE unavailable on this device")
            return
        }
        manager = mgr
        channel = try {
            mgr.initialize(context, context.mainLooper, null)
        } catch (e: Exception) {
            listener?.onWifiDirectError("WifiP2pManager.initialize failed: ${e.message}")
            return
        }

        try {
            val wifiManager =
                context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiLock == null) {
                wifiLock = wifiManager?.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "VigilinkMesh:wifiDirect"
                )?.apply { setReferenceCounted(false) }
            }
            wifiLock?.acquire()
        } catch (e: Exception) {
            listener?.onWifiDirectError("Could not acquire Wi-Fi high-perf lock: ${e.message}")
        }

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> requestPeers()
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> handleConnectionChanged()
                }
            }
        }
        receiver = r
        context.registerReceiver(r, filter)
        ensureDiscoveryLoop()
    }

    fun stop() {
        discoveryRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryRunnable = null
        connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        connectTimeoutRunnable = null
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
        try {
            manager?.removeGroup(channel, null)
        } catch (_: Exception) {
        }
        channel = null
        manager = null
        groupFormed = false
        isBusy = false
        lastDiscoverFailure = null
        peers = emptyList()
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
    }

    // Collapses repeated identical discoverPeers failures into a single
    // report instead of one every DISCOVERY_INTERVAL_MS — an occasional
    // BUSY/ERROR during normal operation is expected noise, not something
    // worth a fresh toast every 20 seconds forever.
    private var lastDiscoverFailure: String? = null

    @SuppressLint("MissingPermission")
    private fun ensureDiscoveryLoop() {
        val r = object : Runnable {
            override fun run() {
                // Already connected/connecting — this device doesn't need
                // to keep scanning for more peers, and a repeated discover
                // call here is a common, real source of BUSY/ERROR against
                // the connection attempt itself.
                if (!isBusy) {
                    try {
                        manager?.discoverPeers(channel, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() {
                                lastDiscoverFailure = null
                            }

                            override fun onFailure(reason: Int) {
                                val msg = "discoverPeers failed: ${reasonText(reason)}"
                                if (msg != lastDiscoverFailure) {
                                    lastDiscoverFailure = msg
                                    listener?.onWifiDirectError(msg)
                                }
                            }
                        })
                    } catch (e: Exception) {
                        val msg = "discoverPeers threw: ${e.message}"
                        if (msg != lastDiscoverFailure) {
                            lastDiscoverFailure = msg
                            listener?.onWifiDirectError(msg)
                        }
                    }
                }
                mainHandler.postDelayed(this, DISCOVERY_INTERVAL_MS)
            }
        }
        discoveryRunnable = r
        mainHandler.post(r)
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers() {
        try {
            manager?.requestPeers(channel) { list: WifiP2pDeviceList ->
                peers = list.deviceList.toList()
            }
        } catch (e: Exception) {
            listener?.onWifiDirectError("requestPeers threw: ${e.message}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleConnectionChanged() {
        try {
            manager?.requestConnectionInfo(channel) { info: WifiP2pInfo ->
                if (info.groupFormed) {
                    connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                    connectTimeoutRunnable = null
                    groupFormed = true
                    isBusy = true
                    listener?.onGroupFormed(info.isGroupOwner, info.groupOwnerAddress?.hostAddress)
                } else if (groupFormed) {
                    groupFormed = false
                    isBusy = false
                    listener?.onGroupLost()
                }
            }
        } catch (e: Exception) {
            listener?.onWifiDirectError("requestConnectionInfo threw: ${e.message}")
        }
    }

    // How long to wait for connect() to actually resolve (group formed, via
    // the WIFI_P2P_CONNECTION_CHANGED_ACTION broadcast, or a clean
    // onFailure) before giving up on it. Confirmed as a real gap from an
    // actual test: both phones showed "already busy/grouped" and
    // "Connecting..." FOREVER, with isBusy never clearing — meaning
    // Android's WPS push-button negotiation (what connect() uses under the
    // hood) can simply hang with no callback either way, not just fail
    // cleanly. There was nothing to recover from that until now.
    private var connectTimeoutRunnable: Runnable? = null

    /** No-op if already negotiating or grouped — see [isBusy]. */
    @SuppressLint("MissingPermission")
    fun connectTo(device: WifiP2pDevice) {
        if (isBusy) return
        isBusy = true
        val config = WifiP2pConfig().apply {
            deviceAddress = device.deviceAddress
            wps.setup = WpsInfo.PBC
        }
        val timeout = Runnable {
            connectTimeoutRunnable = null
            if (!isBusy || groupFormed) return@Runnable
            isBusy = false
            try {
                manager?.cancelConnect(channel, null)
            } catch (_: Exception) {
            }
            listener?.onWifiDirectError(
                "connect to ${device.deviceAddress} timed out after ${CONNECT_TIMEOUT_MS / 1000}s with no response — Android's own Wi-Fi Direct negotiation never resolved"
            )
            listener?.onConnectFailed(device.deviceAddress)
        }
        connectTimeoutRunnable = timeout
        mainHandler.postDelayed(timeout, CONNECT_TIMEOUT_MS)
        manager?.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {
                connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                connectTimeoutRunnable = null
                isBusy = false
                listener?.onWifiDirectError("connect failed: ${reasonText(reason)}")
                listener?.onConnectFailed(device.deviceAddress)
            }
        })
    }

    /**
     * Without a way to set this device's own Wi-Fi Direct name (the hidden
     * `WifiP2pManager.setDeviceName` isn't part of the public SDK), target
     * selection can't match a specific BLE-discovered peer by name. Instead:
     * always prefer a peer that is already a Group Owner — joining an
     * existing group — over negotiating a brand new pairwise one, since a
     * device already serving as GO for another peer usually can't also
     * accept a second, separate P2P negotiation on the same radio. This is
     * what lets a 3rd phone join the first pair's group instead of forming
     * a disconnected second one.
     */
    fun pickConnectTarget(excluding: Set<String>): WifiP2pDevice? {
        val candidates = peers.filter {
            it.deviceAddress !in excluding && it.status != WifiP2pDevice.CONNECTED
        }
        return candidates.firstOrNull { it.isGroupOwner } ?: candidates.firstOrNull()
    }
}
