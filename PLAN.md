# Buccaneer porting plan

Buccaneer is a port of [Bandit](https://github.com/mtrudel/bandit) (v1.12.5)
to Beamtalk: an HTTP/1.1, WebSocket and HTTP/2 server engine on top of
[Catalina](https://github.com/jamesc/beamtalk-catalina), the Beamtalk port of
Thousand Island. Its first consumer is
[beamtalk-http](https://github.com/jamesc/beamtalk-http), whose `HTTPServer`
runs on cowboy today; Buccaneer replaces cowboy there.

**Status: approved with decisions (2026-10-21; see § Decisions).** Nothing
here is implemented yet. Phases whose spec is complete are `agent-ready` in
Linear; Phases 3 and 4 stay `needs-spec` until the questions in § Remaining
open questions are answered.

## Goals

- Bandit's process model and HTTP semantics: one Catalina handler process per
  connection, the HTTP/1 request handled inside that process, one process per
  HTTP/2 stream, WebSocket on the upgraded connection's process, Bandit's
  option names (camelCased) and defaults, its error statuses and its
  telemetry events.
- A small, low-level **engine interface** (the role of Bandit's
  `Plug.Conn.Adapter` callbacks) that beamtalk-http adapts onto
  `HTTPRequest`/`HTTPResponse`, and that is also usable on its own.
  [`docs/engine-interface.md`](docs/engine-interface.md) is the ADR.
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
- A `Stream`-based body API in beamtalk-http. Bodies are explicit
  operations on owner-bound handles (§ Decisions 5); a `Stream` adapter over
  them is a possible later convenience.
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
- HPACK is its own repository and package (`jamesc/beamtalk-hpack`,
  Phase 5) so the future HTTP client can depend on it without depending on
  a server.
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
  Value) with its trade-offs. Phase 0 spike 2 proves the state model,
  including that nothing leaks from one keep-alive request to the next.
- beamtalk-http builds its own owner-bound handles (`req readChunk`,
  `resp sendChunk:`) on the Exchange. Using any handle from another process
  raises a clear error.

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
| `compression.ex` | 208 | `src/compression.bt` (`Accept-Encoding` negotiation; `zlib` FFI for gzip/deflate; OTP 28 `zstd`) | 9 |
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
| (WebSock behaviour, `websock` 128) | — | `src/websocket/websock.bt` (the engine-level Protocol), `websocket_result.bt` | 4 |
| (beamtalk-http side) | — | beamtalk-http: `WebSocketHandler` protocol (`onText:`, `onBinary:`, `onClose:`) and the adapter implementing `WebSock` over it | 4 |
| (`hpax` 1.0.4, separate package) | 913 | **`beamtalk-hpack`**: `HPACK`, `HPACKTable`, `HPACKHuffman`, `HPACKTypes` | 5 |
| `http2/handler.ex` | 207 | `src/http2/http2_protocol.bt` | 6 |
| `http2/connection.ex` | 596 | `src/http2/http2_connection.bt` (process-free connection state, as in Bandit) | 6 |
| `http2/stream.ex` | 647 | `src/http2/http2_stream.bt` (Value implementing `HTTPTransport`) | 6 |
| `http2/stream_process.ex` | 31 | `src/http2/stream_process.bt` (`Server`; runs the pipeline in a `continueWith:` step; monitored by the connection, not linked) | 6 |
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
| `http1/protocol_test.exs` | 174 | 2,851 | 1 (118), 3 (15), 4 (6), 9 (35) |
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
| `websocket/autobahn_test.exs` | 1 | 102 | 4 (CI job) |
| `http2/frame_deserialization_test.exs` | 54 | 475 | 6 |
| `http2/frame_serialization_test.exs` | 19 | 231 | 6 |
| `http2/protocol_test.exs` | 178 | 3,944 | 6 |
| `http2/plug_test.exs` | 60 | 1,148 | 6 |
| `http2/h2spec_test.exs` | 1 | 31 | 6 (CI job) |
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

| Phase | Size | Blocked by | Linear state |
|---|---|---|---|
| 0 Spikes | M | — | agent-ready |
| 1 HTTP/1.1 engine | L | 0 | agent-ready |
| 2 beamtalk-http adapter and backend switch | M | 1 | agent-ready |
| 3 Streaming | M | 1, 2 | needs-spec (two questions below) |
| 4 WebSocket | L | 1, 2 | needs-spec (one question below) |
| 5 HPACK (`jamesc/beamtalk-hpack`) | M | 0 | agent-ready |
| 6 HTTP/2 | XL | 0, 1, 5, BT-4090 | agent-ready (blocked) |
| 7 Release gate | L | 1-4, 6 | agent-ready (blocked) |
| 8 Remove cowboy | M | 2, 3, 7 | agent-ready (blocked) |
| 9 Response compression (later) | M | 1 | agent-ready |

### Phase 0: Spikes (M)

Prove the riskiest assumptions before the module map is trusted. Each spike
is a small BUnit test under `spikes/` with a README of the result, as
Catalina's.

1. **HTTP/1 parsing cost.** A Catalina `Handler` that parses a request with
   `erlang:decode_packet(http_bin | httph_bin, ...)` through FFI and answers
   a fixed response. Measure requests/s and p99 against
   beamtalk-http-on-cowboy (the gate's baseline) and Bandit (context) on the
   same machine, with today's `edge` (BT-4065, BT-4069, BT-4071 status
   recorded).
2. **The Exchange state model.** Owner-process state keyed by a
   `Reference`: owner check (a call from another process raises
   `#not_owner` with a clear message), cost per call, a raise mid-response.
   **It must prove there is no state leak across keep-alive requests**: on a
   connection serving 10,000 sequential requests (including ones whose
   handler raised, left a body unread, or ended a chunked response early),
   no request sees its predecessor's state, and the owner process's
   dictionary size and heap return to the same value after each request.
   Clearing must not drop Catalina's telemetry marker or Buccaneer's own
   keys (Bandit's `clear_process_dict`).
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
   `binary:encode_unsigned` FFI. File any language gap with numbers.
5. **Deferred reply, prototyped.** Exercise the shape BT-4090 specifies
   with a throwaway native-backed actor (ADR 0056, spike-only, never
   shipped): a stream process blocks on `conn readData:` and on a
   flow-controlled `conn sendData:` while the connection parks the calls and
   answers them out of order from `handleInfo:`. Confirms the HTTP/2 design
   needs nothing beyond BT-4090, and feeds its spec.
6. **Stream processes with monitors, not links.** The connection starts
   stream processes unlinked, monitors each (a `DOWN` reaches
   `handleInfo:`, where Bandit handles `EXIT`), resets the stream on an
   abnormal `DOWN`, and kills the remaining streams in `terminate:`. A
   stream process learns of a dead connection from its next call failing.
   Record the cost and what is lost against Bandit's links (a `kill` of the
   connection skips `terminate:`, so its streams run until their next call
   to it).

**Acceptance:** each spike has a result and numbers in `spikes/README.md`;
spike 2's leak test is kept as a regression test for Phase 1; the module
map and the ADR are amended where a spike fails; every Beamtalk gap found is
filed in Linear with a minimal repro.

### Phase 1: HTTP/1.1 engine (L)

**Scope:** `Buccaneer start:` and config; `Clock`; `Headers`;
`HTTPTransport`; `HTTP1Socket` (request line, headers, content-length and
chunked request bodies, response framing by status and method, keepalive
and `Connection: close`, `maxRequests`, request-line and header limits);
`Pipeline` (host and port determination, request targets: origin,
absolute, authority, asterisk); `Exchange` with `readBody`, `readAll:`,
`sendResp:...` and the commit rules; `InitialHandler` for HTTP/1 and
TLS-on-clear; `ConnectionHandler`; `HTTP1Handler`; request telemetry spans
and `BuccaneerLogger`; `HTTPError` → status, `TransportError` → close.
**No response compression** (Phase 9): `Accept-Encoding` is ignored and
responses are identity-encoded.

**Tests to port:** `http1/protocol_test.exs` except the sections in Phases
3, 4 and 9 (118 tests: invalid requests 4, method coverage 4, method case 1,
request line limits 1, origin-form 17, absolute-form 11, authority-form 2,
asterisk-form 2, Host 2, request headers 7, content-length bodies 14,
content-length framing by status 14, chunked request bodies 13,
transfer-encoding edge cases 4, closure and errors 6, keepalive 16);
`http1/plug_test.exs` except `send_file` and upgrade (29);
`http1/telemetry_test.exs` (13); `http1/logging_test.exs` (9);
`headers_test.exs` (20); `initial_handler_test.exs`' HTTP/1 and TLS cases;
`server_test.exs` (6); `adapter_test.exs` (6); `clock_test.exs` and
`socket_helpers_test.exs`. Plus spike 2's keep-alive leak test.

**Acceptance:** about 215 BUnit tests pass on TCP and TLS; a standalone
example (`examples/hello.bt`) serves requests with only buccaneer and
catalina; zero type warnings (every class `typed`, Catalina's typing rule);
every deviation recorded here.

### Phase 2: beamtalk-http adapter and backend switch (M)

**Scope (in beamtalk-http, on a branch):** a Beamtalk adapter in
`src/server/` mapping `Exchange` → `HTTPRequest` (whole body read before the
handler runs, as cowboy does today; query parsing with cowboy's `?flag` →
`"true"` rule; header pairs) and `HTTPResponse` → `sendResp:`; dispatch to
a block, an `HTTPHandler` actor (a real actor send, as today) or an
`HTTPRouter` (the router matcher stays native until Phase 8); 500 on a raise
or a non-`HTTPResponse` answer, as today. `HTTPServer` becomes a plain
Beamtalk `Actor` (it stays an `Actor` subclass, which `testClassIdentity`
checks) owning a Buccaneer server, with a `#backend => #cowboy |
#buccaneer` option, default `#cowboy` in this phase. `#bind` maps to
Catalina's `{ip, ...}` transport option. No new public API in this phase.

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

**Engine:** `Exchange` incremental `readBody:` (`length`, `readLength`,
`readTimeout`), automatic `100 Continue` on the first body read,
`sendChunked:` / `chunk:` (and length-delimited streaming when the caller
sets `content-length`), `sendFile:...` (Catalina's `sendfile`, which falls
back to a pread loop over TLS), `inform:` for 1xx (refused on HTTP/1.0).

**beamtalk-http** (minimal, as decided; details in the ADR § beamtalk-http
API additions). Explicit operations on owner-bound handles, not the stdlib
`Stream`:

- request bodies: `req readChunk -> Result(Binary, Error)`, an empty
  Binary meaning the end of the body; `req body` stays and reads the rest
  (Plug `read_body` semantics);
- chunked responses: `resp startChunked: status headers: h`,
  `resp sendChunk: data -> Result`, `resp finish`;
- sendfile: `HTTPResponse file: path` and `file:offset:length:`, as values;
- 100-continue: automatic when the handler first reads the body;
  `req inform: 103 headers: h` as the optional extra.

The handles work only from the connection process; from any other process
they raise a clear error. An `HTTPHandler` actor still gets the whole body.

**Tests to port:** `http1/protocol_test.exs` sendfile (5), informational
responses (2), `Expect: 100-continue` (3), chunked responses (5);
`http1/plug_test.exs` `send_file` (9); beamtalk-http tests for each new
operation, including the cross-process error.

**Acceptance:** the ported tests pass; a 1 GiB upload and download stream
in bounded memory (asserted in a test). Blocked by Phase 1 (beamtalk-http
parts by Phase 2).

**Open questions (needs-spec until answered):**

1. How does a handler get `resp`, and what does it answer once it has
   streamed? Proposal: a block handler may take two arguments, `[:req :resp
   | ...]`, where `resp` is the owner-bound `HTTPResponder`; after
   `resp finish` the block answers `resp` (or `HTTPResponse sent`) and the
   adapter checks the response was finished.
2. What does "an actor handler delegates streaming back" look like?
   Proposal: the actor answers `HTTPResponse streamWith: aBlock`, and the
   adapter runs `aBlock value: req value: resp` in the connection process
   (the block must not close over the actor's state, as with route blocks
   today).

### Phase 4: WebSocket (L)

**Engine:** frames, extractor, handshake and upgrade validation,
`WebSocketConnection` (fragmentation, control frames, close codes, UTF-8
validation, `maxFrameSize`, timeouts), permessage-deflate; Buccaneer's
engine-level `WebSock` protocol (WebSock's
`init`/`handle_in`/`handle_info`/`handle_control`/`terminate`), run in the
upgraded connection's process; `Exchange upgradeToWebSocket:`.

**beamtalk-http:** `HTTPResponse upgradeWebSocket: handlerClass`, and a
`WebSocketHandler` protocol living in beamtalk-http with `onText:`,
`onBinary:` and `onClose:`. The adapter implements Buccaneer's `WebSock`
over it.

**Tests to port:** `websocket/*` (229 tests: frame deserialization 49,
serialization 20, HTTP/1 handshake 14, protocol 43, sock 86, upgrade 3,
upgrade validation 7, plus `http1/protocol_test.exs` upgrade handling 6 and
`http1/plug_test.exs` upgrade 1); beamtalk-http tests for the upgrade and
each callback.

**Acceptance:** the ported tests pass; Autobahn|Testsuite runs in CI as a
non-blocking job, promoted to blocking once green. Blocked by Phases 1-2.

**Open question (needs-spec until answered):** what is `handlerClass`
instantiated as, and how does a handler send? Proposal: an `Actor` spawned
per connection (linked to the connection process), so `onText:` can keep
mutable state and the handler can be told things by other actors; it sends
with `ws sendText:` / `ws sendBinary:` / `ws close:`, where `ws` is a
`WebSocket` value given to `onOpen:` that casts to the connection process
(the one exception to "owner process only", because a send is a message,
not a socket call). The alternative is a Value run in the connection
process that answers its next self, as the engine's `WebSock` does.

### Phase 5: HPACK package (M)

**Scope:** a new repository, **`jamesc/beamtalk-hpack`** (package
`hpack`), porting hpax 1.0.4 (913 lines): static and dynamic tables with
eviction and size updates, prefixed integers, string literals, the Huffman
code (the table built once into `persistent_term`, not generated at compile
time as in Elixir), and `encode`/`decode` with hpax's error reasons. No
dependency on Buccaneer or Catalina, so the future HTTP client can use it.
Independent of Phases 1-4; can run in parallel with them.

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

How the stream process waits: it calls the connection (`readData:`,
`sendData:`, window waits) and the connection parks each call with
**BT-4090**'s deferred reply until the frame or window it needs arrives,
answering out of order, and expiring parked sends after 15 s as Bandit does.
Stream processes are **monitored, not linked** (spike 6): an abnormal
`DOWN` resets that stream, and `terminate:` kills the rest. BT-4052 is
related, not a blocker; when it lands, links can replace monitors.

**Tests to port:** `http2/frame_deserialization_test.exs` (54),
`frame_serialization_test.exs` (19), `protocol_test.exs` (178),
`plug_test.exs` (60); `initial_handler_test.exs`' h2 cases.

**Acceptance:** the ported tests pass over TLS (ALPN) and clear (prior
knowledge); h2spec runs in CI as a non-blocking job, promoted to blocking
once green. Blocked by BT-4090, Phase 5, Phase 1 and Phase 0.

### Phase 7: Release gate (L)

Reuse Catalina's harness (`bench/harness`, `test/stress`, the peer-VM
runner) and extend it with an HTTP load generator. Servers run side by side,
interleaved round by round: **beamtalk-http on Buccaneer** against
**beamtalk-http 0.1.10 on cowboy** (the gate), with **Buccaneer
standalone** (the adapter's cost on its own) and **Bandit 1.12.5** (a mix
project with the equivalent handler as a bare Plug) reported for context.

**Rows:** GET hello at 1/10/100/1,000 keepalive connections (requests/s,
p50/p99/p99.9); POST 64 KiB echo; a 1 MiB chunked response; `file:` 1 MiB;
connection churn (`Connection: close`); TLS handshakes/s and TLS keepalive
GET; memory and processes per idle keepalive connection (10,000); and, for
context only (cowboy is not serving them in beamtalk-http today), HTTP/2 GET
at 100 streams over 10 connections and WebSocket echo at 100 connections.

**`just stress`:** request fuzz (random framing, random chunk splits,
pipelining; bytes checked), leak churn (processes, ports, ETS,
process-dictionary size of a long keepalive connection), slow-loris on the
request line, headers and body, limits (`maxRequests`, header count and
length, `numConnections`), chaos (kill connection and stream processes
under load), lifecycle (suspend, resume, `stop:` draining in-flight
requests), a 30-minute mixed soak (HTTP/1, TLS, HTTP/2, WebSocket).
Conformance: h2spec and Autobahn in CI (non-blocking until green).

**The gate (decided):**

- beamtalk-http on Buccaneer **matches beamtalk-http on cowboy on
  throughput and p99 on every HTTP/1.1 and TLS gate row** (medians over
  ≥ 5 interleaved rounds; "matches" means not worse beyond the rounds'
  spread, which RESULTS.md reports);
- **zero correctness regressions**: every stress test passes;
- **beamtalk-http's full suite is green on Buccaneer.**

Bandit's numbers are context, not a gate. Any row worse than cowboy is
profiled, and each Beamtalk cost found is filed with numbers, as BT-4051 did.

**Acceptance:** the harness runs with `just bench` / `just stress`;
`bench/RESULTS.md` is written; the gate is met or the misses are filed; a
summary is posted for the user's go/no-go on removing cowboy and on tagging
`v0.1.0`. **Don't tag.** Blocked by Phases 1-4 and 6.

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
the gun client's. Blocked by Phase 7 (the user's go-ahead), Phase 2 and
Phase 3.

### Phase 9: Response compression (M, later)

**Scope:** `Compression` (`Accept-Encoding` negotiation, gzip and deflate
through `zlib` FFI, zstd when the OTP release has it), Bandit's `#http`
options `compress`, `responseEncodings`, `deflateOptions`, `zstdOptions`,
and compression of chunked responses (skipped when the caller sets
`content-length`, as Bandit does).

**Tests to port:** `http1/protocol_test.exs` "content negotiation and
encoding" (35); the compression cases of `http2/plug_test.exs` if Phase 6
has landed.

**Acceptance:** the ported tests pass; beamtalk-http needs no change
(compression is a server option). Blocked by Phase 1; deferred out of
Phase 1 by decision.

## Deviations we expect

Recorded properly when each phase is done; the expected ones:

- **No Plug.** An `Exchange` handle with owner-process state replaces
  `Plug.Conn` and its threaded adapter (see the Decision above and the ADR).
  The `{:plug_conn, :sent}` message Bandit sends itself and later checks
  with `receive ... after 0` becomes a field of the exchange state.
- **No `receive`.** Every selective receive in Bandit (`http1/socket.ex`
  `send_on_error`, `http2/stream.ex` reads and window waits,
  `ensure_completed`) is replaced: by state flags in HTTP/1, and in HTTP/2
  by sync calls to the connection that it answers later (BT-4090).
- **Stream processes are monitored, not linked** (until BT-4052). A `kill`
  of the connection leaves its streams running until their next call to it.
- **Re-raise.** Where Bandit re-raises with `:erlang.raise/3`, Buccaneer
  re-signals (BT-4057), so an `exit(normal)` inside a handler ends the
  request as an error. Switch when `Exception>>pass` lands.
- **Options** are camelCased and nested by section: `#http`, `#http1`,
  `#http2`, `#websocket`, and Catalina's under `#catalina` (Bandit's
  `thousand_island_options`). Telemetry events are `[buccaneer, ...]`.
