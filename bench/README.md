# Spike 1 bench: HTTP/1 keep-alive GET

Phase 0 spike 1 (PLAN.md § Phase 0, BT-4079): what a request costs when
Buccaneer parses HTTP/1 with `erlang:decode_packet` through the FFI on
Catalina, against the release gate's baseline (beamtalk-http 0.1.10 on
cowboy) and Bandit 1.12.5 (context). Throwaway, like the rest of Phase 0;
Phase 7 builds the real harness.

```bash
just spike-bench                              # 5 rounds × 5 s, c = 1, 10, 100
just spike-bench --conns 1,10,100,1000 --profile
just spike-bench --rows smoke                 # 1 round × 1 s, c = 1, 10
just spike-bench --rounds 7 --duration 10000 --warmup 2000
```

It needs Elixir 1.18 or later (`bench/bandit/.tool-versions` pins 1.20.1 on
OTP 28.5) and `beamtalk` on the `PATH`. `bench/run.sh` builds everything
first, then runs `bench/harness/hb_main.erl`. Reports go to
`_build/bench/report-*.md`, one JSON line per measurement to
`_build/bench/raw-*.jsonl`.

## The servers

Each runs in its own peer VM (OTP `peer`, standard_io control channel), the
load generator in a third. All answer every request with `200`,
`content-type: text/plain` and `hello world`.

| Server | Package | Handler |
|---|---|---|
| Buccaneer spike | `bench/buccaneer_node` | Catalina (100 acceptors) running the spike's `SpikeHandler`: `SpikeParser` (`decode_packet` FFI), an owner-bound `SpikeExchange`, Bandit's keep-alive loop and process-dictionary clearing, GC every 5 requests. The spike classes are copied from `spikes/engine_spikes/src/` by `run.sh` (`beamtalk build` skips symlinked sources). |
| cowboy (the gate) | `bench/cowboy_node` | beamtalk-http 0.1.10 (`v0.1.10`, 3905b53) `HTTPServer start: 0 handler: [:req \| HTTPResponse new: ...]`; cowboy 2.18.0 with ranch defaults, as beamtalk-http starts it (10 acceptors, `max_keepalive` 1000). |
| Bandit (context) | `bench/bandit` | Bandit 1.12.5 with a bare Plug (`send_resp(conn, 200, "hello world")`), 100 acceptors. |

The load generator (`hb_load.erl`) is closed-loop: each of `c` connections
sends `GET / HTTP/1.1` with a `host` header and reads the whole response
(`decode_packet` for the head, then the content-length body) before the
next. Every round measures every row once per server, back to back, and
rotates which server goes first; the load average is recorded with every
measurement. The report gives medians over rounds and Buccaneer's ratios.

The parse microbenchmark runs in the Buccaneer node: the spike's 7-header
GET head (request line to `http_eoh`), in plain Erlang the way Bandit reads
it (`decode_packet` plus an ASCII lowercase of each header name) and through
`SpikeParser readHead:socket:`, plus one bare `decode_packet` call and one
`Result ok:` as generated code sends it.

`--profile` adds a sampling profile (tprof answers `badarg` and eprof
crashes in a Beamtalk node, so `hb_node` samples `current_stacktrace`) of
the parse and of the node under a 10-connection load, and the processes
with the longest message queues, and counts the calls a request makes into
Beamtalk class processes (`sys:statistics` on each `beamtalk_class_*`
process over 10,000 sequential requests).

## Caveats

- The response heads differ: cowboy adds `date` and `server`, Bandit `date`,
  `cache-control` and `vary`; the spike sends only `content-length` and
  `content-type` (no `Clock` yet). That favours the spike slightly.
- cowboy closes each connection after 1,000 requests (`max_keepalive`);
  the client reconnects and counts it (`server closes` in the log), the
  reconnect landing in that request's latency.
- The machine is shared and was heavily loaded; the load averages are in
  the report. Treat ratios as indicative within the rounds' spread.

## Results

Run 2026-10-21 20:47-20:55 UTC (`just spike-bench --conns 1,10,100,1000
--profile`): Apple M5 Max (18 cores, 64 GiB), macOS 25.6, OTP 28.5
(ERTS 16.4), Elixir 1.20.1, beamtalk 0.4.0 at main dc216bf52 (BT-4065 and
BT-4071 in review, BT-4069 in backlog: none of the three merged), catalina
main 5ecc9ab, cowboy 2.18.0. 5 rounds × 5 s after a 1 s warm-up. The
machine was shared: `uptime` load averages 13.79 / 24.88 / 25.90 before,
32.83 / 27.98 / 26.52 after; 1-minute load per measurement 11.4 to 35.4.

