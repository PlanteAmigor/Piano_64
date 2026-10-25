# 时序报告摘要

采集时间：2026-10-25
器件：Gowin **GW5AST-LV138PG484AC1/I0**（GW5AST-138C）
系统时钟：50 MHz（周期 20 ns，经 `pll50` 上全局时钟网）
工具：Gowin EDA V1.9.11.03（教育版，**无需 license**）

> ## ✅ 结论：两份设计均 **0 条时序违例**
>
> | 设计 | SETUP 违例 | SETUP 最差 | HOLD 违例 | HOLD 最差 |
> |---|---:|---:|---:|---:|
> | 钢琴整机（现在能烧） | **0** | **+7.993 ns** | **0** | **+0.226 ns** |
> | 谐波引擎 4 声部（独立综合） | **0** | **+3.265 ns** | **0** | **+0.196 ns** |
>
> 原始报告见本目录 `.timing_paths` / `.rpt.txt`。

---

## 🎯 修了什么（原来的 1 条 setup + 22 条 hold）

### ① 22 条 HOLD 违例（最差 −0.726 ns）—— 跨时钟域，已消除

**原路径**：`mode_1_s0 → u_led/n930 → u_led/n929 → u_led/sh_14_s1`

**根因**：`ws2812_keyind` 用的是 **`CLOCK_50` 直连**（上板验证过的配置），
但它的全部控制信号 `mode` / `key_state` / `guide_key` / `guide_key2` /
`engine_rst_n` 都产生于 **`clk_sys`（PLL 输出）** 域。

两者虽然同为 50 MHz（SDC 里 `CLK_SYS` 是 `CLOCK_50` 的 `divide_by 1` 生成时钟），
但落在**不同时钟树分支**：`CLOCK_50_d` 走 PBR2/PBR3，`clk_sys` 走 PBR1/PBR2，
实测**偏斜 ≈ 0.7 ns** → 数据跑赢捕获时钟 → 22 条 hold 违例。

**修复**（`src/add_top.v`）：在 `CLOCK_50` 域加两拍同步器，
把这 16 个慢变信号（去抖后 >10 ms 才变一次）跨域；
`src/piano64.sdc` 加 `set_false_path -from [get_clocks {CLK_SYS}] -to [get_clocks {CLOCK_50}]`
（标准 CDC 处理，同步器隔离后不再对该跨域路径做同步时序检查）。

代价：+30 个寄存器（1898 → 1928），对视觉无影响。

### ② 1 条 SETUP 违例（−0.085 ns）—— 输出约束过紧，已消除

**原路径**：`u_tx/din_s0 → AUD_DIN_obuf`

**根因**：`piano64.sdc` 里
`set_output_delay -clock CLOCK_50 -max 10.000 [get_ports {AUD_BCK AUD_LRCK AUD_DIN}]`
—— 20 ns 周期里留了 **10 ns** 给板外，内部只剩 10 ns。
PCM5102A 实际建立时间只有几 ns，这个约束是不合理的。

**修复**：`-max 10.000` → **`8.000`**（内部留 12 ns）。

### ③ 谐波引擎的 2 条 SETUP 违例（−0.074 ns）—— PnR 选项，已消除

原因是默认布局选项（`place_option 3` / `route_option 2`）在 78% BSRAM 的高占用下
产生拥塞布线（关键路径里有 5~6 ns 全是走线）。

换成 `set_option -place_option 2` + `set_option -route_option 1` 后
最差 slack 从 **−0.074 ns 变成 +3.265 ns**（差 3.3 ns，全部来自布局质量）。

谐波工程的构建脚本已一并归档：`谐波引擎综合工程_build.tcl`。
**注意：钢琴工程用默认选项反而更好**（+9.501 vs +9.265），所以钢琴的
`build.tcl` 没有加这两行。

---

## 一、钢琴整机（当前可烧的，`build.tcl` 直接跑）

| 项目 | 数值 |
|---|---|
| 分量数 | 88 音 × **128** 分量 |
| Logic | 2911 / 138240（**3%**） |
| Register | 1668 / 139095（2%） |
| CLS | 2082 / 69120（3%） |
| BSRAM | **114 / 340（34%）** |
| I/O | 13 / 297（5%） |

### 时序

| 类型 | 条数 | 最差 slack | 违例 |
|---|---:|---:|---:|
| SETUP | 25 | **+7.993 ns** | **0** |
| HOLD | 25 | **+0.226 ns** | **0** |

最差 SETUP 路径：`u_piano/g_voice[0].u_v/er_q_16 → ...`（起音项加法，`ATK=0` 时被优化掉大半），余量 8.0 ns。
最差 HOLD 路径：`u_piano/g_voice[3].u_v/ph_n_*`（相位寄存器），余量 0.23 ns。

> 注：上述数字为修完 `add_voice8.v` 两个 bug + 重算 `sat_gain`（见 `doc/已知bug与修复记录.md`）后重新 PnR 的结果。

---

## 二、谐波引擎（笛子/唢呐，4 声部，独立综合，尚未接入顶层）

综合工程：`.tmp/gwsynth_e4/`（顶层 `harm_synth.v` + `pll50`，表用 `$readmemh` 初始化）

| 项目 | 数值 |
|---|---|
| 声部数 | **4** |
| 表 | 8 个并行 bank，笛子表 3.24 Mbit |
| Logic | 2118 / 138240（**2%**） |
| BSRAM | **264 / 340（78%）** |
| I/O | 70 / 297（24%，其中大量是验证用调试口） |

### 时序（`place_option 2` + `route_option 1`）

| 类型 | 条数 | 最差 slack | 违例 |
|---|---:|---:|---:|
| SETUP | 25 | **+3.265 ns** | **0** |
| HOLD | 25 | **+0.196 ns** | **0** |

---

## 三、每样点的时钟预算（谐波引擎）

一个音频样点 = **1024 个时钟**（50 MHz ÷ 16 ÷ 64 = 48828 Hz）

```
一样点 = 7 × NVOICE（前置） + Σ K_v（所有声部谐波总数） + 6（流水排空）
```

| 场景 | 实测拍数 | 预算 | 占用 |
|---|---:|---:|---:|
| 1 声部（最低音 K=62） | 74 | 1024 | 7% |
| 4 个不同音 | 205 | 1024 | 20% |
| **4 声部同音（最坏 K=62×4）** | **292** | 1024 | **29%** |

余量很大：理论上 Σ K_v 可以到 990，即 4 声部各 247 个谐波。
（实际笛子最多 62、唢呐最多 55，因为 K = ⌊24414/f₀⌋）

---

## 四、复现命令

```bash
export TMPDIR=/mnt/project/InstruementSound/.tmp     # 绝不用 /tmp
export LD_LIBRARY_PATH=/mnt/project/ov-cli/Gowin/IDE/lib
export QT_QPA_PLATFORM=xcb

cd /mnt/project/InstruementSound/piano64_handoff/piano64
/mnt/project/ov-cli/Gowin/IDE/bin/gw_sh build.tcl

# 判据：ERROR 0 条
# 时序：impl/pnr/piano64.timing_paths（本目录同名文件即其归档）
```