- **Clock** is a `supervise`d node singleton, since there is no application
  callback.
- **WebSock** becomes Buccaneer's `WebSock` protocol, whose implementor is
  a Value that is also its state (each callback answers a `WebSocketResult`
  carrying the next value), rather than a module plus a state term.
- **Compression** arrives in Phase 9, after the engine, not with HTTP/1.
- **Errors**: `HTTPError` carries Bandit's `plug_status`; there is no
  `Plug.Exception.status/1` protocol, so any other raised error is a 500.
  Transport errors are bare reasons, as in Catalina.
- **Test clients**: Req/Finch become OTP `httpc` via FFI and Beamtalk ports
  of Bandit's raw-socket clients.

## Risks

1. **Per-request cost.** A 1-byte Catalina echo took 2-7 ms against
   Thousand Island's ~60 µs before BT-4053 (BT-4051's first run); the
   runtime fixes in flight (BT-4065, BT-4069, BT-4071) decide much of
   Buccaneer's speed, and the gate is now "match cowboy". Mitigation: parse
   with `erlang:decode_packet` (C), keep hot-path Values sealed and typed,
   measure in spike 1 against cowboy, gate in Phase 7.
2. **HTTP/2 depends on new stdlib work** (BT-4090, deferred reply).
   Mitigation: spike 5 prototypes the shape first; HTTP/2 is the last engine
   phase, and HTTP/1 + WebSocket ship without it.
