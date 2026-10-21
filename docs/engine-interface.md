# ADR (draft): Buccaneer's engine interface and the beamtalk-http adapter

- **Status:** Proposed (draft for review; nothing implemented)
- **Date:** 2026-10-21
- **Context:** [PLAN.md](../PLAN.md) § Decision, § Phases 1-4 and 8

## Context

beamtalk-http is the API applications program against (`HTTPServer`,
`HTTPRouter`, `Plug`, `PlugChain`, `HTTPRequest`, `HTTPResponse`,
`HTTPClient`). Its server runs on cowboy through native Erlang modules
(`native/beamtalk_http_server.erl`, `beamtalk_http_server_handler.erl`):
cowboy reads the whole body, the handler builds an `HTTPRequest`, calls a
block, an `HTTPHandler` actor or an `HTTPRouter`, and replies with the
`HTTPResponse`'s status, headers and body. There is no streaming, no
sendfile, no WebSocket and no 1xx.

Buccaneer replaces cowboy. It needs a low-level interface between the engine
(HTTP/1.1, HTTP/2, WebSocket) and whatever handles a request. In Bandit
that is `Plug.Conn.Adapter`: `read_req_body`, `send_resp`, `send_file`,
`send_chunked`, `chunk`, `inform`, `upgrade`, `push`, `get_peer_data`,
`get_sock_data`, `get_ssl_data`, `get_http_protocol`, implemented by
`Bandit.Adapter` over the `Bandit.HTTPTransport` protocol. The adapter is a
struct every callback returns updated, and the plug threads it through
`Plug.Conn`.

Three Beamtalk facts shape the design:

1. A block passed to a user-defined method cannot write the caller's locals
   (a compile error), so state threaded through user code must be returned
   explicitly at every step.
2. beamtalk-http's handlers answer an `HTTPResponse`. If the engine handed
   them a threaded value, the engine would never see the final one, and
   could not know how much of the body was read or whether a chunked
   response was finished.
3. There is no `receive`. Bandit's `{:plug_conn, :sent}` self-message,
   checked with `receive ... after 0`, has to be state.

## Decision

### 1. An owner-bound `Exchange` handle

One `Exchange` per request: an HTTP/1 request on a connection, or an HTTP/2
stream. It is a sealed Value that holds an identity and the owning process,
nothing mutable. The request's mutable state (`Bandit.Adapter`'s fields and
the current transport value) lives in the owning process, keyed by the
exchange's `Reference`, and is read and replaced by the Exchange's methods.
Every method first checks that the caller is the owner and raises
`#not_owner` otherwise, as `validate_calling_process!` does. The owner is
the Catalina connection handler (HTTP/1) or the stream process (HTTP/2): the
process that runs the request handler.

Inside the engine nothing changes from Bandit: `HTTP1Socket` and
`HTTP2Stream` are Values implementing `HTTPTransport`, threaded
functionally, and the exchange state stores the latest one. The handle is
the only imperative layer.

### 2. The interface

Signatures as they would be written (Catalina's typing rule: every class
`typed`, precise types, `Result` for expected failures). Checked against
Catalina's `Transport` and `HandlerResult`, beamtalk-http's `Plug` and
`HTTPServer`, and the stdlib's `Stream`.

```beamtalk
/// What a request handler is: a block, or a Value that answers `call:`.
/// It runs in the exchange's owner process, so it must not be an Actor:
/// an actor's `call:` would run in the actor and fail the owner check.
type ExchangeHandlerLike = Block(Exchange, Object) | ExchangeHandler

Protocol define: ExchangeHandler
  /// Handle one request. Send a response (or upgrade) before returning;
  /// the answer is ignored.
  call: exchange :: Exchange -> Object
```

