//==========================================================================
//  tb_phase_bend —— 验证「弯音乘在相位增量上」的算法
//
//  背景：引擎里的 Φ(v_pf) 是【已经回绕到一圈内的相位】（圈长 2^19 = 524288）。
//        旧算法 (Φ × r) mod 2^19 得到 frac(r·frac(f·t))，周期仍是 1/f，
//        音高不变、只有波形折返失真（实测：唢呐音高不动 + 变噪）。
//        新算法对相位【增量】缩放后累加，频率才真正变成 r·f。
//
//  这里把 add_engine_harm 里 pp==0 分支的算术原样搬成整数版：
//      dphi    = v_phl - v_php        (19 位，模 2^19 的差)
//      dphi_s  = dphi[15:0]           (16 位有符号小量)
//      dphi_s2 = (dphi_s * ratio + 8192) >>> 14
//      v_pf   += dphi_s2[18:0]
//  数 v_pf 的回绕次数得到实际频率，与期望 r·f 比对；同时算一遍旧算法作对照。
//==========================================================================
`timescale 1ns/1ps

module tb_phase_bend;

localparam integer FS   = 48828;      // 采样率
localparam integer TURN = 524288;     // 一圈 = 2^19

integer errs = 0;
real    expect_r, got_new_r, got_old_r;

task automatic case_run(input integer fin_hz,
                        input integer ratq14,
                        input integer nsamp);
    integer i, inc, di, dr, ds;
    integer acc_new, acc_new_d, acc_old, acc_old_d;
    integer w_new, w_old, phi19, php19;
    begin
        phi19     = 0;
        php19     = 0;
        acc_new   = 0;
        acc_new_d = 0;
        acc_old   = 0;
        acc_old_d = 0;
        w_new     = 0;
        w_old     = 0;
        inc       = (fin_hz * TURN) / FS;

        for (i = 0; i < nsamp; i = i + 1) begin
            phi19 = (phi19 + inc) % TURN;

            // ---- 新算法：相位增量缩放后累加 ----
            di = phi19 - php19;
            if (di < 0) di = di + TURN;               // 模 2^19 的差
            if (di >= TURN/2) di = di - TURN;         // 解成有符号小量
            dr = di * ratq14;
            if (dr >= 0) ds =  (dr + 8192) / 16384;
            else         ds = -(((-dr) + 8192) / 16384);
            acc_new = ((acc_new + ds) % TURN + TURN) % TURN;
            php19   = phi19;
            if (acc_new < acc_new_d) w_new = w_new + 1;
            acc_new_d = acc_new;

            // ---- 旧算法：缩放已回绕的相位（对照） ----
            acc_old = ((phi19 * ratq14) >> 14) % TURN;
            if (acc_old < acc_old_d) w_old = w_old + 1;
            acc_old_d = acc_old;
        end

        expect_r  = fin_hz * (ratq14 / 16384.0);
        got_new_r = w_new * 1.0 * FS / nsamp;
        got_old_r = w_old * 1.0 * FS / nsamp;
        $display("  fin=%6.0f  ratio=%6.4f (%+5.0f cent) -> expect %8.2f | new %8.2f | old %8.2f",
                 fin_hz * 1.0, ratq14/16384.0,
                 1200.0 * $ln(ratq14/16384.0) / $ln(2.0),
                 expect_r, got_new_r, got_old_r);
        if (got_new_r > expect_r*1.02 || got_new_r < expect_r*0.98) begin
            $display("      FAIL: 新算法频率不对");
            errs = errs + 1;
        end
    end
endtask

initial begin
    $display("=== 相位弯音算法验证（fs=%0d，一圈=%0d）===", FS, TURN);
    case_run( 440, 16384, 40000);    // 不弯
    case_run( 440, 24602, 40000);    // +702 音分（纯五度）
    case_run( 440, 10902, 40000);    // -700 音分
    case_run( 220, 18996, 40000);    // +256 音分
    case_run( 880, 28526, 40000);    // +960 音分
    case_run( 880,  9411, 40000);    // -960 音分
    case_run(1760, 16384, 40000);    // 高音不弯（增量最大 18900）
    $display("==== %0d FAIL ====", errs);
    $finish;
end

endmodule
