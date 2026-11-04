#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,time
R=Path(__file__).resolve().parents[2];D=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('--variants',nargs='+',default=['control720','cascade_old','cascade_ref','div5_ref']);a=ap.parse_args()
variants={'control720':['PROBE_720P'],'cascade_old':['PROBE_OLD_REF'],'cascade_ref':[],'div5_ref':['PROBE_DIV5']}
for name in a.variants:
 defs=variants[name];w=R/'work/hdmi_link'/name;assert not w.exists(),w;w.mkdir(parents=True)
 for f in ['probe.v','clocks.v']:(w/f).write_text(''.join('`define '+x+'\n' for x in defs)+(D/f).read_text())
 for f in ['dvi_tx_top.v','dvi_tx_tmds_enc.v','dvi_tx_tmds_phy.v','dvi_tx_clk_drv.v','tmds_encode.mem']:
  p=w/'src/hdmi/ir4'/f;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(R/'src/hdmi/ir4'/f,p)
 (w/'src/hdmi/ui_video_mode.vh').write_text('`define UI_VIDEO_720P\n' if name=='control720' else '// 1080p probe\n')
 # Link diagnostic relies on configuration GSR for the I/O serializer.
 # Its PCLK encoder/counters remain reset until both PLLs are stable.
 phy=w/'src/hdmi/ir4/dvi_tx_tmds_phy.v'
 source=phy.read_text();assert '.RESET(reset_reg)' in source
 phy.write_text(source.replace('.RESET(reset_reg)',".RESET(1'b0) // Diagnostic only: configuration GSR initializes serializer"))
 shutil.copy2(R/'src/sd/uart_tx.v',w/'uart_tx.v')
 cst='IO_LOC "CLOCK_50" V22;\nIO_PORT "CLOCK_50" IO_TYPE=LVCMOS33 PULL_MODE=NONE;\nIO_LOC "RESET_n" AB13;\nIO_PORT "RESET_n" IO_TYPE=LVCMOS33 PULL_MODE=UP;\nIO_LOC "UART_TX" U15;\nIO_PORT "UART_TX" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8;\n'
 for p,balls in [('tmds_d_p_0[0]','J14,H14'),('tmds_d_p_0[1]','J15,H15'),('tmds_d_p_0[2]','K17,J17'),('tmds_clk_p_0','G15,G16')]:
  cst+=f'IO_LOC "{p}" {balls};\nIO_PORT "{p}" IO_TYPE=LVCMOS33D PULL_MODE=NONE DRIVE=8;\n'
 (w/'probe.cst').write_text(cst)
 sdc='create_clock -name CLOCK_50 -period 20 [get_ports {CLOCK_50}]\nset_false_path -from [get_ports {RESET_n}]\n'
 if name=='control720':
  sdc+='create_generated_clock -name pix -source [get_ports {CLOCK_50}] -multiply_by 3 -divide_by 2 [get_pins {clocks/video/PLL_inst/CLKOUT0}]\ncreate_generated_clock -name ser -source [get_ports {CLOCK_50}] -multiply_by 15 -divide_by 2 [get_pins {clocks/video/PLL_inst/CLKOUT1}]\n'
 else:
  sdc+='create_generated_clock -name ref -source [get_ports {CLOCK_50}] -multiply_by 11 -divide_by 20 [get_pins {clocks/reference/PLL_inst/CLKOUT0}]\ncreate_generated_clock -name ser -source [get_pins {clocks/reference/PLL_inst/CLKOUT0}] -multiply_by 27 [get_pins {clocks/video/PLL_inst/CLKOUT1}]\n'
  if name=='div5_ref':sdc+='create_generated_clock -name pix -source [get_pins {clocks/video/PLL_inst/CLKOUT1}] -divide_by 5 [get_pins {clocks/divide_pixel/CLKOUT}]\n'
  else:sdc+='create_generated_clock -name pix -source [get_pins {clocks/reference/PLL_inst/CLKOUT0}] -multiply_by 27 -divide_by 5 [get_pins {clocks/video/PLL_inst/CLKOUT0}]\n'
 sdc+='set_false_path -from [get_clocks {pix ser'+('' if name=='control720' else ' ref')+'}] -to [get_clocks {CLOCK_50}]\n'
 (w/'probe.sdc').write_text(sdc)
 files=['probe.v','clocks.v','uart_tx.v','probe.cst','probe.sdc']+[str(p.relative_to(w)) for p in sorted((w/'src').rglob('*.v'))]
 tcl='set_device GW5AST-LV138PG484AC1/I0 -name GW5AST-138 -device_version C\n'+''.join('add_file '+p+'\n' for p in files)+'set_option -top_module hdmi_link_probe\nset_option -output_base_name hdmi_probe\nset_option -verilog_std sysv2017\n'
 tcl+='set_option -place_option 3\nset_option -route_option 2\nset_option -replicate_resources 1\nrun all\n';(w/'build.tcl').write_text(tcl)
 inputs={str(p.relative_to(w)):hashlib.sha256(p.read_bytes()).hexdigest() for p in w.rglob('*') if p.is_file()}
 env=os.environ.copy();env['QT_QPA_PLATFORM']='offscreen';env['XDG_CACHE_HOME']=str(w/'cache')
 print('BUILD',name,flush=True)
 with (w/'build.log').open('w') as log:p=subprocess.run(['/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh','build.tcl'],cwd=w,env=env,stdout=log,stderr=subprocess.STDOUT)
 result={'variant':name,'defines':defs,'inputs':inputs,'exit_code':p.returncode,'time':time.time()}
 if p.returncode==0:
  html=(w/'impl/pnr/hdmi_probe_tr_content.html').read_text();v={}
  for k in ['Setup','Hold']:
   m=re.search('Numbers of '+k+r' Violated Endpoints</td>\s*<td>(\d+)</td>',html);assert m;v[k.lower()]=int(m[1])
  result['violations']=v;result['fs_sha256']=hashlib.sha256((w/'impl/pnr/hdmi_probe.fs').read_bytes()).hexdigest()
 for f,h in inputs.items():assert hashlib.sha256((w/f).read_bytes()).hexdigest()==h
 (w/'manifest.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='inputs'}),flush=True)
 assert result.get('violations')=={'setup':0,'hold':0},result
