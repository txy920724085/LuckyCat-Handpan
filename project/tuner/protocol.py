"""Versioned tuning wire protocol, shared by the UI and offline tests."""
from dataclasses import dataclass, asdict
import binascii
import struct

FIELDS = [
 ('peak_scans','等峰采样点数',51,1,4096,'peak'),
 ('filter_scans','串扰收集轮次',40,0,4096,'scan'),
 ('refractory_scans','同通道不应期轮次',800,1,60000,'scan'),
 ('quiet_scans','安静释放轮次',30,1,60000,'scan'),
 ('on_codes','敲击开启阈值',512,1,65535,'code'),
 ('off_codes','安静阈值',128,1,65535,'code'),
 ('rel_shift','相对过滤除数：2 的指数',4,1,6,'ratio'),
 ('abs_min','串扰过滤最低峰值',256,1,65535,'code'),
 ('history_scans','跨通道历史轮次',960,1,60000,'scan'),
 ('min_reference_peak','历史参考最小峰值',4096,1,65535,'code'),
 ('max_suppressed_peak','历史过滤最大弱峰',1024,0,65535,'code'),
 ('baseline_decimate','基线更新间隔轮次',10,1,1000,'scan'),
]
DEFAULTS={name:default for name,_,default,_,_,_ in FIELDS}
DEFAULTS.update(filter_enabled=True,history_enabled=True)
STATUS={0:'成功',1:'协议或操作码错误',2:'CRC 错误',3:'参数范围或关系错误',4:'事务号冲突'}

def values(config):
    result=[]
    if any(not isinstance(config[k],bool) for k in ('filter_enabled','history_enabled')):
        raise ValueError('过滤开关必须为布尔值 true / false')
    for name,label,_,lo,hi,_ in FIELDS:
        value=config[name]
        if isinstance(value,bool) or not isinstance(value,int) or not lo<=value<=hi:
            raise ValueError(f'{label} 必须为 {lo}～{hi} 的整数')
        result.append(value)
    if config['off_codes']>=config['on_codes']:
        raise ValueError('安静阈值必须小于敲击开启阈值')
    if config['max_suppressed_peak']>config['min_reference_peak']:
        raise ValueError('历史过滤最大弱峰不能大于历史参考最小峰值')
    result.append(int(bool(config['filter_enabled'])) | (int(bool(config['history_enabled']))<<1))
    return result+[0,0,0]

def config_from_values(v):
    config={f[0]:v[i] for i,f in enumerate(FIELDS)}
    config.update(filter_enabled=bool(v[12]&1),history_enabled=bool(v[12]&2))
    if v[12]&~3 or any(v[13:]):raise ValueError('Unsupported config flags/reserved fields')
    values(config)
    return config

def request(sequence,op,config=None):
    if op not in (0,1,2):raise ValueError('invalid op')
    data=struct.pack('<2sHB16H',b'\xfcT',sequence,op,*values(config or DEFAULTS))
    return data+struct.pack('<H',binascii.crc_hqx(data,0xffff))

@dataclass(frozen=True)
class Reply:
    sequence:int
    status:int
    flags:int
    generation:int
    config:dict
    scan_cycles:int
    raw_hits:int
    accepted_hits:int
    errors:int

def confirmed(reply,op,config=None):
    if reply.status!=0:return False
    expected=config if op==1 else DEFAULTS if op==2 else reply.config
    return reply.config==expected

class Parser:
    def __init__(self):self.buffer=bytearray();self.crc_errors=0
    def feed(self,data):
        self.buffer.extend(data);out=[]
        while True:
            pos=self.buffer.find(b'TNR1')
            if pos<0:
                if len(self.buffer)>3:del self.buffer[:-3]
                break
            if pos:del self.buffer[:pos]
            if len(self.buffer)<8:break
            if self.buffer[4:8]!=b'\x01\x06\x40\x00':del self.buffer[0];continue
            if len(self.buffer)<64:break
            raw=bytes(self.buffer[:64])
            if binascii.crc_hqx(raw[:62],0xffff)!=struct.unpack_from('<H',raw,62)[0]:
                self.crc_errors+=1;del self.buffer[0];continue
            seq,status,flags,gen=struct.unpack_from('<HBBI',raw,8)
            try:cfg=config_from_values(struct.unpack_from('<16H',raw,16))
            except ValueError:del self.buffer[0];continue
            cyc,hits,accepted,errors=struct.unpack_from('<IIIH',raw,48)
            out.append(Reply(seq,status,flags,gen,cfg,cyc,hits,accepted,errors))
            del self.buffer[:64]
        return out

def timing(config,scan_us=53.3):
    """Nominal windows, NOT an acoustic latency measurement."""
    peak=(config['peak_scans']-1)*scan_us/1000
    collection=config['filter_scans']*scan_us/1000 if config['filter_enabled'] else 0
    return peak,collection,peak+collection
