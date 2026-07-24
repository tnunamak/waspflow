package federationtray

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestVisualStateForDaemonState(t *testing.T) {
	tests := map[string]VisualState{
		"contributing":  VisualActive,
		"paused":        VisualIdle,
		"idle":          VisualIdle,
		"action_needed": VisualAttention,
		"not_joined":    VisualSetup,
		"future_state":  VisualSetup,
	}
	for daemonState, want := range tests {
		if got := VisualStateForDaemonState(daemonState); got != want {
			t.Errorf("VisualStateForDaemonState(%q) = %q, want %q", daemonState, got, want)
		}
	}
}

func TestSetupStatusTitle(t *testing.T) {
	// The setup state must never claim the daemon is "not running" — that copy
	// is reserved for a genuinely unreachable daemon, handled in the tray.
	tests := map[string]string{
		"pending_approval": "Waiting for the collective operator to approve you",
		"not_joined":       "Not in a collective yet — open Federation to join",
		"approval_revoked": "Approval was revoked — open Federation to rejoin",
		"setup_required":   "Setup required — open Federation to continue",
		"unknown_future":   "Open Federation to continue setup",
	}
	for daemonState, want := range tests {
		if got := SetupStatusTitle(daemonState); got != want {
			t.Errorf("SetupStatusTitle(%q) = %q, want %q", daemonState, got, want)
		}
		if got := SetupStatusTitle(daemonState); got == "Federation daemon is not running" {
			t.Errorf("SetupStatusTitle(%q) falsely claimed the daemon is not running", daemonState)
		}
	}
}

func TestReadDaemonInfo(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "daemon.json")
	if err := os.WriteFile(path, []byte(`{"port": 40123, "token": "local-session-token"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := ReadDaemonInfo(path)
	if err != nil {
		t.Fatal(err)
	}
	if info != (DaemonInfo{Port: 40123, Token: "local-session-token"}) {
		t.Fatalf("ReadDaemonInfo() = %#v", info)
	}
}

func TestReadDaemonInfoRejectsInvalidRecords(t *testing.T) {
	directory := t.TempDir()
	for name, contents := range map[string]string{
		"invalid JSON": `{`,
		"bad port":     `{"port": 0, "token": "token"}`,
		"empty token":  `{"port": 40123, "token": ""}`,
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(directory, name+".json")
			if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := ReadDaemonInfo(path); err == nil {
				t.Fatal("ReadDaemonInfo() succeeded for an invalid record")
			}
		})
	}
}

func TestClientCarriesTheDaemonSessionToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if got := request.Header.Get("X-Waspflow-Session-Token"); got != "session-token" {
			t.Errorf("session token header = %q", got)
		}
		if request.Method != http.MethodGet || request.URL.Path != "/status" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
		}
		_, _ = fmt.Fprint(response, `{"state":"contributing"}`)
	}))
	defer server.Close()
	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(serverURL.Port())
	if err != nil {
		t.Fatal(err)
	}
	status, err := (Client{}).Status(context.Background(), DaemonInfo{Port: port, Token: "session-token"})
	if err != nil {
		t.Fatal(err)
	}
	if status.State != "contributing" {
		t.Fatalf("status.State = %q", status.State)
	}
}

// TestPendingApprovalNeverLies is the regression guard for the exact live bug:
// a running daemon at pending_approval used to render "daemon is not running".
func TestPendingApprovalNeverLies(t *testing.T) {
	for _, daemonState := range []string{"pending_approval", "not_joined", "approval_revoked", "setup_required"} {
		if got := VisualStateForDaemonState(daemonState); got != VisualSetup {
			t.Fatalf("VisualStateForDaemonState(%q) = %q; expected VisualSetup", daemonState, got)
		}
		// When the daemon IS up, the tray uses SetupStatusTitle, which must be honest.
		if title := SetupStatusTitle(daemonState); title == "Federation daemon is not running" {
			t.Errorf("running daemon at %q would render the false 'not running' title", daemonState)
		}
	}
}
