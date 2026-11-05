# Release gate results (Phase 7, BT-4086)

**Verdict: no-go.** beamtalk-http on Buccaneer misses the gate on 9 of the
10 HTTP/1.1 and TLS rows. It is 0.39-0.80× cowboy's throughput, with p99
1.2-2.9× worse, and every round of every missing row is worse than every
cowboy round. The one row that passes is the 1 MiB chunked response
(1.00×). The correctness side holds: every stress test passes on
Buccaneer. That holds only after three Buccaneer bugs the suite found
were fixed in this PR (below). beamtalk-http's full suite passes on Buccaneer
(`BEAMTALK_HTTP_BACKEND=buccaneer`: 280 of 283 pass and 1 is skipped). The
2 failures are IPv6 binds, and this container has no IPv6; cowboy fails
the same way (see the end of this page). The misses are filed with profiles: BT-4465, BT-4466,
BT-4467, BT-4468 and BT-4464. The context rows (HTTP/2, WebSocket) are
filed too: BT-4469.

How the harness works is in [README.md](README.md) (`just bench`,
`just stress`).

## Machine and versions

- Run 2026-11-05: bench 13:48-14:33 UTC; stress after it.
- Intel Xeon @ 2.10 GHz, 4 cores, 15 GiB, Linux 6.18 (a cloud container),
  OTP 28 (ERTS 16.4), 4 schedulers.
- beamtalk 0.4.0 at main 873b3fa (edge, as CI installs; stdlib built
  from the same commit).
- Buccaneer 115c626: this branch with origin/main merged, including
  response compression (BT-4093), plus the fixes below. Requests send no
  `accept-encoding`, so compression stays off.
- beamtalk-http d644c20 (main) for both backends, its `buccaneer`
  dependency pointed at this checkout. cowboy 2.20.0, ranch 2.3.0.
  The issue names beamtalk-http 0.1.10 as the cowboy baseline, and
  PLAN.md names 0.2.0. Both predate the backend switch, and 0.1.10 also
  predates the String dispatch flip, which edge beamtalk needs. Running
  the same beamtalk-http commit on both backends compares exactly what
  Phase 8 would remove, and nothing else. The cowboy request path has
  not changed since 0.2.0 apart from BT-4171's UTF-8 checks.
- Bandit 1.12.5 on Elixir 1.20.1.
- 5 rounds, 5 s measured after 1 s warm-up per measurement. The servers
  are interleaved row by row, the order rotating each round, with a
  fresh server per measurement.

**The machine was shared.** It is a 4-core cloud container. Another agent
was building and testing Buccaneer (BT-4093) in another worktree during
the session. The bench's own client and server VMs also saturate the 4
cores. The 1-minute load average was 2.3 at the start of round 1 and
5.9-6.4 for rounds 2-5:

- round 1: 2.31 1.93 1.61
- round 2: 5.90 4.55 2.85
- round 3: 5.89 5.47 3.71
- round 4: 6.31 5.94 4.39
- round 5: 6.39 6.10 4.87

Read the ratios within the spreads below. They are robust here: on every
missing row, the whole Buccaneer range lies on the wrong side of the whole
cowboy range.

## The gate

beamtalk-http on Buccaneer (B) against beamtalk-http on cowboy (C). The
values are medians over the 5 rounds, and `spread` is the min-max over the
rounds. **The rule:** a metric misses when B's median is worse than C's
worst round, that is, worse beyond the rounds' spread.

| Row | Metric | B median | B spread | C median | C spread | B/C | Gate |
|---|---|---:|---|---:|---|---:|---|
| get_c1 | req/s | 4361 | 2947-4622 | 6932 | 6447-8446 | 0.63 | MISS |
| get_c1 | p99 µs | 855 | 628-1153 | 552 | 363-592 | 1.55 | MISS |
| get_c10 | req/s | 14387 | 13943-15039 | 25438 | 23553-29773 | 0.57 | MISS |
| get_c10 | p99 µs | 4688 | 3729-4782 | 1768 | 1617-1840 | 2.65 | MISS |
| get_c100 | req/s | 13658 | 12901-14636 | 26843 | 25727-30934 | 0.51 | MISS |
| get_c100 | p99 µs | 34642 | 23972-44870 | 11946 | 8104-12936 | 2.90 | MISS |
| get_c1000 | req/s | 12376 | 11915-14482 | 26071 | 24292-27236 | 0.47 | MISS |
| get_c1000 | p99 µs | 231732 | 203614-255976 | 112079 | 77559-134063 | 2.07 | MISS |
| post_echo_64KiB_c10 | req/s | 5882 | 5620-6165 | 8345 | 7516-9438 | 0.70 | MISS |
| post_echo_64KiB_c10 | p99 µs | 6072 | 4373-6446 | 3656 | 3149-4119 | 1.66 | MISS |
| chunked_1MiB_c10 | req/s | 1787 | 1678-1952 | 1794 | 1742-1828 | 1.00 | pass |
| chunked_1MiB_c10 | p99 µs | 13065 | 11710-13328 | 12431 | 10923-13065 | 1.05 | pass |
| file_1MiB_c10 | req/s | 1377 | 1269-1589 | 1803 | 1676-1836 | 0.76 | MISS |
| file_1MiB_c10 | p99 µs | 17964 | 13731-20041 | 12555 | 12065-13328 | 1.43 | MISS |
| churn_close_w32 | req/s | 3653 | 3540-3742 | 8698 | 8563-9628 | 0.42 | MISS |
| churn_close_w32 | p99 µs | 21702 | 20649-23500 | 9408 | 8517-10601 | 2.31 | MISS |
| tls_handshake_w32 | req/s | 683 | 651-744 | 856 | 743-890 | 0.80 | MISS |
| tls_handshake_w32 | p99 µs | 79118 | 74533-83986 | 66806 | 61694-70916 | 1.18 | MISS |
| tls_get_c100 | req/s | 8917 | 8502-12979 | 22577 | 19018-23647 | 0.39 | MISS |
| tls_get_c100 | p99 µs | 25447 | 17964-27013 | 10923 | 10087-11480 | 2.33 | MISS |

**Notes on the rows.**

- `chunked_1MiB` and `file_1MiB`: beamtalk-http's cowboy backend cannot
  stream or send files (`unsupported_backend`), so cowboy answers both
  with the same 1 MiB as a plain in-memory body. `file_1MiB` therefore
  compares Buccaneer's sendfile with cowboy sending a binary, and on
  loopback the binary wins. Bandit's sendfile is also 0.84× cowboy there.
  Against Bandit, Buccaneer's sendfile is 0.91× (BT-4468). Since BT-4468
  the row is gated against Bandit's sendfile, not cowboy: see
  [`file_1MiB_c10` against Bandit](#file_1mib_c10-against-bandit-bt-4468)
  below. The table above is the Phase 7 run, against cowboy.
- TLS rows: neither backend has a TLS option in `HTTPServer`, so both run
  beamtalk-http's request path behind their own TLS listener (README §
  The servers).
- cowboy closes keep-alive connections every 1,000 requests
  (`max_keepalive`). Its reconnects are inside its numbers.

## All servers