```beamtalk
sealed typed Value subclass: Exchange
  // Always set by the engine; nilable only because a Value field needs a
  // default and cannot be `late`.
  field: ref :: Reference | Nil = nil    // the key of the owner-process state
  field: owner :: Pid | Nil = nil

  // === The request (fixed once the headers are read) ===
  method -> String                                 // as received: "GET"
  scheme -> #http | #https
  host -> String
  port -> Integer
  path -> String                                   // without the query
  query -> String | Nil                            // raw, unparsed
  headers -> List(Tuple)                           // {name, value}, names lowercase, order and duplicates kept
  header: name :: String -> String | Nil           // first value
  httpProtocol -> #http10 | #http11 | #http2       // Bandit's :"HTTP/1.0" ...
  peer -> Tuple                                    // {address, port}
  sockData -> Tuple                                // {address, port}
  sslData -> Result(Object, Object)                // peer certificate data, or error: #not_secure

  // === The request body ===
  /// Read the next part of the body: up to `#length` bytes (default
  /// 8_000_000), `#readLength` per socket read (1_000_000), waiting
  /// `#readTimeout` ms per read (15_000), as Plug's `read_body/2`.
  /// Sends `100 Continue` first if the client asked and nothing was sent.
  readBody -> Result(BodyPart, Object)
  readBody: options :: Dictionary(Symbol, Integer) -> Result(BodyPart, Object)
  /// The rest of the body in one Binary, or error: #body_too_large.
  readAll: maxBytes :: Integer -> Result(Binary, Object)

  // === The response ===
  sendResp: status :: Integer headers: hs :: List(Tuple) body: body :: Object -> Nil
  sendFile: status :: Integer headers: hs :: List(Tuple) path: path :: String
    offset: offset :: Integer length: length :: Integer | #all -> Nil
  sendChunked: status :: Integer headers: hs :: List(Tuple) -> Nil
  /// One chunk; an empty one ends the response (Bandit's rule).
  chunk: data :: Object -> Result(Nil, Object)
  /// A 1xx response. error: #not_supported on HTTP/1.0.
  inform: status :: Integer headers: hs :: List(Tuple) -> Result(Nil, Object)
  /// Ask to switch protocol once the handler returns; the pipeline then
  /// validates the request, sends 101 and hands the connection over.
  /// error: #not_supported when disabled or not HTTP/1.1.
  upgradeToWebSocket: handler :: WebSocketHandler options: opts :: Dictionary(Symbol, Object) -> Result(Nil, Object)
  /// #unset | #sent | #chunked | #upgraded, as Plug.Conn's state.
  state -> #unset | #sent | #chunked | #upgraded
```

```beamtalk
sealed typed Value subclass: BodyPart
  field: data :: Binary = ""
  /// true when this is the last part (Plug's {:ok, ...}); false for {:more, ...}
  field: done :: Boolean = true
```

`body` in `sendResp:` and `chunk:` is a `String`, a `Binary` or iodata
(an Erlang list of them), passed to the socket as it is. Headers are
`{name, value}` tuples because that is what `decode_packet` produces and
what the socket writes; the adapter converts to beamtalk-http's pairs.

Starting a server standalone:

```beamtalk
srv := (Buccaneer start: #{
  #port => 4000,
  #handler => [:ex |
    ex sendResp: 200 headers: #({"content-type", "text/plain"}) body: "hello"],
  #http1 => #{#maxRequests => 0},
  #websocket => #{#enabled => true},
  #catalina => #{#numAcceptors => 100}}) unwrap
srv listenerInfo   // Catalina's ServerSupervisor, as Bandit returns Thousand Island's
srv stop: 15000
```

### 3. Commit rules (the pipeline after `call:` returns)

As `Bandit.Pipeline.commit_response!/1`:

| `state` after the handler | Pipeline does |
|---|---|
| `#unset` | 500, logged (Bandit raises `Plug.Conn.NotSentError`) |
| `#sent` | nothing |
| `#chunked` | sends the closing empty chunk |
| `#upgraded` | WebSocket handshake; `ConnectionHandler` switches to the WebSocket protocol |

then `ensureCompleted`: on HTTP/1, discard an unread body within limits or
close after the response; on HTTP/2, `RST_STREAM(NO_ERROR)` if the client
is still sending.

### 4. Errors

- **Malformed requests never reach the handler.** `readHeaders` raises
  `HTTPError` with Bandit's message and `plugStatus` (400, 413, 414, 431,
  505 ...); the pipeline answers that status with `Connection: close`,
  logs per `logProtocolErrors` and emits the request span's stop with
  `#error`.
