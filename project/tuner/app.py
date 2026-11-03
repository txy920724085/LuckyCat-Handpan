"""Bluetooth tuning console with a live eight-channel strength panel.

The window never opens a COM port at startup.  PMR1 supplies the sampled
window peak/RMS of every ADC channel; HTE1 supplies the true accepted-hit
events.  The bars are monitor values, not an acoustic latency measurement.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import math
import queue
import random
import secrets
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

import serial
from serial.tools import list_ports

import protocol

spec = importlib.util.spec_from_file_location(
    'legacy_handpan_protocol', Path(__file__).parents[1] / 'gui' / 'protocol.py')
legacy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = legacy
spec.loader.exec_module(legacy)

# ---------------------------------------------------------------- palette ---
BG = '#0a1220'
PANEL = '#111c2e'
CARD = '#16233a'
CARD_DARK = '#0b1626'
BORDER = '#24344f'
TEXT = '#e7eef8'
MUTED = '#8fa4c0'
DIM = '#5f7492'
ACCENT = '#2dd4bf'
BLUE = '#38bdf8'
AMBER = '#fbbf24'
RED = '#fb7185'
GREEN = '#34d399'
FONT = 'Microsoft YaHei UI'
MONO = 'Consolas'

CH_COLORS = ['#38bdf8', '#2dd4bf', '#34d399', '#a3e635',
             '#fbbf24', '#fb923c', '#f472b6', '#c084fc']

FULL_SCALE = 65535.0      # 16-bit |sample - baseline| upper bound
DB_FLOOR = -60.0
METER_DECAY = 0.97        # per 50 ms UI tick
FRAME_DECAY = 0.985       # per PMR1 frame
HOLD_SECONDS = 1.5
HOLD_DECAY = 0.985
FLASH_SECONDS = 0.6

SHORT_LABELS = {
    'peak_scans': '等峰点数',
    'filter_scans': '串扰收集轮次',
    'refractory_scans': '同通道不应期',
    'quiet_scans': '安静释放轮次',
    'on_codes': '敲击开启阈值',
    'off_codes': '安静阈值',
    'rel_shift': '相对过滤指数',
    'abs_min': '过滤最低峰值',
    'history_scans': '跨通道历史轮次',
    'min_reference_peak': '历史参考最小峰值',
    'max_suppressed_peak': '历史弱峰上限',
    'baseline_decimate': '基线更新间隔',
}
GROUPS = [
    ('时序窗口', ['peak_scans', 'filter_scans', 'refractory_scans', 'quiet_scans']),
    ('触发与相对过滤', ['on_codes', 'off_codes', 'rel_shift', 'abs_min']),
    ('跨通道历史与基线', ['history_scans', 'min_reference_peak',
                          'max_suppressed_peak', 'baseline_decimate']),
]


def clamp(value, low=0.0, high=1.0):
    return max(low, min(high, value))


def slider_is_log(lo, hi):
    return (hi - lo) > 200 and (lo == 0 or hi / max(1, lo) > 50)


def slider_position(value, lo, hi):
    value = max(lo, min(hi, int(value)))
    if not slider_is_log(lo, hi):
        return value
    if lo == 0:
        return 1000.0 * math.log1p(value) / math.log1p(hi)
    return 1000.0 * math.log(value / lo) / math.log(hi / lo)


def slider_value(position, lo, hi):
    t = max(0.0, min(1000.0, float(position)))
    if not slider_is_log(lo, hi):
        return int(round(t))
    if lo == 0:
        n = math.expm1(t / 1000.0 * math.log1p(hi))
    else:
        n = lo * (hi / lo) ** (t / 1000.0)
    return int(round(max(lo, min(hi, n))))


def db_of(code):
    if code is None or code <= 1:
        return DB_FLOOR
    return max(DB_FLOOR, 20.0 * math.log10(float(code) / FULL_SCALE))


def db_text(code):
    if code is None or code <= 1:
        return '—'
    value = db_of(code)
    return '< -60 dB' if value <= DB_FLOOR else f'{value:.1f} dB'


def fraction(code, scale):
    if code is None or code <= 0:
        return 0.0
    if scale == 'db':
        return clamp((db_of(code) - DB_FLOOR) / -DB_FLOOR)
    return clamp(float(code) / FULL_SCALE)


def level_color(code, scale):
    f = fraction(code, scale)
    if f >= 0.90:
        return RED
    if f >= 0.74:
        return AMBER
    if f >= 0.50:
        return '#5eead4'
    return ACCENT


def fmt_code(value):
    return f'{int(round(value)):,}'.replace(',', ' ')


def rms_from_sum(total, count):
    return math.sqrt(max(0.0, float(total)) / max(1, int(count)))


# ------------------------------------------------------------------ link ----
class Link(threading.Thread):
    """Single owner of the COM port; replies and monitor frames share a queue."""

    def __init__(self, port, events, logdir=None):
        super().__init__(daemon=True)
        self.port = port
        self.events = events
        self.commands = queue.Queue(maxsize=16)
        self.stop_event = threading.Event()
        self.logdir = Path(logdir) if logdir else Path(__file__).parent / 'logs'
        self.rx_bytes = 0

    def run(self):
        pending = None
        parser = protocol.Parser()
        monitor = legacy.Parser()
        logdir = self.logdir
        logdir.mkdir(exist_ok=True)
        stamp = time.strftime('%Y%m%d_%H%M%S') + '_' + secrets.token_hex(3)
        try:
            with serial.Serial(self.port, 128000, timeout=.03, write_timeout=.5) as port, \
                    (logdir / f'{stamp}.jsonl').open('x', encoding='utf-8') as log:
                self.events.put(('connected', self.port))
                sequence = secrets.randbelow(65536)
                next_poll = 0
                while not self.stop_event.is_set():
                    now = time.monotonic()
                    if pending is None:
                        try:
                            op, cfg = self.commands.get_nowait()
                            explicit = True
                        except queue.Empty:
                            op, cfg, explicit = 0, None, False
                            if now < next_poll:
                                op = None
                        if op is not None:
                            sequence = (sequence + 1) & 65535
                            packet = protocol.request(sequence, op, cfg)
                            pending = dict(sequence=sequence, op=op, cfg=cfg,
                                           explicit=explicit, packet=packet,
                                           deadline=now + 1.5, attempts=1)
                            port.write(packet)
                            log.write(json.dumps(dict(time=time.time(), direction='TX',
                                                      hex=packet.hex(), op=op)) + '\n')
                            log.flush()
                    data = port.read(4096)
                    if data:
                        self.rx_bytes += len(data)
                        log.write(json.dumps(dict(time=time.time(), direction='RX',
                                                  hex=data.hex())) + '\n')
                        log.flush()
                        for reply in parser.feed(data):
                            if pending is None or reply.sequence != pending['sequence']:
                                self.events.put(('stale', reply.sequence))
                                continue
                            self.events.put(('reply', (reply, pending)))
                            pending = None
                            next_poll = time.monotonic() + 2
                        for frame in monitor.feed(data):
                            self.events.put(('monitor', frame))
                    if pending and time.monotonic() > pending['deadline']:
                        if pending['attempts'] < 2:
                            port.write(pending['packet'])
                            pending['attempts'] += 1
                            pending['deadline'] = time.monotonic() + 1.5
                            log.write(json.dumps(dict(time=time.time(), direction='RETRY',
                                                      hex=pending['packet'].hex())) + '\n')
                            log.flush()
                        else:
                            self.events.put(('timeout', pending))
                            pending = None
                            next_poll = time.monotonic() + 3
        except Exception as exc:  # noqa: BLE001 - reported to the UI
            self.events.put(('error', str(exc)))
        finally:
            self.events.put(('disconnected', None))


# --------------------------------------------------------------- metrics ----
class Channel:
    """Meter ballistics for one ADC channel."""

    def __init__(self, index):
        self.index = index
        self.peak = 0
        self.rms = 0.0
        self.level = 0.0
        self.hold = 0.0
        self.hold_until = 0.0
        self.hits = 0
        self.last = None          # (peak, velocity, monotonic time)
        self.flash_until = 0.0

    def observe(self, peak, rms, now):
        self.peak = max(0, int(peak))
        self.rms = max(float(rms), self.rms * 0.75)
        self.level = max(float(self.peak), self.level * FRAME_DECAY)
        self._update_hold(now)

    def hit(self, peak, velocity, now):
        self.hits += 1
        self.last = (int(peak), int(velocity), now)
        self.flash_until = now + FLASH_SECONDS
        self.level = max(self.level, float(peak))
        self._update_hold(now)

    def _update_hold(self, now):
        if self.level >= self.hold:
            self.hold = self.level
            self.hold_until = now + HOLD_SECONDS

    def tick(self, now):
        self.level *= METER_DECAY
        if now > self.hold_until:
            self.hold *= HOLD_DECAY
        if self.hold < self.level:
            self.hold = self.level

    def clear_hold(self):
        self.hold = self.level
        self.hold_until = 0.0


class MeterBoard(tk.Canvas):
    """Eight horizontal bars drawn on one canvas (no per-widget flicker)."""

    def __init__(self, parent, app):
        super().__init__(parent, bg=PANEL, highlightthickness=0, height=460)
        self.app = app
        self.metric = 'peak'
        self.scale = 'db'
        self.rows = []
        self.axis = []
        self._build()
        self.bind('<Configure>', lambda _event: self.layout())

    def _build(self):
        for _ in range(6):
            self.axis.append(self.create_text(0, 0, text='', fill=DIM,
                                              font=(FONT, 7), anchor='s'))
        for i in range(8):
            row = {}
            row['card'] = self.create_rectangle(0, 0, 0, 0, fill=CARD, outline=BORDER)
            row['dot'] = self.create_oval(0, 0, 0, 0, fill=CH_COLORS[i], outline='')
            row['name'] = self.create_text(0, 0, text=f'CH{i}', fill=TEXT,
                                           font=(FONT, 10, 'bold'), anchor='w')
            row['count'] = self.create_text(0, 0, text='', fill=DIM,
                                            font=(FONT, 7), anchor='w')
            row['track'] = self.create_rectangle(0, 0, 0, 0, fill='#08111f', outline=BORDER)
            row['fill'] = self.create_rectangle(0, 0, 0, 0, fill=ACCENT, outline='')
            row['thr'] = self.create_line(0, 0, 0, 0, fill=AMBER, dash=(2, 3))
            row['hold'] = self.create_line(0, 0, 0, 0, fill='#f8fafc', width=2)
            row['hold_mark'] = self.create_polygon(0, 0, 0, 0, 0, 0,
                                                   fill='#f8fafc', outline='')
            row['value'] = self.create_text(0, 0, text='0', fill=TEXT,
                                            font=(MONO, 10, 'bold'), anchor='e')
            row['sub'] = self.create_text(0, 0, text='', fill=MUTED,
                                          font=(MONO, 8), anchor='e')
            self.rows.append(row)

    def layout(self):
        width = self.winfo_width()
        if width < 340:
            return
        left = 76
        right = max(left + 80, width - 150)
        self.left, self.right = left, right
        # Keep all eight rows visible even if the window is shortened; the
        # requested 460 px is the comfortable size, not a hard minimum.
        row_h = max(40, min(54, (self.winfo_height() - 30) // 8))
        for i, row in enumerate(self.rows):
            top = 24 + i * row_h
            bottom = top + row_h - 8
            cy = (top + bottom) // 2
            row['cy'] = cy
            self.coords(row['card'], 6, top, width - 6, bottom)
            self.coords(row['dot'], 15, cy - 3, 21, cy + 3)
            self.coords(row['name'], 28, cy - 7)
            self.coords(row['count'], 28, cy + 9)
            self.coords(row['track'], left, cy - 8, right, cy + 8)
            self.coords(row['value'], width - 12, cy - 8)
            self.coords(row['sub'], width - 12, cy + 9)
        self._layout_axis()

    def _layout_axis(self):
        if not hasattr(self, 'left'):
            return
        if self.scale == 'db':
            ticks = [(0.0, '-60'), (0.2, '-48'), (0.4, '-36'),
                     (0.6, '-24'), (0.8, '-12'), (1.0, '0 dB')]
        else:
            ticks = [(0.0, '0'), (0.25, '16k'), (0.5, '32k'),
                     (0.75, '49k'), (1.0, '65k')]
        for i, item in enumerate(self.axis):
            if i < len(ticks):
                f, text = ticks[i]
                x = self.left + f * (self.right - self.left)
                self.coords(item, x, 19)
                self.itemconfigure(item, text=text, state='normal')
            else:
                self.itemconfigure(item, state='hidden')

    def set_metric(self, metric):
        self.metric = metric
        self.refresh(time.monotonic())

    def set_scale(self, scale):
        self.scale = scale
        self._layout_axis()
        self.refresh(time.monotonic())

    def refresh(self, now):
        if not hasattr(self, 'left'):
            return
        metric, scale = self.metric, self.scale
        span = self.right - self.left
        threshold = clamp(self.app.threshold_codes, 0, 65535)
        tx = self.left + fraction(threshold, scale) * span
        tx = clamp(tx, self.left, self.right)
        for i, row in enumerate(self.rows):
            ch = self.app.channels[i]
            value = ch.peak if metric == 'peak' else ch.rms
            x = self.left + fraction(value, scale) * span
            x = clamp(x, self.left, self.right)
            self.coords(row['fill'], self.left, row['cy'] - 8, x, row['cy'] + 8)
            self.itemconfigure(row['fill'], fill=level_color(value, scale),
                               state='normal' if value > 0 else 'hidden')
            self.coords(row['thr'], tx, row['cy'] - 11, tx, row['cy'] + 11)
            if metric == 'peak' and ch.hold > 0:
                hx = self.left + fraction(ch.hold, scale) * span
                hx = clamp(hx, self.left, self.right)
                self.coords(row['hold'], hx, row['cy'] - 12, hx, row['cy'] + 12)
                self.coords(row['hold_mark'], hx - 4, row['cy'] - 14,
                            hx + 4, row['cy'] - 14, hx, row['cy'] - 8)
                self.itemconfigure(row['hold'], state='normal')
                self.itemconfigure(row['hold_mark'], state='normal')
            else:
                self.itemconfigure(row['hold'], state='hidden')
                self.itemconfigure(row['hold_mark'], state='hidden')
            if metric == 'peak':
                self.itemconfigure(row['value'], text=fmt_code(ch.peak))
                self.itemconfigure(row['sub'], text=db_text(ch.peak))
            else:
                self.itemconfigure(row['value'], text=fmt_code(ch.rms))
                self.itemconfigure(row['sub'], text=db_text(ch.rms))
            flash = now < ch.flash_until
            self.itemconfigure(row['card'], outline=BLUE if flash else BORDER,
                               width=2 if flash else 1)
            self.itemconfigure(row['dot'], fill=BLUE if flash else CH_COLORS[i],
                               outline=BLUE if flash else '')
            self.itemconfigure(row['name'], fill=BLUE if flash else TEXT)
            self.itemconfigure(row['count'], text=f'×{ch.hits}' if ch.hits else '',
                               fill=MUTED if flash else DIM)


# ------------------------------------------------------------- parameters ---
class ParamRow:
    """Spinbox + log slider + live time hint + last confirmed FPGA value."""

    def __init__(self, parent, app, spec_row, row):
        self.app = app
        self.name, label, default, lo, hi, unit = spec_row
        self.lo, self.hi, self.unit = lo, hi, unit
        self.label_text = SHORT_LABELS.get(self.name, label)
        self.syncing = False
        # Code thresholds and long counters span several decades; a linear
        # slider would put every useful value in the first pixel.
        self.logarithmic = slider_is_log(lo, hi)
        self.var = tk.StringVar(value=str(default))
        self.actual = tk.StringVar(value='—')
        self.hint = tk.StringVar(value='')

        ttk.Label(parent, text=self.label_text, style='Param.TLabel',
                  width=15, anchor='w').grid(row=row, column=0, sticky='w',
                                             padx=(0, 4), pady=0)
        self.spin = ttk.Spinbox(parent, from_=lo, to=hi, increment=1, width=8,
                                textvariable=self.var, justify='right')
        self.spin.grid(row=row, column=1, sticky='w', padx=(0, 8), pady=0)
        self.scale = ttk.Scale(parent, from_=0 if self.logarithmic else lo,
                               to=1000 if self.logarithmic else hi,
                               orient='horizontal', command=self._from_scale)
        self.scale.grid(row=row, column=2, sticky='ew', padx=(0, 8), pady=0)
        ttk.Label(parent, textvariable=self.hint, style='Hint.TLabel',
                  width=11, anchor='e').grid(row=row, column=3, sticky='e',
                                             padx=(0, 6), pady=0)
        self.actual_label = ttk.Label(parent, textvariable=self.actual,
                                      style='Actual.TLabel', width=6, anchor='e')
        self.actual_label.grid(row=row, column=4, sticky='e', pady=0)

        self.var.trace_add('write', self._from_text)
        self.spin.bind('<FocusOut>', self._normalize)
        self.spin.bind('<Return>', self._normalize)
        self.syncing = True
        try:
            self.scale.set(self._slider_pos(default))
        finally:
            self.syncing = False
        self.update_hint()

    def _slider_pos(self, value):
        return slider_position(value, self.lo, self.hi)

    def _slider_value(self, position):
        return slider_value(position, self.lo, self.hi)

    def _from_text(self, *_):
        if self.syncing:
            return
        try:
            value = int(self.var.get().strip())
        except ValueError:
            self.hint.set(f'整数 {self.lo}–{self.hi}')
            return
        self.syncing = True
        try:
            self.scale.set(self._slider_pos(value))
        finally:
            self.syncing = False
        self.update_hint()
        self.app.on_edit()

    def _from_scale(self, value):
        if self.syncing:
            return
        n = self._slider_value(value)
        self.syncing = True
        try:
            self.var.set(str(n))
        finally:
            self.syncing = False
        self.update_hint()
        self.app.on_edit()

    def _normalize(self, *_):
        try:
            n = int(self.var.get().strip())
        except ValueError:
            n = self.lo
        self.set_value(max(self.lo, min(self.hi, n)))

    def set_value(self, value):
        value = max(self.lo, min(self.hi, int(value)))
        self.syncing = True
        try:
            self.var.set(str(value))
            self.scale.set(self._slider_pos(value))
        finally:
            self.syncing = False
        self.update_hint()
        self.app.on_edit()

    def set_actual(self, value):
        self.actual.set('—' if value is None else str(value))

    def set_enabled(self, enabled):
        state = 'normal' if enabled else 'disabled'
        self.spin.configure(state=state)
        self.scale.configure(state=state)

    def get(self):
        try:
            return int(self.var.get().strip())
        except ValueError as exc:
            raise ValueError(f'{self.label_text} 必须是整数') from exc

    def update_hint(self):
        try:
            n = int(self.var.get().strip())
        except ValueError:
            self.hint.set('—')
            return
        if n < self.lo or n > self.hi:
            self.hint.set(f'范围 {self.lo}–{self.hi}')
            return
        if self.unit == 'peak':
            self.hint.set(f'{(n - 1) * self.app.scan_us / 1000:.3f} ms')
        elif self.unit == 'scan':
            if self.name == 'filter_scans' and not self.app.filter_enabled.get():
                self.hint.set('旁路')
            else:
                self.hint.set(f'{n * self.app.scan_us / 1000:.3f} ms')
        elif self.unit == 'ratio':
            self.hint.set(f'≥ 1/{2 ** n}')
        else:
            self.hint.set('ADC 码')


class ScrollForm(ttk.Frame):
    """Scrollable parameter area; the action buttons stay pinned below it."""

    def __init__(self, parent):
        super().__init__(parent, style='Panel.TFrame')
        self.canvas = tk.Canvas(self, bg=PANEL, highlightthickness=0)
        self.bar = ttk.Scrollbar(self, orient='vertical', command=self.canvas.yview,
                                 style='Vertical.TScrollbar')
        self.canvas.configure(yscrollcommand=self.bar.set)
        self.bar.pack(side='right', fill='y')
        self.canvas.pack(side='left', fill='both', expand=True)
        self.inner = ttk.Frame(self.canvas, style='Panel.TFrame')
        self.window = self.canvas.create_window((0, 0), window=self.inner, anchor='nw')
        self.inner.bind('<Configure>', self._inner_changed)
        self.canvas.bind('<Configure>', self._canvas_changed)
        self.canvas.bind('<Enter>', self._wheel_on)
        self.canvas.bind('<Leave>', self._wheel_off)

    def _inner_changed(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox('all'))
        self._sync_scrollbar()

    def _canvas_changed(self, event):
        self.canvas.itemconfigure(self.window, width=event.width)
        self._sync_scrollbar()

    def _sync_scrollbar(self):
        needed = self.inner.winfo_reqheight() > self.canvas.winfo_height() + 1
        if needed and not self.bar.winfo_ismapped():
            self.bar.pack(side='right', fill='y')
        elif not needed and self.bar.winfo_ismapped():
            self.bar.pack_forget()

    def _wheel_on(self, _event=None):
        self.canvas.bind_all('<MouseWheel>', self._wheel)

    def _wheel_off(self, _event=None):
        self.canvas.unbind_all('<MouseWheel>')

    def _wheel(self, event):
        if self.inner.winfo_reqheight() > self.canvas.winfo_height():
            self.canvas.yview_scroll(int(-event.delta / 120), 'units')


# --------------------------------------------------------------- live demo ---
class DemoFeed(threading.Thread):
    """Synthetic PMR1/HTE1 traffic for UI review without hardware."""

    def __init__(self, events, stop):
        super().__init__(daemon=True)
        self.events = events
        self.stop = stop

    def run(self):
        levels = [0.0] * 8
        seq = 0
        hits = 0
        while not self.stop.wait(0.068):
            seq += 1
            if random.random() < 0.065:
                ch = random.randrange(8)
                amp = random.uniform(6000, 30000)
                levels[ch] = max(levels[ch], amp)
                hits += 1
                self.events.put(('hit', legacy.HitFrame(
                    hits, ch, random.randint(35, 120), int(amp), hits, 0)))
                for nb in ((ch + 1) % 8, (ch - 1) % 8):
                    if random.random() < 0.55:
                        levels[nb] = max(levels[nb], amp * random.uniform(0.08, 0.30))
            peaks = []
            for i in range(8):
                levels[i] *= 0.70
                peaks.append(int(max(random.uniform(10, 45),
                                     levels[i] + random.uniform(-150, 150))))
            sums = [max(1, int(peaks[i] ** 2 * 0.35)) for i in range(8)]
            self.events.put(('monitor', legacy.PmrFrame(
                seq, seq * 3400000, seq * 1280, 128, 0,
                tuple(peaks), tuple(sums), 0)))


# --------------------------------------------------------------------- UI ---
class App:
    def __init__(self, root, demo=False):
        self.root = root
        self.link = None
        self.events = queue.Queue()
        self.scan_us = 53.3
        self.current = None
        self.last_rx = None
        self.busy = False
        self.loaded = False
        self.baseline = None
        self.action_result = '尚未连接'
        self.demo = demo
        self.demo_started = False
        self.demo_stop = threading.Event()
        self.demo_feed = None
        self.channels = [Channel(i) for i in range(8)]
        self.last_hit = None
        self.window_leader = None
        self.hit_total = 0
        self.hit_dropped = 0
        self.pmr_dropped = 0
        self.pmr_time = None
        self.pmr_frames = 0
        self.log_lines = []
        self.log_window = None
        self.log_text = None
        self._ready = False
        self.filter_enabled = tk.BooleanVar(value=True)
        self.history_enabled = tk.BooleanVar(value=True)

        root.title('手碟调参台 · 8 通道实时强度')
        screen_w, screen_h = root.winfo_screenwidth(), root.winfo_screenheight()
        width = min(1320, max(1180, screen_w - 40))
        height = min(900, max(720, screen_h - 80))
        x = max(0, (screen_w - width) // 2)
        y = max(0, (screen_h - height) // 2)
        root.geometry(f'{width}x{height}+{x}+{y}')
        root.minsize(1180, 720)
        root.configure(bg=BG)
        self._style()
        self._build()
        self._ready = True
        self.refresh_ports()
        self.update_hints()
        self.update_estimate()
        self.update_controls()
        self.update_dirty()
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.after(50, self.poll)
        if demo:
            root.after(250, self.start_demo)

    # -- construction -------------------------------------------------------
    def _style(self):
        style = ttk.Style()
        style.theme_use('clam')
        style.configure('.', font=(FONT, 9), background=PANEL, foreground=TEXT)
        style.configure('Panel.TFrame', background=PANEL)
        style.configure('TLabel', background=PANEL, foreground=TEXT)
        style.configure('ColHead.TLabel', background=PANEL, foreground=DIM,
                        font=(FONT, 8))
        style.configure('Param.TLabel', background=PANEL, foreground=TEXT)
        style.configure('Hint.TLabel', background=PANEL, foreground=MUTED,
                        font=(MONO, 8))
        style.configure('Actual.TLabel', background=PANEL, foreground=BLUE,
                        font=(MONO, 9, 'bold'))
        style.configure('TSpinbox', fieldbackground=CARD_DARK, background='#1b2a44',
                        foreground=TEXT, arrowcolor=MUTED, bordercolor=BORDER,
                        insertcolor=TEXT, padding=2)
        style.map('TSpinbox', fieldbackground=[('readonly', CARD_DARK)],
                  foreground=[('disabled', DIM)])
        style.configure('TScale', background=PANEL, troughcolor='#16233a',
                        bordercolor='#2a3d5c', lightcolor=ACCENT, darkcolor=ACCENT)
        style.configure('TCheckbutton', background=PANEL, foreground=MUTED,
                        indicatorcolor=CARD_DARK)
        style.map('TCheckbutton', background=[('active', PANEL)],
                  foreground=[('selected', TEXT), ('active', TEXT)])
        style.configure('TCombobox', fieldbackground=CARD_DARK, background='#1b2a44',
                        foreground=TEXT, arrowcolor=MUTED, bordercolor=BORDER,
                        padding=4)
        style.map('TCombobox', fieldbackground=[('readonly', CARD_DARK)],
                  foreground=[('readonly', TEXT), ('disabled', DIM)])
        style.configure('Vertical.TScrollbar', background='#1b2a44', troughcolor=PANEL,
                        arrowcolor=MUTED, bordercolor=PANEL,
                        lightcolor='#1b2a44', darkcolor='#1b2a44',
                        borderwidth=0, arrowsize=10)
        style.map('Vertical.TScrollbar', background=[('active', '#2a3d5c')])
        self.root.option_add('*TCombobox*Listbox.background', PANEL)
        self.root.option_add('*TCombobox*Listbox.foreground', TEXT)
        self.root.option_add('*TCombobox*Listbox.selectBackground', ACCENT)
        self.root.option_add('*TCombobox*Listbox.selectForeground', '#04231f')

    def _button(self, parent, text, command, kind='normal', width=None):
        colors = {
            'normal': ('#1b2a44', TEXT, '#263a5b'),
            'accent': (ACCENT, '#04231f', '#5eead4'),
            'danger': ('#3a1d2a', '#fda4af', '#522437'),
            'ghost': (PANEL, MUTED, '#1b2a44'),
        }
        bg, fg, active = colors[kind]
        button = tk.Button(parent, text=text, command=command, bg=bg, fg=fg,
                           activebackground=active, activeforeground=fg,
                           disabledforeground=DIM, relief='flat', bd=0,
                           highlightthickness=0, padx=11, pady=6,
                           font=(FONT, 9, 'bold'), cursor='hand2')
        if width:
            button.configure(width=width)
        return button

    def _panel(self, parent):
        return tk.Frame(parent, bg=PANEL, highlightbackground=BORDER,
                        highlightthickness=1)

    def _stat_cell(self, parent, column, title):
        cell = tk.Frame(parent, bg=CARD, highlightbackground=BORDER,
                        highlightthickness=1)
        cell.grid(row=0, column=column, sticky='nsew', padx=(0, 8))
        tk.Label(cell, text=title, bg=CARD, fg=MUTED,
                 font=(FONT, 8)).pack(anchor='w', padx=11, pady=(6, 0))
        value = tk.StringVar(value='—')
        label = tk.Label(cell, textvariable=value, bg=CARD, fg=TEXT,
                         font=(FONT, 10, 'bold'))
        label.pack(anchor='w', padx=11, pady=(0, 6))
        parent.grid_columnconfigure(column, weight=1)
        return value, label

    def _build(self):
        header = tk.Frame(self.root, bg=BG)
        header.pack(fill='x', padx=22, pady=(14, 8))
        title_box = tk.Frame(header, bg=BG)
        title_box.pack(side='left')
        tk.Label(title_box, text='手碟 · 实时调参台', bg=BG, fg=TEXT,
                 font=(FONT, 20, 'bold')).pack(anchor='w')
        tk.Label(title_box, text='8 通道强度  ·  ADS8688 5 MHz  ·  JDY-31 128000 baud',
                 bg=BG, fg=DIM, font=(FONT, 8)).pack(anchor='w', pady=(2, 0))

        conn = tk.Frame(header, bg=BG)
        conn.pack(side='right')
        tk.Label(conn, text='蓝牙串口', bg=BG, fg=MUTED,
                 font=(FONT, 8)).pack(side='left', padx=(0, 6))
        self.port = tk.StringVar()
        self.ports = ttk.Combobox(conn, textvariable=self.port, width=9,
                                  state='readonly')
        self.ports.pack(side='left')
        self._button(conn, '刷新', self.refresh_ports, 'ghost').pack(side='left', padx=(6, 0))
        self.connect_btn = self._button(conn, '连接', self.connect, 'accent')
        self.connect_btn.pack(side='left', padx=(6, 0))
        self.disconnect_btn = self._button(conn, '断开', self.disconnect, 'normal')
        self.disconnect_btn.pack(side='left', padx=(6, 0))

        strip = tk.Frame(self.root, bg=BG)
        strip.pack(fill='x', padx=22, pady=(0, 10))
        self.link_var, self.link_label = self._stat_cell(strip, 0, '链路')
        self.adc_var, self.adc_label = self._stat_cell(strip, 1, 'ADC')
        self.scan_var, _ = self._stat_cell(strip, 2, '扫描周期')
        self.gen_var, _ = self._stat_cell(strip, 3, '配置代次')
        self.drop_var, _ = self._stat_cell(strip, 4, '遥测丢弃 · PMR / HTE')

        main = tk.Frame(self.root, bg=BG)
        main.pack(fill='both', expand=True, padx=22, pady=(0, 10))
        main.grid_columnconfigure(0, minsize=590, weight=0)
        main.grid_columnconfigure(1, weight=1)
        main.grid_rowconfigure(0, weight=1)

        left = self._panel(main)
        left.grid(row=0, column=0, sticky='nsew', padx=(0, 14))
        self._build_meters(left)

        right = self._panel(main)
        right.grid(row=0, column=1, sticky='nsew')
        self._build_params(right)

        footer = tk.Frame(self.root, bg=BG)
        footer.pack(fill='x', padx=22, pady=(0, 12))
        self.peak_var = self._metric_card(footer, '等峰等待', AMBER)
        self.collect_var = self._metric_card(footer, '串扰收集', BLUE)
        self.total_var = self._metric_card(footer, '两段合计（窗口估算）', ACCENT)
        note = tk.Frame(footer, bg=BG)
        note.pack(side='right', fill='both', expand=True)
        self.footer_note = tk.Label(
            note, text='参数窗口估算，不含采样相位、合成、DAC 与扬声器。',
            bg=BG, fg=DIM, font=(FONT, 8), justify='right', anchor='e')
        self.footer_note.pack(side='right', padx=(10, 0))
        self.log_btn = self._button(note, '运行日志', self.open_log, 'ghost')
        self.log_btn.pack(side='right')

    def _build_meters(self, parent):
        head = tk.Frame(parent, bg=PANEL)
        head.pack(fill='x', padx=12, pady=(10, 0))
        tk.Label(head, text='八通道强度', bg=PANEL, fg=TEXT,
                 font=(FONT, 13, 'bold')).pack(side='left')
        self.metric_var = tk.StringVar(value='peak')
        self.scale_var = tk.StringVar(value='db')
        self.metric_seg = self._segmented(
            head, self.metric_var, [('峰值', 'peak'), ('RMS', 'rms')],
            self._metric_changed)
        self.metric_seg.pack(side='right')

        sub = tk.Frame(parent, bg=PANEL)
        sub.pack(fill='x', padx=12, pady=(2, 6))
        tk.Label(sub, text='PMR1 68.2 ms 窗 · 黄线=阈值 · 白线=1.5 s 保持',
                 bg=PANEL, fg=DIM, font=(FONT, 8)).pack(side='left')
        self.scale_seg = self._segmented(
            sub, self.scale_var, [('dB', 'db'), ('线性', 'linear')],
            self._scale_changed)
        self.scale_seg.pack(side='right')
        self._button(sub, '清保持', self.clear_hold, 'ghost').pack(
            side='right', padx=(0, 4))

        self.meter = MeterBoard(parent, self)
        self.meter.pack(fill='both', expand=True, padx=10, pady=(0, 6))

        hit = tk.Frame(parent, bg=CARD, highlightbackground=BORDER,
                       highlightthickness=1)
        hit.pack(fill='x', padx=12, pady=(0, 12))
        self.hit_ch = tk.Label(hit, text='—', bg=CARD, fg=MUTED,
                               font=(MONO, 17, 'bold'), width=5)
        self.hit_ch.pack(side='left', padx=(10, 4), pady=6)
        text_box = tk.Frame(hit, bg=CARD)
        text_box.pack(side='left', fill='x', expand=True, pady=6)
        self.hit_main = tk.Label(text_box, text='等待敲击事件…', bg=CARD, fg=TEXT,
                                 font=(FONT, 9, 'bold'), anchor='w')
        self.hit_main.pack(fill='x')
        self.hit_sub = tk.Label(text_box, text='HTE1 会给出通道、峰值与力度',
                                bg=CARD, fg=MUTED, font=(FONT, 8), anchor='w')
        self.hit_sub.pack(fill='x')

    def _segmented(self, parent, variable, options, command):
        frame = tk.Frame(parent, bg=PANEL)
        buttons = []
        for text, value in options:
            b = tk.Button(frame, text=text, bg=CARD_DARK, fg=MUTED,
                          activebackground='#1b2a44', activeforeground=TEXT,
                          relief='flat', bd=0, highlightthickness=0,
                          padx=9, pady=2, font=(FONT, 8), cursor='hand2',
                          command=lambda v=value: (variable.set(v), command()))
            b.pack(side='left', padx=(2, 0))
            buttons.append((b, value))
        variable.trace_add('write', lambda *_: self._sync_segment(buttons, variable))
        self._sync_segment(buttons, variable)
        return frame

    @staticmethod
    def _sync_segment(buttons, variable):
        current = variable.get()
        for button, value in buttons:
            selected = value == current
            button.configure(bg=ACCENT if selected else CARD_DARK,
                             fg='#04231f' if selected else MUTED)

    def _metric_changed(self):
        self.meter.set_metric(self.metric_var.get())

    def _scale_changed(self):
        self.meter.set_scale(self.scale_var.get())

    def clear_hold(self):
        for channel in self.channels:
            channel.clear_hold()
        self.note('已清除峰值保持')

    def _build_params(self, parent):
        head = tk.Frame(parent, bg=PANEL)
        head.pack(fill='x', padx=12, pady=(10, 2))
        tk.Label(head, text='参数调节', bg=PANEL, fg=TEXT,
                 font=(FONT, 13, 'bold')).pack(side='left')
        self.dirty_label = tk.Label(head, text='尚未回读', bg=PANEL, fg=DIM,
                                    font=(FONT, 8))
        self.dirty_label.pack(side='right')
        tk.Label(head, text='FPGA 列 = 上次回读值', bg=PANEL, fg=DIM,
                 font=(FONT, 8)).pack(side='right', padx=(0, 10))
        self.scan_note = tk.Label(parent, text='1 轮 = 53.30 µs', bg=PANEL,
                                  fg=DIM, font=(FONT, 8), anchor='w')
        self.scan_note.pack(fill='x', padx=12, pady=(0, 4))

        form = ScrollForm(parent)
        form.pack(fill='both', expand=True, padx=(12, 6), pady=(0, 2))
        inner = form.inner
        inner.grid_columnconfigure(0, minsize=132)
        inner.grid_columnconfigure(1, minsize=76)
        inner.grid_columnconfigure(2, weight=1, minsize=150)
        inner.grid_columnconfigure(3, minsize=94)
        inner.grid_columnconfigure(4, minsize=54)
        for column, text, sticky in ((0, '参数', 'w'), (1, '草稿', 'w'),
                                     (2, '', 'w'), (3, '时间 / 含义', 'e'),
                                     (4, 'FPGA', 'e')):
            ttk.Label(inner, text=text, style='ColHead.TLabel').grid(
                row=0, column=column, sticky=sticky, padx=(0, 6), pady=(0, 1))

        specs = {row[0]: row for row in protocol.FIELDS}
        self.rows = {}
        grid_row = 1
        for title, names in GROUPS:
            group = tk.Frame(inner, bg=PANEL)
            group.grid(row=grid_row, column=0, columnspan=5, sticky='ew',
                       pady=(5, 2))
            tk.Frame(group, bg=ACCENT, width=3, height=12).pack(side='left')
            tk.Label(group, text=title, bg=PANEL, fg=TEXT,
                     font=(FONT, 9, 'bold')).pack(side='left', padx=(7, 0))
            grid_row += 1
            for name in names:
                self.rows[name] = ParamRow(inner, self, specs[name], grid_row)
                grid_row += 1

        quick = tk.Frame(inner, bg=PANEL)
        quick.grid(row=grid_row, column=0, columnspan=5, sticky='ew',
                   pady=(8, 0))
        tk.Label(quick, text='快速实验', bg=PANEL, fg=MUTED,
                 font=(FONT, 8)).pack(side='left')
        for scans in (160, 80, 40):
            self._button(quick, f'收集 {scans} 轮',
                         lambda n=scans: self.quick_filter(n),
                         'normal').pack(side='left', padx=(6, 0))
        tk.Label(quick, text='只改草稿，仍需点击“应用并回读”', bg=PANEL,
                 fg=DIM, font=(FONT, 8)).pack(side='left', padx=(10, 0))
        grid_row += 1
        tk.Label(inner, text='等峰越短，力度越可能偏小；收集越短，迟到串扰越容易漏过。',
                 bg=PANEL, fg=DIM, font=(FONT, 8), anchor='w').grid(
                     row=grid_row, column=0, columnspan=5, sticky='w',
                     pady=(5, 2))

        flags = tk.Frame(parent, bg=PANEL)
        flags.pack(fill='x', padx=12, pady=(4, 2))
        ttk.Checkbutton(flags, text='启用串扰收集 / 相对过滤',
                        variable=self.filter_enabled, command=self.on_toggle,
                        style='TCheckbutton').pack(side='left', padx=(0, 14))
        ttk.Checkbutton(flags, text='启用延迟跨通道历史过滤',
                        variable=self.history_enabled, command=self.on_toggle,
                        style='TCheckbutton').pack(side='left')

        actions = tk.Frame(parent, bg=PANEL)
        actions.pack(fill='x', padx=12, pady=(5, 0))
        self.query_btn = self._button(actions, '读取 FPGA', lambda: self.send(0),
                                      'normal')
        self.query_btn.pack(side='left', padx=(0, 4))
        self.apply_btn = self._button(actions, '应用并回读', lambda: self.send(1),
                                      'accent')
        self.apply_btn.pack(side='left', padx=(0, 4))
        self.default_btn = self._button(actions, '固件默认', lambda: self.send(2),
                                        'normal')
        self.default_btn.pack(side='left', padx=(0, 4))
        self._button(actions, '保存', self.save, 'ghost').pack(side='left', padx=(0, 4))
        self._button(actions, '载入', self.load, 'ghost').pack(side='left')

        self.action_label = tk.Label(parent, text='尚未连接', bg=PANEL, fg=MUTED,
                                     font=(FONT, 8), anchor='w', justify='left',
                                     wraplength=610)
        self.action_label.pack(fill='x', padx=12, pady=(2, 6))

    def _metric_card(self, parent, caption, color):
        card = tk.Frame(parent, bg=CARD, highlightbackground=BORDER,
                        highlightthickness=1)
        card.pack(side='left', padx=(0, 10))
        value = tk.StringVar(value='—')
        tk.Label(card, textvariable=value, bg=CARD, fg=color,
                 font=(MONO, 15, 'bold')).pack(anchor='w', padx=13, pady=(5, 0))
        tk.Label(card, text=caption, bg=CARD, fg=MUTED,
                 font=(FONT, 8)).pack(anchor='w', padx=13, pady=(0, 5))
        return value

    # -- state helpers ------------------------------------------------------
    @property
    def threshold_codes(self):
        if self.current is not None:
            return self.current.config.get('on_codes', protocol.DEFAULTS['on_codes'])
        try:
            return int(self.rows['on_codes'].var.get())
        except (ValueError, KeyError):
            return protocol.DEFAULTS['on_codes']

    def draft(self):
        config = {name: row.get() for name, row in self.rows.items()}
        config.update(filter_enabled=bool(self.filter_enabled.get()),
                      history_enabled=bool(self.history_enabled.get()))
        protocol.values(config)
        return config

    def fill(self, config):
        for name, row in self.rows.items():
            row.set_value(config[name])
        self.filter_enabled.set(bool(config['filter_enabled']))
        self.history_enabled.set(bool(config['history_enabled']))
        self.update_hints()
        self.update_estimate()
        self.update_dirty()

    def update_hints(self):
        for row in self.rows.values():
            row.update_hint()

    def update_estimate(self):
        try:
            peak, collection, total = protocol.timing(self.draft(), self.scan_us)
            self.peak_var.set(f'{peak:.3f} ms')
            self.collect_var.set(f'{collection:.3f} ms')
            self.total_var.set(f'{total:.3f} ms')
        except ValueError:
            for var in (self.peak_var, self.collect_var, self.total_var):
                var.set('—')
        self.scan_note.configure(text=f'1 轮 = {self.scan_us:.2f} µs · '
                                      f'窗口时间仅为换算值，不是声学延迟')

    def update_dirty(self):
        if self.baseline is None:
            text, color = '尚未回读', DIM
        else:
            try:
                same = self.draft() == self.baseline
            except ValueError:
                text, color = '草稿无效', RED
            else:
                text, color = (('与 FPGA 一致', GREEN) if same
                               else ('有未发送改动', AMBER))
        self.dirty_label.configure(text=text, fg=color)

    def on_edit(self):
        if not self._ready:
            return
        self.update_estimate()
        self.update_dirty()

    def quick_filter(self, scans):
        self.rows['filter_scans'].set_value(scans)
        self.note(f'快速草稿：串扰收集 {scans} 轮（尚未发送）')

    def on_toggle(self):
        self.update_hints()
        self.update_estimate()
        self.update_dirty()

    # -- serial actions -----------------------------------------------------
    def refresh_ports(self):
        try:
            ports = [p.device for p in list_ports.comports()]
        except Exception:  # noqa: BLE001 - a missing driver must not crash the UI
            ports = []
        self.ports['values'] = ports
        if ports and not self.port.get():
            self.port.set(ports[0])

    def connect(self):
        if self.demo or (self.link and self.link.is_alive()):
            return
        if not self.port.get():
            messagebox.showerror('串口', '请选择蓝牙传出的 COM 端口')
            return
        self.loaded = False
        self.current = None
        self.last_rx = None
        self.baseline = None
        self.busy = True
        self.action_result = '正在连接；等待本版固件 TNR1 回执…'
        self.reset_meters()
        for row in self.rows.values():
            row.set_actual(None)
        self.update_controls()
        self.update_dirty()
        self.update_action_label()
        self.link = Link(self.port.get(), self.events)
        self.link.start()
        self.note(f'打开串口 {self.port.get()}')

    def reset_meters(self):
        for channel in self.channels:
            channel.peak = 0
            channel.rms = 0.0
            channel.level = 0.0
            channel.hold = 0.0
            channel.hold_until = 0.0
            channel.hits = 0
            channel.last = None
            channel.flash_until = 0.0
        self.last_hit = None
        self.window_leader = None
        self.hit_total = 0
        self.hit_dropped = 0
        self.pmr_dropped = 0

    def disconnect(self):
        if self.link:
            self.link.stop_event.set()

    def send(self, op):
        if self.demo:
            messagebox.showinfo('演示模式', '演示模式只显示合成数据，不发送参数。')
            return
        if not self.link or not self.link.is_alive():
            messagebox.showinfo('未连接', '请先连接蓝牙串口。')
            return
        try:
            config = self.draft() if op == 1 else None
            self.link.commands.put_nowait((op, config))
            self.busy = True
            self.update_controls()
            self.action_result = '已发送，等待 FPGA 校验与回读…'
            self.update_action_label()
            self.note(f'发送操作 {op}')
        except (ValueError, queue.Full) as exc:
            messagebox.showerror('无法发送', str(exc))

    def save(self):
        try:
            config = self.draft()
        except ValueError as exc:
            messagebox.showerror('参数', str(exc))
            return
        path = filedialog.asksaveasfilename(defaultextension='.json',
                                            filetypes=[('参数 JSON', '*.json')])
        if path:
            try:
                Path(path).write_text(
                    json.dumps(dict(schema='handpan-tune-v1', config=config),
                               ensure_ascii=False, indent=2), encoding='utf-8')
                self.note(f'已保存草稿 {Path(path).name}')
            except OSError as exc:
                messagebox.showerror('保存失败', str(exc))

    def load(self):
        if self.busy:
            return
        path = filedialog.askopenfilename(filetypes=[('参数 JSON', '*.json')])
        if not path:
            return
        try:
            data = json.loads(Path(path).read_text(encoding='utf-8-sig'))
            if data['schema'] != 'handpan-tune-v1':
                raise ValueError('参数文件版本不匹配')
            protocol.values(data['config'])
            self.fill(data['config'])
            self.note(f'已载入草稿 {Path(path).name}；尚未发送到 FPGA')
        except (ValueError, KeyError, OSError, TypeError) as exc:
            messagebox.showerror('文件无效', str(exc))

    # -- demo ---------------------------------------------------------------
    def start_demo(self):
        if self.demo_started:
            return
        self.demo_started = True
        self.reset_meters()
        self.demo_feed = DemoFeed(self.events, self.demo_stop)
        self.demo_feed.start()
        for name, row in self.rows.items():
            row.set_actual(protocol.DEFAULTS[name])
        self.baseline = dict(protocol.DEFAULTS)
        self.loaded = True
        self.action_result = '演示模式：合成信号，未连接硬件'
        self.update_hints()
        self.update_estimate()
        self.update_dirty()
        self.update_action_label()
        self.note('演示模式启动（合成 PMR1 / HTE1 数据）')

    # -- event pump ---------------------------------------------------------
    def poll(self):
        now = time.monotonic()
        for _ in range(400):
            try:
                kind, data = self.events.get_nowait()
            except queue.Empty:
                break
            if kind == 'connected':
                self.note('串口已打开；等待有效回执，不据此判定链路正常')
            elif kind == 'reply':
                self._on_reply(data, now)
            elif kind == 'timeout':
                self._on_timeout(data)
            elif kind == 'monitor':
                self._on_monitor(data, now)
            elif kind == 'stale':
                self.note(f'忽略不匹配回执 seq={data}')
            elif kind == 'error':
                self.action_result = '串口错误：' + data
                self.update_action_label()
                self.note(data)
            elif kind == 'disconnected':
                self.busy = False
                self.link = None
                self.action_result = '已断开；草稿保留，设备当前值需重连回读'
                self.update_action_label()
                self.note('串口已断开')
        for channel in self.channels:
            channel.tick(now)
        self.meter.refresh(now)
        self.update_live(now)
        self.update_controls()
        self.root.after(50, self.poll)

    def _on_reply(self, data, now):
        reply, pending = data
        self.last_rx = now
        self.current = reply
        if reply.scan_cycles:
            self.scan_us = reply.scan_cycles / 50.0
            for row in self.rows.values():
                row.update_hint()
        for name, row in self.rows.items():
            row.set_actual(reply.config[name])
        was_loaded = self.loaded
        self.baseline = dict(reply.config)
        self.loaded = True
        if pending['explicit'] or not was_loaded:
            self.busy = False
        matched = protocol.confirmed(reply, pending['op'], pending['cfg'])
        if matched and (pending['explicit'] or not was_loaded):
            self.fill(reply.config)
        if pending['op'] in (1, 2):
            if matched:
                self.action_result = '参数已应用，回读一致'
            elif reply.status == 0:
                self.action_result = '回读与发送不一致，请重新读取'
            else:
                self.action_result = '应用被拒绝：' + protocol.STATUS.get(
                    reply.status, '未知错误')
        elif pending['explicit']:
            self.action_result = ('已读取 FPGA 当前参数' if reply.status == 0
                                  else '读取失败：' + protocol.STATUS.get(
                                      reply.status, '未知错误'))
        if not pending['explicit'] and (not was_loaded or
                                        self.action_result.startswith('正在连接')):
            self.action_result = '链路已建立，已回读 FPGA 参数'
        self.note(f'回执 seq={reply.sequence} status={reply.status} '
                  f'gen={reply.generation} raw={reply.raw_hits} '
                  f'accepted={reply.accepted_hits}')
        self.update_hints()
        self.update_estimate()
        self.update_dirty()
        self.update_action_label()

    def _on_timeout(self, pending):
        if pending['explicit'] or not self.loaded:
            self.busy = False
        if pending['op'] in (1, 2):
            self.action_result = '上次应用结果未知，请重新读取确认'
        elif pending['explicit']:
            self.action_result = '读取超时，参数是否生效未知'
        elif not self.loaded:
            self.action_result = '连接超时：未收到 TNR1 回执，检查固件/波特率'
        self.update_action_label()
        self.note('回执超时；不要依据发送成功判断已生效')

    def _on_monitor(self, frame, now):
        if isinstance(frame, legacy.HitFrame):
            channel = self.channels[frame.channel]
            channel.hit(frame.peak, frame.velocity, now)
            self.last_hit = (frame.channel, frame.peak, frame.velocity, now)
            self.hit_total = frame.accepted_total
            self.hit_dropped = frame.dropped_total
            self.note(f'HTE1 CH{frame.channel} 峰值={frame.peak} '
                      f'力度={frame.velocity}')
        elif isinstance(frame, legacy.PmrFrame):
            count = max(1, frame.window_count)
            for index, channel in enumerate(self.channels):
                channel.observe(frame.peaks[index],
                                rms_from_sum(frame.sum_squares[index], count), now)
            self.pmr_time = now
            self.pmr_frames += 1
            self.pmr_dropped = frame.dropped_windows
            leader = max(range(8), key=lambda i: frame.peaks[i])
            if frame.peaks[leader] >= self.threshold_codes:
                self.window_leader = (leader, frame.peaks[leader], now)
            else:
                self.window_leader = None
        elif isinstance(frame, legacy.KeyFrame):
            self.note(f'QKY1 音色={frame.selected_timbre} Echo={frame.echo_enabled} '
                      f'按键=0x{frame.keys:03X}')

    # -- periodic labels ----------------------------------------------------
    def update_live(self, now):
        if self.demo:
            link_text, link_color = '演示模式', BLUE
        elif self.link and self.link.is_alive():
            if self.last_rx is None:
                link_text, link_color = '已连接 · 等待回执', AMBER
            elif now - self.last_rx > 6:
                link_text, link_color = '回执过期', RED
            else:
                link_text, link_color = f'已连接 · {now - self.last_rx:.1f} s', GREEN
        else:
            link_text, link_color = '未连接', MUTED
        self.link_var.set(link_text)
        self.link_label.configure(fg=link_color)

        if self.current is not None:
            ready = bool(self.current.flags & 1)
            calibrated = bool(self.current.flags & 2)
            adc_text = ('就绪' if ready else '未就绪') + ' · ' + (
                '已标定' if calibrated else '未标定')
            self.adc_label.configure(fg=GREEN if ready and calibrated else AMBER)
            self.gen_var.set(str(self.current.generation))
        elif self.demo:
            adc_text = '演示 · 合成'
            self.adc_label.configure(fg=MUTED)
            self.gen_var.set('演示')
        else:
            adc_text = '—'
            self.adc_label.configure(fg=TEXT)
            self.gen_var.set('—')
        self.adc_var.set(adc_text)
        self.scan_var.set(f'{self.scan_us:.2f} µs')
        self.drop_var.set(f'{self.pmr_dropped} / {self.hit_dropped}')
        if self.window_leader and now - self.window_leader[2] > 5.0:
            self.window_leader = None

        if self.last_hit and now - self.last_hit[3] < 3.0:
            recent = self.last_hit
            channel = self.channels[recent[0]]
            self.hit_ch.configure(text=f'CH{recent[0]}', fg=CH_COLORS[recent[0]])
            self.hit_main.configure(text=f'峰值 {fmt_code(recent[1])}   ·   '
                                         f'力度 {recent[2]}/127')
            self.hit_sub.configure(
                text=f'{now - recent[3]:.1f} s 前   ·   本通道累计 {channel.hits} 次   ·   '
                     f'总接受 {self.hit_total} / 丢弃 {self.hit_dropped}')
        elif self.window_leader:
            index, peak, when = self.window_leader
            self.hit_ch.configure(text=f'CH{index}', fg=CH_COLORS[index])
            self.hit_main.configure(text=f'本窗口最强   ·   峰值 {fmt_code(peak)}')
            self.hit_sub.configure(text=f'PMR1 抽样窗口，最后更新 {now - when:.1f} s 前')
        else:
            self.hit_ch.configure(text='—', fg=MUTED)
            self.hit_main.configure(text='等待敲击事件…')
            self.hit_sub.configure(text='HTE1 会给出通道、峰值与力度')

        if self.demo:
            self.footer_note.configure(
                text='演示模式：柱状图为合成数据；参数不会发送到硬件。')
        elif self.link and self.link.is_alive():
            self.footer_note.configure(
                text=f'PMR1 每 68.2 ms 一窗  ·  TNR1 每 2 s 轮询  ·  '
                     f'RX {self.link.rx_bytes} B  ·  柱状图为窗口监视值')
        else:
            self.footer_note.configure(
                text='柱状图为 PMR1 抽样窗口监视值，不是声学延迟测量。')

    def update_action_label(self):
        text = self.action_result
        color = MUTED
        if '一致' in text or '已读取' in text or '已回读' in text:
            color = GREEN
        elif ('未知' in text or '拒绝' in text or '错误' in text
              or '失败' in text or '超时' in text or '不一致' in text):
            color = RED
        elif '等待' in text or '已发送' in text or '正在' in text:
            color = AMBER
        self.action_label.configure(text=text, fg=color)

    def update_controls(self):
        connected = self.link is not None and self.link.is_alive()
        action_state = 'normal' if connected and not self.busy else 'disabled'
        for button in (self.query_btn, self.apply_btn, self.default_btn):
            button.configure(state=action_state)
        for row in self.rows.values():
            row.set_enabled(not self.busy)
        self.connect_btn.configure(state='disabled' if connected or self.demo else 'normal')
        self.disconnect_btn.configure(state='normal' if connected else 'disabled')

    # -- log ----------------------------------------------------------------
    def note(self, text):
        line = time.strftime('%H:%M:%S') + '  ' + text
        self.log_lines.append(line)
        if len(self.log_lines) > 600:
            del self.log_lines[:200]
        if self.log_text is not None:
            try:
                self.log_text.configure(state='normal')
                self.log_text.insert('end', line + '\n')
                self.log_text.see('end')
                self.log_text.configure(state='disabled')
            except tk.TclError:
                self.log_text = None

    def open_log(self):
        if self.log_window is not None:
            try:
                self.log_window.lift()
                return
            except tk.TclError:
                self.log_window = None
        win = tk.Toplevel(self.root)
        win.title('运行日志')
        win.geometry('760x420')
        win.configure(bg=BG)
        text = tk.Text(win, bg=CARD_DARK, fg=TEXT, insertbackground=TEXT,
                       font=(MONO, 9), relief='flat', bd=0, wrap='word')
        bar = ttk.Scrollbar(win, orient='vertical', command=text.yview,
                            style='Vertical.TScrollbar')
        text.configure(yscrollcommand=bar.set)
        bar.pack(side='right', fill='y')
        text.pack(side='left', fill='both', expand=True, padx=8, pady=8)
        text.insert('end', '\n'.join(self.log_lines) + ('\n' if self.log_lines else ''))
        text.configure(state='disabled')
        self.log_window = win
        self.log_text = text

        def _closed():
            self.log_window = None
            self.log_text = None
            win.destroy()

        win.protocol('WM_DELETE_WINDOW', _closed)

    def close(self):
        self.demo_stop.set()
        if self.link:
            self.link.stop_event.set()
            self.link.join(timeout=1)
        self.root.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--smoke', action='store_true', help='close after 1.5 s')
    parser.add_argument('--preview', action='store_true', help='close after 60 s')
    parser.add_argument('--demo', action='store_true',
                        help='show synthetic channel data without a COM port')
    args = parser.parse_args()
    root = tk.Tk()
    app = App(root, demo=args.demo)
    if args.smoke:
        root.after(1500, app.close)
    if args.preview:
        root.after(60000, app.close)
    root.mainloop()


if __name__ == '__main__':
    main()
