package cn.handpan.practice;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothSocket;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.media.AudioAttributes;
import android.media.SoundPool;
import android.media.ToneGenerator;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.AtomicFile;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.ViewGroup;
import android.widget.CompoundButton;
import android.widget.ArrayAdapter;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.HttpsURLConnection;

import org.json.JSONArray;
import org.json.JSONObject;

public class MainActivity extends Activity {

    /* ------------------------------------------------------------------
     *  Design tokens (from the extracted handpan design system)
     * ------------------------------------------------------------------ */
    static final int BG        = 0xFFFAF7F2;
    static final int CARD      = 0xFFFFFFFF;
    static final int INK       = 0xFF2B2620;
    static final int INK2      = 0xFF6F6357;
    static final int INK3      = 0xFF8A7A68;
    static final int ACCENT    = 0xFFB95125;
    static final int ACCENT_DK = 0xFFA34618;
    static final int SAND      = 0xFFEDE3D3;
    static final int SAND_SOFT = 0xFFF6EFE4;
    static final int LINE      = 0xFFEEE6DA;
    static final int BRONZE    = 0xFFC08A52;
    static final int HIT       = 0xFF3F8F7A;

    Typeface tfBold, tfMedium, tfMono;

    /* ------------------------------------------------------------------
     *  Original state (unchanged behaviour)
     * ------------------------------------------------------------------ */
    final Handler ui = new Handler(Looper.getMainLooper());
    final ExecutorService io = Executors.newSingleThreadExecutor();
    final ExecutorService tx = Executors.newSingleThreadExecutor();
    volatile BluetoothSocket socket;
    volatile int generation = 0;
    Protocol parser = new Protocol();
    TextView status;
    TextView score;
    Pad pad;
    boolean playing = false;
    boolean demo = false;
    int index = 0;
    int bpm = 85;
    int timbre = 0;
    int hits = 0;
    int correct = 0;
    long start;
    long lastQ = 0L;
    long lastSeq = -1L;
    int gaps = 0;
    boolean[] matched;
    boolean metro = false;
    boolean recording = false;
    boolean replay = false;
    int metroBpm = 85;
    int beats = 4;
    int lastBeat = -1;
    int replayIndex = 0;
    long metroStart;
    long recordStart;
    long replayStart;
    ToneGenerator tone;
    SoundPool soundPool;
    int sndBellAccent = 0, sndBellWeak = 0, sndClick = 0;
    int metroPreset = 0;
    LinearLayout lesson;
    LinearLayout metroPage;
    TextView beatText;
    TextView sustainText;
    TextView recordText;
    final ArrayList<long[]> take = new ArrayList();
    Song currentSong;
    float beatPos = 0f;
    boolean loop = false;
    ScoreView notation;

    /* Song library / position mapping (kept from v0.4) */
    final ExecutorService downloads = Executors.newSingleThreadExecutor();
    int[] mapping = {0, 1, 2, 3, 4, 5, 6, 7};
    final ArrayList<String> titles = new ArrayList<>();
    final ArrayList<Song> scores = new ArrayList<>();
    TextView libraryStatus;
    DropdownRow songRow;

    /* New UI-only references */
    ScrollView lessonScroll;
    TextView pillText;
    View pillDot;
    TextView speedValue;
    SeekBar speedBar;
    TextView songTitle;
    TextView metroBpmValue;
    TextView metroButtonLabel;
    Segmented metroSound;
    LinearLayout beatDots;
    NavItem navPractice, navMetro;
    Segmented metroMeter;

    final Runnable tick = new Runnable() {
        @Override
        public void run() {
            int n;
            long l = SystemClock.elapsedRealtime();
            if (metro && (n = (int) ((double) (l - metroStart) / (60000.0 / (double) metroBpm))) != lastBeat) {
                lastBeat = n;
                beatText.setText(n % beats + 1 + " / " + beats);
                playMetroClick(n % beats == 0);
            }
            if (replay && l >= replayStart) {
                n = 0;
                while (replayIndex < take.size() && l - replayStart >= take.get(replayIndex)[0] && n++ < 8) {
                    long[] ev = take.get(replayIndex++);
                    if (l - replayStart - ev[0] > 250L) {
                        replay = false;
                        recordText.setText("回放调度延迟，已停止");
                        break;
                    }
                    write(Protocol.note((int) ev[1], Math.max(1, (int) ev[2]), timbre));
                }
                if (replayIndex >= take.size()) {
                    replay = false;
                    recordText.setText("回放结束（非音频录音）");
                }
            }
            if (playing) {
                double beatMs = 60000.0 / Math.max(40, bpm);
                double beats = (l - start) / beatMs;
                if (beats >= currentSong.length) {
                    if (loop) {
                        start += Math.round(currentSong.length * beatMs);
                        index = -1;
                        correct = 0;
                        matched = new boolean[currentSong.notes.length];
                        beats = (l - start) / beatMs;
                    } else {
                        stop();
                        score.setText("练习结束 · 命中 " + correct + " / " + currentSong.hitCount + "；仅供宽松节奏参考");
                    }
                }
                if (playing) {
                    beatPos = (float) beats;
                    if (beats >= 0) {
                        while (index + 1 < currentSong.notes.length
                                && currentSong.notes[index + 1].start <= beatPos) {
                            index++;
                            if (demo) {
                                Song.Note nt = currentSong.notes[index];
                                if (nt.pos >= 0 && beatPos - nt.start < 0.35f) {
                                    write(Protocol.note(PositionMap.channel(mapping, nt.pos), nt.vel, timbre));
                                }
                            }
                        }
                    }
                }
            }
            if (lastQ > 0L && l - lastQ > 1500L) {
                status.setText("QSU1 STALE · 不代表实时数据有效");
            }
            pad.invalidate();
            notation.invalidate();
            ui.postDelayed((Runnable) this, 25L);
        }
    };

    /* ==================================================================
     *  Lifecycle / UI construction
     * ================================================================== */
    @Override
    public void onCreate(Bundle bundle) {
        super.onCreate(bundle);
        tfBold = Typeface.create("sans-serif", Typeface.BOLD);
        tfMedium = Typeface.create("sans-serif-medium", Typeface.NORMAL);
        tfMono = Typeface.create("monospace", Typeface.NORMAL);

        try {
            tone = new ToneGenerator(3, 65);
        } catch (Exception e) {
            tone = null; // some devices have no usable audio output at startup
        }
        loadMetroPreset();
        initSoundPool();

        for (int i = 0; i < PracticeSongs.NAMES.length; i++) {
            titles.add(PracticeSongs.NAMES[i]);
            scores.add(Song.fromPositions(PracticeSongs.NAMES[i], PracticeSongs.NOTES[i], 85f));
        }
        currentSong = scores.get(0);
        loadLibrary();
        loadMapping();

        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(0xFFFFFDFA);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);

        LinearLayout shell = new LinearLayout(this);
        shell.setOrientation(LinearLayout.VERTICAL);
        shell.setBackgroundColor(BG);
        setContentView(shell);

        shell.addView(buildHeader(), new LinearLayout.LayoutParams(-1, -2));

        FrameLayout content = new FrameLayout(this);
        shell.addView(content, new LinearLayout.LayoutParams(-1, 0, 1f));

        lesson = new LinearLayout(this);
        lesson.setOrientation(LinearLayout.VERTICAL);
        lesson.setPadding(dp(16), dp(4), dp(16), dp(24));
        lessonScroll = new ScrollView(this);
        lessonScroll.setFillViewport(true);
        lessonScroll.setClipToPadding(false);
        lessonScroll.setVerticalScrollBarEnabled(false);
        lessonScroll.addView(lesson);
        content.addView(lessonScroll, new FrameLayout.LayoutParams(-1, -1));

        metroPage = new LinearLayout(this);
        metroPage.setOrientation(LinearLayout.VERTICAL);
        metroPage.setPadding(dp(16), dp(4), dp(16), dp(24));
        metroPage.setVisibility(View.GONE);
        content.addView(metroPage, new FrameLayout.LayoutParams(-1, -1));

        View nav = buildNav();
        shell.addView(nav, new LinearLayout.LayoutParams(-1, -2));

        buildLesson();
        buildMetronome();

