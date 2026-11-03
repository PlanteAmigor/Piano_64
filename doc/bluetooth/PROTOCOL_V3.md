# BT36 曲谱协议 v3（App 与 FPGA 共用）

本工程基于 piano64_3_20261101。默认 50 MHz、115200 baud、8N1；BT36 TX 接 AB20，BT36 RX 接 AA21，U15 保留调试输出。修改波特率须同时修改模块配置与 RTL 参数。

帧：`A5 5A 03 type:u8 seq:u8 payload_len:LE16 payload CRC:LE16`。
CRC16-CCITT-FALSE：初值 FFFF，多项式 1021，覆盖帧头至 payload。一次最多 258 字节 payload。BLE 分片最多 20 字节；每帧必须等 FPGA ACK 后再发下一帧。版本 2 不兼容。

| type | payload | 语义 |
|---|---|---|
| 01 BEGIN | count:LE16, duration_ms:LE32, timbre:u8, flags:u8 | 停止播放，使旧曲谱失效，开始新上传；flags bit0 允许超声部丢音，其余须为 0 |
| 02 DATA | offset:LE16, 1–32 个 8 字节 event | 连续偏移写入；必须与上次已确认数量相等 |
| 03 END | count:LE16 | 数量完整且事件验证通过后，曲谱才变为可播放；不自动播放 |
| 10 PLAY | 空 | 从头播放已提交曲谱；要求音色参数已就绪且不在板端测试模式 |
| 11 STOP | 空 | 停止并归零、释放所有自动播放 gate |
| 12 QUERY | 空 | 查询能力和曲谱状态 |
| 80 ACK | 见下方 | 与请求相同 seq；请求的 type 放在 payload[0] |

event：`start_ms:LE32, note:u8, duration_ms:LE16, velocity:u8`。按 start_ms 非递减排列，duration 为 1–65535 ms，velocity 为 1–127；结束时间不得超过 BEGIN.duration_ms。最多 8192 个事件，总时长不超过 86400000 ms。独立 64 KiB BSRAM 曲谱 RAM，不改变 DDR 音色区地址。

ACK payload 共 14 字节：

`request_type:u8 status:u8 accepted_count:LE16 flags:u8 timbre:u8 voices:u8 note_lo:u8 note_hi:u8 max_events:LE16 position_ms:LE24`

position_ms 仅用于界面显示，超过 0xFFFFFF 饱和；调度器内部仍为 32 位时间。flags bit0=音源已就绪，bit1=曲谱已提交，bit2=正在播放，bit3=上传中，bit4=本次播放发生超声部丢音。

status：0 成功；1 CRC；2 长度；3 状态/数量；4 容量；5 音高/时长/排序/力度范围；6 音源未就绪；7 偏移错误；8 帧内超时；9 超声部且未允许丢音；10 版本；11 不支持的命令。

音色 0 钢琴 MIDI21–108/8声部，1 古筝38–86/8声部，2 唢呐69–96/1声部，3 笛子67–91/1声部。整曲统一音色，不传递 MIDI Program Change。默认禁止超声部；允许时丢弃超额的新音，保留已在演奏的音符，不抢占。

安全约定：帧 CRC 校验后才处理数据；任何 DATA 内容错误使本轮上传失效，必须重新 BEGIN。BEGIN 采用单缓冲，旧曲谱随即失效。重复的上一条成功请求（type、seq、CRC 都相同）只重发 ACK，不重复执行。App 每帧最多重试一次；仍无 ACK 则断开并要求重新上传。帧内最大字节间隔 2 秒，应用 ACK 超时 5 秒。蓝牙断开本身无专用硬件状态线，板端已启动的曲谱继续播放，可重连 QUERY/STOP。
