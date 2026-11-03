"""QSU1 absolute GLOBAL setting telemetry. Not WDY1, not a host estimator."""
from dataclasses import dataclass
import binascii
import struct

HEADER=struct.Struct('<4sBBHIQIBBBB')
MAGIC=b'QSU1'
SIZE=30
HIT_HEADER=struct.Struct('<4sBBHIBBHIIH')
HIT_MAGIC=b'HTE1'
HIT_SIZE=28
PMR_MAGIC=b'PMR1'
PMR_SIZE=88
KEY_MAGIC=b'QKY1'
KEY_SIZE=34

@dataclass(frozen=True)
class Frame:
    sequence:int
    cycles:int
    qt_sequence:int
    sustain_u:int
    flags:int
    qt_mode:int
    qt_error:int

    @property
    def available(self):
        return self.flags & 11 == 11  # enabled, coherent, global setting

@dataclass(frozen=True)
class HitFrame:
    sequence:int
    channel:int
    velocity:int
    peak:int
    accepted_total:int
    dropped_total:int

@dataclass(frozen=True)
class PmrFrame:
    sequence:int
    timestamp_cycles:int
    scan_end:int
    window_count:int
    status:int
    peaks:tuple
    sum_squares:tuple
    dropped_windows:int

@dataclass(frozen=True)
class KeyFrame:
    sequence:int;cycles:int;qt_sequence:int;keys:int;status:int;mode:int;error:int
    healthy:bool;synchronized:bool;press_pulse:int;selected_timbre:int;echo_enabled:bool
    sensor_timbre_seen:bool;last_sensor_timbre:int

def encode(frame):
    if not 0 <= frame.sustain_u <= 255:raise ValueError('sustain_u outside uint8')
    data=HEADER.pack(MAGIC,1,1,SIZE,frame.sequence,frame.cycles,frame.qt_sequence,
                     frame.sustain_u,frame.flags,frame.qt_mode,frame.qt_error)
    return data+struct.pack('<H',binascii.crc_hqx(data,0xffff))

