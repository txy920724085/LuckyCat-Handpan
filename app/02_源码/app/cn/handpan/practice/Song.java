package cn.handpan.practice;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 一首曲谱：带独立速度、每个音符有自己的起点与时长（拍为单位）。
 * 支持 version=1（旧：positions，每拍一音）与 version=2（notes：b/d/p）。
 */
public final class Song {

    public static final class Note {
        public final float start;   // 起点（拍）
        public final float dur;     // 时长（拍）
        public final int pos;       // 0..7 音位；-1 休止
        public final int vel;       // 力度 1..127

        public Note(float start, float dur, int pos) {
            this(start, dur, pos, 100);
        }

        public Note(float start, float dur, int pos, int vel) {
            this.start = start;
            this.dur = dur;
            this.pos = pos;
            this.vel = Math.max(1, Math.min(127, vel));
        }
    }

    public final String title;
    public final float bpm;
    public final Note[] notes;
    public final float length;   // 总拍数
    public final int hitCount;   // 需要敲击的音符数（不含休止）

    private Song(String title, float bpm, Note[] notes) {
        this.title = title;
        this.bpm = bpm;
        this.notes = notes;
        float end = 0f;
        int hits = 0;
        for (Note n : notes) {
            end = Math.max(end, n.start + n.dur);
            if (n.pos >= 0) hits++;
        }
        this.length = Math.max(4f, end);
        this.hitCount = hits;
    }

    public static Song fromPositions(String title, int[] positions, float bpm) {
        Note[] ns = new Note[positions.length];
        for (int i = 0; i < positions.length; i++) {
            int v = positions[i];
            ns[i] = new Note(i, 1f, v <= 0 ? -1 : v - 1);
        }
        return new Song(title, bpm, ns);
    }

    public static Song parse(JSONObject o) throws Exception {
        if (o.getInt("beats_per_bar") != 4) throw new Exception("仅支持 4/4 拍");
        String title = o.getString("title").trim();
        if (title.isEmpty() || title.length() > 60) throw new Exception("标题长度 1～60");
        int version = o.optInt("version", 1);
        float bpm = (float) o.optDouble("bpm", 85);
        if (bpm < 40 || bpm > 200) throw new Exception("BPM 需在 40～200");

        if (version == 1) {
            JSONArray pos = o.getJSONArray("positions");
            if (pos.length() < 4 || pos.length() > 512 || pos.length() % 4 != 0) {
                throw new Exception("positions 长度需为 4 的倍数（4～512）");
            }
            int[] arr = new int[pos.length()];
            for (int i = 0; i < pos.length(); i++) {
                if (!(pos.get(i) instanceof Integer)) throw new Exception("positions 只能是整数");
                int v = pos.getInt(i);
                if (v < 0 || v > 8) throw new Exception("positions 只能是 0～8（0=休止）");
                arr[i] = v;
            }
            return fromPositions(title, arr, bpm);
        }

        if (version == 2) {
            JSONArray arr = o.getJSONArray("notes");
            if (arr.length() < 4 || arr.length() > 512) throw new Exception("notes 数量需在 4～512");
            Note[] ns = new Note[arr.length()];
            float lastStart = -1f;
            for (int i = 0; i < arr.length(); i++) {
                JSONObject n = arr.getJSONObject(i);
                float b = (float) n.getDouble("b");
                float d = (float) n.getDouble("d");
                int p = n.getInt("p");
                int v = n.optInt("v", 100);
                if (b < 0 || b > 512) throw new Exception("音符起点需在 0～512 拍");
                if (d <= 0 || d > 16) throw new Exception("音符时长需在 0～16 拍");
                if (p < 0 || p > 8) throw new Exception("p 只能是 0～8（0=休止）");
                if (v < 1 || v > 127) throw new Exception("v 只能是 1～127");
                if (b < lastStart - 0.001f) throw new Exception("notes 必须按时间升序");
                lastStart = b;
                ns[i] = new Note(b, d, p == 0 ? -1 : p - 1, v);
            }
            return new Song(title, bpm, ns);
        }
        throw new Exception("仅支持 version 1 或 2");
    }

    public JSONObject toJson() throws Exception {
        JSONObject o = new JSONObject();
        o.put("version", 2);
        o.put("beats_per_bar", 4);
        o.put("title", title);
        o.put("bpm", Math.round(bpm * 10f) / 10.0);
        JSONArray arr = new JSONArray();
        for (Note n : notes) {
            JSONObject x = new JSONObject();
            x.put("b", Math.round(n.start * 100f) / 100.0);
            x.put("d", Math.round(n.dur * 100f) / 100.0);
            x.put("p", n.pos < 0 ? 0 : n.pos + 1);
            x.put("v", n.vel);
            arr.put(x);
        }
        o.put("notes", arr);
        return o;
    }

    /** 当前拍所在的音符（用于手碟示意图高亮），没有则返回 null。 */
    public Note noteAt(float beat) {
        for (Note n : notes) {
            if (n.pos >= 0 && beat >= n.start && beat < n.start + n.dur) return n;
        }
        return null;
    }
}
