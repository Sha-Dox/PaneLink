# PaneLink wire protocol (v1)

All integers little-endian.

## Control channel — TCP, Windows agent listens on :49500

Line-based ASCII, `\n` terminated. Mac connects, Windows answers.

### Discovery (UDP :49500)

    Mac -> broadcast  PANELINK?
    Win -> Mac        PANELINK 1 <tcpPort> <wired MAC address or -> <computer name>

### Pairing and auth

Every connection starts unauthenticated: only `PING`, `PAIR`, `PAIRCODE` and `AUTH` work,
anything else answers `NEEDPAIR`. Addresses listed in `C:\ProgramData\PaneLink\trusted.txt`
start authenticated (for scripts that can't pair).

    Mac -> Win  AUTH <token>          -> AUTH 1 | AUTH 0
    Mac -> Win  PAIR <mac name>       -> PAIRING   (6-digit code shown on every PC monitor for 5 min)
                                      -> PAIRFAIL wait   (one PAIR per 3 s)
    Mac -> Win  PAIRCODE <6 digits>   -> PAIRED <token> | PAIRFAIL wrong | PAIRFAIL expired (after 5 wrong tries)

Tokens (32 hex chars) are kept in `C:\ProgramData\PaneLink\private\paired.txt`
(SYSTEM + Administrators only); delete it to forget every Mac. The current code is also in
`private\pair-code.txt` while it is shown, for PCs without a working monitor. The token travels
in clear text on the LAN, like the rest of the control channel.

### Commands

    Mac -> Win  HELLO 1
    Win -> Mac  MONITORS <n>
    Win -> Mac  MON <idx> <x> <y> <w> <h> <hz> <primary 0|1> <device> <friendly name...>   (n lines)
    Mac -> Win  START <idx> <w> <h> <hz> <codec hevc|h264> <udpPort> [vsync 0|1] [autostop 0|1] [power bitmask: 1 quiet fans, 2 GPU clock cap]
                      [autostop mouse px] [autostop grace ms] [GPU cap MHz] [covered left top right bottom px]
    Win -> Mac  OK <idx>            | ERR <idx> <message>
    Mac -> Win  STOP <idx>
    Mac -> Win  STOPALL
    Mac -> Win  PING                -> PONG

    Win -> Mac  STOPPED <hotkey|activity>   (extending ended on the Windows side; connection stays up)

    Win -> Mac  FANS <fan hooks present 0|1> <nvidia-smi present 0|1>   (after the MON lines)

power: while any viewer that asked for it runs, the agent runs
C:\ProgramData\PaneLink\fans-quiet.cmd (bit 1) and `nvidia-smi -lgc 210,1100`
(bit 2); when the last one ends, and at agent startup/shutdown, it runs
fans-normal.cmd and `nvidia-smi -rgc`. Missing scripts = fan part off.

Viewer -> Mac heartbeat (UDP, every 20 ms): 0x12, pad[3], lastGoodFrame u32.
A Mac that has seen heartbeats treats >120 ms of silence as a dead link: it
stops sending (no stale backlog in the Wi-Fi queue) and sends a keyframe on
the first heartbeat back.

If the TCP connection drops, the agent stops every viewer (so quitting the Mac
app never leaves black fullscreen windows on Windows).

## Video channel — UDP, one viewer per monitor, viewer binds :<udpPort>

Mac sends; viewer replies to whatever address the video arrives from.

Packet header (20 bytes):

    u8  type        1 = data, 2 = parity
    u8  flags       bit0 = keyframe
    u16 index       data: packet index in frame; parity: group index
    u32 frame       frame number (monotonic, +1 per encoded frame)
    u16 count       number of data packets in the frame
    u16 group       FEC group size G (data packets per parity packet)
    u32 frameBytes  total Annex-B bytes in the frame
    u32 tsUs        sender clock, microseconds (wraps)

Payload is 1400 bytes (last data packet shorter; parity always 1400 = XOR of the
zero-padded payloads of its group). Groups are interleaved: with ng = ceil(count/group)
groups, data packet i belongs to group i % ng, so bursts spread across groups. Any
single lost packet per group is
recovered. Frames are complete HEVC/H.264 access units in Annex-B, with
parameter sets in front of every keyframe.

## Feedback — UDP, viewer -> Mac (same socket pair)

    0x10 IDR request   u8 type, u8[3] pad, u32 lastGoodFrame
    0x11 stats         u8 type, u8[3] pad, u32 echoTsUs, u32 holdUs,
                       u32 framesOk, u32 framesLost, u32 decodeUs, u32 presentUs

`echoTsUs` is the tsUs of the newest presented frame, `holdUs` is the time the
viewer held it between last packet arrival and Present returning; the Mac
computes `rtt = now - echoTsUs - holdUs`.

### REST (rest the PC)
`REST 1 [name,name…]` pauses (NtSuspendProcess) every process of the signed-in user except PaneLink, the shell, drivers/fan/RGB/peripheral/VPN helpers, and the listed names (plus `C:\ProgramData\PaneLink\rest-keep.txt`). Only while a viewer is live; reply `REST 1 <paused> <protected>`, or `ERR -1 rest only works while extending`. Re-swept every 5 s. `REST 0` resumes everything; the agent also resumes (and sends `REST 0 0 0`) when the last viewer stops, at agent start and at service stop (paused list kept in `rested.txt`). `REST ?` (side connection) lists what it would pause, without pausing.

### Loss reports (UDP, viewer -> Mac)
`0x13` (40 bytes), sent after each recovery from a broken frame: trigger, packets/parity
received for the broken frame, broken FEC groups, gap before the loss, recovery time, IDR
requests, keyframes seen, frame sizes. The Mac classifies them (Wi-Fi dropout, packet-loss burst,
Mac Wi-Fi queue full, Windows stalled) under Performance → "Lost frames: why".

### Diagnostics (side connection, after AUTH)
`SHOT` saves a screenshot of the console to `C:\ProgramData\PaneLink\shot.bmp`; `POKE` taps
Shift (wakes the display); `REST ?` lists what Rest would pause.
