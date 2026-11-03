#!/usr/bin/env python3
"""Generate native UI glyphs and static text cells; no framebuffer or new IP."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import json
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'src/hdmi/ui'
CN=''.join(dict.fromkeys('光影乐器演奏测试教学钢琴古筝唢呐笛子曲谱主旋律自动伴奏音色效果'))
MAP={c:i for i,c in enumerate(CN)}
F_ASC=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',18)
F_CN=ImageFont.truetype('/usr/share/fonts/truetype/LXGWWenKai-Medium.ttf',16)
def code(c):return ord(c) if ord(c)<128 else MAP[c]
def main():
 glyph=[]
 for i in range(128):
  c=CN[i] if i<len(CN) else chr(i) if 32<=i<=126 else ' '
  im=Image.new('L',(16,32));d=ImageDraw.Draw(im);f=F_CN if i<len(CN) else F_ASC
  b=d.textbbox((0,0),c,font=f);d.text(((16-(b[2]-b[0]))//2-b[0],(32-(b[3]-b[1]))//2-b[1]),c,font=f,fill=255)
  for y in range(32):glyph.append(sum((im.getpixel((x,y))>=112)<<x for x in range(16)))
 (OUT/'ui1080_font.hex').write_text(''.join(f'{v:04x}\n' for v in glyph))
 cells=[32]*(3*4096)
 def put(page,row,col,text):
  assert 0<=row<34 and col+len(text)<=120,(page,row,col,text)
  if row==32:
   assert col+len(text)<=80
   row=1
  assert row<32
  for i,c in enumerate(text):cells[page*4096+row*128+col+i]=code(c)
 for p,title in enumerate(['光影乐器 / PERFORMANCE','测试 / SOUND LAB','教学 / MELODY FLOW']):
  put(p,0,0,title);put(p,2,88,'音色');put(p,3,88,'效果')
  put(p,4,4,['演奏 / SOUND IN MOTION','测试 / EIGHT KEYS. EIGHT PURE TONES.','主旋律 / PLAY THE LEAD. FEEL THE MUSIC.'][p])
  put(p,32,4,['KEY0  PAGE    AUX0  音色 / HOLD  效果    R1[8] +    R2[8] -','KEY0  PAGE    R1[0..7]  HOLD TO PLAY    RELEASE TO STOP','R1[8] NEXT / MODE    R2[8] CONFIRM / STOP    HOLD R2[8] BACK'][p])
 put(0,7,4,'01 / SPECTRUM');put(0,17,4,'LOW                      MID                       HIGH')
 put(0,20,4,'02 / COMPONENTS');put(0,29,4,'01              16              32              48            64')
 put(0,7,77,'03 / LISSAJOUS');put(0,27,77,'R2[0] TRAIL    R2[1] SMOOTH')
 put(0,29,77,'LIVE EXPRESSION');put(0,30,77,'HAND               LEVEL')
 put(1,7,6,'SPECTRUM / 32 BANDS');put(1,29,6,'40 HZ                 200 HZ                 1 KHZ                  8 KHZ')
 put(1,7,94,'KEY MONITOR')
 for k in range(8):put(1,10+k*2,95,f'R1[{k}]')
 put(2,7,4,'曲谱 / LIBRARY')
 for k in range(8):put(2,9+k*2,6,'SONG')
 put(2,26,4,'MODE');put(2,27,6,'自动 / AUTO PLAY');put(2,29,6,'教学 / LEAD + 伴奏')
 put(2,7,40,'主旋律');put(2,7,76,'伴奏 / AUTO');put(2,30,40,'POSITION');put(2,30,79,'MISSED');put(2,30,99,'WRONG')
 for k,c in enumerate('CDEFGAB*'):put(2,28,50+k*8,c)
 (OUT/'ui1080_tiles.hex').write_text(''.join(f'{v:02x}\n' for v in cells))
 (OUT/'ui1080_assets.json').write_text(json.dumps({'glyphs':MAP,'font':[16,32],'tiles':[128,32],'visible_cells':[120,34],'footer_row':1,'pages':3},ensure_ascii=False,indent=2)+'\n')
 decimal=['// Constant byte-to-decimal mapping, synthesized as logic.','function [11:0] byte_decimal(input [7:0] value);','begin case(value)']
 for value in range(256):decimal.append(f"8'd{value}:byte_decimal=12'h{value:03d};")
 decimal+=['endcase end','endfunction']
 (OUT/'ui1080_decimal.vh').write_text('\n'.join(decimal)+'\n')
 print('Generated 128 native glyphs and three page text maps')
if __name__=='__main__':main()
