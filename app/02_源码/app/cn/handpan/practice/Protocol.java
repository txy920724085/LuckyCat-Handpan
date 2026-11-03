package cn.handpan.practice;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class Protocol {

    public static final long[] STEPS = new long[]{
            25831026L, 28994347L, 30718440L, 34480283L, 38702809L, 41004198L, 46025656L, 51662052L
    };

    public int crcErrors = 0;
    public int discarded = 0;
    private byte[] pending = new byte[0];

    public static byte[] note(int n, int velocity, int timbre) {
        if (n < 0 || n > 7 || velocity < 1 || velocity > 127 || timbre < 0 || timbre > 3) {
            throw new IllegalArgumentException();
        }
        byte[] out = new byte[9];
        out[0] = (byte) 0xF9;
        for (int i = 0; i < 5; i++) {
            out[i + 1] = (byte) (STEPS[n] >> (7 * i) & 0x7F);
        }
        out[6] = (byte) velocity;
        out[7] = (byte) timbre;
        int x = 0;
        for (int i = 1; i < 8; i++) x ^= out[i];
        out[8] = (byte) x;
        return out;
    }

    public static int u(byte b) {
        return b & 0xFF;
    }

    public static long le(byte[] data, int offset, int len) {
        long v = 0L;
        for (int i = 0; i < len; i++) {
            v |= (long) u(data[offset + i]) << (8 * i);
        }
        return v;
    }

    public static int crc(byte[] data, int len) {
        int crc = 0xFFFF;
        for (int i = 0; i < len; i++) {
            crc ^= u(data[i]) << 8;
            for (int j = 0; j < 8; j++) {
                crc = ((crc << 1) ^ ((crc & 0x8000) != 0 ? 0x1021 : 0)) & 0xFFFF;
            }
        }
        return crc;
    }

    public void feed(byte[] buf, int len, Sink sink) {
        byte[] data = Arrays.copyOf(pending, pending.length + len);
        System.arraycopy(buf, 0, data, pending.length, len);
        int pos = 0;
        while (data.length - pos >= 4) {
            String magic = new String(data, pos, 4, StandardCharsets.US_ASCII);
            int frameLen;
            int type;
            switch (magic) {
                case "QSU1": frameLen = 30; type = 1; break;
                case "HTE1": frameLen = 28; type = 2; break;
                case "PMR1": frameLen = 88; type = 3; break;
                case "QKY1": frameLen = 34; type = 4; break;
                default:
                    pos++;
                    discarded++;
                    continue;
            }
            if (data.length - pos < 8) break;
            if (u(data[pos + 4]) != 1 || u(data[pos + 5]) != type
                    || le(data, pos + 6, 2) != (long) frameLen) {
                pos++;
                discarded++;
                continue;
            }
            if (data.length - pos < frameLen) break;
            byte[] frame = Arrays.copyOfRange(data, pos, pos + frameLen);
            if ((long) crc(frame, frameLen - 2) != le(frame, frameLen - 2, 2)) {
                crcErrors++;
                pos++;
                continue;
            }
            if (magic.equals("HTE1") && (u(frame[12]) > 7 || u(frame[13]) > 127)) {
                pos++;
                continue;
            }
            sink.frame(magic, frame);
            pos += frameLen;
        }
        pending = Arrays.copyOfRange(data, pos, data.length);
    }

    public interface Sink {
        void frame(String magic, byte[] frame);
    }
}