| Row | Metric | http on Buccaneer | http on cowboy | Buccaneer standalone | Bandit | B/cowboy | B/Bandit | B/standalone |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| get_c1 | req/s | 4361 | 6932 | 5348 | 9372 | 0.63 | 0.47 | 0.82 |
| get_c1 | MB/s | 0.0 | 0.1 | 0.1 | 0.1 | 0.63 | 0.47 | 0.82 |
| get_c1 | p50 µs | 190 | 120 | 154 | 97.7 | 1.58 | 1.95 | 1.23 |
| get_c1 | p99 µs | 855 | 552 | 574 | 219 | 1.55 | 3.91 | 1.49 |
| get_c1 | p99.9 µs | 2032 | 1199 | 1822 | 782 | 1.69 | 2.60 | 1.12 |
| get_c10 | req/s | 14387 | 25438 | 16732 | 32635 | 0.57 | 0.44 | 0.86 |
| get_c10 | MB/s | 0.2 | 0.3 | 0.2 | 0.4 | 0.57 | 0.44 | 0.86 |
| get_c10 | p50 µs | 490 | 307 | 390 | 230 | 1.60 | 2.13 | 1.26 |
| get_c10 | p99 µs | 4688 | 1768 | 4505 | 1273 | 2.65 | 3.68 | 1.04 |
| get_c10 | p99.9 µs | 9693 | 4417 | 8688 | 4244 | 2.19 | 2.28 | 1.12 |
| get_c100 | req/s | 13658 | 26843 | 16194 | 41976 | 0.51 | 0.33 | 0.84 |
| get_c100 | MB/s | 0.2 | 0.3 | 0.2 | 0.5 | 0.51 | 0.33 | 0.84 |
| get_c100 | p50 µs | 5721 | 3277 | 4782 | 1312 | 1.75 | 4.36 | 1.20 |
| get_c100 | p99 µs | 34642 | 11946 | 30743 | 10707 | 2.90 | 3.24 | 1.13 |
| get_c100 | p99.9 µs | 70214 | 19452 | 74533 | 44426 | 3.61 | 1.58 | 0.94 |
| get_c1000 | req/s | 12376 | 26071 | 14136 | 37744 | 0.47 | 0.33 | 0.88 |
| get_c1000 | MB/s | 0.1 | 0.3 | 0.2 | 0.4 | 0.47 | 0.33 | 0.88 |
| get_c1000 | p50 µs | 63563 | 34988 | 51577 | 24454 | 1.82 | 2.60 | 1.23 |
| get_c1000 | p99 µs | 231732 | 112079 | 227166 | 96540 | 2.07 | 2.40 | 1.02 |
| get_c1000 | p99.9 µs | 271724 | 148090 | 285585 | 188034 | 1.83 | 1.45 | 0.95 |
| post_echo_64KiB_c10 | req/s | 5882 | 8345 | 7785 | 15202 | 0.70 | 0.39 | 0.76 |
| post_echo_64KiB_c10 | MB/s | 385.5 | 546.9 | 510.2 | 996.3 | 0.70 | 0.39 | 0.76 |
| post_echo_64KiB_c10 | p50 µs | 1464 | 1086 | 1033 | 547 | 1.35 | 2.68 | 1.42 |
| post_echo_64KiB_c10 | p99 µs | 6072 | 3656 | 5179 | 2136 | 1.66 | 2.84 | 1.17 |
| post_echo_64KiB_c10 | p99.9 µs | 11710 | 6194 | 9041 | 4505 | 1.89 | 2.60 | 1.30 |
| chunked_1MiB_c10 | req/s | 1787 | 1794 | 1836 | 2080 | 1.00 | 0.86 | 0.97 |
| chunked_1MiB_c10 | MB/s | 1874.2 | 1881.1 | 1925.1 | 2180.8 | 1.00 | 0.86 | 0.97 |
| chunked_1MiB_c10 | p50 µs | 5389 | 5283 | 5179 | 4550 | 1.02 | 1.18 | 1.04 |
| chunked_1MiB_c10 | p99 µs | 13065 | 12431 | 12936 | 10814 | 1.05 | 1.21 | 1.01 |
| chunked_1MiB_c10 | p99.9 µs | 19069 | 21064 | 17263 | 21919 | 0.91 | 0.87 | 1.10 |
| file_1MiB_c10 | req/s | 1377 | 1803 | 1376 | 1512 | 0.76 | 0.91 | 1.00 |
| file_1MiB_c10 | MB/s | 1444.0 | 1890.6 | 1442.7 | 1585.4 | 0.76 | 0.91 | 1.00 |
| file_1MiB_c10 | p50 µs | 6641 | 5230 | 6708 | 6133 | 1.27 | 1.08 | 0.99 |
| file_1MiB_c10 | p99 µs | 17964 | 12555 | 17610 | 16262 | 1.43 | 1.10 | 1.02 |
| file_1MiB_c10 | p99.9 µs | 23735 | 18880 | 24454 | 22138 | 1.26 | 1.07 | 0.97 |
| churn_close_w32 | req/s | 3653 | 8698 | 3949 | 10118 | 0.42 | 0.36 | 0.93 |
| churn_close_w32 | MB/s | 0.0 | 0.0 | 0.0 | 0.0 | - | - | - |
| churn_close_w32 | p50 µs | 7865 | 3277 | 7336 | 2794 | 2.40 | 2.81 | 1.07 |
| churn_close_w32 | p99 µs | 21702 | 9408 | 20855 | 8602 | 2.31 | 2.52 | 1.04 |
| churn_close_w32 | p99.9 µs | 28391 | 13461 | 28110 | 14007 | 2.11 | 2.03 | 1.01 |
| tls_handshake_w32 | req/s | 683 | 856 | 701 | 843 | 0.80 | 0.81 | 0.97 |
| tls_handshake_w32 | MB/s | 0.0 | 0.0 | 0.0 | 0.0 | - | - | - |
| tls_handshake_w32 | p50 µs | 45772 | 36409 | 44426 | 37888 | 1.26 | 1.21 | 1.03 |
| tls_handshake_w32 | p99 µs | 79118 | 66806 | 83154 | 66144 | 1.18 | 1.20 | 0.95 |
| tls_handshake_w32 | p99.9 µs | 94637 | 80709 | 97505 | 78335 | 1.17 | 1.21 | 0.97 |
| tls_get_c100 | req/s | 8917 | 22577 | 10579 | 28424 | 0.39 | 0.31 | 0.84 |
| tls_get_c100 | MB/s | 0.1 | 0.2 | 0.1 | 0.3 | 0.39 | 0.31 | 0.84 |
| tls_get_c100 | p50 µs | 10707 | 4079 | 8775 | 3343 | 2.63 | 3.20 | 1.22 |
| tls_get_c100 | p99 µs | 25447 | 10923 | 21702 | 8104 | 2.33 | 3.14 | 1.17 |
| tls_get_c100 | p99.9 µs | 32961 | 15784 | 27556 | 11032 | 2.09 | 2.99 | 1.20 |
| idle_10k | node bytes/conn | 15846 | 5581 | 15840 | 14179 | 2.84 | 1.12 | 1.00 |
| idle_10k | process bytes/conn | 4748 | 3257 | 4745 | 3157 | 1.46 | 1.50 | 1.00 |
| idle_10k | processes/conn | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| h2_get_10x10 | req/s | 3127 | - | 3931 | 41454 | - | 0.08 | 0.80 |
| h2_get_10x10 | p50 µs | 30743 | - | 24454 | 1538 | - | 19.99 | 1.26 |
| h2_get_10x10 | p99 µs | 71625 | - | 65489 | 13328 | - | 5.37 | 1.09 |
| h2_get_10x10 | p99.9 µs | 92773 | - | 92773 | 44870 | - | 2.07 | 1.00 |
| ws_echo_c100 | req/s | 20557 | - | 28430 | 49812 | - | 0.41 | 0.72 |
| ws_echo_c100 | p50 µs | 4461 | - | 2094 | 1554 | - | 2.87 | 2.13 |
| ws_echo_c100 | p99 µs | 16425 | - | 15018 | 9790 | - | 1.68 | 1.09 |
| ws_echo_c100 | p99.9 µs | 27283 | - | 79118 | 23037 | - | 1.18 | 0.34 |

