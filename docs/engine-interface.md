# ADR: Buccaneer's engine interface and the beamtalk-http adapter

- **Status:** Accepted with decisions, 2026-10-21 (nothing implemented yet)
- **Date:** 2026-10-21
- **Context:** [PLAN.md](../PLAN.md) § Decision, § Decisions, § Phases 1-4, 6 and 8

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
  upgradeToWebSocket: handler :: WebSock options: opts :: Dictionary(Symbol, Object) -> Result(Nil, Object)
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

### 5. Upgrade and the engine-level `WebSock` protocol

`upgradeToWebSocket:options:` records the request; the switch happens after
the handler returns (Plug's model). The WebSocket handler then runs in the
connection's process, like a Catalina handler. Buccaneer's protocol for it
is named `WebSock`, after the Elixir behaviour it ports, so it does not
collide with beamtalk-http's user-facing `WebSocketHandler` (below):

```beamtalk
// Required: handleIn: and handleInfo:. The others are optional, detected
// with respondsTo: (as Catalina's optional `handshake:timeout:`), so they
// are documented here rather than required by the protocol.
Protocol define: WebSock
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
typed Value subclass: EchoSock
  field: count :: Integer = 0

  handleIn: message :: Tuple -> WebSocketResult =>
    WebSocketResult push: #(message) state: (self withCount: self.count + 1)

  handleInfo: _message :: Object -> WebSocketResult => WebSocketResult ok: self
```

Pushing from elsewhere is a message to the connection process, which
arrives in `handleInfo:`.

### 6. HTTP/2

The same `Exchange`, with the stream process as owner. The stream process
never waits on its own mailbox (Beamtalk has no `receive`). Its body reads,
its flow-controlled sends and its window waits are sync calls to the
connection process, which parks each call with the stdlib deferred reply
(**BT-4090**, decided) and answers it when the frame or window arrives,
out of order, expiring parked sends after 15 s as Bandit does. The
connection **monitors** its stream processes rather than linking them
(decided; BT-4052 is related, not required): an abnormal `DOWN` resets the
stream, and the connection's `terminate:` kills the remaining streams. The
interface above does not change for HTTP/2.

## The beamtalk-http adapter

A Beamtalk class in beamtalk-http (`src/server/http_exchange_adapter.bt`)
that is the `ExchangeHandler` Buccaneer calls. `HTTPServer` becomes a plain
`Actor` that starts Buccaneer with it and stops it in `terminate:`.

| beamtalk-http | from / to the Exchange |
|---|---|
| `HTTPRequest method` | `ex method` |
| `HTTPRequest path` | `ex path` (no query, as cowboy's `path`) |
| `HTTPRequest headers` | `ex headers` as `#(name, value)` pairs; duplicates stay separate (cowboy joined them) |
| `HTTPRequest body` | Phase 2: `ex readAll: maxBodyLength` before the handler runs (default 8 MB, 413 when larger), as cowboy. Phase 3: read on first use by a block handler; still read in full before an `HTTPHandler` actor is called |
| `HTTPRequest queryParams` | `ex query` through `uri_string:dissect_query`; a key without a value is `"true"`, as today |
| `HTTPRequest params` | the router, unchanged |
| block handler | called in the connection process, as cowboy calls it today |
| `HTTPHandler` actor | `handler handle: request` (an actor send; the actor never touches the Exchange) |
| `HTTPRouter` | matched with the router module, then as a block; 404 and 405 as today |
| `HTTPResponse status/headers/body` | `ex sendResp: status headers: pairs-as-tuples body: body`; Buccaneer adds `date` and `content-length` |
| `HTTPResponse file:...` | `ex sendFile:...` (Phase 3) |
| `HTTPResponse streamWith: aBlock` | the adapter runs `aBlock value: resp` in the connection process; `resp` wraps `ex sendChunked:`/`chunk:` (Phase 3) |
| `HTTPResponse upgradeWebSocket: handlerClass` | `ex upgradeToWebSocket:options:` with an adapter `WebSock` that drives a `handlerClass` Value in the connection process (Phase 4) |
| a raise, or an answer that is not an `HTTPResponse` | 500 `text/plain` "Internal Server Error", logged, as today |
| `#bind` option | Catalina `#transportOptions => #({#ip, address})` |
| `srv port` | `srv listenerInfo` port |

Every existing test keeps passing because the observable behaviour of
these rows is cowboy's, except where the table says otherwise; those
differences go in beamtalk-http's README.

## beamtalk-http API additions (decided)

All in scope, each minimal and tied to its phase. They are **explicit
operations on owner-bound handles**, not the stdlib `Stream`: a `Stream` is
lazy and closure-based, evaluated in whichever process forces it, has no
close or error protocol, and is pull-only, which is wrong for socket-owned
bodies when handlers can be actors in another process. A `Stream` adapter
over these operations is out of scope (a possible later convenience).

**Owner-bound.** `HTTPRequest` carries its exchange (a new field, nil in
unit tests that build requests by hand). Every operation below that touches
the connection works only from the connection process; from any other
process it raises an error saying so (`#not_owner`: "request handles can
only be used from the connection process that received the request").
Block and router handlers run in the connection process, so they can use
every operation. An `HTTPHandler` actor runs in its own process: it gets the
whole body already read, and it streams a response the same way every
handler does, with `streamWith:` (A2), whose block the adapter runs back in
the connection process.

**A1. Request bodies (Phase 3).** For block and router handlers (they run
in the connection process); an actor handler uses `req body`, already read.

```beamtalk
// Next part of the body; an empty Binary means the end of the body.
req readChunk -> Result(Binary, Error)
// The rest of the body (Plug read_body semantics); bounded by #maxBodyLength.
req body -> String
```

```beamtalk
total := 0
done := false
[done] whileFalse: [
  chunk := (req readChunk) unwrap
  chunk size =:= 0 ifTrue: [done := true] ifFalse: [total := total + chunk size]]
```

**A2. Chunked responses (Phase 3).** One mechanism for every handler
style. A handler (block, router route or `HTTPHandler` actor) answers a
response value that carries a block; the adapter always runs the block in
the connection process, so the owner-bound `resp` is always used from its
owner and `#not_owner` cannot trip on this path. Push, like Plug's
`send_chunked`/`chunk`:

```beamtalk
HTTPResponse streamWith: [:resp |
  resp startChunked: 200 headers: #(#("content-type", "text/plain"))   // -> Result
  resp sendChunk: "part 1"                                              // -> Result
  resp sendChunk: "part 2"
  resp finish]                                                          // the closing chunk
```

Existing one-argument handlers are unchanged. If the block returns without
`finish`, the adapter finishes the response; if it never called
`startChunked:headers:`, the request is a 500. A raise after the headers
went out cannot become a 500: the connection is closed and the error
logged, as Bandit does. `sendChunk:` answers `Result error: #closed` when
the client has gone.

**What this gives an actor handler.** The block is created in the actor but
runs in the connection process. Under ADR 0133 as amended by ADR 0137, it
sees the actor's fields as they were when the block was made, assigning one
raises `actor_state_unreachable`, and a message it sends to `self` is an
ordinary sync message to the actor. So an actor can stream live data by
having the block ask it for each chunk:

```beamtalk
Actor subclass: ReportHandler
  handle: req :: HTTPRequest -> HTTPResponse =>
    HTTPResponse streamWith: [:resp |
      resp startChunked: 200 headers: #(#("content-type", "text/csv"))
      [self hasMoreRows] whileTrue: [resp sendChunk: self nextRows]   // sync messages to the actor
      resp finish]
```

**A3. sendfile (Phase 3).** Plain values, so they also work from an actor:

```beamtalk
HTTPResponse file: "/srv/static/app.js"
HTTPResponse file: "/srv/video.mp4" offset: 0 length: 1048576
```

with `status`/`headers` set as on any `HTTPResponse`. The adapter calls
`sendFile:`; over TLS Catalina falls back to a read-and-send loop.

**A4. 100-continue (Phase 3).** Automatic: the engine sends `100 Continue`
when the handler first reads the body (`readChunk` or `body`), and not at all
if it answers without reading. The optional extra, also Phase 3:
`req inform: 103 headers: #(#("link", "</app.css>; rel=preload")) ->
Result` (`#not_supported` on HTTP/1.0).

**A5. WebSocket (Phase 4).** Any handler answers
`HTTPResponse upgradeWebSocket: handlerClass`. `handlerClass` makes a
**Value** handler that runs in the connection process, in the style of
Bandit's WebSock and Catalina's `Handler`: no actor per connection and no
extra hop per frame. The handler Value is its own state; each callback
answers the next state, and frames go out through `ws`, a handle owned by
the connection process.

```beamtalk
// onInfo: is optional (detected with respondsTo:): any other message
// sent to the connection process.
Protocol define: WebSocketHandler
  /// The connection is upgraded: answer the first state.
  onOpen: ws :: WebSocket request: req :: HTTPRequest -> WebSocketHandler
  onText: text :: String -> WebSocketHandler
  onBinary: data :: Binary -> WebSocketHandler
  onClose: reason :: Object -> Object
```

```beamtalk
typed Value subclass: EchoSocket
  field: ws :: WebSocket | Nil = nil
  field: count :: Integer = 0

  onOpen: ws :: WebSocket request: _req :: HTTPRequest -> WebSocketHandler =>
    self withWs: ws

  onText: text :: String -> WebSocketHandler =>
    self.ws sendText: text
    self withCount: self.count + 1

  onBinary: data :: Binary -> WebSocketHandler =>
    self.ws sendBinary: data
    self

  onClose: _reason :: Object -> Object => nil
```

`WebSocket` (beamtalk-http) offers `sendText:`, `sendBinary:`, `close:` and
`pid` (the connection process). Using it from another process raises
`#not_owner`. `handlerClass new` is the state before `onOpen:request:`; the
request carries whatever the handler needs to set itself up (path params,
headers).

**A handler that wants an actor forwards to one itself.** It creates or
looks up the actor in `onOpen:request:`, keeps it in a field and casts to
it; the actor pushes back with a plain message to the connection process,
which reaches `onInfo:`, which writes it:

```beamtalk
typed Value subclass: ChatSocket
  field: ws :: WebSocket | Nil = nil
  field: room :: ChatRoom | Nil = nil

  onOpen: ws :: WebSocket request: req :: HTTPRequest -> WebSocketHandler =>
    room := ChatRoom named: (req param: "room")
    room join: ws pid
    (self withWs: ws) withRoom: room

  onText: text :: String -> WebSocketHandler =>
    self.room post: text!
    self

  // ChatRoom sends {#chat, text} to each member's connection pid.
  onInfo: msg :: Object -> WebSocketHandler =>
    msg match: [
      {#chat, text} -> self.ws sendText: text;
      _ -> nil
    ]
    self

  onBinary: _data :: Binary -> WebSocketHandler => self
  onClose: _reason :: Object -> Object => self.room leave: self.ws pid
```

Not in scope: request metadata accessors (`scheme`, `host`, `peer`, ...),
proposed in the first draft; they can follow when an app needs them.

## Alternatives considered

**A threaded `Exchange` Value, as Bandit's adapter.** Every call answers the
next value (`ex := ex sendChunked: 200 headers: h`), the handler answers the
final one, and the engine needs no process-local state. Faithful to Bandit,
easy to test in isolation. Rejected for the public interface because
beamtalk-http's handlers answer an `HTTPResponse`, so A1-A4 would each need
the handler to hand the exchange back as well, and because a stale value
used by mistake (sending on an old exchange) silently corrupts the response
framing. It is still how the engine's internals work.

**Bodies as stdlib `Stream`s** (the first draft's P1/P2). Rejected: see
§ beamtalk-http API additions.

**Two-argument handler blocks** (`[:req :resp | ...]`) for streaming.
Rejected: they change the handler signature and do nothing for actor
handlers. `streamWith:` covers every handler style with one mechanism.

**An Actor per WebSocket connection** running the handler. Rejected: it
doubles the process count and adds a hop per frame. A handler that wants
an actor forwards to one itself (A5).

**An Actor per request** that owns the state. Rejected: the socket's owner
must do the sends (`controlling_process`, `sendfile`), and a process per
request costs what Bandit avoids on HTTP/1.

**Waiting in HTTP/2 stream processes through a native helper or a mailbox
facade.** Rejected for a stdlib deferred reply (BT-4090), which is standard
OTP and keeps Buccaneer pure Beamtalk.

**Keeping cowboy behind beamtalk-http** and porting nothing. Rejected by
the agreed architecture: beamtalk-http should end up pure Beamtalk.

## Consequences

- beamtalk-http's handlers keep their shape; streaming and WebSocket are
  opt-in additions.
- The engine's correctness depends on the exchange state being created,
  replaced and cleared exactly per request. Phase 0 spike 2 must prove no
  state leaks across keep-alive requests; its test stays as a regression
  test, and the keepalive tests (16 in `http1/protocol_test.exs`) and the
  leak stress test guard it.
- Bandit's plug tests that assert on the returned conn are adapted to
  assert on the response and on `ex state`; recorded as deviations per
  phase.
- An Actor cannot be an `ExchangeHandler`, and cannot use request or
  response handles. beamtalk-http keeps its actor style by doing the
  exchange work in the connection process and sending only the
  `HTTPRequest` (with its body read) to the actor.
- HTTP/2 waits on BT-4090.