Medians over the 5 rounds. `B/cowboy` and `B/Bandit` are Buccaneer ÷ the
other (above 1 is better on req/s, worse on latency).

| Row | Metric | Buccaneer spike | cowboy | Bandit | B/cowboy | B/Bandit |
|---|---|---:|---:|---:|---:|---:|
| c = 1 | req/s | 11,751 | 18,818 | 21,152 | 0.62 | 0.56 |
| | p50 µs | 79 | 47 | 36 | 1.68 | 2.20 |
| | p99 µs | 181 | 129 | 124 | 1.40 | 1.46 |
| c = 10 | req/s | 42,010 | 68,567 | 100,602 | 0.61 | 0.42 |
| | p50 µs | 230 | 140 | 95 | 1.65 | 2.42 |
| | p99 µs | 422 | 267 | 187 | 1.58 | 2.26 |
| c = 100 | req/s | 29,990 | 67,599 | 140,310 | 0.44 | 0.21 |
| | p50 µs | 3,180 | 1,478 | 557 | 2.15 | 5.71 |
| | p99 µs | 6,319 | 1,953 | 2,739 | 3.24 | 2.31 |
| c = 1000 | req/s | 19,369 | 67,529 | 144,614 | 0.29 | 0.13 |
| | p50 µs | 44,426 | 14,722 | 5,552 | 3.02 | 8.00 |
| | p99 µs | 135,404 | 16,755 | 27,831 | 8.08 | 4.87 |

