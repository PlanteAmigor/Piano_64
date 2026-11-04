#!/usr/bin/env python3
"""Isolated 150/750MHz full candidate with serialized forwarded TMDS clock.

The production tree and Flash are untouched. This is an unverified physical
link hypothesis, not a claimed fix. Run after the production build finishes.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, time

R = Path(__file__).resolve().parents[2]
D = Path(__file__).resolve().parent
ap = argparse.ArgumentParser()
ap.add_argument('--prepare-only', action='store_true')
ap.add_argument('--optimize-ui', action='store_true', help='Previous parallel-mask experiment; retained for reproducibility')
ap.add_argument('--group-ui', action='store_true', help='Register palette groups in the existing stage5; preserve pixel latency')
a = ap.parse_args()
assert not (a.optimize_ui and a.group_ui)
W = R / ('work/hdmi_serial_clock60_group' if a.group_ui else ('work/hdmi_serial_clock60_opt' if a.optimize_ui else 'work/hdmi_serial_clock60'))
assert not W.exists(), W
subprocess.run(['python3', 'tools/check_build.py'], cwd=R, check=True)
m = json.loads((R / 'impl/pnr/piano64_full.manifest.json').read_text())
assert m['video_mode'] == '1080p30.303'
W.mkdir(parents=True)

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def run(name, args):
    with (W / (name + '.log')).open('w') as log:
        p = subprocess.run(args, cwd=W, stdout=log, stderr=subprocess.STDOUT)
    assert p.returncode == 0, (name, p.returncode)
    return {'name': name, 'command': args, 'exit_code': p.returncode}

for name, h in m['inputs'].items():
    assert sha(R / name) == h, name
    q = W / name
    q.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(R / name, q)
p = W / 'src/hdmi/ui_video_mode.vh'
assert '`define UI_VIDEO_1080P_HALF' in p.read_text()
p.write_text(p.read_text().replace('`define UI_VIDEO_1080P_HALF', '// 150MHz isolated serial-clock candidate'))
p = W / 'src/piano64_hdmi.sdc'
s = p.read_text()
for multiplier, output in [(3, 0), (15, 1)]:
    old = f'-multiply_by {multiplier} -divide_by 2 [get_pins {{u_hdmi/u_pll/u_pixel/PLL_inst/CLKOUT{output}}}]'
    assert old in s, old
    s = s.replace(old, old.replace('-divide_by 2', '-divide_by 1'))
p.write_text(s)
p = W / 'src/hdmi/ir4/dvi_tx_top.v'
s = p.read_text()
old = 'dvi_tx_clk_drv clock_phy(\n\t\t\n\t\t.pixel_clock\t(pixel_clock),'
assert old in s
p.write_text(s.replace(old, old + '\n        .ddr_bit_clock(ddr_bit_clock),'))
# Reuse the identical production serializer primitive/reset strategy on lane 4.
# LSB first: five high bits then five low bits, one forwarded clock per pixel.
(W / 'src/hdmi/ir4/dvi_tx_clk_drv.v').write_text('''module dvi_tx_clk_drv(
    input pixel_clock, input ddr_bit_clock, output [1:0] tmds_clk
);
    dvi_tx_tmds_phy serialized_clock(
        .pixel_clock(pixel_clock), .ddr_bit_clock(ddr_bit_clock),
        .reset(1'b0), .data(10'b0000011111), .tmds_lane(tmds_clk));
endmodule
''')
if a.optimize_ui or a.group_ui:
    p = W / 'src/hdmi/hdmi_ui3_top.v'
    s = p.read_text()
    old = '    wire lane_in0=px>=768 && px<1792 && py>=256 && py<880 && px[6:0]>=16 && px[6:0]<112;'
    assert old in s
    s = s.replace(old, '''    // Compute this vertical window alongside py; lane_in0 keeps its pixel stage.
    reg roll_y_valid0 /* synthesis syn_preserve=1 */;
    always @(posedge clk_p)roll_y_valid0<=logical_y>=256 && logical_y<880;
    wire lane_in0=px>=768 && px<1792 && roll_y_valid0 && px[6:0]>=16 && px[6:0]<112;''')
    old = '''    always @(*)begin
        rgb=background3;
        if(spectrum5)rgb=spectrum_high5?24'h7DE1DA:24'h3DABB7;
        if(component5)rgb=24'h718FD0;
        if(liss5)rgb=liss_color5;
        if(note_auto5)rgb=24'h354957;
        if(note_lead5)rgb=note_color5;
        if(note_hit5)rgb=24'h75E6BC;
        if(note_edge5)rgb=24'hD5F5EE;
        if(judgment5)rgb=24'hF6C77E;
        if(text5)rgb=text_color5;
    end'''
    assert old in s
    if a.optimize_ui:
        s = s.replace(old, '''    // Highest layer wins, as before, using parallel masks instead of a mux chain.
    wire [8:0] overlay_flags5={text5,judgment5,note_edge5,note_hit5,note_lead5,note_auto5,liss5,component5,spectrum5};
    reg [8:0] overlay_pick5;
    always @(*)begin
        for(integer layer=0;layer<9;layer=layer+1)
            overlay_pick5[layer]=overlay_flags5[layer] && !(|(overlay_flags5>>(layer+1)));
        rgb=(background3 & {24{!(|overlay_flags5)}}) |
            ((spectrum_high5?24'h7DE1DA:24'h3DABB7) & {24{overlay_pick5[0]}}) |
            (24'h718FD0 & {24{overlay_pick5[1]}}) |
            (liss_color5 & {24{overlay_pick5[2]}}) |
            (24'h354957 & {24{overlay_pick5[3]}}) |
            (note_color5 & {24{overlay_pick5[4]}}) |
            (24'h75E6BC & {24{overlay_pick5[5]}}) |
            (24'hD5F5EE & {24{overlay_pick5[6]}}) |
            (24'hF6C77E & {24{overlay_pick5[7]}}) |
            (text_color5 & {24{overlay_pick5[8]}});
    end''')
        old = '    reg [23:0] rgb_base,rgb_faded,rgb_direct,rgb_r;'
        assert old in s
        s = s.replace(old, '    reg [23:0] rgb_base /* synthesis syn_preserve=1 */;\n    reg [23:0] rgb_faded,rgb_direct,rgb_r;')
    else:
        s = s.replace(old, '''    // Stage5 resolves two palette groups from stage4 instead of forwarding
    // every flag/color into one long stage6 priority chain. Total pixel latency
    // remains identical; stage6 selects only high/low/background.
    reg [24:0] overlay_hi5 /* synthesis syn_preserve=1 */;
    reg [24:0] overlay_lo5 /* synthesis syn_preserve=1 */;
    always @(posedge clk_p)begin
        overlay_hi5<={text4 || judgment4 || note_edge4 || note_hit4,
            text4?text_color4:judgment4?24'hF6C77E:note_edge4?24'hD5F5EE:24'h75E6BC};
        overlay_lo5<={note_lead4 || note_auto4 || liss4 || component4 || spectrum4,
            note_lead4?note_color4:note_auto4?24'h354957:liss4?liss_color4:
            component4?24'h718FD0:(spectrum_high4?24'h7DE1DA:24'h3DABB7)};
    end
    always @(*)begin
        rgb=overlay_hi5[24]?overlay_hi5[23:0]:
            overlay_lo5[24]?overlay_lo5[23:0]:background3;
    end''')
    p.write_text(s)
# Freeze the same benches and original vendor models used by production checks.
for name in ['probe.v', 'tb_link.v']:
    shutil.copy2(D / name, W / name)
shutil.copy2(R / 'sim/tb_ui_serial_boot.v', W / 'tb_ui_serial_boot.v')
(W / 'production_clocks.v').write_text('''module probe_clocks(input clkin,
output pixel,serial_clk,reference_clk,reference_lock,video_lock);
assign reference_clk=clkin;assign reference_lock=1'b1;
Gowin_PLL_720P prod(.clkin(clkin),.clkout0(pixel),.clkout1(serial_clk),.lock(video_lock));
endmodule
''')
lib = Path('/mnt/project/ov-cli/Gowin/IDE/simlib/gw5a/prim_sim.v')
s = lib.read_text()
models = []
for name in ['PLL', 'OSER10', 'CLKDIV', 'ELVDS_OBUF', 'DPB']:
    match = re.search(r'^module ' + name + r'\s*\(.*?^endmodule[^\n]*', s, re.M | re.S)
    assert match, name
    models.append(match[0])
(W / 'vendor.v').write_text('`timescale 1ns/1fs\n' + '\n'.join(models) + '\nmodule GSR;reg GSRO=0;initial #500 GSRO=1;endmodule\n')
for name, clock_pin, sample in [('tb_link.v', 'cp', 's0={dp[0],s0[9:1]};'),
                              ('tb_ui_serial_boot.v', 'dut.tmds_clk_p_0', 's0={dut.tmds_d_p_0[0],s0[9:1]};')]:
    p = W / name
    s = p.read_text().replace(' reg clk=', ' reg [9:0] clock_word=0;\n reg clk=', 1)
    assert sample in s
    s = s.replace(sample, 'clock_word={' + clock_pin + ',clock_word[9:1]};' + sample, 1)
    match = re.search(r'if\(bits==10\)begin', s)
    assert match
    s = s[:match.end()] + '\n     if(clock_word!==10\'b0000011111)$fatal(1,"forwarded clock/data word phase mismatch %b",clock_word);' + s[match.end():]
    p.write_text(s)
inputs = {str(p.relative_to(W)): sha(p) for p in W.rglob('*') if p.is_file()}
(W / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
common = ['src/hdmi/ir4/' + name for name in ['gowin_pll_720p.v', 'dvi_tx_top.v', 'dvi_tx_tmds_enc.v', 'dvi_tx_tmds_phy.v', 'dvi_tx_clk_drv.v']] + ['vendor.v']
checks = []
checks.append(run('link_compile', ['iverilog', '-g2012', '-DPROBE_1080_SINGLE', '-DPROBE_1080_FAST', '-s', 'tb_link', '-s', 'GSR', '-o', 'link.vvp', 'tb_link.v', 'probe.v', 'production_clocks.v', 'src/sd/uart_tx.v'] + common))
checks.append(run('link', ['vvp', 'link.vvp']))
checks.append(run('boot_compile', ['iverilog', '-g2012', '-DUI_VENDOR_RAM_SIM', '-s', 'tb_ui_serial_boot', '-s', 'GSR', '-o', 'boot.vvp', 'tb_ui_serial_boot.v', 'src/hdmi/hdmi_ui3_top.v', 'src/hdmi/ui/ui_liss_ram.v', 'src/hdmi/ui/ui_scope_points.v'] + common))
checks.append(run('boot', ['vvp', 'boot.vvp']))
assert 'PASS independent serial' in (W / 'link.log').read_text()
assert 'PASS complete UI serial' in (W / 'boot.log').read_text()
assert all(sha(W / p) == h for p, h in inputs.items())
d = {'base_manifest': m, 'inputs': inputs, 'checks': checks, 'vendor_sha256': sha(lib), 'experimental': True, 'physical_result': 'not tested', 'video_mode': '1080p60.606'}
(W / 'prepared.json').write_text(json.dumps(d, indent=2) + '\n')
print('PASS isolated clock/data phase, RGB/sync, natural UI boot and reset models', flush=True)
if a.prepare_only:
    raise SystemExit(0)
assert subprocess.run(['pgrep', '-x', 'gw_sh'], stdout=subprocess.DEVNULL).returncode != 0
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
os.environ['XDG_CACHE_HOME'] = str(W / 'cache')
checks.append(run('build', ['/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh', 'build_full.tcl']))
syn = (W / 'impl/gwsynthesis/piano64_full_syn.rpt.html').read_text()
clocks = {}
for row in re.findall(r'<tr[^>]*>(.*?)</tr>', syn, re.S):
    cells = [re.sub(r'<[^>]+>', '', c).strip() for c in re.findall(r'<td[^>]*>(.*?)</td>', row, re.S)]
    if len(cells) >= 10 and cells[2] == 'Generated':
        clocks[cells[1]] = float(cells[4])
for leaf, mhz in [('CLKOUT0', 150), ('CLKOUT1', 750)]:
    assert clocks.get('u_hdmi/u_pll/u_pixel/PLL_inst/' + leaf + '.default_gen_clk') == mhz
html = (W / 'impl/pnr/piano64_full_tr_content.html').read_text()
d['violations'] = {k.lower(): int(re.search('Numbers of ' + k + r' Violated Endpoints</td>\s*<td>(\d+)</td>', html)[1]) for k in ['Setup', 'Hold']}
d['fs_sha256'] = sha(W / 'impl/pnr/piano64_full.fs')
d['pll_clocks_mhz'] = clocks
d['time'] = time.time()
assert all(sha(W / p) == h for p, h in inputs.items())
(W / 'manifest.json').write_text(json.dumps(d, indent=2) + '\n')
print(json.dumps({k: v for k, v in d.items() if k not in ['base_manifest', 'inputs', 'checks']}, indent=2), flush=True)
assert d['violations'] == {'setup': 0, 'hold': 0}