3. **The Exchange state model** departs from Bandit's threaded adapter.
   Risks: state leaking across keepalive requests, interaction with
   exceptions, test adaptation cost. Mitigation: spike 2's leak test, kept
   as a regression test; the transports stay Bandit-shaped.
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

## Decisions (2026-10-21)

1. **Exchange state:** an owner-bound handle, state in the owning
   connection (or stream) process. Spike 2 must prove no state leaks across
   keep-alive requests.
2. **HTTP/2 waiting:** a stdlib deferred reply on `Server`, runtime-backed
   with no new compiler primitive: **BT-4090** (under BT-3957), which blocks
   Phase 6.
3. **BT-4052:** HTTP/2 ships with monitors instead of links (spike 6).
   BT-4052 is related to Phase 6, not a blocker.
4. **HPACK:** its own repository, `jamesc/beamtalk-hpack` (Phase 5).
5. **beamtalk-http API additions:** streaming request bodies, chunked
   responses, sendfile and WebSocket upgrade are all in scope, each minimal
   and tied to its phase (3 or 4), as explicit operations on owner-bound
   handles. **Not built on the stdlib `Stream`**: it is lazy and
   closure-based, evaluated in whichever process forces it, has no close or
   error protocol, and is pull-only, which is wrong for socket-owned bodies
   when handlers can be actors in another process. A `Stream` adapter is out
   of scope (a possible later convenience). Request metadata (proposed in the first
   draft) is not in scope.
