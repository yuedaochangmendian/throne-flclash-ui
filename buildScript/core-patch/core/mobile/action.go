// The Bettbox-style JSON action bus (ADR 0002, phase 1).
//
// The transport was already Bettbox-shaped — Dart_PostCObject_DL, a message
// port, one long-lived isolate — but every call had its own typed throne_*
// export. This file adds the missing protocol layer: one C entry point
// (`throne_invoke_action`, emitted in bridge_runtime.go) that unmarshals an
// Action, dispatches it through a registry, and answers with an ActionResult
// whose id echoes the request so Dart can correlate it with a Completer.
//
// The 424 typed exports are NOT removed. They are the handlers' implementation:
// a method below calls the same Go functions the typed ABI exposes. That keeps
// symbol_audit.py's three-way equality intact and avoids rewriting generated
// bindings.
//
// Method constants and the registry are checked against Dart's ActionMethod
// enum by tools/diagnostics/action_contract.py. Bettbox keeps those lists in
// sync only by convention and has a real drift on resetConnections; the audit
// is what stops us from copying that bug.

package mobile

import "encoding/json"

// Method is the wire name of one action. It is a string so the JSON shape is
// self-describing and so the same name can be used on both sides of the C ABI.
type Method string

const (
	// actionVersionMethod is the phase-1 smoke test: it proves the bus can
	// round-trip an id, a handler and a result without touching a real config.
	// Phase 3 adds the data-plane methods here, one domain at a time.
	actionVersionMethod Method = "actionVersion"

	// messageMethod is the tag of an unsolicited Go->Dart push. It is not a
	// registered handler: pushes are posted with no id and never correlate.
	messageMethod Method = "message"
)

const (
	actionCodeSuccess = 0
	actionCodeError   = -1
)

// Action is one request. Id is echoed back verbatim; Method names the handler;
// Data is left as raw JSON so each handler decides its own payload shape.
type Action struct {
	Id     string          `json:"id"`
	Method Method          `json:"method"`
	Data   json.RawMessage `json:"data"`
}

// ActionResult is the reply. Port is Go-only: it is the Dart reply port the
// result must be posted to, and is deliberately not serialized.
type ActionResult struct {
	Id     string `json:"id"`
	Method Method `json:"method"`
	Data   any    `json:"data"`
	Code   int    `json:"code"`
	Port   int64  `json:"-"`
}

// JSON marshals the reply. Kept as a method so the emitter and any future
// socket transport share one encoding (Bettbox's server.go does the same).
func (result ActionResult) JSON() ([]byte, error) {
	return json.Marshal(result)
}

type actionHandler func(json.RawMessage) (any, error)

// actionHandlers is the dispatcher registry. Every Method constant that is a
// real request must appear here; action_contract.py enforces that.
var actionHandlers = map[Method]actionHandler{}

// register adds one handler. A duplicate is a programming error: keep the
// first registration and let dispatchAction's unknown-method path stay
// unreachable, rather than panicking in init (a cgo boundary must never see a
// Go panic, even during package initialization).
func register(method Method, handler actionHandler) {
	if _, exists := actionHandlers[method]; exists {
		return
	}
	actionHandlers[method] = handler
}

func init() {
	register(actionVersionMethod, handleActionVersion)
}

// handleActionVersion answers the protocol version and the kernel's own
// version string. It is the end-to-end proof in phase 1: a Dart invoke<T>
// sends an id, this handler runs, and the reply closes the matching Completer.
func handleActionVersion(_ json.RawMessage) (any, error) {
	return map[string]any{
		"protocol": 1,
		"core":     Version(),
	}, nil
}