Per-round values and p99.9 are in the generated report. The spread is wide
(cowboy's c = 10 req/s ran 43,672 to 78,773 across rounds), but the
ordering held in every round of every row: Buccaneer below cowboy below
Bandit, except at c = 1 where cowboy and Bandit overlap.

**Parse microbenchmark** (the 7-header GET head, 20,000 parses per round,
medians):

| Parser | ns per request head |
|---|---:|
| Erlang: `decode_packet` to `http_eoh`, ASCII-lowercased names (Bandit's path) | 2,280 |
| Beamtalk `SpikeParser readHead:socket:` | 10,163 |
| One bare `decode_packet(http_bin, ...)` | 118 |
| One `Result ok:` as generated code sends it (a call into the `Result` class process) | 2,197 |

The Beamtalk parse is 4.5× the Erlang one, and the difference is not the
parse: a sampling profile of the loop has the parsing process in
`gen:do_call` (waiting on a class process) in 87% of its stacks. The parse
makes two synchronous class-process calls (`SpikeRequest method:...`, the
keyword constructor, and `Result ok:`), about 2.2 µs each uncontended.

**Calls into class processes per request** (`--profile`, 10,000 sequential
requests on one connection, `sys:statistics` on every `beamtalk_class_*`
process):

| per request | class process | from |
|---:|---|---|
| 2 | `Exception` | `[...] on: Exception do: [...]` in the pipeline |
| 1 | `Result` | `Result ok:` answering the parsed head |
| 1 | `SpikeRequest` | the keyword constructor |
| 1 | `ExchangeState` | the keyword constructor |

Each is a `gen_server:call` into a single process per class, shared by the
whole node (BT-4065). At c = 1 they add roughly 10 µs to a request (79 µs
p50 against cowboy's 47 µs). Under concurrency every connection queues on
the same five processes, which is why Buccaneer's throughput falls from
c = 10 to c = 1000 while cowboy's stays flat and Bandit's rises; the
handler sampling at c = 10 has 70% of in-request stacks in `gen:do_call`.
The rest of the request path showed up as method lookup through the class
chain (`beamtalk_dispatch:lookup_in_class_chain` / `walk_ancestors`, 16%
of stacks: every `Handler` callback and inherited self-send on the
subclass) and the socket port calls themselves (~9%).

## Rerun with BT-4065 merged

Run 2026-10-21 21:26-21:33 UTC with beamtalk main 41c7f6ff6 (BT-4065
merged; BT-4069, BT-4071 and BT-4099 not) and catalina c06db66, same
options. The machine was much busier (1-minute load 48-209 per
measurement) and every server's rounds varied up to 10×; the medians are
indicative only.

| Row | Buccaneer spike req/s | cowboy | Bandit | B/cowboy | B p99 / cowboy p99 |
|---|---:|---:|---:|---:|---:|
| c = 1 | 983 | 6,193 | 958 | 0.16 | 2.65 |
| c = 10 | 6,987 | 8,883 | 10,788 | 0.79 | 1.22 |
| c = 100 | 40,983 | 52,247 | 114,444 | 0.78 | 1.80 |
| c = 1000 | 25,739 | 38,931 | 130,779 | 0.66 | 3.91 |

Parse: Erlang 2,614 ns, Beamtalk 7,390 ns (2.8×, was 4.5×), one
`Result ok:` 589 ns (was 2,197). Class-process calls per request: 1 into
`SpikeRequest` and 1 into `ExchangeState` (the keyword constructors,
BT-4099), down from 5. Under a 10-connection load, 66% of in-request stacks
are still in `gen:do_call` on those two, and 92% of the parse loop's.

## Rerun with BT-4069 and BT-4099 merged

Run 2026-10-25 16:11-16:19 UTC with beamtalk main 9b6ce88eb and catalina
37b1892 (docs-only since c06db66; now tagged v0.1.0), same options. Load drifted up through
the run (`uptime` 1.63 / 5.95 / 10.35 before, 12.68 / 15.71 / 13.93
after; 1-minute load per measurement 1.63 to 30.86), but the per-round
values stayed tight — the c = 1000 spike rounds ran 147,618 to 150,839
req/s.

| Row | Buccaneer spike req/s | cowboy | Bandit | B/cowboy | B p99 / cowboy p99 |
|---|---:|---:|---:|---:|---:|
| c = 1 | 28,845 | 25,038 | 29,518 | 1.15 | 0.90 |
| c = 10 | 111,255 | 100,302 | 111,164 | 1.11 | 0.91 |
| c = 100 | 142,323 | 130,677 | 142,952 | 1.09 | 1.00 |
| c = 1000 | 147,867 | 118,929 | 149,117 | 1.24 | 1.01 |

The spike is at parity with Bandit on throughput (0.98-1.00×) and just
above cowboy (1.09-1.24×) at every row; p99 matches cowboy, and p50 beats
it. The high-concurrency collapse is gone with the class-process calls
(zero per request now, down from 5, then 2). Two things to watch: p99.9
still trails cowboy at c = 100+ (1.12-1.18×), and the spike keeps its
small structural favours from the caveats above (no `date` header yet).

Parse: Erlang 2,272 ns, Beamtalk 3,280 ns (1.44×, was 2.8×), one bare
`decode_packet` 125 ns. (The `Result ok:` microbenchmark row still drives
the pre-BT-4065 `class_send` path on purpose, as a reference; generated
code no longer takes it.) Request time is now in the socket calls
(`setopts` rearm 45% of sampled stacks, `send` 12%) and FFI coercion
(`apply_with_coercion` 57%, BT-4153); no `gen:do_call`, and the longest
sampled message queues held 1 message. The parse loop's time is the
header lowercase (~24%) and the remaining dynamic sends (~16%
`beamtalk_message_dispatch:send/3`, the open-typed ones BT-4069 leaves
for BT-4118).


## Rerun after BT-4172 (no-sniff boundary conversion)

beamtalk 43b26151a (BT-4070, BT-4200 merged), buccaneer 77e87a4,
2026-10-26, c = 1, 10, 100, 1000, 5 rounds. Load climbed from 7 to 150
during the run, so the req/s rounds vary up to 10×; treat the ratios as
indicative.

| Row | Buccaneer req/s | cowboy | Bandit | B/cowboy | B/Bandit |
|---|---:|---:|---:|---:|---:|
| c = 1 | 3,699 | 3,643 | 2,706 | 1.02 | 1.37 |
| c = 10 | 76,360 | 35,056 | 63,650 | 2.18 | 1.20 |
| c = 100 | 132,596 | 120,672 | 137,792 | 1.10 | 0.96 |
| c = 1000 | 138,962 | 109,002 | 133,838 | 1.28 | 1.04 |

Throughput still clears the gate, but the **parse regressed 7×**: Erlang
2,318 ns, Beamtalk 23,116 ns (10×, was 1.44×); a smoke rerun gave 20,304
ns (10.1×). Class-process calls per request are still ~0. The cause is
the BT-4172 migration (0da78e5): `SpikeParser` now runs
`stringOrOpaque:` and an `isKindOf: String` guard on every request-line
token and header, and `isKindOf:` on a built-in class costs ~500 ns
(four registry/cache lookups, `objectIsKindOf/2`), 20× a `:: String`
type pattern (BT-4221). The pattern is not a drop-in meanwhile: it
matches invalid-UTF-8 binaries that `isKindOf: String` rejects
(BT-4222). `HTTP1Socket` has the same shape, so Phase 1 inherits the
cost until BT-4221 lands.