6. **Release gate:** match beamtalk-http-on-cowboy on throughput and p99
   across the gate rows, zero correctness regressions, beamtalk-http's full
   suite green on Buccaneer. Bandit is context, not a gate.
7. **Compression:** deferred out of Phase 1 into Phase 9 (35 tests).
8. **h2spec and Autobahn:** CI jobs, non-blocking at first, promoted to
   blocking once green.

## Remaining open questions

- **Phase 3:** how a handler obtains the responder handle and what it
  answers after streaming; the form an actor handler uses to delegate
  streaming back to the connection process. (Proposals in § Phase 3.)
- **Phase 4:** what `upgradeWebSocket: handlerClass` instantiates (an Actor
  per connection, or a Value run in the connection process) and how a
  handler sends frames. (Proposal in § Phase 4.)
- **BT-4090:** its spec (name, error replies, interaction with
  `continueWith:` and `stopWith:`) is a Beamtalk decision; Phase 6 waits on
  it.

## Size and effort

Bandit is ~7,000 lines of library and ~14,000 lines of tests; hpax adds
~900 and its tests. Rough split: Phase 0 three days; Phase 1 one to two
weeks; Phase 2 three days; Phase 3 three days; Phase 4 one to two weeks;
Phase 5 three days (parallel); Phase 6 two to three weeks once BT-4090
lands; Phase 7 one week; Phase 8 three days; Phase 9 two to three days.

