package notify

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// The control surface: `POST /mute`, `POST /unmute`, `GET /status`,
// `GET /history?n=`.
//
// # Why these handlers do almost nothing
//
// proposal.md's whole premise correction is that mute/status/history had NO
// owner before 1.1/1.2 — their format was scattered across a Claude-only
// command file, a shell reader, and a package that only knew the outcome
// name. That consolidation is already done by the time this file exists;
// every handler here is a JSON adapter over ParseMuteDuration/SetMute/
// ClearMute (mute.go) and ReadStatus/TailHistory (status.go) — the exact
// functions runMute/runUnmute/runStatus/runHistory (cli.go) already call.
// A handler that parsed a duration or walked history rows itself would
// recreate the ownerless-format hazard this whole proposal exists to close
// (`## STOP conditions`: "Mute semantics diverging between the API path and
// the fallback path").
//
// # Wire shapes, settled here since the proposal left them open
//
//   - POST /mute body: {"duration": "30s"} — the same s/m/h/d vocabulary
//     ParseMuteDuration accepts from the CLI, not a seconds integer. A
//     tailnet caller and an operator typing `herald notify mute 30s` must
//     mean the same thing when they say "30s"; a parallel numeric API would
//     silently fork that vocabulary. An omitted or empty duration defaults
//     to "1h", mirroring runMute's own default (cli.go) exactly.
//   - POST /mute and POST /unmute responses mirror runMute/runUnmute's
//     `--json` shape verbatim (map[string]any{"muted": ..., "until": ...}) —
//     a client watching for "did this call mute Herald" should not need a
//     second, HTTP-only shape to check.
//   - GET /status and GET /history reuse Status and []Record directly
//     (status.go), the same JSON-tagged types `--json` already encodes —
//     one shape, two transports.
//   - GET /history?n=: mirrors the CLI flag's semantics exactly, including
//     what TailHistory already defines for n<=0 ("everything") — n=0 and a
//     negative n both mean "all" here for the same reason `runHistory`
//     never special-cases them beyond what TailHistory does. Missing `n`
//     defaults to 10, matching the CLI flag's own default. A malformed
//     (non-integer) `n` is the one case the CLI can't hit — `flag.Int`
//     rejects it before `runHistory` ever runs — so there is no existing
//     precedent to mirror; decided here as 400, consistent with every other
//     malformed-input case in this file and in HandleNotify (send.go).

// defaultMuteSpec is POST /mute's fallback when the request omits a
// duration, copied from runMute's own `spec := "1h"` (cli.go) so an HTTP
// caller and a bare `herald notify mute` get the same default rather than
// two independently-chosen ones.
const defaultMuteSpec = "1h"

// defaultHistoryN mirrors runHistory's `-n` flag default (cli.go).
const defaultHistoryN = 10

// registerControlHandlers is the single line service.go's NewServer calls
// (task 1.6's whole footprint there, matching how 1.5 added its own single
// line for /notify).
func registerControlHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/mute", handleMute)
	mux.HandleFunc("/unmute", handleUnmute)
	mux.HandleFunc("/status", handleStatus)
	mux.HandleFunc("/history", handleHistory)
}

// muteRequest is POST /mute's wire body.
type muteRequest struct {
	Duration string `json:"duration"`
}

// handleMute delegates entirely to ParseMuteDuration (mute.go's owner of
// the operator vocabulary) and SetMute (mute.go's owner of the on-disk
// write) — this function's only job is turning an HTTP body into their
// arguments and their result into a response.
func handleMute(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeNotifyJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}

	var body muteRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, maxNotifyBodyBytes))
	if err := dec.Decode(&body); err != nil && err != io.EOF {
		// io.EOF means an empty body, which is valid here (falls through to
		// defaultMuteSpec below) — everywhere else in this file an empty
		// body is fine for the same reason: /mute's only required input is
		// optional.
		writeNotifyJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("notify: malformed request body: %v", err),
		})
		return
	}

	spec := strings.TrimSpace(body.Duration)
	if spec == "" {
		spec = defaultMuteSpec
	}
	d, err := ParseMuteDuration(spec)
	if err != nil {
		writeNotifyJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	until, err := SetMute(ResolveStateDir(), d)
	if err != nil {
		writeNotifyJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"muted": true, "until": until})
}

// handleUnmute delegates to ClearMute (mute.go), which already treats
// "unmute when not muted" as success rather than an error — there is
// nothing left for this handler to decide.
func handleUnmute(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeNotifyJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST only"})
		return
	}
	if err := ClearMute(ResolveStateDir()); err != nil {
		writeNotifyJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"muted": false})
}

// handleStatus delegates to ReadStatus (status.go). ReadStatus's own
// contract is fail-soft — a missing or unreadable piece degrades to its
// zero value rather than failing the call, "because status is the command
// an operator runs when something is already wrong" — so the error return
// is deliberately not branched into a 5xx here either: the same host that
// makes ReadStatus degrade gracefully for the CLI must degrade the same way
// over HTTP, not fail one transport and not the other.
func handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeNotifyJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET only"})
		return
	}
	st, _ := ReadStatus(ResolveStateDir())
	writeJSON(w, http.StatusOK, st)
}

// handleHistory delegates to TailHistory (status.go) for both the tail
// count and the n<=0 "everything" semantics — see the file doc comment for
// why a malformed n is the one 400 case with no CLI precedent to mirror.
func handleHistory(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeNotifyJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "GET only"})
		return
	}

	n := defaultHistoryN
	if raw := strings.TrimSpace(r.URL.Query().Get("n")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil {
			writeNotifyJSON(w, http.StatusBadRequest, map[string]string{
				"error": fmt.Sprintf("notify: n=%q is not an integer", raw),
			})
			return
		}
		n = parsed
	}

	records, err := TailHistory(ResolveStateDir(), n)
	if err != nil {
		writeNotifyJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	// Same non-nil-empty-slice discipline as runHistory's --json path
	// (cli.go): a consumer should not have to special-case first-run state
	// differently over HTTP than it already doesn't over the CLI.
	if records == nil {
		records = []Record{}
	}
	writeJSON(w, http.StatusOK, records)
}

// writeJSON is writeNotifyJSON's (send.go) counterpart for success bodies
// that are not the map[string]string error shape — Status, []Record, and
// the mute/unmute maps above all need arbitrary JSON, not just a string
// error field.
func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