Other points in this table:

- **The adapter's share.** beamtalk-http on Buccaneer runs at
  0.82-0.88× of Buccaneer standalone on GET, 0.76× on the 64 KiB echo and
  0.72× on WebSocket echo (BT-4466). Most of the gap to cowboy is in the
  engine itself: standalone is 0.5-0.6× cowboy (BT-4465).
- **Idle connections (reported, not gated).** 15.8 KB of node memory per
  idle keep-alive connection on Buccaneer, against 5.6 KB on cowboy and
  14.2 KB on Bandit. Every server uses one process per connection.
- **HTTP/2 (context).** 0.08× Bandit (BT-4469).
- **WebSocket (context).** 0.41× Bandit through beamtalk-http and 0.57×
  standalone.

## Gate misses, profiled

`just bench-profile --impl buccaneer --row get_c1` traces call time over
the whole server node (528 GETs in 3 s). No single hotspot stands out. The
time goes to Beamtalk's per-send and per-FFI overhead, multiplied by how
many of each the port makes. Per request:

| Cost | Calls per GET | Share |
|---|---:|---:|
| FFI: `beamtalk_erlang_proxy:apply_with_coercion` (+ string unwrapping) | ~47 (+57) | 7.9% (module) |
| `beamtalk_class_derived_cache:fetch` | ~77 | 4.4% |
| dynamic sends (`beamtalk_message_dispatch:send`, `beamtalk_primitive:send`) | ~69 each | ~9.6% (`beamtalk_primitive`) |
| `dispatch/3` on HTTP1Socket / ExchangeState / Exchange / HTTP1Handler | 64 / 36 / 29 / 27 | ~6% |
| `persistent_term:get` / `ets:lookup` | ~189 / ~94 | 2.4% |
| `objectIsKindOf/2` | ~26 | 2.5% (module) |
| calls into class processes (`sys:statistics`) | 2.00 → 0 after the fix below | |

Filed:

| Issue | What | Rows |
|---|---|---|
| BT-4465 | Buccaneer HTTP/1.1 request path: per-request sends, FFI calls, derived-cache lookups (engine side and runtime side) | get_c1-c1000, post_echo, tls_get |
| BT-4466 | beamtalk-http's Buccaneer adapter: 12-18% of throughput (28% on WebSocket) | all rows through beamtalk-http |
| BT-4467 | connection setup: churn 0.42×, TLS handshakes 0.80× | churn_close, tls_handshake |
| BT-4468 | `sendFile:` 1 MiB, 0.91× Bandit's sendfile; the row's baseline needs deciding | file_1MiB |
| BT-4464 | `Reference new` is a call into the Reference class process (worked around here) | all |
| BT-4469 | HTTP/2 at 0.08× Bandit (context) | h2_get |

## `file_1MiB_c10` against Bandit (BT-4468)

**The baseline.** `file_1MiB_c10` is gated against Bandit's `send_file`,
like for like, instead of beamtalk-http on cowboy. beamtalk-http's cowboy
backend cannot send files, so cowboy answers the row from an in-memory
binary; cowboy's figure stays in the report for reference only. In
`bench_main.erl` the row's class is `{gate, bandit}`, and the gate table
has a Baseline column.

**Measured** with `just bench --only file_1MiB_c10 --impls
http_buccaneer,http_cowboy,buccaneer,bandit` (5 rounds, 2026-11-05, the
same 4-core container, load 2-8):

| Server | req/s median (spread) | p99 µs |
|---|---|---:|
| beamtalk-http on Buccaneer (B) | 1,631 (1,557-1,686) | 15,168 |
| beamtalk-http on cowboy (in memory, reference) | 2,137 (2,019-2,240) | 10,923 |
| Buccaneer standalone | 1,587 (1,571-1,684) | 15,168 |
| Bandit 1.12.5 (baseline) | 1,808 (1,702-1,835) | 14,289 |

B/Bandit is 0.90 on req/s and 1.06 on p99, so the row still misses, now
against Bandit. Seven more runs of the row without cowboy (the chunk-size
runs below) put B/Bandit at 0.90-0.95 and standalone/Bandit at 0.90-0.97.

**The sendfile path is already Bandit's.** `Exchange sendFile:` →
`HTTP1Socket sendfile:` (send the buffered head) → Catalina's
`TCPTransport sendfile:`, which is one `file:open` with `[read, raw,
binary]` and one `file:sendfile/5` for the whole range, then `file:close`.
That is Thousand Island's `ThousandIsland.Transports.TCP.sendfile/4`. A
call-count profile shows the same OTP calls per request on both servers:
one `gen_tcp:send` (the head), one `prim_inet:sendfile` (with OTP's own
`nopush` cork and uncork around it, 2 `setopts` plus the re-arm), one
`getopts`, and no read-and-send fallback. Both servers' connection sockets
have identical options (`sndbuf`, `recbuf`, `buffer`, `nodelay`,
watermarks).

**Chunk size.** Bandit sends the whole file in one call. Measured by
passing `chunk_size` to `file:sendfile/5` (a local experiment in
Catalina, not committed), runs alternated, B/Bandit:

| Chunk | B req/s | Standalone req/s | Bandit req/s | B/Bandit |
|---|---:|---:|---:|---:|
| 64 KiB | 1,541 / 1,642 / 1,561 | 1,572 / 1,606 / 1,664 | 1,617 / 1,741 / 1,733 | 0.95 / 0.94 / 0.90 |
| 1 MiB | 1,589 | 1,619 | 1,771 | 0.90 |
| whole file | 1,617 / 1,607 / 1,595 | 1,646 / 1,655 / 1,582 | 1,788 / 1,719 / 1,755 | 0.90 / 0.93 / 0.91 |

A 1 MiB chunk is the whole file here. The differences are inside the
machine's run-to-run noise, so the path keeps Bandit's single call.

**Where the gap is.** Server CPU per request, read from the peer VM's
`/proc` stat over 5 s of load: Buccaneer 1,167-1,227 µs against Bandit's
1,009-1,081 µs on `file_1MiB_c10`, and 100-114 µs against 43-58 µs on
`get_c10`. With load generator and servers on 4 shared cores the row is
CPU-bound, so every microsecond of Beamtalk work per request is time the
kernel does not spend copying. Timed one request at a time on one
connection (no contention):

| Median | Buccaneer | Bandit |
|---|---:|---:|
| `/file`, first byte | 248-295 µs | 147-167 µs |
| `/file`, whole response | 706-759 µs | 591-628 µs |
| `GET /`, first byte | 95-128 µs | 75-89 µs |

