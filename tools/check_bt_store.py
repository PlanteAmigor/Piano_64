#!/usr/bin/env python3
"""Independent on-disk oracle for append-only FAT32 song storage RTL."""
from pathlib import Path
import struct, binascii, subprocess
ROOT=Path(__file__).resolve().parents[1]; OUT=ROOT/'work/bt_store'
def run(args):
 p=subprocess.run(list(map(str,args)),cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if p.returncode: raise RuntimeError(p.stdout)
 return p.stdout
def frame(kind,seq,payload):
 b=struct.pack('<BBBBBH',0xa5,0x5a,3,kind,seq,len(payload))+payload
 return b+struct.pack('<H',binascii.crc_hqx(b,0xffff))
def prepare(n,flags=0):
 ev=[struct.pack('<IBHB',i*250,60,200,100) for i in range(n)]
 (OUT/'encode_events.hex').write_text(''.join(f'{int.from_bytes(b,"little"):016x}\n' for b in ev)+ '0000000000000000\n'*(2048-n))
 result=frame(1,0,struct.pack('<HIBB',n,n*250,0,flags))
 for i in range(0,n,32):result+=frame(2,i//32+1,struct.pack('<H',i)+b''.join(ev[i:i+32]))
 result+=frame(3,(n+31)//32+1,struct.pack('<H',n))
 (OUT/'encode_expected.hex').write_text(''.join(f'{b:02x}\n' for b in result))
 return result
def bench(name,files,**params):
 exe=OUT/(name+'.vvp')
 run(['iverilog','-g2012','-s',name,'-o',exe,*[f'-P{name}.{k}={v}' for k,v in params.items()],*files])
 log=run(['vvp',exe]);assert 'PASS' in log,log
 return log
class Volume:
 def __init__(self,spc=1,nfats=2,base=0,active=0,root_mode='short',nospace=False,full=False,bad=False):
  self.spc=spc;self.nfats=nfats;self.base=base;self.active=active;self.res=8;self.fatsz=2
  self.clusters=100;self.total=self.res+nfats*self.fatsz+self.clusters*spc
  self.data=base+self.res+nfats*self.fatsz;self.image=bytearray((base+self.total)*512)
  self.root=[2];self.old={};self.fat={0:0xffffff8,1:0xfffffff,2:0xfffffff,3:0xfffffff,5:0xfffffff,7:0xfffffff}
  if root_mode=='chain':self.root=[2,9];self.fat[2]=9;self.fat[9]=0xfffffff
  if nospace:self.fat.update({c:0xfffffff for c in range(2,self.clusters+2)})
  b=bytearray(512);b[:3]=b'\xeb\x58\x90';struct.pack_into('<H',b,11,512);b[13]=spc
  struct.pack_into('<HB',b,14,self.res,nfats);struct.pack_into('<IIHHIHH',b,32,self.total,self.fatsz,0x81 if active else 0,0,2,1,6)
  b[510:]=b'\x55\xaa';self.put(base,b)
  if base:
   m=bytearray(512);m[450]=0x0c;struct.pack_into('<II',m,454,base,self.total);m[510:]=b'\x55\xaa';self.put(0,m)
  if bad:self.image[base*512+13]=3
  f=bytearray(512);struct.pack_into('<I',f,0,0x41615252);struct.pack_into('<I',f,484,0x61417272);struct.pack_into('<III',f,488,95,4,0);struct.pack_into('<I',f,508,0xaa550000)
  self.put(base+1,f);self.put(base+7,f)
  for copy in range(nfats):
   for c,v in self.fat.items():struct.pack_into('<I',self.image,(base+8+copy*2)*512+c*4,v|0xa0000000)
  entries=[self.entry(b'P64     BIN',3,b'original instruments'),self.entry(b'SONG01  BIN',5,b'original song one'),self.entry(b'SONG03  BIN',7,b'original song three')]
  if full:
   for n in range(4,18):entries.append(self.entry(f'SONG{n:02d}  BIN'.encode(),3,b'original instruments'))
  slots={'short':3,'last':15,'cluster_last':spc*16-1,'extend':spc*16,'chain':spc*16+3}.get(root_mode)
  while len(entries)<slots:entries.append(self.dirent(f'OTHER{len(entries):03d}TXT'.encode(),3,20))
  for j,e in enumerate(entries):
   cluster=self.root[j//(spc*16)];o=(self.lba(cluster)+(j%(spc*16))//16)*512+(j%16)*32;self.image[o:o+32]=e
  self.before=bytes(self.image)
 def put(self,lba,b):self.image[lba*512:(lba+1)*512]=b
 def lba(self,c):return self.data+(c-2)*self.spc
 def dirent(self,name,c,size):
  e=bytearray(32);e[:11]=name;e[11]=0x20;struct.pack_into('<H',e,20,c>>16);struct.pack_into('<HI',e,26,c&65535,size);return e
 def entry(self,name,c,data):
  off=self.lba(c)*512;self.image[off:off+len(data)]=data;self.old[c]=bytes(self.image[off:off+self.spc*512]);return self.dirent(name,c,len(data))
 def fatget(self,c,copy=None):
  copy=self.active if copy is None else copy
  return struct.unpack_from('<I',self.image,(self.base+8+copy*2)*512+c*4)[0]&0xfffffff
 def entries(self):
  c=2;seen=set();out={}
  while c<0xffffff8:
   assert c not in seen,'root loop';seen.add(c)
   for j in range(self.spc*16):
    off=self.lba(c)*512+j*32;e=self.image[off:off+32]
    if e[0]==0:return out
    if e[0]!=0xe5 and e[11]&0x18==0:out[bytes(e[:11])]=e
   c=self.fatget(c)
  return out
 def check(self,data,error=0):
  for c,old in self.old.items():assert bytes(self.image[self.lba(c)*512:self.lba(c)*512+len(old)])==old,'existing file changed'
  entries=self.entries()
  if error:assert b'SONG02  BIN' not in entries,'failed write published';return
  e=entries[b'SONG02  BIN'];size=struct.unpack_from('<I',e,28)[0];assert size==len(data)
  c=struct.unpack_from('<H',e,26)[0]+(struct.unpack_from('<H',e,20)[0]<<16);seen=set();got=b''
  while c<0xffffff8:
   assert c not in seen and 2<=c<=self.clusters+1;seen.add(c)
   got+=bytes(self.image[self.lba(c)*512:(self.lba(c)+self.spc)*512]);c=self.fatget(c)
  assert got[:size]==data,'canonical file mismatch'
  if not self.active and self.nfats==2:assert self.image[(self.base+8)*512:(self.base+10)*512]==self.image[(self.base+10)*512:(self.base+12)*512],'FAT mirrors differ'
  if self.active:assert self.image[(self.base+8)*512:(self.base+10)*512]==self.before[(self.base+8)*512:(self.base+10)*512],'inactive FAT changed'
def main():
 OUT.mkdir(parents=True,exist_ok=True);logs=[]
 for n,flags in [(1,0),(32,0),(33,0),(140,0),(2048,0),(140,128)]:
  prepare(n,flags);log=bench('tb_song_file_encode',['sim/tb_song_file_encode.v','src/song/song_file_encode.v'],COUNT=n,FLAGS=flags);print(log.strip());logs.append(log)
 cases=[('fragmented',{}),('spc2',{'spc':2}),('card64',{'spc':64}),('singlefat',{'nfats':1}),('activefat',{'active':1}),('mbr',{'base':32}),('lastslot',{'spc':2,'root_mode':'last'}),('clusterlast',{'root_mode':'cluster_last'}),('rootextend',{'root_mode':'extend'}),('rootchain',{'root_mode':'chain'}),('maxevents',{}),('nospace',{'nospace':True}),('fullcatalog',{'full':True,'spc':2}),('badgeometry',{'bad':True}),('writeerror',{}),('readbackerror',{})]
 for name,opts in cases:
  n=2048 if name=='maxevents' else 140;expected=prepare(n);vol=Volume(**opts)
  error={'nospace':23,'fullcatalog':22,'badgeometry':20,'writeerror':24,'readbackerror':25}.get(name,0)
  inject={'writeerror':1,'readbackerror':2}.get(name,0)
  (OUT/'fat.img').write_bytes(vol.image);(OUT/'fat.before').write_bytes(vol.image)
  log=bench('tb_fat32_song_store',['sim/tb_fat32_song_store.v','src/sd/fat32_song_store.v','src/song/song_file_encode.v'],COUNT=n,INJECT=inject,EXPECT_ERROR=error)
  vol.image=bytearray((OUT/'fat.img').read_bytes());vol.check(expected,error)
  result=f'PASS {name}: '+log.split('PASS')[-1].strip()+'; independent file/chain/preservation oracle\n';print(result.strip(),flush=True);logs.append(result)
 # The physical SD model exercises both command and data wires.
 prepare(33)
 (OUT/'upload33.hex').write_bytes((OUT/'encode_expected.hex').read_bytes())
 for name,files in [
  ('tb_sd_sector_rw',['sim/tb_sd_sector_rw.v','sim/vendor/sd_fake_rw.v','src/sd/sd_sector_rw.sv','src/sd/sdcmd_ctrl.sv']),
  ('tb_bt_song_upload',['sim/tb_bt_song_upload.v',*map(str,(ROOT/'src/bt').glob('*.v')),'src/song/bt_frame_rx.v','src/song/song_file_encode.v'])]:
  log=bench(name,files);print(log.strip(),flush=True);logs.append(log)
 # Construct the existing fragmented P64/SONG card; never depend on stale fixtures.
 import random
 payload=random.Random(64).randbytes(32*63)
 checksum=sum(struct.unpack('<504I',payload))&0xffffffff
 # Match the real loader's image header, including both modal table base words.
 header=struct.pack('<4s7I',b'P64I',2,64,checksum,1,21,1,38)
 fixture=ROOT/'work/song_checks';fixture.mkdir(parents=True,exist_ok=True)
 (fixture/'P64.BIN').write_bytes(header+payload)
 run(['python3','tools/make_test_card.py'])
 (OUT/'btcard.hex').write_bytes((fixture/'card.hex').read_bytes())
 before=b''.join(struct.pack('<H',int(t,16)) for t in (OUT/'btcard.hex').read_text().split())
 log=bench('tb_bt_sd_card',['sim/tb_bt_sd_card.v','sim/vendor/sd_fake_rw.v',
   *map(str,(ROOT/'src/sd').glob('*.v')),*map(str,(ROOT/'src/sd').glob('*.sv')),
   'src/sd_ddr_loader.v',*map(str,(ROOT/'src/bt').glob('*.v')),*map(str,(ROOT/'src/song').glob('*.v'))])
 print(log.strip(),flush=True);logs.append(log)
 after=(OUT/'btcard.after').read_bytes()
 def files(image):
  base=struct.unpack_from('<I',image,454)[0];boot=base*512
  reserved=struct.unpack_from('<H',image,boot+14)[0];nf=image[boot+16];fz=struct.unpack_from('<I',image,boot+36)[0];spc=image[boot+13]
  fat=(base+reserved)*512;data=base+reserved+nf*fz
  def chain(c):
   seen=set();b=b''
   while c<0xffffff8:
    assert 2<=c<128 and c not in seen;seen.add(c);start=(data+(c-2)*spc)*512
    b+=image[start:start+spc*512];c=struct.unpack_from('<I',image,fat+4*c)[0]&0xfffffff
   return b
  root=chain(struct.unpack_from('<I',image,boot+44)[0]);result={}
  for i in range(0,len(root),32):
   e=root[i:i+32]
   if not e[0]:break
   if e[0]==0xe5 or e[11]&0x18:continue
   c=struct.unpack_from('<H',e,26)[0]+(struct.unpack_from('<H',e,20)[0]<<16);size=struct.unpack_from('<I',e,28)[0]
   result[e[:11]]=chain(c)[:size]
  return result
 old,got=files(before),files(after)
 assert all(got[k]==v for k,v in old.items()),'physical SD write changed an existing file'
 assert got[b'SONG05  BIN']==prepare(33),'physical SD file differs from original uploaded events'
 logs.append('PASS independent native SD image oracle: P64 and all original files exact; SONG05 canonical bytes and FAT chain exact\n')
 print(logs[-1].strip(),flush=True)
 (OUT/'regression.log').write_text(''.join(logs))
if __name__=='__main__':main()
