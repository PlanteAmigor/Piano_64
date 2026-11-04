#!/usr/bin/env python3
"""Receive real production single-PLL/serializer RTL at the differential pins."""
from pathlib import Path
import hashlib,json,re,subprocess
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
W=R/'work/hdmi_production_link';W.mkdir(parents=True,exist_ok=True)
mode=(R/'src/hdmi/ui_video_mode.vh').read_text()
assert '`define UI_VIDEO_1080P_SINGLE' in mode
half='`define UI_VIDEO_1080P_HALF' in mode
wrapper=W/'production_clocks.v'
wrapper.write_text("module probe_clocks(input clkin,output pixel,output serial_clk,output reference_clk,output reference_lock,output video_lock);assign reference_clk=clkin;assign reference_lock=1'b1;Gowin_PLL_720P prod(.clkin(clkin),.clkout0(pixel),.clkout1(serial_clk),.lock(video_lock));endmodule\n")
lib=Path('/mnt/project/ov-cli/Gowin/IDE/simlib/gw5a/prim_sim.v');s=lib.read_text();models=[]
for name in ['PLL','OSER10','CLKDIV','ELVDS_OBUF']:
 m=re.search(r'^module '+name+r'\s*\(.*?^endmodule[^\n]*',s,re.M|re.S);assert m,name;models.append(m[0])
vendor=W/'vendor.v';vendor.write_text('`timescale 1ns/1fs\n'+'\n'.join(models)+"\nmodule GSR;reg GSRO=0;initial #500 GSRO=1;endmodule\n")
files=[D/'tb_link.v',D/'probe.v',wrapper,R/'src/sd/uart_tx.v',R/'src/hdmi/ir4/gowin_pll_720p.v',vendor]+[R/'src/hdmi/ir4'/n for n in ['dvi_tx_top.v','dvi_tx_tmds_enc.v','dvi_tx_tmds_phy.v','dvi_tx_clk_drv.v']]
assets=[R/'src/hdmi/ui_video_mode.vh',R/'src/hdmi/ir4/tmds_encode.mem']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(R)):sha(p) for p in files+assets}
cmd=['iverilog','-g2012','-DPROBE_1080_SINGLE']+([] if half else ['-DPROBE_1080_FAST'])+['-s','tb_link','-s','GSR','-o',str(W/'link.vvp'),*[str(p) for p in files]]
p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);assert p.returncode==0,p.stdout+p.stderr
p=subprocess.run(['vvp',str(W/'link.vvp')],cwd=R,capture_output=True,text=True);(W/'serial.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
assert p.returncode==0 and 'PASS independent serial' in p.stdout
assert before=={str(p.relative_to(R)):sha(p) for p in files+assets}
(W/'results.json').write_text(json.dumps({'pass':True,'single_pll_half_rate':half,'vendor_sha256':sha(lib),'sources':before,'limits':'Colorbar lines at boot and after reset; full frame/UI covered separately.'},indent=2)+'\n')
