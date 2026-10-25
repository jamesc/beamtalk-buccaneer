# Phase 0 spikes

Throwaway checks of the assumptions in [PLAN.md](../PLAN.md) § Phase 0
(BT-4079). Each spike is a BUnit test, and the classes it drives live in
one of two nested packages — `engine_spikes/` (spikes 1-4) or
`http2_streams/` (spikes 5 and 6, which needs a throwaway native module) —
so they compile in package mode, as the shipped library does, and never
ship. (Test-fixture mode miscompiles sealed self-sends on the current
toolchain, BT-4152; package mode is also the more realistic vehicle.)
None of it is library code; the phases rewrite all of it, except
`exchange_state_spike_test.bt`'s leak test, which Phase 1 keeps as a
regression test.

```bash
just spikes                                    # every spike (both packages), then the numbers
beamtalk test spikes/engine_spikes/test/exchange_state_spike_test.bt
just spike-bench                               # spike 1's three-way HTTP bench (bench/README.md)
(cd bench/bandit && elixir ../../spikes/codec_baseline.exs)   # spike 4's Elixir baseline
```

The spikes are kept out of `just test` because they use loopback sockets and
wall-clock timing. CI runs `just spikes` (the tests must pass; the numbers
are informational) and a one-round `just spike-bench --rows smoke`
(non-blocking).

Toolchain: beamtalk 0.4.0 built from main at dc216bf52 (BT-4065, BT-4069
and BT-4071 not merged), catalina 5ecc9ab (spike 1 rerun and the final
spike run: main 41c7f6ff6 with BT-4065, catalina c06db66), OTP 28.5, Elixir 1.20.1, macOS
on an Apple M5 Max. Rerun 2026-10-25: beamtalk main 9b6ce88eb (BT-4065,
BT-4069, BT-4071, BT-4096/4097/4098, BT-4099, BT-4101 and BT-4105/4106/4107
all merged), catalina 37b1892 (docs-only since c06db66), same machine. The
machine is shared: load averages during the runs were 2 to 209 (recorded
with each number below), so treat the absolute numbers as indicative and
the ratios as the result.

## Results