        loadTake();
        ui.post(tick);
    }

    /* ------------------------------ header ------------------------------ */
    View buildHeader() {
        LinearLayout head = new LinearLayout(this);
        head.setOrientation(LinearLayout.HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);
        head.setPadding(dp(18), dp(14), dp(18), dp(10));

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        TextView over = label("HANDPAN PRACTICE", 9.5f, INK3, Typeface.NORMAL);
        over.setLetterSpacing(0.18f);
        TextView title = label("申田由甲 · 手碟跟练", 21f, INK, Typeface.BOLD);
        title.setPadding(0, dp(2), 0, 0);
        box.addView(over);
        box.addView(title);
        head.addView(box, new LinearLayout.LayoutParams(0, -2, 1f));

        LinearLayout pill = new LinearLayout(this);
        pill.setOrientation(LinearLayout.HORIZONTAL);
        pill.setGravity(Gravity.CENTER_VERTICAL);
        pill.setPadding(dp(10), dp(6), dp(12), dp(6));
        pill.setBackground(shape(SAND_SOFT, dp(20), 0, 0));
        pillDot = new View(this);
        pillDot.setBackground(shape(INK3, dp(4), 0, 0));
        LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dp(7), dp(7));
        dotLp.rightMargin = dp(6);
        pill.addView(pillDot, dotLp);
        pillText = label("未连接", 10.5f, INK2, Typeface.NORMAL);
        pill.addView(pillText);
        head.addView(pill);
        return head;
    }

    /* ------------------------------ bottom nav ------------------------------ */
    View buildNav() {
        LinearLayout wrap = new LinearLayout(this);
        wrap.setOrientation(LinearLayout.VERTICAL);
        View line = new View(this);
        line.setBackgroundColor(LINE);
        wrap.addView(line, new LinearLayout.LayoutParams(-1, 1));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setBackgroundColor(0xFFFFFDFA);
        bar.setPadding(dp(24), dp(9), dp(24), dp(14));

        navPractice = new NavItem("跟练", NavItem.HANDPAN);
        navMetro = new NavItem("节拍", NavItem.METRONOME);
        bar.addView(navPractice.view, new LinearLayout.LayoutParams(0, -2, 1f));
        bar.addView(navMetro.view, new LinearLayout.LayoutParams(0, -2, 1f));

        navPractice.setSelected(true);
        navPractice.view.setOnClickListener(v -> {
            metro = false;
            metroPage.setVisibility(View.GONE);
            lessonScroll.setVisibility(View.VISIBLE);
            navPractice.setSelected(true);
            navMetro.setSelected(false);
        });
        navMetro.view.setOnClickListener(v -> {
            stop();
            lessonScroll.setVisibility(View.GONE);
            metroPage.setVisibility(View.VISIBLE);
            navPractice.setSelected(false);
            navMetro.setSelected(true);
        });

        wrap.addView(bar);
        return wrap;
    }

    /* ------------------------------ lesson page ------------------------------ */
    void buildLesson() {
        /* status card */
        Card statusCard = new Card();
        LinearLayout statusRow = new LinearLayout(this);
        statusRow.setOrientation(LinearLayout.HORIZONTAL);
        statusRow.setGravity(Gravity.CENTER_VERTICAL);
        status = label("未连接 · 先在系统蓝牙设置配对 JDY-31", 11.5f, INK2, Typeface.NORMAL);
        status.setLineSpacing(dp(2), 1f);
        statusRow.addView(status, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView connect = button("连接", 2);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(dp(64), dp(34));
        clp.leftMargin = dp(8);
        statusRow.addView(connect, clp);
        connect.setOnClickListener(v -> choose());
        statusCard.addView(statusRow);
        add(statusCard, 10);

        /* pad card */
        Card padCard = new Card();
        LinearLayout padHead = rowBetween("音区", "轻触试听 · 不计入命中");
        padCard.addView(padHead);
        pad = new Pad();
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(-1, dp(258));
        plp.topMargin = dp(2);
        padCard.addView(pad, plp);
        score = label("真实敲击 0 · 等待演奏", 10.5f, INK3, Typeface.NORMAL);
        score.setTypeface(tfMono);
        score.setLineSpacing(dp(1), 1f);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-1, -2);
        slp.topMargin = dp(6);
        padCard.addView(score, slp);
        add(padCard, 10);

        /* transport card */
        Card transport = new Card();
        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        TextView demoBtn = button("示范", 1);
        TextView pracBtn = button("跟练", 0);
        TextView stopBtn = button("停止", 2);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(0, dp(46), 1f);
        alp.rightMargin = dp(8);
        actions.addView(demoBtn, alp);
        LinearLayout.LayoutParams alp2 = new LinearLayout.LayoutParams(0, dp(46), 1f);
        alp2.rightMargin = dp(8);
        actions.addView(pracBtn, alp2);
        actions.addView(stopBtn, new LinearLayout.LayoutParams(0, dp(46), 1f));
        demoBtn.setOnClickListener(v -> begin(true));
        pracBtn.setOnClickListener(v -> begin(false));
        stopBtn.setOnClickListener(v -> stop());
        transport.addView(actions);

        LinearLayout speedHead = new LinearLayout(this);
        speedHead.setOrientation(LinearLayout.HORIZONTAL);
        speedHead.setGravity(Gravity.CENTER_VERTICAL);
        TextView speedLabel = label("速度", 12f, INK2, Typeface.NORMAL);
        speedValue = label("85 BPM", 12f, ACCENT, Typeface.BOLD);
        speedHead.addView(speedLabel, new LinearLayout.LayoutParams(0, -2, 1f));
        speedHead.addView(speedValue);
        LinearLayout.LayoutParams shlp = new LinearLayout.LayoutParams(-1, -2);
        shlp.topMargin = dp(12);
        transport.addView(speedHead, shlp);

        SeekBar speed = new SeekBar(this);
        speedBar = speed;
        speed.setMax(160);
        speed.setProgress(45);
        tintSeek(speed);
        transport.addView(speed, new LinearLayout.LayoutParams(-1, dp(36)));
        speed.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onStartTrackingTouch(SeekBar seekBar) { }
            public void onStopTrackingTouch(SeekBar seekBar) { }
            public void onProgressChanged(SeekBar seekBar, int n, boolean bl) {
                if (playing) stop();
                bpm = 40 + n;
                speedValue.setText(bpm + " BPM");
                score.invalidate();
            }
        });
        add(transport, 10);

        /* notation card */
        Card scoreCard = new Card();
        LinearLayout scoreHead = new LinearLayout(this);
        scoreHead.setOrientation(LinearLayout.HORIZONTAL);
        scoreHead.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout titleBox = new LinearLayout(this);
        titleBox.setOrientation(LinearLayout.VERTICAL);
        TextView cap = label("当前曲谱", 9.5f, INK3, Typeface.NORMAL);
        cap.setLetterSpacing(0.08f);
        songTitle = label(PracticeSongs.NAMES[0], 15f, INK, Typeface.BOLD);
        titleBox.addView(cap);
        titleBox.addView(songTitle);
        scoreHead.addView(titleBox, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView meterChip = chip("4/4");
        scoreHead.addView(meterChip);
        scoreCard.addView(scoreHead);
        notation = new ScoreView();
        LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(-1, dp(128));
        nlp.topMargin = dp(4);
        scoreCard.addView(notation, nlp);
        add(scoreCard, 10);


        /* library card */
        Card library = new Card();
        library.addView(sectionTitle("曲谱库"));
        songRow = new DropdownRow("曲谱", titles.toArray(new String[0]), 0, n -> selectSong(n));
        library.addView(songRow);
        library.addView(divider());
        LinearLayout libActions = new LinearLayout(this);
        libActions.setOrientation(LinearLayout.HORIZONTAL);
        String[] libLabels = new String[]{"链接下载", "导入文件", "位置映射"};
        for (int i = 0; i < libLabels.length; i++) {
            TextView b = button(libLabels[i], 2);
            b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(40), 1f);
            if (i < 2) lp.rightMargin = dp(6);
            libActions.addView(b, lp);
            final String cmd = libLabels[i];
            b.setOnClickListener(v -> onLibraryAction(cmd));
        }
        LinearLayout.LayoutParams lalp = new LinearLayout.LayoutParams(-1, -2);
        lalp.topMargin = dp(4);
        library.addView(libActions, lalp);
        libraryStatus = label("内置/已保存曲谱可离线使用 · 在线曲谱需 HTTPS JSON 链接", 10.5f, INK3, Typeface.NORMAL);
        libraryStatus.setLineSpacing(dp(1), 1f);
        LinearLayout.LayoutParams lslp = new LinearLayout.LayoutParams(-1, -2);
        lslp.topMargin = dp(8);
        library.addView(libraryStatus, lslp);
        add(library, 10);

        /* settings card */
        Card settings = new Card();
        settings.addView(sectionTitle("练习设置"));
        settings.addView(new DropdownRow("音色", new String[]{"Handpan", "Pluck", "Marimba", "Drum"}, 0, n -> timbre = n));
        settings.addView(divider());

        final Switch loopSwitch = new Switch(this);
        loopSwitch.setText("整曲循环练习");
        loopSwitch.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        loopSwitch.setTextColor(INK);
        loopSwitch.setTypeface(tfMedium);
        loopSwitch.setPadding(0, dp(6), 0, dp(6));
        loopSwitch.setThumbTintList(android.content.res.ColorStateList.valueOf(ACCENT));
        loopSwitch.setTrackTintList(android.content.res.ColorStateList.valueOf(SAND));
        loopSwitch.setOnCheckedChangeListener((compoundButton, bl) -> loop = bl);
        settings.addView(loopSwitch);

        LinearLayout reverbRow = new LinearLayout(this);
        reverbRow.setOrientation(LinearLayout.HORIZONTAL);
        reverbRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout reverbText = new LinearLayout(this);
        reverbText.setOrientation(LinearLayout.VERTICAL);
        reverbText.addView(label("回响", 13f, INK, Typeface.BOLD));
        reverbText.addView(label("实体板上的效果开关", 10f, INK3, Typeface.NORMAL));
        reverbRow.addView(reverbText, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView on = pillButton("ON");
        TextView off = pillButton("OFF");
        LinearLayout.LayoutParams olp = new LinearLayout.LayoutParams(dp(56), dp(34));
        olp.rightMargin = dp(6);
        reverbRow.addView(on, olp);
        reverbRow.addView(off, new LinearLayout.LayoutParams(dp(56), dp(34)));
        on.setOnClickListener(v -> {
            int n = 106;
            write(new byte[]{(byte) 0xFA, (byte) n, (byte) (n ^ 0x55)});
        });
        off.setOnClickListener(v -> {
            int n = 42;
            write(new byte[]{(byte) 0xFA, (byte) n, (byte) (n ^ 0x55)});
        });
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(-1, -2);
        rlp.topMargin = dp(8);
        settings.addView(reverbRow, rlp);

        sustainText = label("延音：等待 QSU1；通过实体滑环调节，只影响新音符", 10.5f, INK3, Typeface.NORMAL);
        sustainText.setLineSpacing(dp(1), 1f);
        LinearLayout.LayoutParams stlp = new LinearLayout.LayoutParams(-1, -2);
        stlp.topMargin = dp(8);
        settings.addView(sustainText, stlp);
        add(settings, 10);

        /* record card */
        Card rec = new Card();
        rec.addView(sectionTitle("录制与回放"));
        LinearLayout recBtns = new LinearLayout(this);
        recBtns.setOrientation(LinearLayout.HORIZONTAL);
        String[] recLabels = new String[]{"开始录制", "停止保存", "回放"};
        for (int i = 0; i < recLabels.length; i++) {
            TextView b = button(recLabels[i], 2);
            b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(40), 1f);
            if (i < 2) lp.rightMargin = dp(6);
            recBtns.addView(b, lp);
            final String cmd = recLabels[i];
            b.setOnClickListener(v -> onRecordAction(cmd));
        }
        rec.addView(recBtns);
        recordText = label("", 11f, INK2, Typeface.NORMAL);
        recordText.setLineSpacing(dp(1), 1f);
        LinearLayout.LayoutParams rtlp = new LinearLayout.LayoutParams(-1, -2);
        rtlp.topMargin = dp(10);
        rec.addView(recordText, rtlp);
        add(rec, 10);

        TextView hint = label("浅金=曲谱提示；青绿=真实 HTE1 敲击。点击音区仅发送试听，不计真实敲击。"
                + "跟练用实体键选择音色；评分含蓝牙延迟。保持前台使用。", 10f, INK3, Typeface.NORMAL);
        hint.setLineSpacing(dp(2), 1f);
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(-1, -2);
        hlp.leftMargin = dp(4);
        hlp.rightMargin = dp(4);
        hlp.topMargin = dp(2);
        lesson.addView(hint, hlp);

        /* keep pill in sync with the status string */
        status.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            public void onTextChanged(CharSequence s, int a, int b, int c) { }
            public void afterTextChanged(Editable s) {
                syncPill(s.toString());
            }
        });
        syncPill(status.getText().toString());
    }

    void syncPill(String s) {
        int color;
        String text;
        if (s.contains("已连接")) {
            color = HIT;
            text = "已连接";
        } else if (s.contains("连接中")) {
            color = 0xFFC98A3C;
            text = "连接中";
        } else if (s.contains("断开") || s.contains("失败")) {
            color = 0xFFB0503F;
            text = "未连接";
        } else if (s.startsWith("QSU1")) {
            color = 0xFFC98A3C;
            text = "数据延迟";
        } else {
            color = 0xFFB7A895;
            text = "未连接";
        }
        pillDot.setBackground(shape(color, dp(4), 0, 0));
        pillText.setText(text);
    }

    /* ------------------------------ metronome page ------------------------------ */
    void buildMetronome() {
        TextView over = label("METRONOME", 9.5f, INK3, Typeface.NORMAL);
        over.setLetterSpacing(0.18f);
        over.setPadding(dp(4), dp(8), 0, 0);
        metroPage.addView(over);
        TextView title = label("节拍器", 24f, INK, Typeface.BOLD);
        title.setPadding(dp(4), dp(2), 0, dp(10));
        metroPage.addView(title);

        Card card = new Card();
        LinearLayout bpmRow = new LinearLayout(this);
        bpmRow.setOrientation(LinearLayout.HORIZONTAL);
        bpmRow.setGravity(Gravity.BOTTOM);
        TextView bpmBig = label("85", 56f, INK, Typeface.BOLD);
        bpmBig.setTypeface(Typeface.create("sans-serif-thin", Typeface.NORMAL));
        metroBpmValue = bpmBig;
        bpmRow.addView(bpmBig);
        TextView unit = label("BPM", 12f, INK2, Typeface.NORMAL);
        unit.setPadding(dp(8), 0, 0, dp(10));
        bpmRow.addView(unit);
        card.addView(bpmRow);

        beatText = label("准备", 34f, ACCENT, Typeface.BOLD);
        beatText.setGravity(Gravity.CENTER);
        beatText.setPadding(0, dp(6), 0, dp(2));
        card.addView(beatText);

        beatDots = new LinearLayout(this);
        beatDots.setOrientation(LinearLayout.HORIZONTAL);
        beatDots.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams bdlp = new LinearLayout.LayoutParams(-1, -2);
        bdlp.bottomMargin = dp(10);
        card.addView(beatDots, bdlp);

        beatText.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) { }
            public void onTextChanged(CharSequence s, int a, int b, int c) { }
            public void afterTextChanged(Editable s) {
                renderBeatDots(s.toString());
            }
        });
        renderBeatDots("准备");

        TextView info = label("85 BPM · 手机本地节拍，不向 FPGA 发音符", 10.5f, INK3, Typeface.NORMAL);
        info.setGravity(Gravity.CENTER);
        card.addView(info);

        SeekBar seekBar = new SeekBar(this);
        seekBar.setMax(180);
        seekBar.setProgress(45);
        tintSeek(seekBar);
        LinearLayout.LayoutParams sklp = new LinearLayout.LayoutParams(-1, dp(40));
        sklp.topMargin = dp(8);
        card.addView(seekBar, sklp);
        seekBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onStartTrackingTouch(SeekBar s) { }
            public void onStopTrackingTouch(SeekBar s) { }
            public void onProgressChanged(SeekBar s, int n, boolean bl) {
                boolean wasRunning = metro;
                metroBpm = 40 + n;
                metro = false;
                metroBpmValue.setText("" + metroBpm);
                info.setText(metroBpm + " BPM · 手机媒体音量控制节拍响度");
                if (wasRunning) beatText.setText("已停止");
                if (metroButtonLabel != null) metroButtonLabel.setText("启动节拍");
            }
        });

        TextView soundCap = label("音色", 11f, INK3, Typeface.NORMAL);
        soundCap.setPadding(0, dp(6), 0, dp(8));
        card.addView(soundCap);
        metroSound = new Segmented(new String[]{"铃 + 木", "机械单击"}, metroPreset, n -> {
            metroPreset = n;
            getPreferences(0).edit().putInt("metro_preset", n).apply();
            if (metro) {
                metro = false;
                beatText.setText("已停止");
                if (metroButtonLabel != null) metroButtonLabel.setText("启动节拍");
            }
        });
        card.addView(metroSound.view);

        TextView meterCap = label("拍号", 11f, INK3, Typeface.NORMAL);
        meterCap.setPadding(0, dp(14), 0, dp(6));
        card.addView(meterCap);
        metroMeter = new Segmented(new String[]{"4/4", "3/4", "2/4"}, 0, n -> {
            beats = new int[]{4, 3, 2}[n];
            if (metro) {
                metro = false;
                beatText.setText("已停止");
                if (metroButtonLabel != null) metroButtonLabel.setText("启动节拍");
            }
        });
        card.addView(metroMeter.view);

        final TextView metroBtn = button("启动节拍", 0);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(-1, dp(50));
        mlp.topMargin = dp(18);
        card.addView(metroBtn, mlp);
        metroButtonLabel = metroBtn;
        metroBtn.setOnClickListener(v -> {
            metro = !metro;
            metroStart = SystemClock.elapsedRealtime();
            lastBeat = -1;
            if (!metro) {
                beatText.setText("已停止");
                metroBtn.setText("启动节拍");
            } else {
                metroBtn.setText("停止节拍");
            }
        });
        metroPage.addView(card, cardParams(10));
    }

    /* ==================================================================
     *  Original behaviour, unchanged below (except UI plumbing)
     * ================================================================== */

    void onRecordAction(String cmd) {
        if (cmd.equals("开始录制")) {
            stop();
            if (socket == null) {
                recordText.setText("请先连接手碟");
                return;
            }
            take.clear();
            recordStart = SystemClock.elapsedRealtime();
            recording = true;
            recordText.setText("录制真实敲击中；最多5分钟/4096事件");
        } else if (cmd.equals("停止保存")) {
            recording = false;
            saveTake();
        } else {
            stop();
            if (socket == null || take.isEmpty()) {
                recordText.setText("先连接并录制真实敲击");
                return;
            }
            replay = true;
            replayIndex = 0;
            replayStart = SystemClock.elapsedRealtime() + 1000L;
            recordText.setText("回放事件；使用当前实体延音与回响设置");
        }
    }

    void saveTake() {
        try {
            JSONArray arr = new JSONArray();
            for (long[] lArray : take) {
                JSONArray one = new JSONArray();
                for (long v : lArray) one.put(v);
                arr.put(one);
            }
            FileOutputStream fos = openFileOutput("last_take.json", 0);
            fos.write(arr.toString().getBytes(StandardCharsets.UTF_8));
            fos.close();
            recordText.setText("本机保存 " + take.size() + " 个事件；不含音色/延音/回响自动化");
        } catch (Exception e) {
            recordText.setText("保存失败：" + e.getMessage());
        }
    }

    void loadTake() {
        try {
            FileInputStream fis = openFileInput("last_take.json");
            int n;
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[1024];
            while ((n = fis.read(buf)) > 0) {
                if (bos.size() + n > 300000) throw new Exception("文件过大");
                bos.write(buf, 0, n);
            }
            fis.close();
            JSONArray arr = new JSONArray(bos.toString("UTF-8"));
            long last = -1L;
            for (int i = 0; i < arr.length() && i < 4096; i++) {
                JSONArray one = arr.getJSONArray(i);
                long t = one.getLong(0);
                long note = one.getLong(1);
                long vel = one.getLong(2);
                if (t < last || t > 300000L || note < 0L || note > 7L || vel < 0L || vel > 127L) {
                    throw new Exception("事件无效");
                }
                take.add(new long[]{t, note, vel});
                last = t;
            }
            recordText.setText("已载入上次 " + take.size() + " 个事件");
        } catch (FileNotFoundException e) {
            recordText.setText("尚无录制");
        } catch (Exception e) {
            take.clear();
            recordText.setText("读取失败：" + e.getMessage());
        }
    }

    void choose() {
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission("android.permission.BLUETOOTH_CONNECT") != 0) {
            requestPermissions(new String[]{"android.permission.BLUETOOTH_CONNECT"}, 1);
            return;
        }
        try {
            BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter adapter = bm.getAdapter();
            if (adapter == null || !adapter.isEnabled()) {
                status.setText("请在系统设置开启蓝牙");
                return;
            }
            final ArrayList<BluetoothDevice> devices = new ArrayList<>(adapter.getBondedDevices());
            CharSequence[] items = new CharSequence[devices.size()];
            for (int i = 0; i < devices.size(); i++) {
                items[i] = devices.get(i).getName() + " · " + devices.get(i).getAddress();
            }
            new AlertDialog.Builder(this)
                    .setTitle("选择 JDY-31，勿选其他设备")
                    .setItems(items, (DialogInterface dialog, int n) -> connect(devices.get(n)))
                    .show();
        } catch (Exception e) {
            status.setText(e.toString());
        }
    }

    void disconnect() {
        ++generation;
        BluetoothSocket s = socket;
        socket = null;
        if (s != null) {
            try {
                s.close();
            } catch (Exception ignored) {
            }
        }
        stop();
    }

    void connect(BluetoothDevice device) {
        disconnect();
        final int gen = generation;
        parser = new Protocol();
        lastQ = 0L;
        lastSeq = -1L;
        gaps = 0;
        status.setText("连接中…");
        final BluetoothDevice dev = device;
        io.execute(() -> {
            BluetoothSocket s = null;
            try {
                socket = s = dev.createRfcommSocketToServiceRecord(UUID.fromString("00001101-0000-1000-8000-00805F9B34FB"));
                s.connect();
                if (gen != generation) {
                    s.close();
                    return;
                }
                ui.post(() -> status.setText("蓝牙已连接 · 等待真实遥测"));
                byte[] buf = new byte[2048];
                int n;
                while (gen == generation && (n = s.getInputStream().read(buf)) != -1) {
                    final byte[] data = buf;
                    final int len = n;
                    parser.feed(data, len, (frame, payload) -> ui.post(() -> {
                        if (gen == generation) receive(frame, payload);
                    }));
                }
            } catch (Exception e) {
                ui.post(() -> {
                    if (gen == generation) {
                        status.setText("连接断开：" + e.getMessage());
                        stop();
                    }
                });
            } finally {
                try {
                    if (s != null) s.close();
                } catch (Exception ignored) {
                }
                if (gen == generation) socket = null;
            }
        });
    }

    void send(int n) {
        write(Protocol.note(n, 100, timbre));
    }

    void write(final byte[] data) {
        final BluetoothSocket s = socket;
        tx.execute(() -> {
            try {
                if (s == null || !s.isConnected()) return;
                s.getOutputStream().write(data);
            } catch (Exception e) {
                ui.post(() -> status.setText("发送失败：" + e.getMessage()));
            }
        });
    }

    void receive(String frame, byte[] data) {
        long l = SystemClock.elapsedRealtime();
        if (frame.equals("QSU1")) {
            lastQ = l;
            boolean valid = (Protocol.u(data[25]) & 0xB) == 11;
            sustainText.setText("延音 " + Protocol.u(data[24]) + " / 255 · "
                    + (valid ? "滑环控制，新音符锁存" : "数据不可用") + "；手机不下发延音");
            status.setText("蓝牙已连接 · QSU1 " + (valid ? "VALID" : "UNAVAILABLE")
                    + " · 延音 " + Protocol.u(data[24]) + " · QT错误 " + Protocol.u(data[27])
                    + " · CRC错误 " + parser.crcErrors);
        }
        if (frame.equals("HTE1")) {
            long seq = Protocol.le(data, 8, 4);
            if (lastSeq >= 0L) {
                long diff = seq - lastSeq & 0xFFFFFFFFL;
                if (diff == 0L || diff > Integer.MAX_VALUE) return;
                gaps += (int) (diff - 1L);
            }
            lastSeq = seq;
            int n = Protocol.u(data[12]);
            ++hits;
            if (recording) {
                if (l - recordStart > 300000L || take.size() >= 4096) {
                    recording = false;
                    saveTake();
                } else {
                    take.add(new long[]{l - recordStart, n, Protocol.u(data[13])});
                    recordText.setText("已录制 " + take.size() + " 个真实事件");
                }
            }
            pad.flash[n] = l;
            pad.vel[n] = Protocol.u(data[13]);
            if (playing && !demo) {
                long t = l - start;
                double beatMs = 60000.0 / Math.max(40, bpm);
                int best = -1;
                double bestDiff = Double.MAX_VALUE;
                for (int i = 0; i < currentSong.notes.length; i++) {
                    Song.Note nt = currentSong.notes[i];
                    if (matched[i] || nt.pos < 0) continue;
                    if (PositionMap.channel(mapping, nt.pos) != n) continue;
                    double diff = Math.abs(nt.start * beatMs - t);
                    if (diff <= 250.0 && diff < bestDiff) {
                        bestDiff = diff;
                        best = i;
                    }
                }
                if (best >= 0) {
                    matched[best] = true;
                    ++correct;
                }
            }
            score.setText("真实敲击 " + hits + " · CH" + n + " · 力度 " + pad.vel[n]
                    + " · Peak " + Protocol.le(data, 14, 2) + " · 命中 " + correct
                    + " · 序号缺失 " + gaps);
            pad.invalidate();
        }
    }

    void begin(boolean isDemo) {
        stop();
        if (socket == null || !socket.isConnected()) {
            status.setText("请先连接手碟");
            return;
        }
        demo = isDemo;
        playing = true;
        index = -1;
        correct = 0;
        matched = new boolean[currentSong.notes.length];
        beatPos = 0f;
        start = SystemClock.elapsedRealtime() + Math.round(240000.0 / (double) bpm);
    }

    void stop() {
        replay = false;
        playing = false;
        index = -1;
        beatPos = 0f;
        if (pad != null) pad.invalidate();
    }

    @Override
    protected void onPause() {
        super.onPause();
        stop();
        metro = false;
        if (recording) {
            recording = false;
            saveTake();
        }
    }

    void loadMetroPreset() {
        metroPreset = getPreferences(0).getInt("metro_preset", 0);
        if (metroPreset < 0 || metroPreset > 1) metroPreset = 0;
    }

    void initSoundPool() {
        try {
            AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build();
            soundPool = new SoundPool.Builder()
                    .setMaxStreams(4)
                    .setAudioAttributes(attrs)
                    .build();
            sndBellAccent = loadRaw("metro_bell");
            sndBellWeak = loadRaw("metro_wood");
            sndClick = loadRaw("metro_click");
        } catch (Exception e) {
            soundPool = null;
        }
    }

    int loadRaw(String name) {
        int id = getResources().getIdentifier(name, "raw", getPackageName());
        return id == 0 ? 0 : soundPool.load(this, id, 1);
    }

    void playMetroClick(boolean accent) {
        int id;
        float vol;
        if (metroPreset == 0) {
            id = accent ? sndBellAccent : sndBellWeak;
            vol = accent ? 1.0f : 0.9f;
        } else {
            id = sndClick;
            vol = accent ? 1.0f : 0.72f;
        }
        boolean played = false;
        if (soundPool != null && id != 0) {
            played = soundPool.play(id, vol, vol, 1, 0, 1.0f) != 0;
        }
        if (!played && tone != null) {
            // fallback if the sample is still loading / unavailable
            tone.startTone(accent ? 1 : 2, 55);
        }
    }

    @Override
    protected void onDestroy() {
        ui.removeCallbacksAndMessages(null);
        disconnect();
        io.shutdownNow();
        tx.shutdownNow();
        if (tone != null) tone.release();
        if (soundPool != null) {
            soundPool.release();
            soundPool = null;
        }
        super.onDestroy();
    }


    /* ================= Song library & mapping (v0.4 behaviour) ================= */
    void selectSong(int n) {
        if (n < 0 || n >= scores.size()) return;
        stop();
        currentSong = scores.get(n);
        matched = null;
        songTitle.setText(currentSong.title);
        bpm = Math.max(40, Math.min(200, Math.round(currentSong.bpm)));
        if (speedBar != null) speedBar.setProgress(bpm - 40);
        if (speedValue != null) speedValue.setText(bpm + " BPM");
        if (songRow != null) songRow.setValue(n);
        if (notation != null) notation.invalidate();
    }

    void loadMapping() {
        try {
            String[] parts = getPreferences(0).getString("position_map", "0,1,2,3,4,5,6,7").split(",");
            int[] m = new int[parts.length];
            for (int i = 0; i < parts.length; i++) m[i] = Integer.parseInt(parts[i]);
            PositionMap.validate(m);
            mapping = m;
        } catch (Exception e) {
            mapping = new int[]{0, 1, 2, 3, 4, 5, 6, 7};
        }
    }

    void storeMapping() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 8; i++) {
            if (i > 0) sb.append(',');
            sb.append(mapping[i]);
        }
        getPreferences(0).edit().putString("position_map", sb.toString()).apply();
        libraryStatus.setText("映射已保存：" + sb + "；示范与跟练一致，真实CH编号不变");
    }

    void editMapping() {
        stop();
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), dp(8));
        final Spinner[] spinners = new Spinner[8];
        String[] channels = new String[]{"CH0", "CH1", "CH2", "CH3", "CH4", "CH5", "CH6", "CH7"};
        for (int i = 0; i < 8; i++) {
            LinearLayout row = new LinearLayout(this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, dp(2), 0, dp(2));
            TextView t = label("谱位 " + (i + 1) + " →", 13f, INK2, Typeface.NORMAL);
            row.addView(t, new LinearLayout.LayoutParams(0, -2, 1f));
            Spinner sp = new Spinner(this);
            sp.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, channels));
            sp.setSelection(mapping[i]);
            spinners[i] = sp;
            row.addView(sp, new LinearLayout.LayoutParams(dp(120), -2));
            box.addView(row);
        }
        ScrollView sc = new ScrollView(this);
        sc.addView(box);
        final AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("曲谱位置映射（不改实体音高）")
                .setView(sc)
                .setPositiveButton("保存", null)
                .setNeutralButton("恢复默认", (d, w) -> {
                    mapping = new int[]{0, 1, 2, 3, 4, 5, 6, 7};
                    storeMapping();
                })
                .setNegativeButton("取消", null)
                .create();
        dialog.setOnShowListener(d -> {
            for (int b : new int[]{DialogInterface.BUTTON_POSITIVE, DialogInterface.BUTTON_NEUTRAL, DialogInterface.BUTTON_NEGATIVE}) {
                if (dialog.getButton(b) != null) dialog.getButton(b).setTextColor(ACCENT);
            }
            dialog.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener(v -> {
            try {
                int[] m = new int[8];
                for (int i = 0; i < 8; i++) m[i] = spinners[i].getSelectedItemPosition();
                PositionMap.validate(m);
                mapping = m;
                storeMapping();
                dialog.dismiss();
            } catch (Exception e) {
                Toast.makeText(this, e.getMessage(), Toast.LENGTH_SHORT).show();
            }
            });
        });
        dialog.show();
    }

    void addScore(String text) throws Exception {
        Song parsed = Song.parse(new JSONObject(text));
        if (titles.size() >= 62) throw new Exception("最多保存50段外部曲谱");
        String title = parsed.title;
        if (titles.contains(title)) throw new Exception("同名曲谱已存在");
        scores.add(parsed);
        titles.add(title);
        try {
            saveLibrary();
            if (songRow != null) songRow.setItems(titles.toArray(new String[0]), titles.size() - 1);
            selectSong(titles.size() - 1);
            libraryStatus.setText("已保存，可离线使用：" + title);
        } catch (Exception e) {
            titles.remove(titles.size() - 1);
            scores.remove(scores.size() - 1);
            throw e;
        }
    }

    void saveLibrary() throws Exception {
        JSONArray arr = new JSONArray();
        for (int i = PracticeSongs.NAMES.length; i < titles.size(); i++) {
            arr.put(scores.get(i).toJson());
        }
        AtomicFile file = new AtomicFile(new File(getFilesDir(), "scores.json"));
        FileOutputStream out = file.startWrite();
        try {
            out.write(arr.toString().getBytes(StandardCharsets.UTF_8));
            file.finishWrite(out);
        } catch (Exception e) {
            file.failWrite(out);
            throw e;
        }
    }

    void loadLibrary() {
        try {
            FileInputStream in = openFileInput("scores.json");
            JSONArray arr = new JSONArray(readLimited(in, 4000000));
            in.close();
            for (int i = 0; i < Math.min(50, arr.length()); i++) {
                Song loaded = Song.parse(arr.getJSONObject(i));
                titles.add(loaded.title);
                scores.add(loaded);
            }
        } catch (Exception ignored) {
        }
    }

    String readLimited(InputStream in, int max) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) != -1) {
            if (bos.size() + n > max) throw new Exception("文件过大");
            bos.write(buf, 0, n);
        }
        return bos.toString("UTF-8");
    }

    void onLibraryAction(String cmd) {
        if (cmd.equals("链接下载")) {
            showDownloadSheet();
        } else if (cmd.equals("导入文件")) {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.setType("*/*");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            startActivityForResult(intent, 22);
        } else {
            editMapping();
        }
    }

    void downloadDialog() {
        final EditText input = new EditText(this);
        input.setHint("https://…/score.json");
        new AlertDialog.Builder(this)
                .setTitle("下载真实曲谱链接（非在线曲库）")
                .setView(input)
                .setPositiveButton("下载", (d, w) -> {
                    final String url = input.getText().toString().trim();
                    libraryStatus.setText("下载中…");
                    downloads.execute(() -> {
                        try {
                            final String text = fetchHttps(url);
                            ui.post(() -> {
                                try {
                                    addScore(text);
                                } catch (Exception e) {
                                    libraryStatus.setText("曲谱拒绝：" + e.getMessage());
                                }
                            });
                        } catch (final Exception e) {
                            ui.post(() -> libraryStatus.setText("下载失败：" + e.getMessage()));
                        }
                    });
                })
                .setNegativeButton("取消", null)
                .show();
    }

    String fetchHttps(String address) throws Exception {
        URL url = new URL(address);
        if (!url.getProtocol().equals("https") || url.getUserInfo() != null) {
            throw new Exception("仅支持HTTPS，不带账号密码");
        }
        HttpsURLConnection conn = (HttpsURLConnection) url.openConnection();
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(10000);
        conn.setInstanceFollowRedirects(false);
        try {
            int code = conn.getResponseCode();
            if (code != 200) throw new Exception("HTTP " + code + "，请提供最终直链");
            InputStream in = conn.getInputStream();
            try {
                return readLimited(in, 65536);
            } finally {
                in.close();
            }
        } finally {
            conn.disconnect();
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 22 || result != RESULT_OK || data == null || data.getData() == null) return;
        final Uri uri = data.getData();
        downloads.execute(() -> {
            try {
                InputStream in = getContentResolver().openInputStream(uri);
                try {
                    final String text = readLimited(in, 65536);
                    ui.post(() -> {
                        try {
                            addScore(text);
                        } catch (Exception e) {
                            libraryStatus.setText("导入拒绝：" + e.getMessage());
                        }
                    });
                } finally {
                    in.close();
                }
            } catch (final Exception e) {
                ui.post(() -> libraryStatus.setText("读取失败：" + e.getMessage()));
            }
        });
    }


    /* ================= Brand bottom sheet ================= */
    Dialog buildSheet(String title, View content, String positive, Runnable onPositive) {
        Dialog dialog = new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackground(shape(CARD, dp(24), 0, 0));
        root.setPadding(dp(20), dp(10), dp(20), dp(16));

        View handle = new View(this);
        handle.setBackground(shape(0xFFE2D6C6, dp(2), 0, 0));
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(dp(36), dp(4));
        hlp.gravity = Gravity.CENTER_HORIZONTAL;
        hlp.bottomMargin = dp(12);
        root.addView(handle, hlp);

        TextView t = label(title, 17f, INK, Typeface.BOLD);
        t.setPadding(0, 0, 0, dp(10));
        root.addView(t);

        ViewGroup.LayoutParams existing = content.getLayoutParams();
        int contentHeight = existing != null ? existing.height : ViewGroup.LayoutParams.WRAP_CONTENT;
        root.addView(content, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, contentHeight));

        if (positive != null) {
            LinearLayout actions = new LinearLayout(this);
            actions.setOrientation(LinearLayout.HORIZONTAL);
            actions.setGravity(Gravity.END);
            actions.setPadding(0, dp(12), 0, 0);
            TextView cancel = label("取消", 14f, INK2, Typeface.NORMAL);
            cancel.setPadding(dp(14), dp(10), dp(14), dp(10));
            cancel.setOnClickListener(v -> dialog.dismiss());
            TextView ok = label(positive, 14f, ACCENT, Typeface.BOLD);
            ok.setPadding(dp(14), dp(10), dp(14), dp(10));
            ok.setOnClickListener(v -> {
                if (onPositive != null) onPositive.run();
                dialog.dismiss();
            });
            actions.addView(cancel);
            actions.addView(ok);
            root.addView(actions);
        }

        dialog.setContentView(root);
        Window w = dialog.getWindow();
        if (w != null) {
            w.setBackgroundDrawable(new ColorDrawable(0x00000000));
            w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            w.setGravity(Gravity.BOTTOM);
        }
        return dialog;
    }

    LinearLayout sheetRow(String text, boolean selected, Runnable click) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(dp(6), dp(12), dp(6), dp(12));
        row.setBackground(pressable(0x00FFFFFF, 0x0FB95125, dp(10), 0, 0));

        View dot = new View(this);
        dot.setBackground(selected ? shape(ACCENT, dp(6), 0, 0) : shape(0x00000000, dp(6), 0xFFD8CBB9, dp(1.5f)));
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(dp(12), dp(12));
        dlp.rightMargin = dp(12);
        row.addView(dot, dlp);

        TextView label = label(text, 14f, selected ? ACCENT : INK, selected ? Typeface.BOLD : Typeface.NORMAL);
        row.addView(label, new LinearLayout.LayoutParams(0, -2, 1f));

        if (selected) {
            TextView check = label("✓", 14f, ACCENT, Typeface.BOLD);
            row.addView(check);
        }
        row.setOnClickListener(v -> {
            click.run();
        });
        return row;
    }

    void showSongPicker() {
        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        for (int i = 0; i < titles.size(); i++) {
            final int idx = i;
            list.addView(sheetRow(titles.get(i), i == songRow.selected, () -> {
                selectSong(idx);
                sheetHolder[0].dismiss();
            }));
        }
        ScrollView sc = new ScrollView(this);
        sc.setVerticalScrollBarEnabled(false);
        sc.addView(list);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(-1, dp(360));
        sc.setLayoutParams(slp);
        Dialog d = buildSheet("选择曲谱", sc, null, null);
        sheetHolder[0] = d;
        d.show();
    }

    void showDownloadSheet() {
        EditText input = new EditText(this);
        input.setHint("https://…/score.json");
        input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
        input.setTextColor(INK);
        input.setHintTextColor(INK3);
        input.setSingleLine(true);
        input.setPadding(dp(12), dp(12), dp(12), dp(12));
        input.setBackground(shape(SAND_SOFT, dp(12), 0, 0));
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.addView(input);
        TextView tip = label("仅支持 HTTPS 直链；文件 ≤ 64KB；version=1、4/4、每拍一音。", 10.5f, INK3, Typeface.NORMAL);
        tip.setLineSpacing(dp(2), 1f);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(-1, -2);
        tlp.topMargin = dp(10);
        box.addView(tip, tlp);
        buildSheet("链接下载曲谱", box, "下载", () -> {
            final String url = input.getText().toString().trim();
            libraryStatus.setText("下载中…");
            downloads.execute(() -> {
                try {
                    final String text = fetchHttps(url);
                    ui.post(() -> {
                        try {
                            addScore(text);
                        } catch (Exception e) {
                            libraryStatus.setText("曲谱拒绝：" + e.getMessage());
                        }
                    });
                } catch (final Exception e) {
                    ui.post(() -> libraryStatus.setText("下载失败：" + e.getMessage()));
                }
            });
        }).show();
    }

    final Dialog[] sheetHolder = new Dialog[1];

    void renderBeatDots(String text) {
        if (beatDots == null) return;
        int total = beats;
        int current = -1;
        try {
            String[] parts = text.split("/");
            if (parts.length == 2) {
                total = Integer.parseInt(parts[1].trim());
                current = Integer.parseInt(parts[0].trim()) - 1;
            }
        } catch (Exception ignored) {
        }
        if (total < 1) total = 4;
        if (beatDots.getChildCount() != total) {
            beatDots.removeAllViews();
            for (int i = 0; i < total; i++) {
                View dot = new View(this);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(dp(8), dp(8));
                lp.leftMargin = dp(4);
                lp.rightMargin = dp(4);
                beatDots.addView(dot, lp);
            }
        }
        for (int i = 0; i < beatDots.getChildCount(); i++) {
            boolean on = i == current;
            View dot = beatDots.getChildAt(i);
            dot.setBackground(shape(on ? ACCENT : 0xFFE2D6C6, dp(4), 0, 0));
            LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) dot.getLayoutParams();
            int size = dp(on ? 10 : 7);
            lp.width = size;
            lp.height = size;
            dot.setLayoutParams(lp);
        }
    }

    /* ==================================================================
     *  Custom views
     * ================================================================== */

    class ScoreView extends View {
        final Paint brush = new Paint(Paint.ANTI_ALIAS_FLAG);

        ScoreView() {
            super(MainActivity.this);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float f = getResources().getDisplayMetrics().density;
            float w = getWidth();
            float h = getHeight();
            float left = 2f * f;
            float right = w - 2f * f;
            float top = 26f * f;
            float bottom = Math.min(h - 6f * f, top + 82f * f);

            int totalBars = Math.max(1, (int) Math.ceil(currentSong.length / 4f));
            int bar = playing ? Math.min(totalBars, (int) (beatPos / 4f) + 1) : 1;

            brush.setTextAlign(Paint.Align.LEFT);
            brush.setTypeface(tfMedium);
            brush.setTextSize(10.5f * f);
            brush.setColor(INK3);
            canvas.drawText("位置谱 · 4/4 · 第 " + bar + " / " + totalBars + " 小节", left, 14f * f, brush);

            float windowStart = playing ? Math.max(0f, (float) Math.floor(beatPos / 8f) * 8f) : 0f;
            float beatW = (right - left) / 8f;

            brush.setColor(SAND_SOFT);
            canvas.drawRoundRect(left, top, right, bottom, 10f * f, 10f * f, brush);

            brush.setColor(0x33C9B79F);
            brush.setStrokeWidth(1f * f);
            canvas.drawLine(left + 4 * beatW, top + 4f * f, left + 4 * beatW, bottom - 4f * f, brush);

            brush.setTypeface(tfMedium);
            brush.setTextSize(8.5f * f);
            brush.setTextAlign(Paint.Align.CENTER);
            brush.setColor(INK3);
            for (int j = 0; j < 8; j++) {
                canvas.drawText("" + (j % 4 + 1), left + (j + 0.5f) * beatW, bottom - 5f * f, brush);
            }

            for (int i = 0; i < currentSong.notes.length; i++) {
                Song.Note nt = currentSong.notes[i];
                float s = nt.start;
                float e = nt.start + nt.dur;
                if (e < windowStart || s > windowStart + 8f) continue;
                float x1 = left + (Math.max(s, windowStart) - windowStart) * beatW;
                float x2 = left + (Math.min(e, windowStart + 8f) - windowStart) * beatW;
                if (x2 - x1 < 3f * f) x2 = x1 + 3f * f;

                if (nt.pos < 0) {
                    brush.setColor(INK3);
                    canvas.drawCircle((x1 + x2) / 2f, (top + bottom) / 2f, 2f * f, brush);
                    continue;
                }
                boolean done = matched != null && i < matched.length && matched[i];
                boolean current = playing && beatPos >= s && beatPos < e;
                brush.setColor(current ? 0x33B95125 : (done ? 0x26B95125 : 0xFFFFFFFF));
                canvas.drawRoundRect(x1, top + 8f * f, x2, bottom - 14f * f, 7f * f, 7f * f, brush);
                brush.setTypeface(tfBold);
                brush.setTextSize(17f * f);
                brush.setTextAlign(Paint.Align.CENTER);
                brush.setColor(current || done ? ACCENT : INK);
                if (x2 - x1 > 13f * f) {
                    canvas.drawText("" + (nt.pos + 1), (x1 + x2) / 2f, (top + bottom) / 2f + 2f * f, brush);
                }
            }

            if (playing) {
                float px = left + (float) Math.max(0, Math.min(8, beatPos - windowStart)) * beatW;
                brush.setColor(ACCENT);
                brush.setStrokeWidth(2f * f);
                brush.setStrokeCap(Paint.Cap.ROUND);
                canvas.drawLine(px, top + 4f * f, px, bottom - 4f * f, brush);
            }
            brush.setTextAlign(Paint.Align.LEFT);
        }
    }

    class Pad extends View {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        long[] flash = new long[8];
        int[] vel = new int[8];
        float[] xs = new float[8];
        float[] ys = new float[8];
        float radius;
        float cx, cy, disc;
        Shader discShader, dingShader, padShader, padHint, padLit;
        final String[] labels = {"CH0", "CH1", "CH2", "CH3", "CH4", "CH5", "CH6", "CH7"};
        int shaderW, shaderH;

        Pad() {
            super(MainActivity.this);
            p.setTypeface(tfBold);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth(), h = getHeight();
            cx = w / 2f;
            cy = h * 0.53f;
            disc = Math.min(w * 0.39f, h * 0.42f);
            radius = disc * 0.155f;

            if (discShader == null || shaderW != (int) w || shaderH != (int) h) {
                shaderW = (int) w;
                shaderH = (int) h;
                discShader = new RadialGradient(cx - disc * 0.32f, cy - disc * 0.36f, disc * 1.75f,
                        new int[]{0xFFF6D9AE, 0xFFE3B77A, 0xFFC58C55, 0xFF9A6538, 0xFF6E4325},
                        new float[]{0f, 0.25f, 0.55f, 0.82f, 1f}, Shader.TileMode.CLAMP);
                dingShader = new RadialGradient(cx - disc * 0.1f, cy - disc * 0.12f, disc * 0.5f,
                        new int[]{0xFFF0C48F, 0xFFC08A52, 0xFF8A5A34}, null, Shader.TileMode.CLAMP);
                padShader = new RadialGradient(-radius * 0.3f, -radius * 0.34f, radius * 1.4f,
                        new int[]{0xFFF0D0A3, 0xFFC08A52, 0xFF7C4E2B},
                        new float[]{0f, 0.55f, 1f}, Shader.TileMode.CLAMP);
                padHint = new RadialGradient(-radius * 0.3f, -radius * 0.34f, radius * 1.4f,
                        new int[]{0xFFFFE7C6, 0xFFE0B27C, 0xFFB07B44},
                        new float[]{0f, 0.55f, 1f}, Shader.TileMode.CLAMP);
                padLit = new RadialGradient(-radius * 0.3f, -radius * 0.34f, radius * 1.4f,
                        new int[]{0xFFD7F0E7, 0xFF4E9E8E, 0xFF2F6F61},
                        new float[]{0f, 0.55f, 1f}, Shader.TileMode.CLAMP);
            }

            /* soft shadow */
            p.setShader(null);
            p.setStyle(Paint.Style.FILL);
            p.setColor(0x1F5A3A22);
            canvas.drawCircle(cx, cy + disc * 0.06f, disc * 1.02f, p);

            /* rubber rim */
            p.setColor(0xFF231F1C);
            canvas.drawCircle(cx, cy, disc, p);
            p.setColor(0xFF3A3735);
            canvas.drawCircle(cx, cy, disc * 0.975f, p);

            /* bronze body */
            p.setShader(discShader);
            canvas.drawCircle(cx, cy, disc * 0.955f, p);
            p.setShader(null);

            /* sheen */
            p.setColor(0x14FFFFFF);
            canvas.drawCircle(cx - disc * 0.22f, cy - disc * 0.30f, disc * 0.55f, p);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(1.2f * density());
            p.setColor(0x33FFE3BC);
            canvas.drawCircle(cx, cy, disc * 0.93f, p);
            p.setStyle(Paint.Style.FILL);

            Song.Note curNote = playing ? currentSong.noteAt(beatPos) : null;
            /* pads */
            for (int i = 0; i < 8; i++) {
                double d = (double) i * Math.PI / 4.0 - Math.PI / 2.0;
                xs[i] = cx + (float) Math.cos(d) * disc * 0.56f;
                ys[i] = cy + (float) Math.sin(d) * disc * 0.56f;
                long l = SystemClock.elapsedRealtime() - flash[i];
                boolean lit = flash[i] > 0L && l < 400L;
                boolean hinted = curNote != null && PositionMap.channel(mapping, curNote.pos) == i;

                if (lit) {
                    float k = l / 400f;
                    p.setColor(0x333F8F7A);
                    canvas.drawCircle(xs[i], ys[i], radius * (1.15f + k * 0.55f), p);
                }

                /* dimple */
                p.setShader(null);
                p.setColor(0xFF6E4325);
                canvas.drawCircle(xs[i], ys[i] + radius * 0.10f, radius, p);
                canvas.save();
                canvas.translate(xs[i], ys[i]);
                p.setShader(lit ? padLit : (hinted ? padHint : padShader));
                p.setColor(0xFFFFFFFF);
                canvas.drawCircle(0, 0, radius, p);
                p.setShader(null);
                p.setStyle(Paint.Style.STROKE);
                p.setStrokeWidth(1f * density());
                p.setColor(hinted ? 0x99B95125 : 0x556E4325);
                canvas.drawCircle(0, 0, radius, p);
                p.setStyle(Paint.Style.FILL);
                canvas.restore();

                /* label */
                p.setColor(lit ? 0xFFFFFFFF : 0xF2FFF6E9);
                p.setTextSize(radius * 0.42f);
                p.setTextAlign(Paint.Align.CENTER);
                p.setTypeface(tfBold);
                canvas.drawText(labels[i].substring(2), xs[i], ys[i] + radius * 0.14f, p);
                p.setTextSize(radius * 0.26f);
                p.setColor(0xCCFFF6E9);
                p.setTypeface(tfMedium);
                canvas.drawText("CH", xs[i], ys[i] - radius * 0.34f, p);
            }

            /* ding */
            p.setShader(dingShader);
            p.setColor(0xFFFFFFFF);
            canvas.drawCircle(cx, cy, disc * 0.255f, p);
            p.setShader(null);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(1.2f * density());
            p.setColor(0x666E4325);
            canvas.drawCircle(cx, cy, disc * 0.255f, p);
            p.setStyle(Paint.Style.FILL);

            p.setTextAlign(Paint.Align.CENTER);
            p.setColor(0xF2FFF6E9);
            p.setTypeface(tfBold);
            p.setTextSize(disc * 0.115f);
            canvas.drawText(playing ? (SystemClock.elapsedRealtime() < start ? "准备…" : (demo ? "示范" : "跟练"))
                    : "HANDPAN", cx, cy + disc * 0.03f, p);
            p.setTypeface(tfMedium);
            p.setTextSize(disc * 0.052f);
            p.setColor(0xB3FFF6E9);
            canvas.drawText("D KURD · 9", cx, cy + disc * 0.115f, p);
        }

        @Override
        public boolean onTouchEvent(MotionEvent e) {
            if (e.getAction() != MotionEvent.ACTION_UP) return true;
            for (int i = 0; i < 8; i++) {
                if (Math.hypot(e.getX() - xs[i], e.getY() - ys[i]) <= radius * 1.25f) {
                    send(i);
                    pad.flash[i] = SystemClock.elapsedRealtime();
                    pad.vel[i] = 100;
                    performClick();
                    invalidate();
                    break;
                }
            }
            return true;
        }

        @Override
        public boolean performClick() {
            super.performClick();
            return true;
        }
    }

    /* ==================================================================
     *  Small UI toolkit
     * ================================================================== */

    float density() {
        return getResources().getDisplayMetrics().density;
    }

    int dp(float v) {
        return Math.round(v * density());
    }

    GradientDrawable shape(int fill, float radius, int stroke, int strokeW) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setColor(fill);
        d.setCornerRadius(radius);
        if (stroke != 0) d.setStroke(strokeW, stroke);
        return d;
    }

    Drawable pressable(int fill, int pressed, float radius, int stroke, int strokeW) {
        StateListDrawable s = new StateListDrawable();
        s.addState(new int[]{android.R.attr.state_pressed}, shape(pressed, radius, stroke, strokeW));
        s.addState(new int[]{}, shape(fill, radius, stroke, strokeW));
        return s;
    }

    TextView label(String text, float size, int color, int style) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, size);
        t.setTextColor(color);
        t.setTypeface(style == Typeface.BOLD ? tfBold : (style == Typeface.NORMAL ? tfMedium : tfBold));
        t.setIncludeFontPadding(false);
        return t;
    }

    TextView sectionTitle(String s) {
        TextView t = label(s, 11f, INK3, Typeface.NORMAL);
        t.setLetterSpacing(0.06f);
        t.setPadding(0, 0, 0, dp(8));
        return t;
    }

    TextView chip(String s) {
        TextView t = label(s, 10f, 0xFF8A5A2B, Typeface.NORMAL);
        t.setBackground(shape(0xFFF3E5D6, dp(8), 0, 0));
        t.setPadding(dp(8), dp(4), dp(8), dp(4));
        return t;
    }

    TextView button(String text, int style) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setGravity(Gravity.CENTER);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, style == 0 ? 15f : 13f);
        t.setTypeface(tfBold);
        t.setClickable(true);
        t.setFocusable(true);
        if (style == 0) {
            t.setTextColor(0xFFFFFFFF);
            t.setBackground(pressable(ACCENT, ACCENT_DK, dp(14), 0, 0));
        } else if (style == 1) {
            t.setTextColor(ACCENT);
            t.setBackground(pressable(0xFFF8E7D8, 0xFFF0DAC6, dp(14), 0, 0));
        } else {
            t.setTextColor(INK2);
            t.setBackground(pressable(0x00FFFFFF, 0x14B95125, dp(14), LINE, dp(1)));
        }
        return t;
    }

    TextView pillButton(String s) {
        TextView t = label(s, 11f, ACCENT, Typeface.BOLD);
        t.setGravity(Gravity.CENTER);
        t.setClickable(true);
        t.setBackground(pressable(0xFFF8E7D8, 0xFFF0DAC6, dp(12), 0, 0));
        return t;
    }

    void tintSeek(SeekBar s) {
        s.setProgressTintList(android.content.res.ColorStateList.valueOf(ACCENT));
        s.setThumbTintList(android.content.res.ColorStateList.valueOf(ACCENT));
        s.setProgressBackgroundTintList(android.content.res.ColorStateList.valueOf(SAND));
        s.setPadding(dp(4), 0, dp(4), 0);
    }

    LinearLayout rowBetween(String left, String right) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER_VERTICAL);
        TextView l = label(left, 13f, INK, Typeface.BOLD);
        TextView rr = label(right, 10f, INK3, Typeface.NORMAL);
        r.addView(l, new LinearLayout.LayoutParams(0, -2, 1f));
        r.addView(rr);
        return r;
    }

    View divider() {
        View v = new View(this);
        v.setBackgroundColor(LINE);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(1));
        lp.topMargin = dp(10);
        lp.bottomMargin = dp(4);
        v.setLayoutParams(lp);
        return v;
    }

    LinearLayout.LayoutParams cardParams(int bottomMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.bottomMargin = dp(bottomMargin);
        return lp;
    }

    void add(View v, int bottomMargin) {
        lesson.addView(v, cardParams(bottomMargin));
    }

    class Card extends LinearLayout {
        Card() {
            super(MainActivity.this);
            setOrientation(VERTICAL);
            setPadding(dp(16), dp(15), dp(16), dp(16));
            setBackground(shape(CARD, dp(20), LINE, dp(1)));
            setElevation(dp(1.5f));
        }
    }

    class DropdownRow extends LinearLayout {
        final TextView value;
        String[] items;
        int selected;

        DropdownRow(String title, String[] items, int selected, final ValueListener listener) {
            super(MainActivity.this);
            this.items = items;
            this.selected = selected;
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER_VERTICAL);
            setPadding(0, dp(10), 0, dp(10));
            setClickable(true);
            setBackgroundColor(0x00000000);

            LinearLayout box = new LinearLayout(MainActivity.this);
            box.setOrientation(VERTICAL);
            box.addView(label(title, 10f, INK3, Typeface.NORMAL));
            value = label(items[selected], 14f, INK, Typeface.BOLD);
            value.setPadding(0, dp(2), 0, 0);
            box.addView(value);
            addView(box, new LayoutParams(0, -2, 1f));

            TextView arrow = label("›", 20f, INK3, Typeface.NORMAL);
            addView(arrow);

            setOnClickListener(v -> {
                if (title.equals("曲谱")) {
                    showSongPicker();
                    return;
                }
                final int[] choice = {-1};
                LinearLayout list = new LinearLayout(MainActivity.this);
                list.setOrientation(LinearLayout.VERTICAL);
                for (int i = 0; i < DropdownRow.this.items.length; i++) {
                    final int idx = i;
                    list.addView(sheetRow(DropdownRow.this.items[i], i == DropdownRow.this.selected, () -> {
                        choice[0] = idx;
                        DropdownRow.this.selected = idx;
                        value.setText(DropdownRow.this.items[idx]);
                        listener.onPick(idx);
                        sheetHolder[0].dismiss();
                    }));
                }
                ScrollView sc = new ScrollView(MainActivity.this);
                sc.setVerticalScrollBarEnabled(false);
                sc.addView(list);
                sc.setLayoutParams(new LinearLayout.LayoutParams(-1, dp(300)));
                Dialog d = buildSheet(title, sc, null, null);
                sheetHolder[0] = d;
                d.show();
            });
        }

        void setItems(String[] newItems, int sel) {
            items = newItems;
            if (sel >= 0 && sel < newItems.length) {
                selected = sel;
                value.setText(newItems[sel]);
            }
        }

        void setValue(int sel) {
            if (sel >= 0 && sel < items.length) {
                selected = sel;
                value.setText(items[sel]);
            }
        }
    }

    class Segmented {
        final LinearLayout view = new LinearLayout(MainActivity.this);
        final TextView[] items;
        int selected;

        Segmented(String[] labels, int initial, final ValueListener listener) {
            selected = initial;
            view.setOrientation(LinearLayout.HORIZONTAL);
            view.setBackground(shape(SAND_SOFT, dp(12), 0, 0));
            view.setPadding(dp(3), dp(3), dp(3), dp(3));
            items = new TextView[labels.length];
            for (int i = 0; i < labels.length; i++) {
                final int idx = i;
                TextView t = label(labels[i], 11.5f, INK2, Typeface.NORMAL);
                t.setGravity(Gravity.CENTER);
                t.setPadding(0, dp(8), 0, dp(8));
                items[i] = t;
                view.addView(t, new LinearLayout.LayoutParams(0, -2, 1f));
                t.setOnClickListener(v -> {
                    setSelected(idx);
                    listener.onPick(idx);
                });
            }
            setSelected(initial);
        }

        void setSelected(int idx) {
            selected = idx;
            for (int i = 0; i < items.length; i++) {
                boolean on = i == idx;
                items[i].setTextColor(on ? ACCENT : INK2);
                items[i].setTypeface(on ? tfBold : tfMedium);
                items[i].setBackground(on ? shape(CARD, dp(10), 0, 0) : null);
                items[i].setElevation(on ? dp(1) : 0);
            }
        }
    }

    class NavItem {
        static final int HANDPAN = 0;
        static final int METRONOME = 1;
        final LinearLayout view = new LinearLayout(MainActivity.this);
        final TextView label;
        final IconView icon;

        NavItem(String text, int type) {
            view.setOrientation(LinearLayout.VERTICAL);
            view.setGravity(Gravity.CENTER);
            view.setPadding(0, dp(2), 0, 0);
            view.setClickable(true);
            icon = new IconView(type);
            view.addView(icon, new LinearLayout.LayoutParams(dp(22), dp(22)));
            label = MainActivity.this.label(text, 10f, INK3, Typeface.NORMAL);
            label.setPadding(0, dp(3), 0, 0);
            label.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
            lp.gravity = Gravity.CENTER_HORIZONTAL;
            view.addView(label, lp);
        }

        void setSelected(boolean on) {
            label.setTextColor(on ? ACCENT : INK3);
            label.setTypeface(on ? tfBold : tfMedium);
            icon.color = on ? ACCENT : INK3;
            icon.invalidate();
        }
    }

    class IconView extends View {
        int type;
        int color = INK3;
        final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

        IconView(int type) {
            super(MainActivity.this);
            this.type = type;
        }

        @Override
        protected void onDraw(Canvas c) {
            float w = getWidth(), h = getHeight();
            float cx = w / 2f, cy = h / 2f;
            p.setColor(color);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeWidth(dp(1.6f));
            p.setStrokeCap(Paint.Cap.ROUND);
            if (type == NavItem.HANDPAN) {
                c.drawCircle(cx, cy, w * 0.40f, p);
                c.drawCircle(cx, cy, w * 0.13f, p);
                for (int i = 0; i < 8; i++) {
                    double a = i * Math.PI / 4 - Math.PI / 2;
                    c.drawCircle(cx + (float) Math.cos(a) * w * 0.26f,
                            cy + (float) Math.sin(a) * w * 0.26f, w * 0.05f, p);
                }
            } else {
                float top = cy - h * 0.32f;
                android.graphics.Path path = new android.graphics.Path();
                path.moveTo(cx, top);
                path.lineTo(cx + w * 0.26f, top + h * 0.62f);
                path.lineTo(cx - w * 0.26f, top + h * 0.62f);
                path.close();
                c.drawPath(path, p);
                c.drawLine(cx, top + h * 0.16f, cx - w * 0.16f, top + h * 0.40f, p);
            }
        }
    }

    interface ValueListener {
        void onPick(int index);
    }
}