A timestamped trace of the connection process puts the extra time before
the head goes out: request parsing and the pipeline up to the handler, and
building the head. That is the request path every row shares (BT-4465,
BT-4473), not the sendfile call. The file operations themselves cost the
same on both servers: `file:open` plus `file:close` is 55-70 µs on this
container's filesystem in plain Erlang too. Turning off scheduler
busy-waiting (`+sbwt none`, a diagnostic run) raised every server and left
B/Bandit at 0.91. beamtalk-http's adapter (BT-4466) adds nothing measurable
on this row: B/standalone is 0.94-1.03.

## Bugs found and fixed in this PR

The stress suite and the profile found these. Each one is small and fixed
here; the bench above ran with all of them.

1. **`HTTP2Stream` leaked a `TimeoutProxy` actor whenever a stream process
   was killed mid-call** (`chaos_kill_streams`: +100 processes after 5 s).
   `withConn:` spawned a `withTimeout:` proxy per blocking connection call
   and stopped it in an `ensure:`, which does not run on a kill. It is now
   a direct `perform:withArguments:timeout:` call: no proxy, no spawn per
   call, no leak.
2. **`Clock`'s per-second updater was never started.** Every response
   missed the ETS cache, logged "Header timestamp couldn't be fetched from
   ETS cache" at warning level, and formatted the date with
   `DateTime format:`. That was ~5% of request CPU in the profile, and a
   log line per request on any node with warnings enabled. The first miss
   now forks the updater, which owns the table and refreshes it every
   second, as Bandit.Clock does.
3. **An empty request body was the String `""` rather than a Binary.**
   `HTTP1Socket readData:` answered `""` for a bodiless request and for an
   empty chunked body. beamtalk-http's `HTTPRequest body` then sent
   `isError` to a String, so `req body` answered **500** on beamtalk-http
   on Buccaneer for any GET, and for any empty chunked POST
   (`fuzz_pipelined_requests`). Fixed in the engine: the body is always a
   Binary.
4. **Two calls per request into the `Reference` class process**
   (`Reference new` in `Exchange class>>open:` and in the telemetry span).
   Both now use `erlang:make_ref` directly; the language fix is filed as
   BT-4464.
5. `HTTP1Socket http1Opt:default:` did a non-local return from inside
   `ifAbsent:` blocks (a throw/catch) several times per request. It now
   answers without one.

## Stress results

`just stress`, full sizes, with the full 30-minute soak (it ran here; it
was not scaled down). **Every test passes on Buccaneer.** The run came in
two parts:

1. Everything, 14:33-15:05 UTC: 31 passed and 3 failed. The 3 failures
   were the harness's fault. `chaos_kill_streams`' victim finder then
   picked "whatever a connection process monitors". A connection in a
   `gen_server:call` monitors the callee, so the killer killed class
   processes and the server actor in the `http_buccaneer` node. That node
   broke (`class_not_found 'Block'`), and the two tests that ran on it
   afterwards, `lifecycle_stop_drains` and the soak, failed to start a
   server. The finder now picks stream processes by their process
   dictionary.
2. Rerun after that fix, `--only chaos_kill_streams,lifecycle,soak`,
   14:43-15:16 UTC: 8 passed, 0 failed.

| Test | Server | Result | Detail |
|---|---|---|---|
| fuzz_pipelined_requests | http on Buccaneer | pass | 21,875 requests (7,281 GET, 7,297 POST, 7,297 chunked POST), bytes checked |
| | Buccaneer standalone | pass | 21,456 |
| | http on cowboy, Bandit | pass | 21,438, 21,698 |
| fuzz_malformed_requests | all four | pass | 180/180 rejected (4xx, 505) |
| leak_churn | all four | pass | 10,000 cycles, back to baseline (Buccaneer 2.3-2.5 s, cowboy 0.9 s, Bandit 0.8 s) |
| leak_keepalive | http on Buccaneer, standalone, Bandit | pass | 5,000 requests on one connection: dictionary 4 → 4 entries, process memory 8,984 → 8,984 bytes (Bandit 3 → 3, 2,808 → 2,808) |
| slowloris_drip | Buccaneer standalone | pass | 200 dripping clients all served; 2,793 ordinary requests alongside, p99 4.3 ms |
| slowloris_stall | Buccaneer standalone | pass | 60 stalled clients closed at the 3 s read timeout (request line, headers) and the 15 s body timeout (slowest 15,034 ms) |
| limits_max_requests | Buccaneer standalone | pass | only the 5th response says `connection: close`, then the connection closes |
| limits_headers | standalone, http on Buccaneer, Bandit | pass | 431, 431, 414, as Bandit |
| limits_num_connections | Buccaneer standalone | pass | the 6th connection waits while 5 are open, then is served |
| chaos_kill_connections | all four | pass | 30 s, a kill every 50 ms (Buccaneer 388-393 kills, 308-395k good answers); no wrong answers; back to baseline |
| chaos_kill_streams (rerun) | http on Buccaneer, standalone | pass | 30 s, 916 / 938 stream processes killed, each answered with RST_STREAM; 10.6-10.8k good streams; back to baseline |
| lifecycle_suspend_resume (rerun) | Buccaneer standalone | pass | open connections served while suspended; new ones refused; served again after resume |
| lifecycle_stop_drains (rerun) | http on Buccaneer, standalone, Bandit | pass | 10 in-flight `/slow` requests all answered; stop took 705-721 ms |
| lifecycle_stop_deadline (rerun) | Buccaneer standalone | pass | `#shutdownTimeout` 300 ms: stop returned in 305 ms, in-flight requests cut off |
| soak_mixed_load (rerun) | http on Buccaneer | pass | 30 min: 6.59M HTTP/1.1, 595,890 HTTP/2 streams, 3.52M WebSocket echoes, 237,898 churned connections (TCP and TLS), 500 idle connections; no errors. Memory floor 115 → 116 MiB; process peak 1,755 → 1,254; memory 93 MiB before, 96 MiB after |

Bandit, for context: in `chaos_kill_streams` a killed stream process
leaves its stream unanswered (no RST_STREAM) until the client times out,
so that test runs on Buccaneer only. Buccaneer resets the stream.
`fuzz_malformed_requests` leaves out bare empty lines: Buccaneer and
Bandit wait for a request line after them (RFC 9112 § 2.2), while cowboy
closes.

## Conformance

h2spec and Autobahn stay as their own non-blocking CI jobs (`just h2spec`,
`just autobahn`), unchanged here.

## beamtalk-http's suite on Buccaneer

beamtalk-http d644c20 (`_build/bench/beamtalk-http`, its `buccaneer`
dependency pointed at this branch), `BEAMTALK_HTTP_BACKEND=buccaneer beamtalk test`:
**14 files, 283 tests, 280 passed, 1 skipped, 2 failed** (77 s).

The two failures are `HTTPServerTest testClientDialsIpv6Literal` and
`HttpExchangeAdapterTest testBindIpv6`. Both bind `::1`, and this
container has no IPv6: `gen_tcp:listen(0, [inet6, {ip, {0,0,0,0,0,0,0,1}}])`
answers `eafnosupport`. With `BEAMTALK_HTTP_BACKEND=cowboy`,
`httpserver_test.bt` fails its IPv6 test here too. CI (ubuntu-latest, with
IPv6) is where this suite should be confirmed.