| # | Assumption | Result | Spike |
|---|---|---|---|
| 1 | Parsing with `erlang:decode_packet` through the FFI keeps Buccaneer's per-request cost near cowboy's | **Holds on the current toolchain** (failed on the original one, for a reason that was not the parser: every request made 5 synchronous calls into node-wide class processes, 0.29-0.62× cowboy's req/s). With BT-4065, BT-4069 and BT-4099 merged, a request makes no class-process calls, the Beamtalk parse is 1.44× Erlang's (3.3 µs), and the spike server does 1.09-1.24× cowboy's req/s at 1-1,000 connections, at parity with Bandit. Decision: keep `decode_packet`. | `parse_cost_spike_test.bt`, `bench/` |
| 2 | Owner-process exchange state keyed by a `Reference`, with no leak across keep-alive requests | **Holds.** 10,000 sequential requests on one connection (plain, body read, body left unread, chunked response ended early, handler writing its own process-dictionary key): no request saw its predecessor's state, the process dictionary was 5 keys after every request, no exchange state survived, and the heap after a full collection never grew. A non-owner call raises `NotOwner`; a raise before or during the response closes the connection, as Bandit, and still erases the state. A handle read costs 0.6-0.7 µs against 0.12 µs for a plain Value field. Two amendments: Bandit's `clear_process_dict` keep-list would delete the runtime's own keys, and a Value's sends cannot answer Nil. | `exchange_state_spike_test.bt` |
| 3 | The whole request runs inside `handleData:`: a blocking body `recv`, a handler calling an actor, pipelined requests served from the buffer | **Holds.** The socket is `{active, false}` inside the callback, so `Socket recv:timeout:` reads the rest of a body sent in pauses; a handler's sync call to an actor works; three requests in one packet are answered from one `handleData:` call. | `blocking_work_spike_test.bt` |
| 4 | Binary patterns in `match:` decode HTTP/2, WebSocket and HPACK; iodata builds frames | **Holds, with four language gaps worked around** (BT-4096, BT-4097). Decoding is 2-8× Elixir per operation (most of it the call and loop overhead), building a frame header as a list of bytes 40×, but each is under 0.7 µs. | `byte_codecs_spike_test.bt` |
| 5 | HTTP/2 stream processes can wait on the connection through a deferred reply (BT-4090's shape) | **Holds.** With only "park the caller" in a throwaway native gen_server, everything else in Beamtalk (tokens in a Dictionary, `gen_server:reply` through the FFI from `handleInfo:`): out-of-order answers, a flow-controlled send released by window updates, expiry, late and dead callers, stop. A parked-then-answered call costs about 2× a plain sync call. | `http2_streams/test/deferred_reply_spike_test.bt` |
| 6 | Stream processes monitored instead of linked | **Holds, with one design rule.** `DOWN` in `handleInfo:` resets abnormal streams and forgets normal ones; `terminate:` kills the rest; a stream learns of a dead connection from its next call (`#actor_dead`). Monitor and link cost the same. Lost against links: a `kill` of the connection leaves its streams running until their next call. Rule: spawn the stream idle, monitor it, then start it (there is no atomic spawn-monitor, BT-4104). | `http2_streams/test/stream_monitor_spike_test.bt` |

## Spike 1: parse cost and the three-way bench

In the VM (`parse_cost_spike_test.bt`, 20,000 parses of a 7-header GET, 251
bytes):

| Measure | ns per request head |
|---|---:|
| `SpikeParser readHead:socket:` (Beamtalk, `decode_packet` per line) | 9,958-13,309 (7,083 on 41c7f6ff6; 3,278-3,667 on 9b6ce88eb) |
| One bare `Erlang erlang decode_packet:` FFI call | 180-203 (160-198 on 9b6ce88eb) |
| Erlang `decode_packet` to `http_eoh` with lowercased names (bench) | 2,280 (2,272 on 9b6ce88eb) |

End to end (`bench/README.md` has the method, caveats and per-round data):
keep-alive `GET /` answering `hello world`, 5 interleaved rounds × 5 s,
2026-10-21 20:47-20:55 UTC, 1-minute load 11-35. Medians:

| Connections | Buccaneer spike req/s | cowboy (gate) | Bandit | spike / cowboy | spike p99 / cowboy p99 |
|---:|---:|---:|---:|---:|---:|
| 1 | 11,751 | 18,818 | 21,152 | 0.62 | 1.40 |
| 10 | 42,010 | 68,567 | 100,602 | 0.61 | 1.58 |
| 100 | 29,990 | 67,599 | 140,310 | 0.44 | 3.24 |
| 1,000 | 19,369 | 67,529 | 144,614 | 0.29 | 8.08 |

The spike's throughput falls as connections go up while cowboy's stays flat:
the five class-process calls per request queue every connection in the node
on the same five processes (`sys:statistics` on the class processes,
`just spike-bench --profile`). The rest of a request is method lookup
through the class chain (16% of stacks) and the socket calls (9%).

**Rerun on beamtalk main 41c7f6ff6** (BT-4065 merged; catalina c06db66),
2026-10-21 21:26-21:33 UTC, 1-minute load 48-209 (the machine was very
busy; rounds varied up to 10× for every server, so these medians are
indicative only):

| Connections | Buccaneer spike req/s | cowboy | Bandit | spike / cowboy |
|---:|---:|---:|---:|---:|
| 1 | 983 | 6,193 | 958 | 0.16 |
| 10 | 6,987 | 8,883 | 10,788 | 0.79 |
| 100 | 40,983 | 52,247 | 114,444 | 0.78 |
| 1,000 | 25,739 | 38,931 | 130,779 | 0.66 |

Class-process calls per request fell from 5 to 2 (`SpikeRequest` and
`ExchangeState` keyword constructors, BT-4099); the Beamtalk parse fell to
7.4 µs (2.8× Erlang's 2.6 µs), and a `Result ok:` to 0.59 µs. Under a
10-connection load 66% of request stacks are still in `gen:do_call` on
those two constructors, so BT-4099 is the next fix that matters.

**Rerun on beamtalk main 9b6ce88eb** (BT-4069 and BT-4099 merged;
catalina 37b1892), 2026-10-25 16:11-16:19 UTC, 1-minute load 1.6-30.9
(drifting up through the run; per-round values stayed tight):

| Connections | Buccaneer spike req/s | cowboy | Bandit | spike / cowboy | spike / Bandit |
|---:|---:|---:|---:|---:|---:|
| 1 | 28,845 | 25,038 | 29,518 | 1.15 | 0.98 |
| 10 | 111,255 | 100,302 | 111,164 | 1.11 | 1.00 |
| 100 | 142,323 | 130,677 | 142,952 | 1.09 | 1.00 |
| 1,000 | 147,867 | 118,929 | 149,117 | 1.24 | 0.99 |

Class-process calls per request are now zero; the high-concurrency
collapse is gone, and the spike sits at parity with Bandit and just above
cowboy on throughput at every row. p99 is at parity with cowboy
(0.90-1.01×); p99.9 still trails slightly at 100+ connections (1.12-1.18×).
The Beamtalk parse is 3.3 µs, 1.44× Erlang's 2.3 µs. Request time is now
in the socket calls and FFI coercion (`apply_with_coercion` on 57% of
sampled request stacks, BT-4153); the parse, in the header lowercase and
the remaining dynamic sends. `bench/README.md` has the method and the
full per-round data.

## Spike 2: the exchange state model

`SpikeExchange` (a sealed Value: `ref`, `owner`) keeps an `ExchangeState` in
the owner's process dictionary under `{buccaneer_exchange, Ref}`;
`SpikeHandler` runs Bandit's keep-alive loop around it.

| Measure | Value |
|---|---|
| Requests on one connection | 10,000, 5 variants rotating, every one answered `ok <id>` (no `LEAK`) |
| Process-dictionary keys after every request | 5: `$initial_call`, `$ancestors`, `$process_label`, `$beamtalk_actor`, `$bt_actor_state` |
| Exchange states left after every request | 0 |
| Heap after a full collection (words) | always one of 987, 1,598 (and 2,586 on the older toolchain; 610, 987, 1,598 on 9b6ce88eb); the maximum over requests 11-1,010 equals the maximum over the last 1,000 |
| Time per request (client in the same VM, GC and probe every request) | 520-758 µs (load 133-165); 173 µs on 41c7f6ff6 (load ~70); 54 µs on 9b6ce88eb (load ~2) |
| `ex method` (owner check, `get`, field) | 620-732 ns (165-179 on 9b6ce88eb) |
| `ex store: ex load` | 597-620 ns (178-213 on 9b6ce88eb) |
| A plain Value field read | 120-125 ns (32-46 on 9b6ce88eb) |

Findings:

- **The runtime keeps actor state in the process dictionary**
  (`$beamtalk_actor`, `$bt_actor_state`). Bandit's `clear_process_dict`
  keeps only `$ancestors`, `$initial_call` and `$process_label`; ported as
  is, it would delete the handler's own state. The spike snapshots the keys
  present at `handleConnection:` and, between requests, erases every other
  key except Catalina's telemetry marker (`{catalina_exception_emitted, _}`)
  and Buccaneer's connection keys (`{buccaneer_connection, _}`). Phase 1
  keeps that rule.
- **Raising requests cannot share a keep-alive connection** with the
  10,000: Bandit closes after any handler raise (`Pipeline.handle_error`
  answers `{:error, _}`, the handler `{:close, state}`). The raise cases are
  `testRaiseClosesAndForgetsTheExchange`: before anything was sent (500
  with `connection: close`, then closed) and mid-response (head and chunk,
  no closing chunk, closed); both leave no exchange state.
- **`#not_owner` is an `Error` subclass** (`NotOwner`), because
  `Exception signalKind:` only takes the runtime's closed `ExceptionKind`
  set. The message starts `not_owner:` and names both processes.
- **Value methods cannot answer Nil**: `sendResp:...` declared `-> Nil` on a
  Value is ADR 0042's "side-effecting void method" warning, an error under
  `--warnings-as-errors`. The sends answer the exchange instead.
- **`size` is not a byte count.** Socket data that is valid UTF-8 is a
  `String`, and `String size` counts grapheme clusters (CR LF is one). Every
  length in the engine is `byteSize`; `part:size:` and `concat:` are
  byte-level.

## Spike 3: blocking work in `handleData:`

All three cases hold (`blocking_work_spike_test.bt`): a 10,000-byte body
sent as the head plus 100 bytes, then four parts 20 ms apart, read with
blocking `recv` in one `handleData:` call; 100 requests each calling a
`SpikeCounter` actor; three pipelined GETs answered from one `handleData:`
call. Nothing here needs Catalina or Beamtalk changes. Rerun on
9b6ce88eb: still 3/3, unchanged.

## Spike 4: byte codecs

`FrameCodec` (100,000 operations each, after a warm-up; the Beamtalk loop
alone costs 34-37 ns). Elixir: `spikes/codec_baseline.exs`, the same
operations as Bandit and HPAX write them.

| Operation | Beamtalk ns | Elixir ns | Beamtalk ns, rerun 9b6ce88eb | Elixir ns, rerun |
|---|---:|---:|---:|---:|
| HTTP/2 frame header (`<<len:24, type:8, flags:8, _r:1, sid:31, rest/binary>>`) | 40-61 | 11-18 | 38 | 9 |
| HTTP/2 header and payload (two matches; one in Elixir) | 50-84 | 15-25 | 46 | 11 |
| WebSocket masked frame, header to unmasked payload | 496-691 | 77-93 | 398 | 54 |
| HPACK integer, 5-bit prefix, 2 continuation bytes | 131-162 | 17-20 | 111 | 12 |
| HTTP/2 frame header as iodata (9 bytes computed with `bitShift:`/`bitAnd:`) | 237-277 | 6-7 | 204 | 4 |
| the same, as a binary (`iolist_to_binary`) | 406-481 | 28-33 | 346 | 22 |
| HPACK integer encode (1337, 5-bit prefix) | 154-174 | 9-12 | 132 | 7 |
| Unmask 64 KiB (`crypto:exor`), µs | 256-571 | 92-97 | 233 | 76 |

Gaps found (each worked around in `frame_codec.bt`):

- a segment size bound by an earlier segment (`<<n:8, payload:n/binary>>`)
  compiles to a field read and invalid Core Erlang (BT-4096): match the
  header, then the payload in a second `match:` with the size in a
  parameter;
- no `bits`/`bitstring` segments, no literal segment values
  (`<<0:1, v:7>>`), no size expressions, and a variable used only as a size
  is reported unused (BT-4097): skip flag bits inside the byte, bind and
  guard, compute sizes into locals, mention the size in a guard;
- two `_` wildcards in one pattern do not compile (BT-4098): name them.

Without bitstrings, HPACK's Huffman decoder (Phase 5) is a byte- or
nibble-at-a-time table decoder, not hpax's bit-at-a-time one. Frame
construction through lists of byte integers costs 0.2-0.5 µs per frame
header; Phase 6 keeps it unless the HTTP/2 rows of Phase 7 show it.

## Spike 5: deferred reply (BT-4090's shape)

`DeferredConn` is a native-backed actor (ADR 0056) whose gen_server only
answers `{noreply, ...}` and hands `From` to `ConnLogic`, a Beamtalk Value.
`ConnLogic` keeps `ReplyTo` tokens in a Dictionary by stream id and answers
them with `gen_server:reply` through the FFI from ordinary methods,
including the ones `handleInfo:` reaches.

| Call (10,000) | µs per call |
|---|---:|
| Native gen_server, direct `{reply, ...}` | 2.6-5.5 (2.45 on 9b6ce88eb) |
| Parked, then answered from Beamtalk through `gen_server:reply` | 5.3-14 (6.7 in the last run; 2.58 on 9b6ce88eb — now at parity with a plain call) |
| Plain Beamtalk actor sync call | 2.6-4.6 (2.48 on 9b6ce88eb) |
| 100 streams parked, answered in reverse order, per stream end to end | 36-170 (31.7 on 9b6ce88eb) |

Input for BT-4090's spec:

1. The token is a plain Value around OTP's `From` (`{Pid, Tag}`), storable
   anywhere; typed `Tuple`, it type-checks against `gen_server:reply/2`.
2. Replies must have the shape `beamtalk_actor:sync_send/3` unwraps:
   `{ok, V}` for a value, `{error, E}` for an error. `E` can be a caught
   Beamtalk exception; the caller sees that exception raised.
3. A late reply to a caller that timed out, or died, is harmless (OTP calls
   through a process alias).
4. When the server stops, parked callers fail with `#actor_dead`; its
   message says "Cannot send 'readData:' to unknown": the class name is
   lost once the process is dead.
5. Per-call timeouts work through `withTimeout:`; expiring parked sends (15
   s in Bandit) needs only a timer message and a tag, in Beamtalk.
6. All BT-4090 needs is `self deferReply -> ReplyTo` inside a sync method
   and "the method's answer is then ignored"; `reply:` and `replyError:`
   can be plain Beamtalk over `gen_server:reply`.
7. Building the `ReplyTo` Value was a class-process call (BT-4099, now
   merged: construction is direct, which is why a parked-then-answered
   call costs the same as a plain one on the rerun).

## Spike 6: monitors instead of links

`MonitoringConn` starts `StreamProc`s unlinked and monitors them (5,000
streams, best of 3 interleaved rounds, each with a `finish!` cast):

| Per stream | µs |
|---|---:|
| spawn only | 17-24 (12.0 on 9b6ce88eb) |
| spawn + `monitor` | 38-56 (31.4 on 9b6ce88eb) |
| spawn + `erlang:link` | 40-54 (31.8 on 9b6ce88eb) |
| one queued `DOWN` handled in `handleInfo:` | 0.47-0.66 (0.34 on 9b6ce88eb) |

- An abnormal `DOWN` resets that stream (recorded as `{sid, reason}`); the
  connection and its other streams carry on. A normal exit is forgotten.
- `stop`, and a crash from a cast (ADR 0134), run `terminate:`, which kills
  the remaining streams. Overriding `terminate:` makes the connection trap
  exits; harmless, since nothing is linked.
- **Lost against Bandit's links:** a `kill` of the connection skips
  `terminate:`; its streams keep running until their next call to it fails
  with `#actor_dead` (pinned by a test).
- **Rule for Phase 6:** an actor has no atomic spawn-and-monitor. A stream
  that finished before the connection called `monitor` came back as
  `DOWN noproc` and was counted as a reset. Spawn the stream idle, monitor
  it, then cast it `run` (BT-4104).

## Bugs and gaps filed

All under BT-3957, linked to BT-4079.

| Issue | What | Spike |
|---|---|---|
| BT-4094 | A test class calling a dependency's class method (`Catalina start:`) compiles to the wrong module; a package class works (`SpikeServer` wraps it) | 2, 3 |
| BT-4096 | Binary pattern: a size bound by an earlier segment compiles to invalid Core Erlang | 4 |
| BT-4097 | Binary patterns: no bitstring segments, literal segment values or size expressions; a size-only variable reported unused | 4 |
| BT-4098 | Two `_` wildcards in one pattern produce invalid Core Erlang | 1, 4 |
| BT-4099 | Value construction (`Pt x: 1 y: 2`, `Pt new`) is a call into the class process, even for a sealed Value | 1, 5 |
| BT-4100 | No `\r`/`\n` escapes in string literals | 1-3 |
| BT-4101 | FFI arity check rejects `erlang:integer_to_binary/2` | 2 |
| BT-4102 | Block literal parameter types not inferred from a return type or a collection literal; `[:x :: T | ...]` annotations discarded | 1-3 |
| BT-4104 | No atomic spawn-and-monitor (or link) for an actor | 6 |
| BT-4105 | `beamtalk build` silently skips symlinked `.bt` files | 1 (bench) |
| BT-4106 | `tprof` and `eprof` fail in a Beamtalk node | 1 (bench) |
| BT-4107 | `(a isNil or: [b isNil]) ifTrue: [^nil]` does not narrow | 5 |
| BT-4152 | `typed_sealed` direct dispatch targets a nonexistent qualified module for `beamtalk test` fixtures (spikes 1-4 moved to the `engine_spikes` package) | 1-3 (rerun) |
| BT-4153 | FFI call path is heavy: `apply_with_coercion` + result coercion dominate request profiles (child of BT-4112) | 1 (rerun) |

Already filed and confirmed by the spikes: BT-4065 (class references,
`Result ok:`; merged during Phase 0), BT-4090 (deferred reply), BT-4052
(trapping Server and linked exits). Merged since the original runs:
BT-4069, BT-4071, BT-4096, BT-4097, BT-4098, BT-4099, BT-4101, BT-4105,
BT-4106, BT-4107.

## Idioms the spikes settled

- A `match:` arm that does more than one thing calls a method; recursion
  (as Bandit's `do_read_headers!`) keeps parsers typed, where a step tuple
  read back with `at:` is `Dynamic` everywhere.
- FFI results are `Dynamic` in a typed class: annotate the local
  (`keys :: List(Object) := Erlang erlang get_keys`) or match with a type
  pattern (`b :: String -> b`, an `is_binary` test, also for non-UTF-8
  data).
- Pass a handler block straight to a method whose parameter is typed
  `Block(SpikeExchange, Object)`; written in a Dictionary literal its
  parameter is `Dynamic` (BT-4102).
- Bytes: `byteSize`, `part:size:`, `concat:`; never `size` or `++` on wire
  data.
- `Exception signalKind:` is closed; a domain error is an `Error`
  subclass.
