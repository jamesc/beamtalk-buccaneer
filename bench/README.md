# The release gate: `just bench` and `just stress`

Phase 7 (PLAN.md § Phase 7, BT-4086): does beamtalk-http on Buccaneer
match beamtalk-http on cowboy, and does Buccaneer hold up under load and
failure? Results are in [RESULTS.md](RESULTS.md). The harness is
Catalina's (its `bench/` and `test/stress/`, BT-4051) with an HTTP load
generator added. Phase 0's spike bench is [SPIKE.md](SPIKE.md)
(`just spike-bench`).

```bash
just bench                               # 5 rounds x 5 s, every row, four servers
just bench --rounds 7 --duration 10000   # longer
just bench --only get_c10,tls_get_c100   # some rows
just bench --impls http_buccaneer,http_cowboy
just bench-smoke                         # 1 round x 1 s on the smoke rows (CI)
just stress                              # every stress test, full sizes, 30-minute soak
just stress --soak-minutes 5 --only soak
just stress --impls buccaneer --only lifecycle
just stress-smoke                        # smoke sizes, 1-minute soak (CI)
just bench-profile --impl buccaneer --row get_c10   # call-time profile of one row
```

Neither is part of `just test`; CI runs `bench-smoke` and `stress-smoke`
as non-blocking steps. Both need `beamtalk`, Erlang/OTP 28 and Elixir
1.18 or later (`bench/bandit/.tool-versions` pins 1.20.1 on OTP 28.5) on
the `PATH`, network access on the first run, and about 20,000 file
descriptors (`ulimit -n`) for the 10,000-connection row. With a source
build of beamtalk whose stdlib is built elsewhere, set
`BEAMTALK_RUNTIME_DIR` as for `beamtalk test`.

`bench/run.sh` builds everything, then runs one Erlang entry module
(`bench_main`, `stress_main` or `bench_profile`). Reports go to
`_build/bench/report-*.md`, one JSON line per measurement to
`_build/bench/raw-*.jsonl`; stress server logs to `_build/stress/`.

## The servers

Each runs in its own peer VM (OTP `peer`, standard_io control channel)
for the whole run; the load generator runs in the calling VM, so clients
and servers never share schedulers.

| Name | What | Role |
|---|---|---|
| `http_buccaneer` | beamtalk-http's `HTTPServer start:handler:options:` with `#backend => #buccaneer` | the gate |
| `http_cowboy` | the same, `#backend => #cowboy` (cowboy 2.20 with ranch defaults, as beamtalk-http starts it: 10 acceptors, `max_keepalive` 1,000) | the gate's baseline |
| `buccaneer` | Buccaneer standalone: `Buccaneer start:handler:` with an `Exchange` handler serving the same routes | context: the adapter's cost is the difference |
| `bandit` | Bandit 1.12.5 with a bare Plug (`bench/bandit`) | context |

The three Beamtalk servers come from one package, `bench/http_node`
(`HttpNode`). beamtalk-http is pinned by commit in `bench/run.sh`
(`HTTP_REV`, main d644c20, the same code for both backends, so the gate
compares the backends and nothing else). beamtalk-http pins Buccaneer by
git rev and a path dependency does not override a transitive one, so
`run.sh` clones beamtalk-http into `_build/bench/beamtalk-http` and points
its `buccaneer` dependency at this checkout: the gate always measures the
Buccaneer you have.

Routes, the same on every server: `/` answers `hello world`
(`text/plain`); `POST /echo` the request body; `/chunked` 1 MiB as 16
chunks of 64 KiB; `/file` a 1 MiB file (`HTTPResponse file:`, Bandit's
`send_file`); `/slow` `hello world` after a second; `/ws` a WebSocket
echo. beamtalk-http's cowboy backend cannot stream or send files (it
raises `unsupported_backend`), so on cowboy `/chunked` and `/file` answer
the same 1 MiB as a plain body: that is how a cowboy-backed app serves it
today.

TLS: `HTTPServer` has no TLS option on either backend. The TLS rows run
beamtalk-http's request path behind each backend's TLS listener: on
Buccaneer, `Buccaneer start:` with `#scheme => #https` and
`HttpExchangeAdapter serve:handler:` (what `HTTPBuccaneerServer` runs);
on cowboy, `cowboy:start_tls` with beamtalk-http's
`beamtalk_http_server_handler` (what `beamtalk_http_server` runs on its
clear listener). Both use `test/fixtures/{cert,key}.pem`.

## The load generator

Closed loop (`bench/harness/bench_load.erl`): each worker sends one
request and reads the whole answer before the next, recording latency
into a shared lock-free histogram (`hb_hist`, 1% buckets). Every answer is
checked (status 200 and, where the row says, the body size), and a bad
one is an error. Requests send no `accept-encoding`, so Buccaneer's
response compression (on by default since BT-4093) stays off and every
server sends the same bytes. A `connection: close` response (cowboy closes a
keep-alive connection after `max_keepalive`, 1,000 requests) is counted
and the worker reconnects; the reconnect lands in that request's latency.