- **Expected outcomes the handler may branch on answer `Result`**:
  `readBody` (`#timeout`, `#closed`, `#body_too_large`), `chunk:` (Plug's
  `chunk/2` is the one send callback that returns an error), `inform:` and
  `upgradeToWebSocket:` (`#not_supported`). Error values are bare reasons,
  as Catalina's transports'.
- **Socket failures while sending raise `TransportError`** (`sendResp:`,
  `sendFile:`, `sendChunked:`), as Bandit raises `Bandit.TransportError`:
  the handler has nothing useful to do, and the pipeline catches it, emits
  the span stop and closes the connection.
- **Misuse raises**: `#not_owner`, `#already_sent` (a second `sendResp:`),
  `#not_chunked` (`chunk:` before `sendChunked:`), a negative `sendFile:`
  offset or a length past the end of the file (Bandit's messages).
- **Anything else the handler raises** is caught by the pipeline: a 500 if
  nothing was sent, the request span's `exception` event, a log line if the
  status is in `logExceptionsWithStatusCodes` (default 500-599). It is
  re-signalled, not re-raised unchanged, until BT-4057.

### 5. Upgrade and WebSocket

`upgradeToWebSocket:options:` records the request; the switch happens after
the handler returns (Plug's model). The WebSocket handler then runs in the
connection's process, like a Catalina handler:

```beamtalk
// Required: handleIn: and handleInfo:. The others are optional, detected
// with respondsTo: (as Catalina's optional `handshake:timeout:`), so they
// are documented here rather than required by the protocol.
Protocol define: WebSocketHandler
  /// A data frame: message is {#text, String} or {#binary, Binary}.
  handleIn: message :: Tuple -> WebSocketResult
  /// Any other message to the connection process.
  handleInfo: message :: Object -> WebSocketResult

// Optional, same Value:
//   init -> WebSocketResult                      (default: WebSocketResult ok: self)
//   handleControl: message :: Tuple -> WebSocketResult   ({#ping, data} / {#pong, data})
//   terminate: reason :: Object -> Object         (#normal, #remote, #shutdown, #timeout, {#error, r})
```

The implementor is a Value that **is** its state: each callback answers a
`WebSocketResult` carrying the next value (WebSock's `{:ok, state}`,
`{:push, frames, state}`, `{:reply, ...}`, `{:stop, reason, state}`):

```beamtalk
typed Value subclass: EchoSocket
  field: count :: Integer = 0

  handleIn: message :: Tuple -> WebSocketResult =>
    WebSocketResult push: #(message) state: (self withCount: self.count + 1)

  handleInfo: _message :: Object -> WebSocketResult => WebSocketResult ok: self
```

Pushing from elsewhere is a message to the connection process, which
arrives in `handleInfo:`; the handler gets its pid from `init`
(`Erlang erlang self`).

### 6. HTTP/2

The same `Exchange`, with the stream process as owner. Its body reads and
its sends wait on the connection process; how they wait is open until Phase
0 spike 5 (Beamtalk has no `receive` and no deferred reply for a pure
`Server`). The interface does not change with the answer.

## The beamtalk-http adapter

A Beamtalk class in beamtalk-http (`src/server/http_exchange_adapter.bt`)
that is the `ExchangeHandler` Buccaneer calls. `HTTPServer` becomes a plain
`Actor` that starts Buccaneer with it and stops it in `terminate:`.

| beamtalk-http | from / to the Exchange |
|---|---|
| `HTTPRequest method` | `ex method` |
| `HTTPRequest path` | `ex path` (no query, as cowboy's `path`) |
| `HTTPRequest headers` | `ex headers` as `#(name, value)` pairs; duplicates stay separate (cowboy joined them) |
| `HTTPRequest body` | `ex readAll: maxBodyLength` (default 8 MB) → 413 when larger |
| `HTTPRequest queryParams` | `ex query` through `uri_string:dissect_query`; a key without a value is `"true"`, as today |
| `HTTPRequest params` | the router, unchanged |
| block handler | called in the connection process, as cowboy calls it today |
| `HTTPHandler` actor | `handler handle: request` (an actor send; the actor never sees the Exchange) |
| `HTTPRouter` | matched with the router module, then as a block; 404 and 405 as today |
| `HTTPResponse status/headers/body` | `ex sendResp: status headers: pairs-as-tuples body: body`; Buccaneer adds `date` and `content-length` |
| a raise, or an answer that is not an `HTTPResponse` | 500 `text/plain` "Internal Server Error", logged, as today |
| `#bind` option | Catalina `#transportOptions => #({#ip, address})` |
| `srv port` | `srv listenerInfo` port |

Every existing test keeps passing because the observable behaviour of
these rows is cowboy's, except where the table says otherwise; those
differences go in beamtalk-http's README.

## Additions beamtalk-http's API needs

Small proposals, each its own PR in beamtalk-http after the backend switch
(PLAN Phases 3-4). All are additive: existing handlers keep working.

**P1. Streaming request bodies.** A route or server option
`#body => #stream` (default `#eager`) leaves the body unread, and
`HTTPRequest` gains `bodyReader -> BodyReader` (a Value over the exchange):
`read -> Result(String | Nil, Object)` (nil at the end) and
`inject: acc into: [:acc :chunk | ...]`. `HTTPRequest body` raises in
`#stream` mode. `#maxBodyLength` bounds `#eager` mode.

**P2. Streaming responses.** `HTTPResponse` gains `stream :: Stream(String)
| Nil`: `HTTPResponse status: 200 headers: h stream: (File lines: path)
unwrap`. The adapter sends chunked (or length-delimited when the headers
set `content-length`) and writes each element with `chunk:`. A `Stream` is
lazy, so the body is produced while it is sent. Open: a long-lived stream
(server-sent events) fed by another actor needs a generator the stdlib does
not expose yet (`Stream` has no public unfold); P2 ships without it.

**P3. sendfile.** `HTTPResponse status: 200 headers: h file: path` (and
`file:offset:length:`). The adapter calls `sendFile:`; over TLS Catalina
falls back to a read-and-send loop.

**P4. WebSocket upgrade.** A router entry `r webSocket: "/ws" handler:
[:req | EchoSocket new]` and a response form `HTTPResponse webSocket:
aHandler options: opts` for block handlers. The `WebSocketHandler` protocol
and `WebSocketResult` live in buccaneer; whether beamtalk-http re-exports
them depends on spike 7 (transitive package visibility).

**P5. Informational responses.** `req inform: 103 headers: #(#("link",
"</app.css>; rel=preload"))`, answering `Result`. This needs `HTTPRequest`
to carry its exchange (a new field, nil in unit tests that build requests
by hand). `Expect: 100-continue` is handled by the engine on the first body
read; in `#eager` mode that is before the handler runs, as cowboy does.

**P6. Request metadata.** `HTTPRequest` gains `scheme`, `host`, `port`,
`queryString`, `httpVersion` and `peer`, all read from the exchange. Small,
but every real app asks for one of them.

## Alternatives considered

**A threaded `Exchange` Value, as Bandit's adapter.** Every call answers the
next value (`ex := ex sendChunked: 200 headers: h`), the handler answers the
final one, and the engine needs no process-local state. Faithful to Bandit,
easy to test in isolation. Rejected for the public interface because
beamtalk-http's handlers answer an `HTTPResponse`, so P1-P5 would each need
the handler to hand the exchange back as well, and because a stale value
used by mistake (sending on an old exchange) silently corrupts the response
framing. It is still how the engine's internals work.

**An Actor per request** that owns the state. Rejected: the socket's owner
must do the sends (`controlling_process`, `sendfile`), and a process per
request costs what Bandit avoids on HTTP/1.

**Keeping cowboy behind beamtalk-http** and porting nothing. Rejected by
the agreed architecture: beamtalk-http should end up pure Beamtalk.

## Consequences

- beamtalk-http's handlers keep their shape; streaming and WebSocket are
  opt-in additions.
- The engine's correctness depends on the exchange state being created,
  replaced and cleared exactly per request. Phase 0 spike 2 proves it, and
  the keepalive tests (16 in `http1/protocol_test.exs`) and the leak stress
  test guard it.
- Bandit's plug tests that assert on the returned conn are adapted to
  assert on the response and on `ex state`; recorded as deviations per
  phase.
- An Actor cannot be an `ExchangeHandler`. beamtalk-http keeps its actor
  style by doing the exchange work in the connection process and sending
  only the `HTTPRequest` to the actor.
