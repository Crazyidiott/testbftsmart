package bftsmart.demo.rlWrapper;

import java.nio.ByteBuffer;

/**
 * Utility class for encoding/decoding consensus-agreed configuration change requests.
 *
 * <p>Format of an encoded payload:
 * <pre>
 *   [8 bytes: MAGIC] [4 bytes: type (int)] [4 bytes: value (int)]
 * </pre>
 *
 * <p>A config-change request is submitted via {@code ServiceProxy.invokeOrdered()} so that
 * BFT-SMaRt's consensus protocol guarantees ALL replicas apply the change at the same
 * consensus delivery point.  Parameters that require cross-replica consistency (e.g.
 * {@code requestTimeout}) must go through this path; locally-tunable parameters (e.g.
 * {@code batchSize}, {@code batchTimeout}) can be applied directly without consensus.
 */
public class ConfigChangeRequest {

    /** 8-byte magic header that distinguishes a config-change payload from a normal request. */
    public static final byte[] MAGIC = new byte[]{
            (byte) 0xBF, 0x43, 0x46, 0x47, (byte) 0xBF, 0x43, 0x46, 0x47
    };

    /** Total header length: MAGIC + type field + value field. */
    public static final int PAYLOAD_LENGTH = MAGIC.length + Integer.BYTES + Integer.BYTES;

    // ── Config type IDs ──────────────────────────────────────────────────────

    /**
     * Type ID for {@code system.totalordermulticast.timeout} (view-change trigger timeout).
     * This parameter must be identical on all replicas to ensure consistent leader-change
     * detection; therefore it is adjusted via the consensus path.
     */
    public static final int TYPE_REQUEST_TIMEOUT = 1;

    // ── Encoding / Decoding ──────────────────────────────────────────────────

    /**
     * Encodes a config-change request into a byte array.
     *
     * @param type  Config type ID (e.g. {@link #TYPE_REQUEST_TIMEOUT}).
     * @param value New parameter value.
     * @return Encoded payload.
     */
    public static byte[] encode(int type, int value) {
        ByteBuffer buf = ByteBuffer.allocate(PAYLOAD_LENGTH);
        buf.put(MAGIC);
        buf.putInt(type);
        buf.putInt(value);
        return buf.array();
    }

    /**
     * Returns {@code true} if {@code data} starts with the config-change magic header.
     *
     * @param data Byte array to inspect (may be {@code null} or shorter than {@link #MAGIC}).
     */
    public static boolean isConfigChange(byte[] data) {
        if (data == null || data.length < MAGIC.length) return false;
        for (int i = 0; i < MAGIC.length; i++) {
            if (data[i] != MAGIC[i]) return false;
        }
        return true;
    }

    /**
     * Decodes a config-change payload previously produced by {@link #encode(int, int)}.
     *
     * @param data Encoded payload.
     * @return int array {@code [type, value]}.
     * @throws IllegalArgumentException if {@code data} is not a valid config-change payload.
     */
    public static int[] decode(byte[] data) {
        if (!isConfigChange(data)) {
            throw new IllegalArgumentException("Not a config-change payload");
        }
        if (data.length < PAYLOAD_LENGTH) {
            throw new IllegalArgumentException("Payload too short: " + data.length);
        }
        ByteBuffer buf = ByteBuffer.wrap(data);
        buf.position(MAGIC.length);
        int type  = buf.getInt();
        int value = buf.getInt();
        return new int[]{type, value};
    }
}