## Beamtalk work this port depends on

| Need | Issue | Status (2026-10-21) | Relation |
|---|---|---|---|
| Deferred reply for a pure-Beamtalk Server | BT-4090 | Backlog, needs-spec | **blocks Phase 6** |
| A trapping Server handling linked `EXIT`s itself | BT-4052 | Backlog, needs-spec | related to Phase 6 (monitors meanwhile) |
| Re-raise unchanged (`exit(normal)` in a handler) | BT-4057 | Backlog, needs-spec | deviation until fixed |
| `late` slot holding nil | BT-4061 | Backlog | typing workaround |
| Class references and `Result ok:` serialised through class processes | BT-4065 | In progress | performance (gate) |
| Sends to a sealed-Value-typed parameter still dynamic | BT-4069 | Backlog | performance (gate) |
| `hasField:` cost (~20 µs) | BT-4071 | In progress | performance (gate) |

## References

- Bandit 1.12.5 `lib/` and `test/` (tag `1.12.5`), hpax 1.0.4.
- Catalina: README § Public API, PLAN.md, `bench/` and `test/stress/`.
- beamtalk-http 0.1.10: `src/`, `native/`, `test/`.
- Beamtalk ADRs 0043 (sync sends), 0056 (native actors, deferred reply),
  0065 (Server, `handleInfo:`), 0068 (protocols), 0076 (FFI), 0124
  (`late`), 0134 (crash semantics), 0135 (supervisors).
