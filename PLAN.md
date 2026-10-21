# Buccaneer porting plan

Buccaneer is a port of [Bandit](https://github.com/mtrudel/bandit) (v1.12.5)
to Beamtalk: an HTTP/1.1, WebSocket and HTTP/2 server engine on top of
[Catalina](https://github.com/jamesc/beamtalk-catalina), the Beamtalk port of
Thousand Island. Its first consumer is
[beamtalk-http](https://github.com/jamesc/beamtalk-http), whose `HTTPServer`
runs on cowboy today; Buccaneer replaces cowboy there.

**Status: draft for review.** Nothing here is implemented. Every phase issue
is `needs-spec` until this plan is approved.

## Goals

- Bandit's process model and HTTP semantics: one Catalina handler process per
  connection, the HTTP/1 request handled inside that process, one process per
  HTTP/2 stream, WebSocket on the upgraded connection's process, Bandit's
  option names (camelCased) and defaults, its error statuses and its
  telemetry events.
- A small, low-level **engine interface** (the role of Bandit's
  `Plug.Conn.Adapter` callbacks) that beamtalk-http adapts onto
  `HTTPRequest`/`HTTPResponse`, and that is also usable on its own.
  [`docs/engine-interface.md`](docs/engine-interface.md) is the draft ADR.
- beamtalk-http's existing server and router tests pass **unchanged** on
  Buccaneer before cowboy is removed.
- Pure Beamtalk, as Catalina is: no `native/*.erl`. OTP is reached through
  `Erlang` FFI and stdlib facades. Where the language cannot express
  something Bandit needs, the gap is filed against Beamtalk, as Catalina did
  under BT-3957, not hidden in a native module.
- Measured against Bandit **and** against beamtalk-http-on-cowboy before
  cowboy goes.

## Non-goals (for 1.0)

- Plug. Buccaneer has no `Plug.Conn`; the engine interface is its own
  (see the ADR). Plug's helpers that Bandit leans on (query parsing, status
  reason phrases, `Plug.Exception.status/1`) are reimplemented minimally
  where the engine needs them, and otherwise belong in beamtalk-http.
- `Bandit.PhoenixAdapter` (116 lines), `Bandit.Trace` (150 lines; a
  debugging aid, revisit after 1.0), HTTP/2 server push (Bandit answers
  `{:error, :not_supported}` too), h2c upgrade (Bandit does not support it
  either), HTTP/3.
- The HTTP client. A Mint-style client replacing gun is a separate, later
  epic ("Pure-Beamtalk HTTP client (Mint port) under beamtalk-http"). It
  shares the HPACK package designed here.

## Layering and dependency direction

```
app ──► beamtalk-http   HTTPServer, HTTPRouter, Plug, PlugChain, HTTPRequest, HTTPResponse, HTTPClient
          │
          ├─ adapter (beamtalk-http, src/server/): Exchange ⇄ HTTPRequest/HTTPResponse
          ▼
        buccaneer       engine: HTTP/1.1, WebSocket, HTTP/2; the Exchange interface
          │       └──► beamtalk-hpack (HPACK, shared with the future HTTP client)
          ▼
        catalina        listener, acceptors, connection handlers, transports
```

- beamtalk-http depends on buccaneer. Buccaneer never imports beamtalk-http
  and never names `HTTPRequest`, `HTTPResponse` or `HTTPRouter`.
- Buccaneer depends on catalina only through catalina's README § Public API
  (pinned by catalina's `SurfaceTest`). Anything else is internal.
- HPACK is its own package (`beamtalk-hpack`, Phase 5) so the future HTTP
  client can depend on it without depending on a server.
- Until Phase 8, beamtalk-http carries both backends and can switch between
  them, so the switch is reversible.

## Decision: the engine interface is an owner-bound `Exchange` handle

Bandit's `Plug.Conn.Adapter` is a struct that every callback returns
updated, and the plug threads it back. In Beamtalk that threading cannot go
through user code safely: a block passed to a user-defined method cannot
write the caller's locals (the compiler rejects it), and beamtalk-http's
handlers answer an `HTTPResponse`, not a connection, so the engine would
never see the final adapter. So:

- An **`Exchange`** is a sealed Value holding only an identity (a
  `Reference`) and the owning process. Its per-request state (Bandit's
  `Bandit.Adapter` fields and the transport value: read state, write state,
  buffer, metrics, compression context) lives in the owning process, keyed
  by that reference, and every method checks the caller is the owner, as
  Bandit's `validate_calling_process!` does.
- Inside the engine, the transports stay **Bandit-shaped Values**
  (`HTTP1Socket`, `HTTP2Stream`) threaded functionally; the Exchange stores
  the latest one between calls. Porting `http1/socket.ex` and
  `http2/stream.ex` stays line-for-line.
- Calls are imperative: `ex sendResp: 200 headers: h body: "ok"`. The ADR
  lists the full interface, the error rules and the alternative (a threaded
  Value) with its trade-offs. Phase 0 spike 2 proves the state model.

## Module map

Bandit 1.12.5 `lib/` → Buccaneer. One class per file, snake_case file names;
subdirectories as Catalina's `src/transports/`. Line counts are Bandit's.

| Bandit | LOC | Buccaneer | Phase |
|---|---|---|---|
| `bandit.ex` | 450 | `src/buccaneer.bt` (`start:` facade over `Catalina start:`), `src/buccaneer_config.bt` (option validation and defaults; `#http`, `#http1`, `#http2`, `#websocket`, `#catalina` sections) | 1 |
| `application.ex` | 14 | none: no OTP application callback. The clock is a node singleton started with `supervise` | 1 |
| `clock.ex` | 56 | `src/clock.bt` (`Date` header cached in ETS, refreshed each second by a `supervise`d singleton actor) | 1 |
| `adapter.ex` | 334 | `src/exchange.bt` (the engine interface), `src/exchange_state.bt` (the owner-process state) | 1, 3 |
| `http_transport.ex` | 47 | `src/http_transport.bt` (Protocol: `readHeaders`, `readData:`, `sendHeaders:...`, `sendData:end:`, `sendfile:...`, `ensureCompleted`, `supportsUpgrade:`, `sendOnError:`) | 1 |
| `pipeline.ex` | 246 | `src/pipeline.bt` (read headers → build Exchange → call handler → commit / upgrade / error) | 1 |
| `initial_handler.ex` | 86 | `src/initial_handler.bt` (ALPN and wire sniffing: TLS-on-clear → close; `PRI * HTTP/2.0` → HTTP/2; else HTTP/1) | 1, 6 |
| `delegating_handler.ex` | 78 | `src/connection_handler.bt`: the Catalina `Handler` subclass; delegates to the current protocol value in `userState`, switches protocol on `{switch, ...}` | 1 |
| `http1/handler.ex` | 108 | `src/http1/http1_handler.bt` (keepalive, `maxRequests`, GC every n requests, process-dictionary clearing) | 1 |
| `http1/socket.ex` | 627 | `src/http1/http1_socket.bt` (Value implementing `HTTPTransport`; request line and headers via `erlang:decode_packet` FFI; content-length and chunked bodies; response framing) | 1, 3 |
| `headers.ex` | 214 | `src/headers.bt` (header lookup, host/port parsing, content-length rules, `Connection` tokens) | 1 |
| `compression.ex` | 208 | `src/compression.bt` (`Accept-Encoding` negotiation; `zlib` FFI for gzip/deflate; OTP 28 `zstd`) | 1 |
| `socket_helpers.ex` | 74 | `src/socket_helpers.bt` (peer, sock and SSL data; iodata helpers) | 1 |
| `telemetry.ex` | 250 | `src/buccaneer_telemetry.bt` (`[buccaneer, request\|websocket, ...]` spans over the stdlib `Telemetry` facade, parented to Catalina's connection span) | 1 |
| `logger.ex` | 64 | `src/buccaneer_logger.bt` (`logProtocolErrors` `#short`/`#verbose`/`false`, `logClientClosures`) | 1 |
| `http_error.ex`, `transport_error.ex` | 12 | `src/http_error.bt` (with `plugStatus`), `src/transport_error.bt` | 1 |
| `extractor.ex` | 113 | `src/websocket/frame_extractor.bt` | 4 |
| `primitive_ops/websocket.ex` | 34 | `src/websocket/websocket_ops.bt` (unmasking via `crypto:exor` FFI) | 4 |
| `websocket/handshake.ex` | 105 | `src/websocket/handshake.bt` | 4 |
| `websocket/upgrade_validation.ex` | 65 | `src/websocket/upgrade_validation.bt` | 4 |
| `websocket/handler.ex` | 99 | `src/websocket/websocket_protocol.bt` (the protocol value `ConnectionHandler` delegates to) | 4 |
| `websocket/connection.ex` | 352 | `src/websocket/websocket_connection.bt` | 4 |
| `websocket/socket.ex` | 75 | `src/websocket/websocket_socket.bt` | 4 |
| `websocket/frame.ex` + `frame/*.ex` (6) | 382 | `src/websocket/frame.bt` + one Value per frame type | 4 |
| `websocket/permessage_deflate.ex` | 187 | `src/websocket/permessage_deflate.bt` | 4 |
| (WebSock behaviour, `websock` 128) | — | `src/websocket/websocket_handler.bt` (Protocol), `websocket_result.bt`, `websocket_message.bt` | 4 |
| (`hpax` 1.0.4, separate package) | 913 | **`beamtalk-hpack`**: `HPACK`, `HPACKTable`, `HPACKHuffman`, `HPACKTypes` | 5 |
| `http2/handler.ex` | 207 | `src/http2/http2_protocol.bt` | 6 |
| `http2/connection.ex` | 596 | `src/http2/http2_connection.bt` (process-free connection state, as in Bandit) | 6 |
| `http2/stream.ex` | 647 | `src/http2/http2_stream.bt` (Value implementing `HTTPTransport`) | 6 |
| `http2/stream_process.ex` | 31 | `src/http2/stream_process.bt` (`Server`; runs the pipeline in a `continueWith:` step) | 6 |
| `http2/stream_collection.ex`, `flow_control.ex`, `settings.ex`, `errors.ex` | 203 | `src/http2/` one class each | 6 |
| `http2/frame.ex` + `frame/*.ex` (11) | 760 | `src/http2/frame.bt` + one Value per frame type | 6 |
| `phoenix_adapter.ex` | 116 | not ported | — |
| `trace.ex` | 150 | not ported (after 1.0) | — |

Bandit is ~6,970 lines (plus hpax's 913); its test suite is ~14,150 lines in
813 tests (counts below). Expect Buccaneer to come in a little larger, as
Catalina did, for FFI plumbing and typed signatures.

## Bandit's test suite, sized

Bandit's tests are not in the hex package. Counted from the `1.12.5` tag
(`test "` / `property "` occurrences):

| File | Tests | Lines | Phase |
|---|---|---|---|
| `http1/protocol_test.exs` | 174 | 2,851 | 1 (153), 3 (15), 4 (6) |
| `http1/plug_test.exs` | 39 | 637 | 1 (29), 3 (9 `send_file`), 4 (1 upgrade) |
| `http1/telemetry_test.exs` | 13 | 363 | 1 |
| `http1/logging_test.exs` | 9 | 203 | 1 |
| `headers_test.exs` | 20 | 168 | 1 |
| `initial_handler_test.exs` | 10 | 109 | 1 (HTTP/1 and TLS sniffing), 6 (h2 cases) |
| `server_test.exs` | 6 | 75 | 1 |
| `adapter_test.exs` | 6 | 156 | 1 |
| `clock_test.exs`, `socket_helpers_test.exs` | 2 | 32 | 1 |
| `websocket/frame_deserialization_test.exs` | 49 | 438 | 4 |
| `websocket/frame_serialization_test.exs` | 20 | 173 | 4 |
| `websocket/http1_handshake_test.exs` | 14 | 321 | 4 |
| `websocket/protocol_test.exs` | 43 | 908 | 4 |
| `websocket/sock_test.exs` | 86 | 1,555 | 4 |
| `websocket/upgrade_test.exs`, `upgrade_validation_test.exs` | 10 | 226 | 4 |
| `websocket/autobahn_test.exs` | 1 | 102 | 7 (conformance) |
| `http2/frame_deserialization_test.exs` | 54 | 475 | 6 |
| `http2/frame_serialization_test.exs` | 19 | 231 | 6 |
| `http2/protocol_test.exs` | 178 | 3,944 | 6 |
| `http2/plug_test.exs` | 60 | 1,148 | 6 |
| `http2/h2spec_test.exs` | 1 | 31 | 7 (conformance) |
| hpax `test/` | 37 (7 properties) | — | 5 |

The suites drive Bandit with raw-socket clients (`test/support/simple_*_client.ex`)
and with Req/Finch. Buccaneer's harness ports the raw clients to Beamtalk
test fixtures (TCP, TLS, a minimal HTTP/2 framer and a WebSocket client)
and replaces Req with OTP's `httpc` through FFI, so no hex test dependencies
are needed. Test certificates are copied from Catalina's (valid to 2126).

## Phases

Each phase ends green on `just ci` and with one PR. Tests mirror Bandit's
`test/` file by file; the Elixir suite is the spec. Each phase section, once
done, records the tests ported and every deviation, as Catalina's PLAN.md
does. Sizes: S ≈ a day, M ≈ 2-4 days, L ≈ a week, XL ≈ more than a week.

### Phase 0: Spikes (M)

Prove the riskiest assumptions before the module map is trusted. Each spike
is a small BUnit test under `spikes/` with a README of the result, as
Catalina's.

1. **HTTP/1 parsing cost.** A Catalina `Handler` that parses a request with
   `erlang:decode_packet(http_bin | httph_bin, ...)` through FFI and answers
   a fixed response. Measure requests/s and p99 against Bandit's
   hello-world on the same machine, with today's `edge` (BT-4065, BT-4069,
   BT-4071 status recorded). This sets the expectation for the release gate.
2. **The Exchange state model.** Owner-process state keyed by a
   `Reference`: owner check, cost per call, behaviour when the handler
   raises mid-response, and clearing between keepalive requests without
   dropping Catalina's telemetry marker or Buccaneer's own keys
   (Bandit's `clear_process_dict`).
3. **Blocking request work inside `handleData:`.** The handler runs the
   whole request (including a blocking `Socket recv:timeout:` for the body
   and a user block that calls an actor) inside `handleData:`; the socket is
   passive between Catalina's `{active, once}` arms; a pipelined second
   request already in the buffer is served without re-arming.
4. **Byte codecs.** Binary patterns (BT-663) in `match:` for an HTTP/2
   frame header (`<<len:24, type:8, flags:8, _:1, sid:31, rest/binary>>`), a
   WebSocket header with a variable-size payload segment bound by an earlier
   segment, and HPACK's prefixed integers. Measure against Elixir. Frame
   construction (there is no binary construction syntax) through iodata and
   `binary:encode_unsigned` FFI. Outcome: which codecs need a Beamtalk issue.
5. **Waiting inside an HTTP/2 stream process.** Bandit's stream process runs
   the plug in one `handle_continue` and blocks on selective `receive ...
   after` for body data, window updates and resets (`http2/stream.ex`
   lines 300-480, 560-620), and the connection answers a stream's
   `send_data` call later with `GenServer.reply/2` (flow-control
   backpressure). Beamtalk has neither a `receive` nor a deferred reply for
   a pure-Beamtalk `Server` (only native-backed actors can, ADR 0056).
   Try the candidates: (a) a stdlib deferred reply on `Server` (the
   connection parks the caller and replies when a frame arrives); (b) a
   stdlib mailbox-wait facade; (c) restructuring so the stream process only
   ever makes sync calls the connection can answer at once (polling; likely
   rejected). File the chosen stdlib gap with a repro.
6. **Stream exits without BT-4052.** Can the connection **monitor** its
   stream processes (a `DOWN` reaches `handleInfo:`) and kill them in
   `terminate:`, instead of linking? Record what is lost against Bandit's
   links (a `kill` of the connection leaves streams running until their
   next call to it fails). This decides whether HTTP/2 must wait for
   BT-4052 or can ship with a documented deviation.
7. **Transitive package visibility.** Can an app that depends only on
   `http` name a class from `buccaneer` (for WebSocket handlers), or must
   beamtalk-http re-export? Decides where the WebSocket types live.

**Acceptance:** each spike has a result and numbers in `spikes/README.md`;
the module map and the ADR are amended where a spike fails; every Beamtalk
gap found is filed in Linear with a minimal repro.

### Phase 1: HTTP/1.1 engine (L)

**Scope:** `Buccaneer start:` and config; `Clock`; `Headers`;
`HTTPTransport`; `HTTP1Socket` (request line, headers, content-length and
chunked request bodies, response framing by status and method, keepalive
and `Connection: close`, `maxRequests`, request-line and header limits);
`Pipeline` (host and port determination, request targets: origin,
absolute, authority, asterisk); `Exchange` with `readBody`, `sendResp:...`
and the commit rules; `InitialHandler` for HTTP/1 and TLS-on-clear;
`ConnectionHandler`; `HTTP1Handler`; response compression (gzip, deflate;
zstd when OTP has it); request telemetry spans and `BuccaneerLogger`;
`HTTPError` → status, `TransportError` → close.

**Tests to port:** `http1/protocol_test.exs` except the four sections in
Phases 3-4 (153 tests: invalid requests 4, method coverage 4, method case 1,
request line limits 1, origin-form 17, absolute-form 11, authority-form 2,
asterisk-form 2, Host 2, request headers 7, content-length bodies 14,
content-length framing by status 14, chunked request bodies 13,
transfer-encoding edge cases 4, content negotiation and encoding 35,
closure and errors 6, keepalive 16); `http1/plug_test.exs` except
`send_file` and upgrade (29); `http1/telemetry_test.exs` (13);
`http1/logging_test.exs` (9); `headers_test.exs` (20);
`initial_handler_test.exs`' HTTP/1 and TLS cases; `server_test.exs` (6);
`adapter_test.exs` (6); `clock_test.exs` and `socket_helpers_test.exs`.

**Acceptance:** about 250 BUnit tests pass on TCP and TLS; a standalone
example (`examples/hello.bt`) serves requests with only buccaneer and
catalina; zero type warnings (every class `typed`, Catalina's typing rule);
every deviation recorded here.

The 35 content-negotiation tests are compression; if Phase 1 runs long they
split out into their own PR.

### Phase 2: beamtalk-http adapter and backend switch (M)

**Scope (in beamtalk-http, on a branch):** a Beamtalk adapter in
`src/server/` mapping `Exchange` → `HTTPRequest` (eager body, query
parsing with cowboy's `?flag` → `"true"` rule, header pairs) and
`HTTPResponse` → `sendResp:`; dispatch to a block, an `HTTPHandler` actor
(a real actor send, as today) or an `HTTPRouter` (the router matcher stays
native until Phase 8); 500 on a raise or a non-`HTTPResponse` answer, as
today. `HTTPServer` becomes a plain Beamtalk `Actor` (it stays an `Actor`
subclass, which `testClassIdentity` checks) owning a Buccaneer server, with
a `#backend => #cowboy | #buccaneer` option, default `#cowboy` in this
phase. `#bind` maps to Catalina's `{ip, ...}` transport option.

**Tests:** none new to port. `httpserver_test.bt` (12), `httprouter_test.bt`
(16), `plug_chain_test.bt` (6) and `plugs/request_logger_test.bt` (2) pass
**unchanged** on both backends (the suite runs twice in CI, once per
backend, selected by an environment variable read by `HTTPServer`). Add an
adapter test file for the mapping edge cases the existing tests do not hit
(duplicate headers, HEAD, chunked request bodies, 100-continue).

**Acceptance:** the 36 server-side tests pass on both backends; the client
tests are untouched; behaviour differences from cowboy (no `server`
header, duplicate request headers kept as separate pairs rather than
comma-joined) are documented in beamtalk-http's README. Blocked by Phase 1.

### Phase 3: Streaming (M)

**Scope:** `Exchange` incremental `readBody:` (`length`, `readLength`,
`readTimeout`), automatic `100 Continue` on the first body read,
`sendChunked:` / `chunk:` (and length-delimited streaming when the caller
sets `content-length`), `sendFile:...` (Catalina's `sendfile`, which falls
back to a pread loop over TLS), `inform:` for 1xx (refused on HTTP/1.0).
In beamtalk-http: the streaming proposals P1-P3 and P5 of the ADR.

**Tests to port:** `http1/protocol_test.exs` sendfile (5), informational
responses (2), `Expect: 100-continue` (3), chunked responses (5);
`http1/plug_test.exs` `send_file` (9); beamtalk-http tests for each new API.

**Acceptance:** the ported tests pass; a 1 GiB upload and download stream
in constant memory (asserted in a test with a process memory bound).
Blocked by Phase 1 (beamtalk-http parts by Phase 2).

### Phase 4: WebSocket (L)

**Scope:** frames, extractor, handshake and upgrade validation,
`WebSocketConnection` (fragmentation, control frames, close codes, UTF-8
validation, `maxFrameSize`, timeouts), permessage-deflate; the
`WebSocketHandler` protocol (WebSock's `init`/`handle_in`/`handle_info`/
`handle_control`/`terminate`), run in the upgraded connection's process;
`Exchange upgrade:`. In beamtalk-http: proposal P4 (router
`webSocket:handler:`).

**Tests to port:** `websocket/*` (229 tests: frame deserialization 49,
serialization 20, HTTP/1 handshake 14, protocol 43, sock 86, upgrade 3,
upgrade validation 7, plus `http1/protocol_test.exs` upgrade handling 6 and
`http1/plug_test.exs` upgrade 1).

**Acceptance:** the ported tests pass; Autobahn|Testsuite runs clean
locally (in CI if Docker is available; see Phase 7). Blocked by Phase 1 and
spike 7.

### Phase 5: HPACK package (M)

**Scope:** a new repository and package, `beamtalk-hpack`, porting hpax
1.0.4 (913 lines): static and dynamic tables with eviction and size updates,
prefixed integers, string literals, the Huffman code (the table built once
into `persistent_term`, not generated at compile time as in Elixir), and
`encode`/`decode` with hpax's error reasons. No dependency on Buccaneer or
Catalina, so the future HTTP client can use it. Independent of Phases 1-4;
can run in parallel with them.

**Tests to port:** hpax's 37 (the 7 StreamData properties become seeded
random loops, as Catalina's stress fuzz does), plus the RFC 7541 Appendix C
examples.

**Acceptance:** the tests pass; encode/decode of a typical request header
block measured against hpax.

### Phase 6: HTTP/2 (XL)

**Scope:** frames (11 types) and their (de)serialization, settings,
`HTTP2Connection` (process-free state, HPACK contexts, flow-control
windows, stream collection, `maxConcurrentStreams`, `maxResetStreamRate`,
GOAWAY, pending sends with expiry), `HTTP2Stream` implementing
`HTTPTransport`, `StreamProcess`, `HTTP2Protocol` in `ConnectionHandler`;
`InitialHandler` ALPN `h2` and prior-knowledge preface; `Exchange` over a
stream (owner = the stream process).

**Tests to port:** `http2/frame_deserialization_test.exs` (54),
`frame_serialization_test.exs` (19), `protocol_test.exs` (178),
`plug_test.exs` (60); `initial_handler_test.exs`' h2 cases.

**Acceptance:** the ported tests pass over TLS (ALPN) and clear (prior
knowledge); h2spec runs clean. **Blocked by BT-4052** (or by spike 6's
monitor-based deviation, if the user accepts it), by the stdlib gap spike 5
files, and by Phase 5.

### Phase 7: Release gate (L)

Reuse Catalina's harness (`bench/harness`, `test/stress`, the peer-VM
runner) and extend it with an HTTP load generator. Three servers run side by
side, interleaved round by round: **Buccaneer**, **Bandit 1.12.5**
(a mix project with the equivalent handler as a bare Plug), and
**beamtalk-http 0.1.10 on cowboy** (the current backend) next to
**beamtalk-http on Buccaneer** (the same app, so the adapter's cost is
visible on its own).

**`just bench`** rows: GET hello at 1/10/100/1,000 keepalive connections
(requests/s, p50/p99/p99.9); POST 64 KiB echo; a 1 MiB chunked response;
`sendFile` 1 MiB; connection churn (`Connection: close`); TLS handshakes/s
and TLS keepalive GET; memory and processes per idle keepalive connection
(10,000); HTTP/2 GET at 100 streams over 10 connections; WebSocket echo at
100 connections. `bench/RESULTS.md` holds medians, every round, the ratios
and the machine and versions; profile any row more than 2× Bandit, and file
each Beamtalk cost found with numbers, as BT-4051 did.

**`just stress`**: request fuzz (random framing, random chunk splits,
pipelining; bytes checked), leak churn (processes, ports, ETS,
process-dictionary size of a long keepalive connection), slow-loris on the
request line, headers and body, limits (`maxRequests`, header count and
length, `numConnections`), chaos (kill connection and stream processes
under load), lifecycle (suspend, resume, `stop:` draining in-flight
requests), a 30-minute mixed soak (HTTP/1, TLS, HTTP/2, WebSocket).
Conformance: h2spec and Autobahn|Testsuite.

**Acceptance:** the harness runs with `just bench` / `just stress`, RESULTS.md
is written, every stress test passes on Buccaneer (and on Bandit where the
expectation is "as Bandit does"), a summary is posted for the user's
go/no-go on removing cowboy and on tagging `v0.1.0`. **Don't tag.** Blocked
by Phases 1-4 and 6 (the HTTP/2 rows) and Phase 2 (the beamtalk-http rows).

### Phase 8: Remove cowboy from beamtalk-http (M)

**Scope (in beamtalk-http):** flip the default backend, then delete it:
`native/beamtalk_http_server.erl`, `beamtalk_http_server_handler.erl`,
`beamtalk_http_response.erl` (if nothing else uses it), the cowboy
`[native.dependencies]` entry and the backend switch. Replace the cowboy test
server the client tests use (`native/test/beamtalk_http_test_server.erl`,
`beamtalk_test_handler.erl`) with a Buccaneer-backed BUnit fixture serving
the same endpoints, so `httptest.bt` (24) passes unchanged. Port
`native/beamtalk_http_router.erl` (222 lines) and its 22 EUnit tests to
Beamtalk, and the 9 `beamtalk_http_server_tests.erl` cases to BUnit. gun
stays until the client epic. README and version bump (0.2.0).

**Acceptance:** beamtalk-http builds with no cowboy or ranch in its
dependency tree; every BUnit test passes; the only native modules left are
the gun client's. Blocked by Phase 7 (the user's go-ahead) and Phase 3 (the
streaming API it ships).

## Deviations we expect

Recorded properly when each phase is done; the expected ones:

- **No Plug.** An `Exchange` handle with owner-process state replaces
  `Plug.Conn` and its threaded adapter (see the Decision above and the ADR).
  The `{:plug_conn, :sent}` message Bandit sends itself and later checks
  with `receive ... after 0` becomes a field of the exchange state.
- **No `receive`.** Every selective receive in Bandit (`http1/socket.ex`
  `send_on_error`, `http2/stream.ex` reads and window waits,
  `ensure_completed`) is replaced, by state flags in HTTP/1 and by the
  mechanism spike 5 chooses in HTTP/2.
- **Links to stream processes** may become monitors (spike 6) until BT-4052.
- **Re-raise.** Where Bandit re-raises with `:erlang.raise/3`, Buccaneer
  re-signals (BT-4057), so an `exit(normal)` inside a handler ends the
  request as an error. Switch when `Exception>>pass` lands.
- **Options** are camelCased and nested by section: `#http`, `#http1`,
  `#http2`, `#websocket`, and Catalina's under `#catalina` (Bandit's
  `thousand_island_options`). Telemetry events are `[buccaneer, ...]`.
- **Clock** is a `supervise`d node singleton, since there is no application
  callback.
- **WebSock** becomes the `WebSocketHandler` protocol, whose implementor is
  a Value that is also its state (`handleIn:` answers a `WebSocketResult`
  carrying the next value), rather than a module plus a state term.
- **Errors**: `HTTPError` carries Bandit's `plug_status`; there is no
  `Plug.Exception.status/1` protocol, so any other raised error is a 500.
  Transport errors are bare reasons, as in Catalina.
- **Test clients**: Req/Finch become OTP `httpc` via FFI and Beamtalk ports
  of Bandit's raw-socket clients.

## Risks

1. **Per-request cost.** A 1-byte Catalina echo took 2-7 ms against Thousand
   Island's ~60 µs before BT-4053 (BT-4051's first run); the runtime fixes in flight (BT-4065, BT-4069,
   BT-4071) decide much of Buccaneer's speed. HTTP adds parsing and many
   Value sends per request. Mitigation: parse with `erlang:decode_packet`
   (C), keep hot-path Values sealed and typed, measure in spike 1 and gate
   in Phase 7 against both Bandit and cowboy.
2. **HTTP/2 needs primitives Beamtalk lacks:** no selective receive, no
   deferred reply in a pure-Beamtalk `Server`, and BT-4052. Mitigation:
   spikes 5-6 before Phase 6 starts; HTTP/2 is the last engine phase, and
   HTTP/1 + WebSocket can ship without it.
3. **The Exchange state model** departs from Bandit's threaded adapter.
   Risks: state leaks across keepalive requests, interaction with
   exceptions, and test adaptation cost (Bandit's plug tests assert on the
   returned conn). Mitigation: spike 2; the ADR keeps the transports
   Bandit-shaped so most porting is mechanical.
4. **Byte-level codecs** (HTTP/2 frames, WebSocket masking, HPACK Huffman)
   with binary patterns but no binary construction syntax. Mitigation:
   spike 4; FFI to `binary`, `crypto:exor` and `zlib`; file language gaps
   with numbers rather than dropping to native code.
5. **Drop-in compatibility with cowboy** in beamtalk-http: header case and
   duplicates, query parsing, error statuses, default headers, port 0 and
   `#bind`, and the gun client in the same VM. Mitigation: Phase 2 runs the
   unchanged suite on both backends before any default flips.

Also: porting volume (~810 tests, ~14,000 lines of Elixir), and type-checker
friction in `typed` classes (BT-4061, BT-4039..BT-4044), as Catalina found.

## Open decisions for the user

1. **Exchange state model:** owner-process state behind a handle
   (recommended) or Bandit's threaded Value. See the ADR.
2. **HTTP/2's wait primitive:** a stdlib deferred reply on `Server`
   (recommended: standard OTP, also useful elsewhere), a stdlib
   mailbox-wait facade, or a native helper in buccaneer (breaks
   pure-Beamtalk). And: wait for BT-4052, or ship HTTP/2 with monitors
   (spike 6)?
3. **HPACK as its own repository** (`jamesc/beamtalk-hpack`, recommended)
   or a second package inside the buccaneer repository.
4. **Which beamtalk-http API additions** (ADR P1-P6) are in scope for the
   cowboy removal, and where WebSocket types live (buccaneer, re-exported by
   http, or both).
5. **Gate thresholds:** what ratio against cowboy (and Bandit) is
   acceptable to remove cowboy, e.g. "no row worse than cowboy by more than
   2×, p99 included"?
6. **Compression** (gzip/deflate/zstd) in Phase 1, or deferred: it is 35 of
   Phase 1's tests.
7. **Conformance suites** (h2spec, Autobahn) need Docker or binaries: local
   only, or a nightly CI job?

## Size and effort

Bandit is ~7,000 lines of library and ~14,000 lines of tests; hpax adds
~900 and its tests. Rough split: Phase 0 three days; Phase 1 one to two
weeks; Phase 2 three days; Phase 3 three days; Phase 4 one to two weeks;
Phase 5 three days (parallel); Phase 6 two to three weeks once unblocked;
Phase 7 one week; Phase 8 three days. Plus the Beamtalk work the spikes
file, which gates Phase 6.

## Beamtalk work this port depends on

| Need | Issue | Status (2026-10-21) | Gates |
|---|---|---|---|
| A trapping Server handling linked `EXIT`s itself | BT-4052 | Backlog, needs-spec | Phase 6 |
| Re-raise unchanged (`exit(normal)` in a handler) | BT-4057 | Backlog, needs-spec | deviation until fixed |
| `late` slot holding nil | BT-4061 | Backlog | typing workaround |
| Class references and `Result ok:` serialised through class processes | BT-4065 | In progress | performance |
| Sends to a sealed-Value-typed parameter still dynamic | BT-4069 | Backlog | performance |
| `hasField:` cost (~20 µs) | BT-4071 | In progress | performance |
| Deferred reply or mailbox wait for a pure-Beamtalk Server | to file after spike 5 | — | Phase 6 |

## References

- Bandit 1.12.5 `lib/` and `test/` (tag `1.12.5`), hpax 1.0.4.
- Catalina: README § Public API, PLAN.md, `bench/` and `test/stress/`.
- beamtalk-http 0.1.10: `src/`, `native/`, `test/`.
- Beamtalk ADRs 0043 (sync sends), 0056 (native actors, deferred reply),
  0065 (Server, `handleInfo:`), 0068 (protocols), 0076 (FFI), 0124
  (`late`), 0134 (crash semantics), 0135 (supervisors).
