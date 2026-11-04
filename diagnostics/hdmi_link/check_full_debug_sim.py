#!/usr/bin/env python3
"""Verify the diagnostic mux at actual production serial pins, before loading."""
from pathlib import Path
import argparse,hashlib,json,subprocess
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('--half-rate',action='store_true');ap.add_argument('--uart-only',action='store_true');a=ap.parse_args()
W=R/'work/hdmi_black'/('full_debug30' if a.half_rate else 'full_debug');O=R/'work/hdmi_black'/('debug_serial30' if a.half_rate else 'debug_serial');O.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
inputs=json.loads((W/'inputs.json').read_text());assert all(sha(W/p)==h for p,h in inputs.items())
models=[R/'work/hdmi_production_link/vendor.v',R/'work/video_primitives/dpb.v'];results=[]
for mode in ([] if a.uart_only else [1,2]):
 wrapper=O/('wrapper'+str(mode)+'.v')
 # Replace only the parameter literal, preserving the DEBUG_MODE port name.
 s="""module hdmi_link_probe #(parameter WINDOW=5000)(input CLOCK_50,input RESET_n,output UART_TX,output tmds_clk_n_0,tmds_clk_p_0,output[2:0]tmds_d_n_0,tmds_d_p_0);
assign UART_TX=1'b1;
hdmi_ui3_top ui(.DEBUG_MODE(2'd__MODE__),.DEBUG(),.CLK_SCOPE(CLOCK_50),.clk(CLOCK_50),.resetn(RESET_n),.BANDS(256'd0),.BANDS_TICK(1'b0),.UI_INFO(19'd0),.SONG_UI(384'd0),.SONG_ROLL(1024'd0),.SONG_UI_TOGGLE(1'b0),.COMP_AMP(512'd0),.SCOPE_SMP(16'sd0),.SCOPE_TOG(1'b0),.SCOPE_TRG(1'b0),.tmds_clk_n_0(tmds_clk_n_0),.tmds_clk_p_0(tmds_clk_p_0),.tmds_d_n_0(tmds_d_n_0),.tmds_d_p_0(tmds_d_p_0));
wire pixel=ui.clk_p,serial_clk=ui.clk_p5,video_reset=ui.dbg_reset,lock=ui.pll_lock;
wire[11:0] x=ui.dbg_x,y=ui.dbg_y;wire[7:0]video_por=ui.dbg_por;wire de=ui.dbg_de;wire[23:0]rgb=ui.dbg_rgb;
endmodule
""";wrapper.write_text(s.replace('__MODE__',str(mode)))
 tb=O/('tb'+str(mode)+'.v');s=(D/'tb_link.v').read_text().replace('dut.video.','dut.ui.u_dvi.').replace('#1000000;','#3000000;')
 if mode==1:s=s.replace('palette(visible)',"24'h40a0ff")
 tb.write_text(s)
 files=[tb,wrapper,*[W/p for p in ['src/hdmi/hdmi_ui3_top.v','src/hdmi/ui/ui_liss_ram.v','src/hdmi/ui/ui_scope_points.v','src/hdmi/ir4/gowin_pll_720p.v','src/hdmi/ir4/dvi_tx_top.v','src/hdmi/ir4/dvi_tx_tmds_enc.v','src/hdmi/ir4/dvi_tx_tmds_phy.v','src/hdmi/ir4/dvi_tx_clk_drv.v']],*models]
 exe=O/('mode'+str(mode)+'.vvp');p=subprocess.run(['iverilog','-g2012','-DUI_VENDOR_RAM_SIM','-DPROBE_1080_SINGLE',*(['-DPROBE_1080_FAST'] if not a.half_rate else []),'-s','tb_link','-s','GSR','-o',str(exe),*[str(p) for p in files]],cwd=W,capture_output=True,text=True)
 (O/('mode'+str(mode)+'.compile.log')).write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout+p.stderr
 with (O/('mode'+str(mode)+'.log')).open('w') as f:p=subprocess.run(['vvp',str(exe)],cwd=W,stdout=f,stderr=subprocess.STDOUT)
 log=(O/('mode'+str(mode)+'.log')).read_text();print(mode,log,flush=True);assert p.returncode==0 and 'PASS independent serial' in log
 results.append({'mode':mode,'pass':True,'sources':{str(p):sha(p) for p in files}})
assert all(sha(W/p)==h for p,h in inputs.items())
if not a.uart_only:(O/'results.json').write_text(json.dumps({'results':results,'frozen_inputs_sha256':sha(W/'inputs.json')},indent=2)+'\n')

# Keep the diagnostic UART independently reproducible as well.
uart_files=[R/'sim/tb_hdmi_debug_uart.v',W/'diagnostics/hdmi_link/full_debug_uart.v',W/'src/sd/uart_tx.v']
exe=R/'work/hdmi_black/debug_uart.vvp';log=R/'work/hdmi_black/debug_uart.log'
p=subprocess.run(['iverilog','-g2012','-s','tb_hdmi_debug_uart','-o',str(exe),*[str(p) for p in uart_files]],cwd=R,capture_output=True,text=True);assert p.returncode==0,p.stdout+p.stderr
with log.open('w') as f:p=subprocess.run(['vvp',str(exe)],cwd=R,stdout=f,stderr=subprocess.STDOUT)
assert p.returncode==0 and 'PASS diagnostic UART' in log.read_text(),log.read_text()
names=['sim/tb_hdmi_debug_uart.v','diagnostics/hdmi_link/full_debug_uart.v','src/sd/uart_tx.v']
uart_sources={name:sha(p) for name,p in zip(names,uart_files)}
assert all(sha(R/name)==h for name,h in uart_sources.items())
(R/'work/hdmi_black/debug_uart.json').write_text(json.dumps({'pass':True,'sources':uart_sources,'log_sha256':sha(log),'limits':'Constant 96-bit status through actual UART pins at 115200 8N1; full diagnostic multi-bit CDC remains approximate.'},indent=2)+'\n')
print(log.read_text(),flush=True)