class Parser:
    def __init__(self):
        self.buffer=bytearray();self.crc_errors=0;self.header_errors=0;self.discarded=0
        self.hit_crc_errors=0;self.hit_header_errors=0
        self.pmr_crc_errors=0;self.pmr_header_errors=0
        self.key_crc_errors=0;self.key_header_errors=0

    def feed(self,data):
        self.buffer.extend(data);frames=[]
        while True:
            qpos=self.buffer.find(MAGIC);hpos=self.buffer.find(HIT_MAGIC);ppos=self.buffer.find(PMR_MAGIC);kpos=self.buffer.find(KEY_MAGIC)
            positions=[p for p in (qpos,hpos,ppos,kpos) if p>=0]
            pos=min(positions) if positions else -1
            if pos < 0:
                if len(self.buffer)>3:self.discarded+=len(self.buffer)-3;del self.buffer[:-3]
                break
            if pos:self.discarded+=pos;del self.buffer[:pos]
            if self.buffer[:4]==MAGIC:
                if len(self.buffer)<SIZE:break
                raw=bytes(self.buffer[:SIZE]);v=HEADER.unpack(raw[:28])
                if v[1:4]!=(1,1,SIZE) or v[8]&0xf0 or v[9]>15 or v[10]>15:
                    self.header_errors+=1;del self.buffer[0];continue
                if binascii.crc_hqx(raw[:28],0xffff)!=struct.unpack('<H',raw[28:])[0]:
                    self.crc_errors+=1;del self.buffer[0];continue
                del self.buffer[:SIZE];frames.append(Frame(*v[4:]));continue
            if self.buffer[:4]==HIT_MAGIC:
                if len(self.buffer)<HIT_SIZE:break
                raw=bytes(self.buffer[:HIT_SIZE]);v=HIT_HEADER.unpack(raw[:26])
                if v[1:4]!=(1,2,HIT_SIZE) or v[5]>7 or v[6]>127:
                    self.hit_header_errors+=1;del self.buffer[0];continue
                if binascii.crc_hqx(raw[:26],0xffff)!=struct.unpack('<H',raw[26:])[0]:
                    self.hit_crc_errors+=1;del self.buffer[0];continue
                del self.buffer[:HIT_SIZE]
                frames.append(HitFrame(v[4],v[5],v[6],v[7],v[8],v[9]));continue
            if self.buffer[:4]==KEY_MAGIC:
                if len(self.buffer)<KEY_SIZE:break
                raw=bytes(self.buffer[:KEY_SIZE]);magic,ver,kind,size,seq=struct.unpack_from('<4sBBHI',raw)
                if (magic,ver,kind,size)!=(KEY_MAGIC,1,4,KEY_SIZE):
                    self.key_header_errors+=1;del self.buffer[0];continue
                if binascii.crc_hqx(raw[:32],0xffff)!=struct.unpack_from('<H',raw,32)[0]:
                    self.key_crc_errors+=1;del self.buffer[0];continue
                flags=raw[27];frames.append(KeyFrame(seq,int.from_bytes(raw[12:18],'little'),
                    struct.unpack_from('<I',raw,18)[0],struct.unpack_from('<H',raw,22)[0]&0xfff,
                    raw[24],raw[25]&15,raw[26]&15,bool(flags&2),bool(flags&4),raw[28]&31,
                    raw[29]&3,bool(raw[30]&1),bool(flags&8),raw[31]&3))
                del self.buffer[:KEY_SIZE];continue
            if len(self.buffer)<PMR_SIZE:break
            raw=bytes(self.buffer[:PMR_SIZE]);magic,ver,kind,size,seq=struct.unpack_from('<4sBBHI',raw)
            if (magic,ver,kind,size)!=(PMR_MAGIC,1,3,PMR_SIZE) or raw[25]!=0:
                self.pmr_header_errors+=1;del self.buffer[0];continue
            if binascii.crc_hqx(raw[:86],0xffff)!=struct.unpack_from('<H',raw,86)[0]:
                self.pmr_crc_errors+=1;del self.buffer[0];continue
            peaks=[];sums=[]
            for ch in range(8):
                off=26+7*ch;peaks.append(struct.unpack_from('<H',raw,off)[0]);sums.append(int.from_bytes(raw[off+2:off+7],'little'))
            frames.append(PmrFrame(seq,int.from_bytes(raw[12:18],'little'),struct.unpack_from('<I',raw,18)[0],
                struct.unpack_from('<H',raw,22)[0],raw[24],tuple(peaks),tuple(sums),struct.unpack_from('<I',raw,82)[0]))
            del self.buffer[:PMR_SIZE]
        return frames

class Latest:
    """Receive-time freshness; duplicates never renew it. No integration of steps."""
    def __init__(self,stale_s=1.0):
        self.stale_s=stale_s;self.frame=None;self.received_at=None
        self.duplicates=0;self.conflicts=0;self.gaps=0;self.restarts=0;self.reordered=0
        self.synced=False

    def observe(self,f,now):
        old=self.frame
        if old is not None:
            if (f.sequence,f.cycles)==(old.sequence,old.cycles):
                if f==old:self.duplicates+=1
                else:self.conflicts+=1
                return False
            if f.cycles<old.cycles:
                # No persistent boot ID exists. Counter restart OR reordering,
                # not proof of a physical reset; require another forward frame.
                self.restarts+=1;self.frame=f;self.received_at=now;self.synced=False
                return True
            distance=(f.sequence-old.sequence)&0xffffffff
            if distance==0 or distance>0x7fffffff or f.cycles<=old.cycles:
                self.reordered+=1;return False
            self.gaps+=distance-1
        self.frame=f;self.received_at=now;self.synced=True;return True

    def state(self,now):
        if self.frame is None or not self.synced:return 'UNSYNCED',None
        if now-self.received_at>=self.stale_s:return 'STALE',None
        if not self.frame.available:return 'UNAVAILABLE',None
        return 'VALID',self.frame.sustain_u
