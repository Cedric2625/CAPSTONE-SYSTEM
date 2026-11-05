package ph.edu.carsu.vehicleguard.meshtransport

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors

/**
 * Runs only on a Wi-Fi Direct P2P Client (the non-Group-Owner side). There
 * is exactly one peer from this side's perspective: the Group Owner.
 * Connections are keyed by BLE beacon token, same as [MeshSocketServer] —
 * see `MeshSocketIO.encodeHandshake` for why a token rather than an address.
 */
class MeshSocketClient(
    private val myName: String,
    private val myToken: String,
    private val onConnected: (endpointId: String, peerName: String) -> Unit,
    private val onPayload: (endpointId: String, bytes: ByteArray) -> Unit,
    private val onDisconnected: (endpointId: String) -> Unit,
) {
    private val executor = Executors.newCachedThreadPool()

    @Volatile
    private var socket: Socket? = null

    @Volatile
    private var running = false

    @Volatile
    private var endpointToken: String? = null

    fun connect(groupOwnerAddress: String) {
        if (running) return
        running = true
        executor.execute {
            var connected: Socket? = null
            var attempt = 0
            while (running && attempt < 10 && connected == null) {
                try {
                    val s = Socket()
                    s.connect(
                        InetSocketAddress(
                            InetAddress.getByName(groupOwnerAddress),
                            WifiDirectManager.SOCKET_PORT
                        ),
                        3_000
                    )
                    connected = s
                } catch (_: Exception) {
                    attempt++
                    try {
                        Thread.sleep(1_000)
                    } catch (_: InterruptedException) {
                    }
                }
            }
            val s = connected
            if (s == null) {
                running = false
                return@execute
            }
            socket = s
            runSession(s)
        }
    }

    private fun runSession(s: Socket) {
        try {
            MeshSocketIO.writeFrame(s.getOutputStream(), MeshSocketIO.encodeHandshake(myName, myToken))
            val first = MeshSocketIO.readFrame(s.getInputStream()) ?: return
            val (peerToken, peerName) = MeshSocketIO.decodeHandshake(first) ?: return
            endpointToken = peerToken
            onConnected(peerToken, peerName)

            while (running) {
                val frame = MeshSocketIO.readFrame(s.getInputStream()) ?: break
                onPayload(peerToken, frame)
            }
        } catch (_: Exception) {
        } finally {
            try {
                s.close()
            } catch (_: Exception) {
            }
            running = false
            endpointToken?.let { onDisconnected(it) }
        }
    }

    fun stop() {
        // A real test showed this gap: stop() (called from a group-lost
        // event when the Wi-Fi Direct connection itself drops, which these
        // phones apparently do often) used to only close the socket and
        // leave the "this peer is actually gone" notification to whatever
        // thread happened to notice the closed socket later — asynchronous,
        // with no guaranteed timing. If a new group formed and a fresh
        // MeshSocketClient was created in that gap, a Dart-side retry could
        // fire against the NEW client before its own handshake had even
        // completed, producing exactly the confirmed symptom: "acting as a
        // client, but its connected peer's token is 'none'". Reporting the
        // disconnect synchronously, right here, closes that gap. endpointToken
        // is cleared BEFORE closing the socket so runSession's own finally
        // block (woken up by this close) sees it already null and skips
        // firing onDisconnected a second time for the same peer — same
        // pattern already used in send()'s failure path.
        running = false
        val token = endpointToken
        endpointToken = null
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        token?.let { onDisconnected(it) }
    }

    fun send(bytes: ByteArray): Boolean {
        val s = socket ?: return false
        return try {
            synchronized(s) { MeshSocketIO.writeFrame(s.getOutputStream(), bytes) }
            true
        } catch (_: Exception) {
            // Same reasoning as MeshSocketServer.send — a failed write means
            // a genuinely broken socket, not a missing one. endpointToken is
            // cleared BEFORE closing the socket so runSession's own finally
            // block (woken up by this close) sees it already null and skips
            // firing onDisconnected a second time for the same peer.
            val token = endpointToken
            endpointToken = null
            socket = null
            try {
                s.close()
            } catch (_: Exception) {
            }
            token?.let { onDisconnected(it) }
            false
        }
    }

    fun currentEndpointToken(): String? = endpointToken
}
