package ph.edu.carsu.vehicleguard.meshtransport

import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Runs only on the Wi-Fi Direct Group Owner. A GO can serve several
 * simultaneous P2P Clients (it behaves like a small access point), which is
 * what lets 3+ phones share one mesh without a true multi-link topology —
 * each client only needs a path through the GO, matching the existing
 * store-carry-forward relay's assumption of "some" connected peer, not a
 * direct link to every other peer.
 */
class MeshSocketServer(
    private val myName: String,
    private val myToken: String,
    private val onConnected: (endpointId: String, peerName: String) -> Unit,
    private val onPayload: (endpointId: String, bytes: ByteArray) -> Unit,
    private val onDisconnected: (endpointId: String) -> Unit,
) {
    private val executor = Executors.newCachedThreadPool()
    private val sockets = ConcurrentHashMap<String, Socket>()

    @Volatile
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var running = false

    fun start() {
        if (running) return
        running = true
        executor.execute {
            try {
                val server = ServerSocket(WifiDirectManager.SOCKET_PORT)
                serverSocket = server
                while (running) {
                    val socket = try {
                        server.accept()
                    } catch (_: Exception) {
                        break
                    }
                    executor.execute { handleClient(socket) }
                }
            } catch (_: Exception) {
            }
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        for ((id, s) in sockets) {
            try {
                s.close()
            } catch (_: Exception) {
            }
            onDisconnected(id)
        }
        sockets.clear()
    }

    private fun handleClient(socket: Socket) {
        var endpointId: String? = null
        try {
            MeshSocketIO.writeFrame(
                socket.getOutputStream(),
                MeshSocketIO.encodeHandshake(myName, myToken)
            )
            val first = MeshSocketIO.readFrame(socket.getInputStream()) ?: return
            val (peerToken, peerName) = MeshSocketIO.decodeHandshake(first) ?: return
            endpointId = peerToken
            sockets[endpointId] = socket
            onConnected(endpointId, peerName)

            while (running) {
                val frame = MeshSocketIO.readFrame(socket.getInputStream()) ?: break
                onPayload(endpointId, frame)
            }
        } catch (_: Exception) {
        } finally {
            try {
                socket.close()
            } catch (_: Exception) {
            }
            endpointId?.let {
                if (sockets.remove(it) != null) onDisconnected(it)
            }
        }
    }

    fun send(endpointId: String, bytes: ByteArray): Boolean {
        val socket = sockets[endpointId] ?: return false
        return try {
            synchronized(socket) { MeshSocketIO.writeFrame(socket.getOutputStream(), bytes) }
            true
        } catch (_: Exception) {
            // A real test confirmed this exact case: the socket WAS
            // correctly registered, but the write itself failed — meaning
            // the socket is actually broken, not missing. Leaving it
            // registered made every subsequent send to this endpoint fail
            // identically forever (confirmed: an immediate retry hit the
            // same dead socket and failed the same way). Tearing it down
            // for real and reporting the disconnect lets the existing
            // rediscovery/reconnect path form a fresh connection instead.
            // `sockets.remove` returning non-null also guards handleClient's
            // own cleanup from firing onDisconnected a second time for the
            // same socket.
            if (sockets.remove(endpointId) != null) {
                try {
                    socket.close()
                } catch (_: Exception) {
                }
                onDisconnected(endpointId)
            }
            false
        }
    }

    fun connectedIds(): Set<String> = sockets.keys.toSet()
}
