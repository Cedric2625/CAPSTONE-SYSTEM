package ph.edu.carsu.vehicleguard.meshtransport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.UUID

/**
 * Pure presence beacon over BLE advertise/scan — never carries alert data,
 * only "a VIGILINK node is nearby" plus its current Wi-Fi Direct role/token
 * so [WifiDirectManager] knows which peer to actually connect to. Raw
 * AOSP BLE APIs only, no Google Play Services involved, so this has no
 * internet dependency of any kind.
 *
 * Every peer is identified by its beacon TOKEN, never by
 * `ScanResult.device.address`. Android periodically rotates a device's BLE
 * advertising address for privacy — confirmed the real cause of a real-world
 * bug where the same two physical phones showed up as 7+ "different"
 * devices, each a dead "Connecting…" entry, and messages silently went to
 * the wrong (stale) connection. The token is generated once per role and
 * travels in the advertisement itself, so it stays stable across address
 * rotation; it only changes when this device's own role actually changes
 * (see [updateRole]).
 */
class BleMeshBeacon(private val context: Context) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("8e35f9c2-7b1a-4e42-9c3a-6a1d9f2b7c40")

        // Not a Bluetooth SIG-registered company ID — acceptable for a
        // local-only beacon that only this app's own installs ever parse.
        const val MANUFACTURER_ID = 0x5750
        private const val LOST_TIMEOUT_MS = 15_000L
        private const val SWEEP_INTERVAL_MS = 5_000L

        fun newRandomToken(): String {
            val chars = "0123456789abcdef"
            return (1..8).map { chars.random() }.joinToString("")
        }
    }

    interface Listener {
        /**
         * [token] is the stable peer identity — see the class doc.
         * [deviceName] is the OS-level Bluetooth name for this device, if
         * Android happens to expose one for this scan result (often
         * available when the two phones are already paired/bonded via
         * classic Bluetooth, sometimes not otherwise) — purely cosmetic for
         * the "Nearby Devices" list; never required for anything to work.
         */
        fun onBeaconSeen(token: String, isGroupOwner: Boolean, deviceName: String?)
        fun onBeaconLost(token: String)

        /**
         * `startAdvertising`/`startScan` return immediately and report real
         * success/failure asynchronously via callback — a null check on the
         * adapter alone (what `start()` does) can't see a failure like
         * ADVERTISE_FAILED_FEATURE_UNSUPPORTED that only shows up here.
         */
        fun onBleError(message: String)

        /** Non-error diagnostic info — see the first-scan-result/first-advertise-
         * confirmation checks below. */
        fun onBleInfo(message: String)
    }

    var listener: Listener? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter: BluetoothAdapter? get() = bluetoothManager.adapter
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null

    private var myRole = false
    private var myToken = newRandomToken()

    // The OS-level Bluetooth device name is usually unavailable for an
    // unpaired device, and the app's own display name only becomes known
    // once connected (via the socket handshake) — which is why "Nearby
    // Devices" used to show a generic placeholder for every peer before
    // connecting. Embedding the real display name directly in the
    // advertisement fixes that; truncated to this many UTF-8 bytes to stay
    // within the legacy 31-byte advertisement limit alongside the role/
    // token bytes (dropping the service UUID — see advertiseCurrentRole —
    // freed the room for this).
    private var myDisplayName = ""
    private val maxNameBytes = 16

    fun setDisplayName(name: String) {
        if (myDisplayName == name) return
        myDisplayName = name
        if (advertiser != null) advertiseCurrentRole()
    }

    private var advertiseConfirmed = false
    private var sawAnyScanResult = false

    // Keyed by the peer's beacon TOKEN, not its (rotating) BLE address.
    private val lastSeenAt = mutableMapOf<String, Long>()
    private val roleByToken = mutableMapOf<String, Boolean>()

    // BLE-transport branch addition: a GATT connection needs an actual
    // BluetoothDevice object to connect to, which a pure presence beacon
    // never needed before. Updated on every scan result (not just
    // first-seen) so it always reflects this peer's current advertising
    // address even after Android rotates it — stale otherwise.
    private val deviceByToken = mutableMapOf<String, BluetoothDevice>()

    private var sweepRunnable: Runnable? = null

    fun roleOf(token: String): Boolean = roleByToken[token] ?: false
    fun deviceForToken(token: String): BluetoothDevice? = deviceByToken[token]
    val myCurrentToken: String get() = myToken

    /**
     * Lets Dart supply a token that persists across this device's own
     * foreground/background hand-off (see `NearbyMeshService`'s hand-off
     * logic): the foreground app and the background service each run in a
     * separate Flutter engine/isolate, so each gets its OWN BleMeshBeacon
     * instance via `onAttachedToEngine` and would otherwise each generate a
     * different random token at construction — splitting one physical
     * phone into two identities right at the hand-off boundary, which is
     * exactly what produced duplicate "found" entries and sends to a
     * peer's now-stale token. No-op if [token] isn't a valid 8-hex-char
     * value or is already current.
     */
    fun setToken(token: String) {
        if (token.length != 8 || token.toLongOrNull(16) == null) return
        if (myToken == token) return
        myToken = token
        if (advertiser != null) advertiseCurrentRole()
    }

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        val bleAdapter = adapter
        if (bleAdapter == null) {
            listener?.onBleError("No Bluetooth adapter on this device")
            return false
        }
        if (!bleAdapter.isEnabled) {
            listener?.onBleError("Bluetooth is switched off")
            return false
        }
        advertiser = bleAdapter.bluetoothLeAdvertiser
        scanner = bleAdapter.bluetoothLeScanner
        if (advertiser == null) {
            listener?.onBleError("This device's Bluetooth chipset doesn't support BLE advertising (peripheral role)")
            return false
        }
        if (scanner == null) {
            listener?.onBleError("This device's Bluetooth chipset doesn't support BLE scanning")
            return false
        }

        advertiseCurrentRole()
        startScan()
        ensureSweep()
        return true
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        try {
            advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        sweepRunnable?.let { mainHandler.removeCallbacks(it) }
        sweepRunnable = null
        lastSeenAt.clear()
        roleByToken.clear()
        deviceByToken.clear()
    }

    /** Called whenever this device becomes/stops being a Wi-Fi Direct Group Owner. */
    /**
     * The token never changes here — only the role flag. It used to
     * regenerate a fresh token on every role change, which was a real bug:
     * a peer that had already discovered this device via BLE under its old
     * token had no way to learn the new one, splitting one physical peer
     * into two identities (one "found," one "connected") the moment it
     * became Group Owner — which is exactly when a socket needs to exist
     * under an id the other side can still recognize. The token only needs
     * to be unique per device for one mesh session, which generating it
     * once already guarantees.
     */
    fun updateRole(isGroupOwner: Boolean) {
        myRole = isGroupOwner
        advertiseCurrentRole()
    }

    @SuppressLint("MissingPermission")
    private fun advertiseCurrentRole() {
        val adv = advertiser ?: return
        try {
            adv.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }

        // Connectable, even though nothing ever GATT-connects over this
        // beacon (BLE is presence/signaling only — see the class doc).
        // Non-connectable advertising is a less commonly exercised mode on
        // some budget/OEM Bluetooth chipsets and has been reported to
        // silently fail to transmit on them; connectable mode is the
        // overwhelmingly common case (every BLE peripheral/beacon library
        // defaults to it) and far more broadly tested in practice.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        val nameBytes = myDisplayName.toByteArray(Charsets.UTF_8)
            .let { if (it.size > maxNameBytes) it.copyOf(maxNameBytes) else it }

        val payload = ByteArray(5 + nameBytes.size)
        payload[0] = if (myRole) 1 else 0
        val tokenBytes = tokenToBytes(myToken)
        System.arraycopy(tokenBytes, 0, payload, 1, 4)
        System.arraycopy(nameBytes, 0, payload, 5, nameBytes.size)

        // No service UUID here — it was never used for matching (scanning
        // has no ScanFilter; onScanResult matches on manufacturer data
        // directly) and dropping it is what makes room for the name above
        // within the legacy 31-byte advertisement limit.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(MANUFACTURER_ID, payload)
            .build()

        try {
            adv.startAdvertising(settings, data, advertiseCallback)
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        val sc = scanner ?: return
        // Mirrors advertiseCurrentRole()'s own defensive stop-before-start
        // just below — without it, a scan left running from before a mesh
        // restart (the OS can take a moment to actually release it) made
        // every subsequent startScan() fail with "already started" instead
        // of just reusing or cleanly replacing the existing scan.
        try {
            sc.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        try {
            // Deliberately no ScanFilter here: on some chipsets, firmware-
            // level service-UUID filtering silently drops matches that a
            // plain, unfiltered scan still delivers. onScanResult already
            // does the equivalent selectivity itself by checking
            // getManufacturerSpecificData(MANUFACTURER_ID) in app code,
            // which can't be affected by a buggy hardware filter.
            sc.startScan(emptyList(), settings, scanCallback)
        } catch (_: Exception) {
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            if (advertiseConfirmed) return
            advertiseConfirmed = true
            mainHandler.post { listener?.onBleInfo("BLE advertising confirmed started by the OS") }
        }

        override fun onStartFailure(errorCode: Int) {
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "advertise data too large"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers already running — if this persists, toggling Bluetooth off and back on clears Android's own leftover slots from earlier sessions"
                ADVERTISE_FAILED_ALREADY_STARTED -> "already started"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "internal error"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "BLE advertising not supported on this device/chipset"
                else -> "error code $errorCode"
            }
            mainHandler.post { listener?.onBleError("BLE advertising failed to start: $reason") }
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) {
            val reason = when (errorCode) {
                SCAN_FAILED_ALREADY_STARTED -> "already started"
                SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "app registration failed"
                SCAN_FAILED_INTERNAL_ERROR -> "internal error"
                SCAN_FAILED_FEATURE_UNSUPPORTED -> "BLE scanning not supported on this device/chipset"
                else -> "error code $errorCode"
            }
            mainHandler.post { listener?.onBleError("BLE scan failed to start: $reason") }
        }

        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!sawAnyScanResult) {
                sawAnyScanResult = true
                val name = try { result.device.name } catch (_: SecurityException) { null }
                mainHandler.post {
                    listener?.onBleInfo(
                        "BLE scan is receiving advertisements from the environment " +
                            "(first seen: ${name ?: "unnamed"} / ${result.device.address})"
                    )
                }
            }
            val record = result.scanRecord ?: return
            val data = record.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
            if (data.size < 5) return
            val isGo = data[0].toInt() == 1
            val token = bytesToToken(data.copyOfRange(1, 5))
            if (token == myToken) return // our own advertisement, bounced back by some stacks

            val now = System.currentTimeMillis()
            val wasKnown = lastSeenAt.containsKey(token)
            lastSeenAt[token] = now
            roleByToken[token] = isGo
            deviceByToken[token] = result.device

            if (!wasKnown) {
                // The real VIGILINK display name travels in the
                // advertisement itself now (see advertiseCurrentRole) —
                // the OS Bluetooth device name is only a fallback, since
                // it's usually unavailable for a device that was never
                // classic-Bluetooth-paired.
                val embeddedName = if (data.size > 5) {
                    String(data.copyOfRange(5, data.size), Charsets.UTF_8)
                        .trim()
                } else {
                    ""
                }
                val deviceName = embeddedName.ifEmpty {
                    try {
                        result.device.name
                    } catch (_: SecurityException) {
                        null
                    }
                }
                mainHandler.post { listener?.onBeaconSeen(token, isGo, deviceName) }
            }
            // A role change on an already-known token is tracked silently
            // above — re-firing "found" for a peer Dart already knows about
            // would trigger a redundant extra connect attempt there.
        }
    }

    private fun ensureSweep() {
        if (sweepRunnable != null) return
        val r = object : Runnable {
            override fun run() {
                val now = System.currentTimeMillis()
                val lost = lastSeenAt.filterValues { now - it > LOST_TIMEOUT_MS }.keys.toList()
                for (token in lost) {
                    lastSeenAt.remove(token)
                    roleByToken.remove(token)
                    deviceByToken.remove(token)
                    listener?.onBeaconLost(token)
                }
                mainHandler.postDelayed(this, SWEEP_INTERVAL_MS)
            }
        }
        sweepRunnable = r
        mainHandler.postDelayed(r, SWEEP_INTERVAL_MS)
    }

    private fun tokenToBytes(token: String): ByteArray {
        val v = token.toLongOrNull(16) ?: 0L
        return byteArrayOf(
            ((v shr 24) and 0xFF).toByte(),
            ((v shr 16) and 0xFF).toByte(),
            ((v shr 8) and 0xFF).toByte(),
            (v and 0xFF).toByte()
        )
    }

    private fun bytesToToken(bytes: ByteArray): String {
        var v = 0L
        for (b in bytes) v = (v shl 8) or (b.toLong() and 0xFF)
        return v.toString(16).padStart(8, '0')
    }
}
