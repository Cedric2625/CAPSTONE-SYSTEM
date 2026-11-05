package ph.edu.carsu.vehicleguard.meshtransport

import java.io.ByteArrayOutputStream

/**
 * Wire format for a message sent over a BLE GATT characteristic write.
 *
 * A GATT write has no separate handshake step the way the Wi-Fi Direct TCP
 * sockets did (see `MeshSocketIO`) — the sender's identity has to travel
 * with every message itself. A single write is also capped by the
 * negotiated MTU, so one logical message can arrive as several separate
 * writes that need reassembling.
 *
 * Format: [4-byte big-endian total length][8-ASCII-char sender token][JSON
 * payload bytes]. "Total length" covers the token + payload together, so
 * a receiver only needs to track how many bytes it has versus that one
 * number, regardless of how many separate writes delivered them.
 */
object BleFraming {
    private const val TOKEN_LEN = 8
    const val MAX_FRAME_BYTES = 2 * 1024 * 1024

    fun encode(senderToken: String, payload: ByteArray): ByteArray {
        require(senderToken.length == TOKEN_LEN) { "token must be $TOKEN_LEN chars" }
        val tokenBytes = senderToken.toByteArray(Charsets.US_ASCII)
        val total = TOKEN_LEN + payload.size
        val out = ByteArrayOutputStream(4 + total)
        out.write((total shr 24) and 0xFF)
        out.write((total shr 16) and 0xFF)
        out.write((total shr 8) and 0xFF)
        out.write(total and 0xFF)
        out.write(tokenBytes)
        out.write(payload)
        return out.toByteArray()
    }

    data class Decoded(val senderToken: String, val payload: ByteArray)

    /**
     * Accumulates chunks from repeated GATT writes for one in-flight
     * message. One instance per connected peer (on the server) or per
     * outgoing connection (on the client) — never shared between peers,
     * since two peers' writes must never be interleaved into one buffer.
     */
    class Accumulator {
        private val buffer = ByteArrayOutputStream()

        /** Returns the completed message once enough bytes have arrived, else null. */
        fun feed(chunk: ByteArray): Decoded? {
            buffer.write(chunk)
            val bytes = buffer.toByteArray()
            if (bytes.size < 4) return null
            val total = ((bytes[0].toInt() and 0xFF) shl 24) or
                ((bytes[1].toInt() and 0xFF) shl 16) or
                ((bytes[2].toInt() and 0xFF) shl 8) or
                (bytes[3].toInt() and 0xFF)
            if (total < TOKEN_LEN || total > MAX_FRAME_BYTES) {
                reset()
                return null
            }
            if (bytes.size < 4 + total) return null
            val token = String(bytes, 4, TOKEN_LEN, Charsets.US_ASCII)
            val payload = bytes.copyOfRange(4 + TOKEN_LEN, 4 + total)
            reset()
            // Any bytes belonging to a NEXT message that arrived in the same
            // chunk are intentionally dropped here — in this app's actual
            // usage each GATT connection carries exactly one message before
            // disconnecting, so there is never a legitimate next message to
            // preserve, and dropping avoids misparsing leftover bytes as a
            // new frame's length header.
            return Decoded(token, payload)
        }

        fun reset() {
            buffer.reset()
        }
    }
}