Before this PR's fix 3, every handler that called `req body` on a request
with no body answered 500 on Buccaneer. beamtalk-http's suite did not
catch it because its body tests all send a body.

## Every round

| Row | Metric | Server | Rounds | Errors |
|---|---|---|---|---|
| get_c1 | req/s | http on Buccaneer | 4395, 2947, 3730, 4361, 4622 | 0 |
| get_c1 | req/s | http on cowboy | 8446, 6932, 6447, 7070, 6919 | 0 |
| get_c1 | req/s | Buccaneer standalone | 6339, 4028, 6576, 4817, 5348 | 0 |
| get_c1 | req/s | Bandit | 11853, 7620, 9372, 12321, 7576 | 0 |
| get_c1 | MB/s | http on Buccaneer | 0.0, 0.0, 0.0, 0.0, 0.1 | 0 |
| get_c1 | MB/s | http on cowboy | 0.1, 0.1, 0.1, 0.1, 0.1 | 0 |
| get_c1 | MB/s | Buccaneer standalone | 0.1, 0.0, 0.1, 0.1, 0.1 | 0 |
| get_c1 | MB/s | Bandit | 0.1, 0.1, 0.1, 0.1, 0.1 | 0 |
| get_c1 | p50 µs | http on Buccaneer | 176, 237, 202, 190, 169 | 0 |
| get_c1 | p50 µs | http on cowboy | 104, 120, 128, 120, 120 | 0 |
| get_c1 | p50 µs | Buccaneer standalone | 128, 181, 125, 156, 154 | 0 |
| get_c1 | p50 µs | Bandit | 75.4, 109, 97.7, 74.0, 113 | 0 |
| get_c1 | p99 µs | http on Buccaneer | 855, 1153, 872, 628, 687 | 0 |
| get_c1 | p99 µs | http on cowboy | 363, 574, 592, 510, 552 | 0 |
| get_c1 | p99 µs | Buccaneer standalone | 500, 855, 475, 737, 574 | 0 |
| get_c1 | p99 µs | Bandit | 181, 510, 219, 162, 500 | 0 |
| get_c1 | p99.9 µs | http on Buccaneer | 2032, 3959, 2336, 1538, 1751 | 0 |
| get_c1 | p99.9 µs | http on cowboy | 1153, 1286, 1199, 1153, 1312 | 0 |
| get_c1 | p99.9 µs | Buccaneer standalone | 1822, 2012, 1130, 2245, 1649 | 0 |
| get_c1 | p99.9 µs | Bandit | 782, 1699, 701, 654, 1130 | 0 |
| get_c10 | req/s | http on Buccaneer | 15039, 13943, 14387, 14490, 14020 | 0 |
| get_c10 | req/s | http on cowboy | 25438, 23553, 23786, 26012, 29773 | 0 |
| get_c10 | req/s | Buccaneer standalone | 16732, 14638, 16206, 17854, 19581 | 0 |
| get_c10 | req/s | Bandit | 39207, 32558, 32635, 30470, 33577 | 0 |
| get_c10 | MB/s | http on Buccaneer | 0.2, 0.2, 0.2, 0.2, 0.2 | 0 |
| get_c10 | MB/s | http on cowboy | 0.3, 0.3, 0.3, 0.3, 0.3 | 0 |
| get_c10 | MB/s | Buccaneer standalone | 0.2, 0.2, 0.2, 0.2, 0.2 | 0 |
| get_c10 | MB/s | Bandit | 0.4, 0.4, 0.4, 0.3, 0.4 | 0 |
| get_c10 | p50 µs | http on Buccaneer | 510, 500, 461, 466, 490 | 0 |
| get_c10 | p50 µs | http on cowboy | 307, 332, 336, 304, 264 | 0 |
| get_c10 | p50 µs | Buccaneer standalone | 397, 426, 390, 374, 349 | 0 |
| get_c10 | p50 µs | Bandit | 208, 239, 228, 249, 230 | 0 |
| get_c10 | p99 µs | http on Buccaneer | 3729, 4735, 4782, 4688, 4688 | 0 |
| get_c10 | p99 µs | http on cowboy | 1733, 1840, 1768, 1617, 1786 | 0 |
| get_c10 | p99 µs | Buccaneer standalone | 4505, 4782, 4642, 4505, 4417 | 0 |
| get_c10 | p99 µs | Bandit | 973, 1273, 1421, 1435, 1211 | 0 |
| get_c10 | p99.9 µs | http on Buccaneer | 8517, 9693, 8775, 10814, 9790 | 0 |
| get_c10 | p99.9 µs | http on cowboy | 4417, 4550, 4373, 4329, 4782 | 0 |
| get_c10 | p99.9 µs | Buccaneer standalone | 8688, 8863, 8688, 8433, 8349 | 0 |
| get_c10 | p99.9 µs | Bandit | 3244, 4244, 4830, 4417, 4244 | 0 |
| get_c100 | req/s | http on Buccaneer | 13935, 13649, 14636, 13658, 12901 | 0 |
| get_c100 | req/s | http on cowboy | 26843, 25727, 26565, 28300, 30934 | 0 |
| get_c100 | req/s | Buccaneer standalone | 13896, 15685, 17617, 16805, 16194 | 0 |
| get_c100 | req/s | Bandit | 42340, 41976, 43230, 40120, 39620 | 0 |
| get_c100 | MB/s | http on Buccaneer | 0.2, 0.2, 0.2, 0.2, 0.1 | 0 |
| get_c100 | MB/s | http on cowboy | 0.3, 0.3, 0.3, 0.3, 0.3 | 0 |
| get_c100 | MB/s | Buccaneer standalone | 0.2, 0.2, 0.2, 0.2, 0.2 | 0 |
| get_c100 | MB/s | Bandit | 0.5, 0.5, 0.5, 0.4, 0.4 | 0 |
| get_c100 | p50 µs | http on Buccaneer | 6133, 5230, 5283, 5778, 5721 | 0 |
| get_c100 | p50 µs | http on cowboy | 3376, 3376, 3277, 2996, 3056 | 0 |
| get_c100 | p50 µs | Buccaneer standalone | 5389, 4782, 4596, 4417, 4977 | 0 |
| get_c100 | p50 µs | Bandit | 2223, 1312, 1236, 1248, 1449 | 0 |
| get_c100 | p99 µs | http on Buccaneer | 23972, 41851, 34642, 34642, 44870 | 0 |
| get_c100 | p99 µs | http on cowboy | 10188, 12936, 12431, 11946, 8104 | 0 |
| get_c100 | p99 µs | Buccaneer standalone | 36049, 34988, 19259, 29543, 30743 | 0 |
| get_c100 | p99 µs | Bandit | 6194, 11142, 10496, 10707, 14289 | 0 |
| get_c100 | p99.9 µs | http on Buccaneer | 39820, 77559, 66144, 70214, 74533 | 0 |
| get_c100 | p99.9 µs | http on cowboy | 13731, 20444, 19452, 21919, 12308 | 0 |
| get_c100 | p99.9 µs | Buccaneer standalone | 102479, 90044, 49565, 64199, 74533 | 0 |
| get_c100 | p99.9 µs | Bandit | 11032, 44426, 41437, 62311, 49074 | 0 |
| get_c1000 | req/s | http on Buccaneer | 14482, 11915, 12097, 12667, 12376 | 0 |
| get_c1000 | req/s | http on cowboy | 24292, 24762, 26071, 27236, 26740 | 0 |
| get_c1000 | req/s | Buccaneer standalone | 13435, 13583, 14437, 14875, 14136 | 0 |
| get_c1000 | req/s | Bandit | 36142, 34272, 39829, 37744, 37893 | 0 |
| get_c1000 | MB/s | http on Buccaneer | 0.2, 0.1, 0.1, 0.1, 0.1 | 0 |
| get_c1000 | MB/s | http on cowboy | 0.3, 0.3, 0.3, 0.3, 0.3 | 0 |
| get_c1000 | MB/s | Buccaneer standalone | 0.1, 0.1, 0.2, 0.2, 0.2 | 0 |
| get_c1000 | MB/s | Bandit | 0.4, 0.4, 0.4, 0.4, 0.4 | 0 |
| get_c1000 | p50 µs | http on Buccaneer | 68149, 61694, 62311, 64841, 63563 | 0 |
| get_c1000 | p50 µs | http on cowboy | 37512, 34988, 33959, 31361, 36773 | 0 |
| get_c1000 | p50 µs | Buccaneer standalone | 61694, 58700, 50060, 51067, 51577 | 0 |
| get_c1000 | p50 µs | Bandit | 18693, 27556, 24454, 23972, 24946 | 0 |
| get_c1000 | p99 µs | http on Buccaneer | 203614, 255976, 216141, 241141, 231732 | 0 |
| get_c1000 | p99 µs | http on cowboy | 98480, 131422, 112079, 134063, 77559 | 0 |
| get_c1000 | p99 µs | Buccaneer standalone | 220485, 229438, 227166, 229438, 214001 | 0 |
| get_c1000 | p99 µs | Bandit | 57543, 102479, 96540, 113200, 92773 | 0 |
| get_c1000 | p99.9 µs | http on Buccaneer | 241141, 328272, 250933, 274441, 271724 | 0 |
| get_c1000 | p99.9 µs | http on cowboy | 131422, 207707, 148090, 211882, 97505 | 0 |
| get_c1000 | p99.9 µs | Buccaneer standalone | 250933, 279958, 291325, 285585, 315463 | 0 |
| get_c1000 | p99.9 µs | Bandit | 69518, 178908, 255976, 227166, 188034 | 0 |
| post_echo_64KiB_c10 | req/s | http on Buccaneer | 5952, 5854, 6165, 5882, 5620 | 0 |
| post_echo_64KiB_c10 | req/s | http on cowboy | 8345, 7516, 8277, 9438, 8410 | 0 |
| post_echo_64KiB_c10 | req/s | Buccaneer standalone | 7225, 7184, 8789, 7952, 7785 | 0 |
| post_echo_64KiB_c10 | req/s | Bandit | 16561, 12354, 15202, 16024, 14130 | 0 |
| post_echo_64KiB_c10 | MB/s | http on Buccaneer | 390.0, 383.6, 404.0, 385.5, 368.3 | 0 |
| post_echo_64KiB_c10 | MB/s | http on cowboy | 546.9, 492.5, 542.4, 618.5, 551.2 | 0 |
| post_echo_64KiB_c10 | MB/s | Buccaneer standalone | 473.5, 470.8, 576.0, 521.2, 510.2 | 0 |
| post_echo_64KiB_c10 | MB/s | Bandit | 1085.4, 809.6, 996.3, 1050.2, 926.0 | 0 |
| post_echo_64KiB_c10 | p50 µs | http on Buccaneer | 1523, 1393, 1338, 1464, 1464 | 0 |
| post_echo_64KiB_c10 | p50 µs | http on cowboy | 1086, 1199, 1097, 917, 1075 | 0 |
| post_echo_64KiB_c10 | p50 µs | Buccaneer standalone | 1075, 1086, 964, 1033, 1003 | 0 |
| post_echo_64KiB_c10 | p50 µs | Bandit | 520, 708, 547, 525, 616 | 0 |
| post_echo_64KiB_c10 | p99 µs | http on Buccaneer | 4373, 6133, 6072, 5608, 6446 | 0 |
| post_echo_64KiB_c10 | p99 µs | http on cowboy | 3656, 4119, 3584, 3149, 3881 | 0 |
| post_echo_64KiB_c10 | p99 µs | Buccaneer standalone | 5497, 5336, 4079, 4550, 5179 | 0 |
| post_echo_64KiB_c10 | p99 µs | Bandit | 1786, 2480, 2136, 2073, 2245 | 0 |
| post_echo_64KiB_c10 | p99.9 µs | http on Buccaneer | 7410, 11710, 13595, 10087, 12431 | 0 |
| post_echo_64KiB_c10 | p99.9 µs | http on cowboy | 6576, 7192, 6012, 5497, 6194 | 0 |
| post_echo_64KiB_c10 | p99.9 µs | Buccaneer standalone | 11595, 9223, 8267, 7865, 9041 | 0 |
| post_echo_64KiB_c10 | p99.9 µs | Bandit | 4202, 5389, 4830, 4461, 4505 | 0 |
| chunked_1MiB_c10 | req/s | http on Buccaneer | 1786, 1800, 1952, 1787, 1678 | 0 |
| chunked_1MiB_c10 | req/s | http on cowboy | 1799, 1743, 1794, 1742, 1828 | 0 |
| chunked_1MiB_c10 | req/s | Buccaneer standalone | 1790, 1901, 2000, 1696, 1836 | 0 |
| chunked_1MiB_c10 | req/s | Bandit | 1993, 2125, 2145, 2080, 2042 | 0 |
| chunked_1MiB_c10 | MB/s | http on Buccaneer | 1872.5, 1887.3, 2046.7, 1874.2, 1759.2 | 0 |
| chunked_1MiB_c10 | MB/s | http on cowboy | 1886.6, 1827.7, 1881.1, 1827.0, 1916.9 | 0 |
| chunked_1MiB_c10 | MB/s | Buccaneer standalone | 1876.6, 1993.9, 2096.9, 1778.2, 1925.1 | 0 |
| chunked_1MiB_c10 | MB/s | Bandit | 2089.6, 2228.7, 2248.8, 2180.8, 2141.5 | 0 |
| chunked_1MiB_c10 | p50 µs | http on Buccaneer | 5389, 5336, 4782, 5443, 5894 | 0 |
| chunked_1MiB_c10 | p50 µs | http on cowboy | 5230, 5389, 5283, 5608, 5230 | 0 |
| chunked_1MiB_c10 | p50 µs | Buccaneer standalone | 5443, 5026, 4688, 5664, 5179 | 0 |
| chunked_1MiB_c10 | p50 µs | Bandit | 4830, 4550, 4550, 4461, 4642 | 0 |
| chunked_1MiB_c10 | p99 µs | http on Buccaneer | 13328, 13065, 13196, 11710, 13065 | 0 |
| chunked_1MiB_c10 | p99 µs | http on cowboy | 12555, 13065, 12065, 10923, 12431 | 0 |
| chunked_1MiB_c10 | p99 µs | Buccaneer standalone | 13065, 12065, 13065, 12936, 12936 | 0 |
| chunked_1MiB_c10 | p99 µs | Bandit | 11480, 10496, 10188, 10814, 11946 | 0 |
| chunked_1MiB_c10 | p99.9 µs | http on Buccaneer | 19069, 19843, 25447, 14722, 16589 | 0 |
| chunked_1MiB_c10 | p99.9 µs | http on cowboy | 19452, 24699, 21274, 21064, 18880 | 0 |
| chunked_1MiB_c10 | p99.9 µs | Buccaneer standalone | 17263, 16589, 32961, 16755, 18143 | 0 |
| chunked_1MiB_c10 | p99.9 µs | Bandit | 40218, 14722, 13065, 21919, 26218 | 0 |
| file_1MiB_c10 | req/s | http on Buccaneer | 1377, 1269, 1399, 1589, 1372 | 0 |
| file_1MiB_c10 | req/s | http on cowboy | 1746, 1813, 1836, 1676, 1803 | 0 |
| file_1MiB_c10 | req/s | Buccaneer standalone | 1376, 1242, 1380, 1367, 1400 | 0 |
| file_1MiB_c10 | req/s | Bandit | 1524, 1461, 1534, 1444, 1512 | 0 |
| file_1MiB_c10 | MB/s | http on Buccaneer | 1444.0, 1330.5, 1467.5, 1665.9, 1438.8 | 0 |
| file_1MiB_c10 | MB/s | http on cowboy | 1831.3, 1901.2, 1925.4, 1757.5, 1890.6 | 0 |
| file_1MiB_c10 | MB/s | Buccaneer standalone | 1442.7, 1302.5, 1447.2, 1433.3, 1468.5 | 0 |
| file_1MiB_c10 | MB/s | Bandit | 1598.1, 1531.5, 1608.2, 1514.2, 1585.4 | 0 |
| file_1MiB_c10 | p50 µs | http on Buccaneer | 6641, 7192, 6641, 5894, 6708 | 0 |
| file_1MiB_c10 | p50 µs | http on cowboy | 5336, 5179, 5179, 5778, 5230 | 0 |
| file_1MiB_c10 | p50 µs | Buccaneer standalone | 6708, 7410, 6708, 6911, 6510 | 0 |
| file_1MiB_c10 | p50 µs | Bandit | 6012, 6256, 5953, 6641, 6133 | 0 |
| file_1MiB_c10 | p99 µs | http on Buccaneer | 17964, 20041, 17092, 13731, 17964 | 0 |
| file_1MiB_c10 | p99 µs | http on cowboy | 13328, 12555, 12308, 12065, 12555 | 0 |
| file_1MiB_c10 | p99 µs | Buccaneer standalone | 17964, 20041, 17610, 16425, 17610 | 0 |
| file_1MiB_c10 | p99 µs | Bandit | 15784, 17435, 16425, 13196, 16262 | 0 |
| file_1MiB_c10 | p99.9 µs | http on Buccaneer | 27013, 27556, 22360, 17964, 23735 | 0 |
| file_1MiB_c10 | p99.9 µs | http on cowboy | 23500, 20242, 17435, 17263, 18880 | 0 |
| file_1MiB_c10 | p99.9 µs | Buccaneer standalone | 24946, 26745, 24454, 21702, 23735 | 0 |
| file_1MiB_c10 | p99.9 µs | Bandit | 21064, 23735, 23500, 18325, 22138 | 0 |
| churn_close_w32 | req/s | http on Buccaneer | 3742, 3540, 3716, 3653, 3614 | 0 |
| churn_close_w32 | req/s | http on cowboy | 9145, 8617, 8698, 8563, 9628 | 0 |
| churn_close_w32 | req/s | Buccaneer standalone | 3874, 3781, 3949, 4350, 3954 | 0 |
| churn_close_w32 | req/s | Bandit | 9574, 10118, 10792, 9273, 10574 | 0 |
| churn_close_w32 | MB/s | http on Buccaneer | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| churn_close_w32 | MB/s | http on cowboy | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| churn_close_w32 | MB/s | Buccaneer standalone | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| churn_close_w32 | MB/s | Bandit | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| churn_close_w32 | p50 µs | http on Buccaneer | 7710, 8185, 7865, 8023, 7865 | 0 |
| churn_close_w32 | p50 µs | http on cowboy | 3277, 3376, 3309, 3180, 3026 | 0 |
| churn_close_w32 | p50 µs | Buccaneer standalone | 7336, 7558, 7336, 6775, 7410 | 0 |
| churn_close_w32 | p50 µs | Bandit | 3118, 2794, 2632, 3180, 2739 | 0 |
| churn_close_w32 | p99 µs | http on Buccaneer | 21702, 22360, 21702, 20649, 23500 | 0 |
| churn_close_w32 | p99 µs | http on cowboy | 8517, 10087, 9408, 10601, 9041 | 0 |
| churn_close_w32 | p99 µs | Buccaneer standalone | 22360, 22138, 20855, 17964, 20649 | 0 |
| churn_close_w32 | p99 µs | Bandit | 8349, 9131, 8602, 8688, 8104 | 0 |
| churn_close_w32 | p99.9 µs | http on Buccaneer | 28110, 28391, 29251, 26481, 33290 | 0 |
| churn_close_w32 | p99.9 µs | http on cowboy | 12431, 15473, 13461, 14432, 13328 | 0 |
| churn_close_w32 | p99.9 µs | Buccaneer standalone | 29839, 30743, 28110, 23500, 27013 | 0 |
| churn_close_w32 | p99.9 µs | Bandit | 10923, 14869, 14007, 15320, 11254 | 0 |
| tls_handshake_w32 | req/s | http on Buccaneer | 651, 738, 683, 744, 673 | 0 |
| tls_handshake_w32 | req/s | http on cowboy | 743, 793, 856, 890, 868 | 0 |
| tls_handshake_w32 | req/s | Buccaneer standalone | 639, 715, 701, 764, 653 | 0 |
| tls_handshake_w32 | req/s | Bandit | 820, 843, 845, 871, 819 | 0 |
| tls_handshake_w32 | MB/s | http on Buccaneer | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| tls_handshake_w32 | MB/s | http on cowboy | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| tls_handshake_w32 | MB/s | Buccaneer standalone | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| tls_handshake_w32 | MB/s | Bandit | 0.0, 0.0, 0.0, 0.0, 0.0 | 0 |
| tls_handshake_w32 | p50 µs | http on Buccaneer | 48588, 41851, 45772, 41851, 46230 | 0 |
| tls_handshake_w32 | p50 µs | http on cowboy | 42270, 39426, 36409, 35338, 35692 | 0 |
| tls_handshake_w32 | p50 µs | Buccaneer standalone | 48588, 43986, 44426, 41437, 48107 | 0 |
| tls_handshake_w32 | p50 µs | Bandit | 38266, 37888, 36773, 36049, 37888 | 0 |
| tls_handshake_w32 | p99 µs | http on Buccaneer | 83986, 76031, 81516, 74533, 79118 | 0 |
| tls_handshake_w32 | p99 µs | http on cowboy | 70916, 70916, 64841, 61694, 66806 | 0 |
| tls_handshake_w32 | p99 µs | Buccaneer standalone | 97505, 83154, 80709, 71625, 85674 | 0 |
| tls_handshake_w32 | p99 µs | Bandit | 64199, 62311, 70214, 66144, 72341 | 0 |
| tls_handshake_w32 | p99.9 µs | http on Buccaneer | 103503, 83986, 95584, 92773, 94637 | 0 |
| tls_handshake_w32 | p99.9 µs | http on cowboy | 83154, 79910, 81516, 75278, 80709 | 0 |
| tls_handshake_w32 | p99.9 µs | Buccaneer standalone | 117797, 104538, 97505, 86531, 97505 | 0 |
| tls_handshake_w32 | p99.9 µs | Bandit | 75278, 74533, 83986, 78335, 87396 | 0 |
| tls_get_c100 | req/s | http on Buccaneer | 8502, 8829, 8917, 12979, 9031 | 0 |
| tls_get_c100 | req/s | http on cowboy | 19018, 22577, 23377, 23647, 22164 | 0 |
| tls_get_c100 | req/s | Buccaneer standalone | 10855, 10569, 10343, 10832, 10579 | 0 |
| tls_get_c100 | req/s | Bandit | 26374, 28424, 28142, 28644, 29290 | 0 |
| tls_get_c100 | MB/s | http on Buccaneer | 0.1, 0.1, 0.1, 0.1, 0.1 | 0 |
| tls_get_c100 | MB/s | http on cowboy | 0.2, 0.2, 0.3, 0.3, 0.2 | 0 |
| tls_get_c100 | MB/s | Buccaneer standalone | 0.1, 0.1, 0.1, 0.1, 0.1 | 0 |
| tls_get_c100 | MB/s | Bandit | 0.3, 0.3, 0.3, 0.3, 0.3 | 0 |
| tls_get_c100 | p50 µs | http on Buccaneer | 11254, 10707, 10707, 7410, 10601 | 0 |
| tls_get_c100 | p50 µs | http on cowboy | 5077, 4079, 3998, 3919, 4202 | 0 |
| tls_get_c100 | p50 µs | Buccaneer standalone | 8517, 8775, 8952, 8602, 8775 | 0 |
| tls_get_c100 | p50 µs | Bandit | 3548, 3309, 3376, 3343, 3244 | 0 |
| tls_get_c100 | p99 µs | http on Buccaneer | 27013, 26481, 25447, 17964, 24454 | 0 |
| tls_get_c100 | p99 µs | http on cowboy | 11480, 10923, 10087, 10814, 11366 | 0 |
| tls_get_c100 | p99 µs | Buccaneer standalone | 21274, 23037, 23037, 21487, 21702 | 0 |
| tls_get_c100 | p99 µs | Bandit | 9131, 8602, 8104, 7710, 8023 | 0 |
| tls_get_c100 | p99.9 µs | http on Buccaneer | 33959, 32961, 34642, 26481, 32634 | 0 |
| tls_get_c100 | p99.9 µs | http on cowboy | 15784, 21487, 14576, 16755, 15628 | 0 |
| tls_get_c100 | p99.9 µs | Buccaneer standalone | 26481, 29543, 28110, 27556, 27283 | 0 |
| tls_get_c100 | p99.9 µs | Bandit | 11480, 12808, 11032, 10087, 10496 | 0 |
| idle_10k | node bytes/conn | http on Buccaneer | 15939, 15846, 15835, 15810, 15853 | 0 |
| idle_10k | node bytes/conn | http on cowboy | 5662, 5586, 5570, 5578, 5581 | 0 |
| idle_10k | node bytes/conn | Buccaneer standalone | 15944, 15836, 15838, 15840, 15860 | 0 |
| idle_10k | node bytes/conn | Bandit | 14273, 14179, 14165, 14192, 14167 | 0 |
| idle_10k | process bytes/conn | http on Buccaneer | 4747, 4757, 4748, 4717, 4763 | 0 |
| idle_10k | process bytes/conn | http on cowboy | 3248, 3262, 3254, 3257, 3261 | 0 |
| idle_10k | process bytes/conn | Buccaneer standalone | 4745, 4737, 4745, 4748, 4760 | 0 |
| idle_10k | process bytes/conn | Bandit | 3156, 3168, 3157, 3184, 3155 | 0 |
| idle_10k | processes/conn | http on Buccaneer | 1.00, 1.00, 1.00, 1.00, 1.00 | 0 |
| idle_10k | processes/conn | http on cowboy | 1.00, 1.00, 1.00, 1.00, 1.00 | 0 |
| idle_10k | processes/conn | Buccaneer standalone | 1.00, 1.00, 1.00, 1.00, 1.00 | 0 |
| idle_10k | processes/conn | Bandit | 1.00, 1.00, 1.00, 1.00, 1.00 | 0 |
| h2_get_10x10 | req/s | http on Buccaneer | 2961, 3123, 3190, 3127, 3246 | 0 |
| h2_get_10x10 | req/s | Buccaneer standalone | 3758, 3617, 4139, 3931, 3948 | 0 |
| h2_get_10x10 | req/s | Bandit | 37792, 41896, 41454, 45148, 38668 | 0 |
| h2_get_10x10 | p50 µs | http on Buccaneer | 32634, 30743, 30137, 31050, 29839 | 0 |
| h2_get_10x10 | p50 µs | Buccaneer standalone | 25447, 26218, 23267, 24454, 24454 | 0 |
| h2_get_10x10 | p50 µs | Bandit | 1682, 1538, 1508, 1449, 1569 | 0 |
| h2_get_10x10 | p99 µs | http on Buccaneer | 76792, 72341, 67474, 71625, 64199 | 0 |
| h2_get_10x10 | p99 µs | Buccaneer standalone | 68149, 69518, 61083, 65489, 56973 | 0 |
| h2_get_10x10 | p99 µs | Bandit | 13869, 11828, 13328, 11142, 18693 | 0 |
| h2_get_10x10 | p99.9 µs | http on Buccaneer | 104538, 99465, 88270, 92773, 88270 | 0 |
| h2_get_10x10 | p99.9 µs | Buccaneer standalone | 109871, 103503, 92773, 91854, 90945 | 0 |
| h2_get_10x10 | p99.9 µs | Bandit | 45772, 43551, 44870, 31991, 57543 | 0 |
| ws_echo_c100 | req/s | http on Buccaneer | 19753, 19978, 20557, 20955, 20752 | 0 |
| ws_echo_c100 | req/s | Buccaneer standalone | 28145, 27779, 29770, 29260, 28430 | 0 |
| ws_echo_c100 | req/s | Bandit | 48687, 48373, 50919, 49812, 50429 | 0 |
| ws_echo_c100 | p50 µs | http on Buccaneer | 4550, 4550, 4461, 4202, 4202 | 0 |
| ws_echo_c100 | p50 µs | Buccaneer standalone | 2157, 2136, 1877, 1934, 2094 | 0 |
| ws_echo_c100 | p50 µs | Bandit | 1617, 1554, 1421, 1649, 1464 | 0 |
| ws_echo_c100 | p99 µs | http on Buccaneer | 16589, 16425, 15942, 15628, 16589 | 0 |
| ws_echo_c100 | p99 µs | Buccaneer standalone | 11595, 20041, 15018, 14722, 15784 | 0 |
| ws_echo_c100 | p99 µs | Bandit | 9597, 9987, 9888, 9790, 9131 | 0 |
| ws_echo_c100 | p99.9 µs | http on Buccaneer | 27283, 28110, 25195, 23500, 28110 | 0 |
| ws_echo_c100 | p99.9 µs | Buccaneer standalone | 79118, 76031, 70214, 88270, 79118 | 0 |
| ws_echo_c100 | p99.9 µs | Bandit | 21919, 23972, 23037, 23037, 21919 | 0 |
