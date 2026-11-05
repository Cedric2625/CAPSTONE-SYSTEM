package ph.edu.carsu.vehicleguard.meshtransport

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * Raw TCP sockets have no message boundaries, so every frame (handshake or
 * payload) is a 4-byte big-endian length prefix followed by that many bytes.
 */
object MeshSocketIO {
    private const val MAX_FRAME_BYTES = 10 * 1024 * 1024

    fun writeFrame(out: OutputStream, bytes: ByteArray) {
        val dos = DataOutputStream(out)
        dos.writeInt(bytes.size)
        dos.write(bytes)
        dos.flush()
    }

    /** Returns null on a clean EOF/error (peer closed or broke the socket). */
    fun readFrame(input: InputStream): ByteArray? {
        val dis = DataInputStream(input)
        val length = try {
            dis.readInt()
        } catch (_: Exception) {
            return null
        }
        if (length < 0 || length > MAX_FRAME_BYTES) return null
        val buf = ByteArray(length)
        return try {
            dis.readFully(buf)
            buf
        } catch (_: Exception) {
            null
        }
    }

    /**
     * The very first frame each side sends after the socket connects —
     * identifies the sender by its current BLE beacon token (not a BLE
     * address: an app can't read its own local Bluetooth MAC, and scanned
     * addresses can rotate, but both sides already know their own token by
     * value) plus its display name. This token becomes the endpoint id used
     * for `sockets[endpointId]` registration (`MeshSocketServer`) and for
     * `sendBytesPayload` matching (`MeshSocketClient.currentEndpointToken`)
     * on both ends — there is no separate address-to-token mapping step.
     */
    fun encodeHandshake(name: String, myToken: String): ByteArray {
        val safeName = name.replace("|", " ")
        return "H|$myToken|$safeName".toByteArray(Charsets.UTF_8)
    }

    /** Returns (senderToken, senderName), or null if malformed. */
    fun decodeHandshake(bytes: ByteArray): Pair<String, String>? {
        val s = String(bytes, Charsets.UTF_8)
        if (!s.startsWith("H|")) return null
        val rest = s.substring(2)
        val idx = rest.indexOf('|')
        if (idx < 0) return null
        val token = rest.substring(0, idx)
        val name = rest.substring(idx + 1)
        return token to name
    }
}
