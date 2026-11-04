#!/usr/bin/env python3
"""Freeze the rejected full candidate and add reversible black-screen diagnostics."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,time
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('--half-rate',action='store_true');a=ap.parse_args()
W=R/'work/hdmi_black'/('full_debug30' if a.half_rate else 'full_debug');assert not W.exists();W.mkdir(parents=True)
assert subprocess.run(['pgrep','-x','gw_sh'],stdout=subprocess.DEVNULL).returncode!=0
m=json.loads((R/'impl/pnr/piano64_full.manifest.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for p,h in m['inputs'].items():
 assert sha(R/p)==h,p
 q=W/p;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(R/p,q)
if a.half_rate:
 q=W/'src/hdmi/ui_video_mode.vh';q.write_text(q.read_text()+'\n`define UI_VIDEO_1080P_HALF\n')
 q=W/'src/piano64_hdmi.sdc';s=q.read_text().replace('-multiply_by 3 -divide_by 1 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT0}]','-multiply_by 3 -divide_by 2 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT0}]').replace('-multiply_by 15 -divide_by 1 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}]','-multiply_by 15 -divide_by 2 [get_pins {u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT1}]');q.write_text(s)
for name in ['full_debug_ui.vh','full_debug_uart.v']:
 q=W/'diagnostics/hdmi_link'/name;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(D/name,q)
q=W/'src/hdmi/hdmi_ui3_top.v';s=q.read_text();s=s.replace('    input wire CLK_SCOPE,','    input wire [1:0] DEBUG_MODE, output wire [95:0] DEBUG,\n    input wire CLK_SCOPE,',1)
s=s.replace('`ifndef SIM_UI3\n    dvi_tx_top', '`include "diagnostics/hdmi_link/full_debug_ui.vh"\n`ifndef SIM_UI3\n    dvi_tx_top',1)
s=s.replace('.reset(dvi_reset),','.reset(dbg_reset),').replace('.den(vis_d9),.hsync(hs_d9),.vsync(vs_d9),.pixel_data(rgb_r)', '.den(dbg_de),.hsync(dbg_hs),.vsync(dbg_vs),.pixel_data(dbg_rgb)');q.write_text(s)
q=W/'src/piano64_top.v';s=q.read_text().replace('    wire scope_clk;', '    wire [95:0] debug_info; wire [1:0] debug_mode;wire debug_audio_uart;\n    hdmi_debug_uart u_debug_uart(.clk(CLOCK_50),.resetn(RESET_n),.info(debug_info),.mode(debug_mode),.tx(UART_TX));\n    wire scope_clk;',1).replace('.UART_TX    (UART_TX)', '.UART_TX    (debug_audio_uart)',1).replace('    hdmi_ui3_top u_hdmi (','    hdmi_ui3_top u_hdmi (.DEBUG_MODE(debug_mode),.DEBUG(debug_info),',1);q.write_text(s)
q=W/'build_full.tcl';q.write_text(q.read_text().replace('run all','add_file diagnostics/hdmi_link/full_debug_uart.v\nrun all'))
inputs={str(p.relative_to(W)):sha(p) for p in W.rglob('*') if p.is_file()}
(W/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
env=os.environ.copy();env['QT_QPA_PLATFORM']='offscreen';env['XDG_CACHE_HOME']=str(W/'cache')
with (W/'build.log').open('w') as f:p=subprocess.run(['/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh','build_full.tcl'],cwd=W,env=env,stdout=f,stderr=subprocess.STDOUT)
d={'exit_code':p.returncode,'time':time.time(),'base_manifest':m,'inputs':inputs,'diagnostic_only':True,'half_rate':a.half_rate,'mode_sequence':'UI, solid blue using UI timing, independent colorbars, UI; 1.342 seconds per mode'}
if p.returncode==0:
 h=(W/'impl/pnr/piano64_full_tr_content.html').read_text();d['violations']={k.lower():int(re.search('Numbers of '+k+r' Violated Endpoints</td>\s*<td>(\d+)</td>',h)[1]) for k in ['Setup','Hold']};d['fs_sha256']=sha(W/'impl/pnr/piano64_full.fs')
assert all(sha(W/p)==v for p,v in inputs.items())
(W/'manifest.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps({k:v for k,v in d.items() if k not in ['inputs','base_manifest']}),flush=True)
assert d.get('violations')=={'setup':0,'hold':0},d.get('violations')