Clients: `bench_http` (HTTP/1.1: content-length and chunked bodies,
pipelining-safe buffering), `bench_conn` (TCP or TLS), `bench_h2` (a
minimal prior-knowledge h2c client: static HPACK, any number of streams
in flight, window management) and `bench_ws` (WebSocket upgrade, masked
frames).

## Rows

| Row | Load | Gate? |
|---|---|---|
| `get_c1` ... `get_c1000` | keep-alive `GET /` at 1, 10, 100, 1,000 connections | gate |
| `post_echo_64KiB_c10` | `POST /echo`, 64 KiB body, 10 connections | gate |
| `chunked_1MiB_c10` | `GET /chunked`, 10 connections | gate |
| `file_1MiB_c10` | `GET /file`, 10 connections | gate |
| `churn_close_w32` | a new connection per request (`connection: close`), 32 workers | gate |
| `tls_handshake_w32` | the same over TLS: a full handshake per request | gate |
| `tls_get_c100` | keep-alive `GET /` over TLS, 100 connections | gate |
| `idle_10k` | 10,000 idle keep-alive connections (one GET each): node and process memory and processes per connection | reported |
| `h2_get_10x10` | HTTP/2 `GET /`, 10 connections x 10 streams in flight | context (not cowboy) |
| `ws_echo_c100` | WebSocket echo, 64-byte text, 100 connections | context (not cowboy) |

Every round measures every row once per server, back to back, rotating
which server goes first, and each measurement starts a fresh server. The
report gives every round, the medians, each side's spread (min-max over
the rounds) and the ratios against cowboy and Bandit.

**The gate rule**, per gate row, for requests/s and p99: beamtalk-http
on Buccaneer misses when its median is worse than cowboy's worst round
(below cowboy's lowest requests/s, above cowboy's highest p99), that is,
worse beyond the rounds' spread. A row with errors misses.

## Stress tests (`test/stress/`)

Each test runs against beamtalk-http on Buccaneer and/or Buccaneer
standalone, and where the expectation is "as the incumbent does", against
cowboy or Bandit with the same assertions, so a test that fails only on
Buccaneer is a Buccaneer bug.

| Test | Checks |
|---|---|
| `fuzz_pipelined_requests` | pipelined batches of random GETs, content-length POSTs and chunked POSTs (random chunk sizes and extensions, random header case), sent in random splits with random pauses; every response checked byte for byte; back to baseline |
| `fuzz_malformed_requests` | malformed request lines, headers, lengths and chunk sizes are rejected (4xx, or 505) or closed; still serving; back to baseline |
| `leak_churn` | thousands of connections ending every way (close, reset after a response, no data, reset mid-head, reset mid-body): processes, ports, ETS back to baseline, ETS rows flat |
| `leak_keepalive` | one connection, thousands of requests: the connection process's dictionary and memory stay flat |
| `slowloris_drip` | clients dripping a byte every 200 ms through the request line, headers and body are served in the end, while ordinary clients stay prompt (p99 under 1 s) |
| `slowloris_stall` | clients stalling in the request line or headers are closed at the read timeout (3 s here), in the body at the body read timeout (15 s) |
| `limits_max_requests` | `#http1 #maxRequests` closes after that many, the last response saying `connection: close` |
| `limits_headers` | too many headers or a too-long header is a 431, a too-long request line a 414 (Bandit's answers; defaults on beamtalk-http too) |
| `limits_num_connections` | `#catalina #numConnections` holds a new connection unserved until one closes |
| `chaos_kill_connections` | connection processes killed every 50 ms under load: clients see only closed sockets, never a wrong answer; back to baseline |
| `chaos_kill_streams` | HTTP/2 stream processes killed every 20 ms: the stream is reset or answered 500, the connection carries on; back to baseline |
| `lifecycle_suspend_resume` | while suspended, open connections are served and new ones are not; after resume, new ones are served on the same port |
| `lifecycle_stop_drains` | requests in flight at stop all complete, and stop returns once they are done |
| `lifecycle_stop_deadline` | with `#shutdownTimeout` 300 ms, stop returns at about the deadline and cuts the requests off |
| `soak_mixed_load` | beamtalk-http on Buccaneer for 30 minutes under HTTP/1.1 (keep-alive and churn), TLS (keep-alive and churn), HTTP/2, WebSocket and idle connections; no errors or corrupt bytes, no process or memory-floor growth, back to baseline |

Conformance runs separately: `just h2spec` and `just autobahn` (CI jobs,
non-blocking until green).

## Caveats

- The machine is usually shared. RESULTS.md records the load average at
  every round; read ratios within the rounds' spread. `--max-load L`
  waits (up to 30 minutes) for a quieter machine before each round.
- The response heads differ a little: cowboy adds `server`, Bandit
  `cache-control` and `vary`; all send `date`.
- cowboy closes a keep-alive connection every 1,000 requests; Buccaneer
  and Bandit do not by default.
