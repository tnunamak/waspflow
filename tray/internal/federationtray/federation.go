// Package federationtray contains the intentionally small daemon boundary for
// the native Federation tray helper. It owns no federation-loop logic.
package federationtray

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultPollInterval = 2 * time.Second
	daemonInfoFilename  = "daemon.json"
)

// VisualState is the small visual vocabulary exposed by the tray icon.
type VisualState string

const (
	VisualActive    VisualState = "active"
	VisualIdle      VisualState = "idle"
	VisualAttention VisualState = "attention"
	VisualSetup     VisualState = "setup"
)

// DaemonInfo is the discovery record written by the local Node daemon.
type DaemonInfo struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
}

// Status is the subset of the daemon's response that the tray renders.
type Status struct {
	State string `json:"state"`
}

// DaemonInfoPath returns the daemon discovery path. The environment override
// mirrors the daemon's configHome() behavior and keeps tests and custom
// installations out of a user's real Federation directory.
func DaemonInfoPath() (string, error) {
	if home := os.Getenv("WASPFLOW_FEDERATION_HOME"); home != "" {
		return filepath.Join(home, daemonInfoFilename), nil
	}
	userHome, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find user home for Federation daemon: %w", err)
	}
	return filepath.Join(userHome, ".waspflow", "federation", daemonInfoFilename), nil
}

// ReadDaemonInfo parses and validates a daemon discovery record before any
// network request uses it.
func ReadDaemonInfo(path string) (DaemonInfo, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return DaemonInfo{}, fmt.Errorf("read Federation daemon info: %w", err)
	}
	var info DaemonInfo
	if err := json.Unmarshal(contents, &info); err != nil {
		return DaemonInfo{}, fmt.Errorf("parse Federation daemon info: %w", err)
	}
	if info.Port < 1 || info.Port > 65535 {
		return DaemonInfo{}, errors.New("Federation daemon info has an invalid port")
	}
	if info.Token == "" {
		return DaemonInfo{}, errors.New("Federation daemon info has an empty session token")
	}
	return info, nil
}

// VisualStateForDaemonState maps the daemon's state machine to the tray's
// deliberately smaller visual vocabulary. Unknown states fail safely to setup.
func VisualStateForDaemonState(state string) VisualState {
	switch state {
	case "contributing":
		return VisualActive
	case "paused", "idle":
		return VisualIdle
	case "action_needed":
		return VisualAttention
	default:
		return VisualSetup
	}
}

// TooltipForVisualState gives every visual state an accessible text equivalent.
func TooltipForVisualState(state VisualState) string {
	switch state {
	case VisualActive:
		return "Waspflow Federation — contributing"
	case VisualIdle:
		return "Waspflow Federation — idle or paused"
	case VisualAttention:
		return "Waspflow Federation — action needed"
	default:
		return "Waspflow Federation — setup required"
	}
}

// FederationURL is the tokenized localhost URL consumed by the user's browser.
func FederationURL(info DaemonInfo) string {
	return fmt.Sprintf("http://127.0.0.1:%d/?token=%s", info.Port, url.QueryEscape(info.Token))
}

// Client performs the only daemon API calls this program is allowed to make.
type Client struct {
	HTTPClient *http.Client
}

func (c Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return &http.Client{Timeout: time.Second}
}

func daemonURL(info DaemonInfo, endpoint string) string {
	return fmt.Sprintf("http://127.0.0.1:%d%s", info.Port, endpoint)
}

func daemonRequest(ctx context.Context, method string, info DaemonInfo, endpoint string) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, method, daemonURL(info, endpoint), nil)
	if err != nil {
		return nil, fmt.Errorf("build Federation daemon request: %w", err)
	}
	request.Header.Set("X-Waspflow-Session-Token", info.Token)
	return request, nil
}

// Status retrieves the daemon's present state with the session token header.
func (c Client) Status(ctx context.Context, info DaemonInfo) (Status, error) {
	request, err := daemonRequest(ctx, http.MethodGet, info, "/status")
	if err != nil {
		return Status{}, err
	}
	response, err := c.httpClient().Do(request)
	if err != nil {
		return Status{}, fmt.Errorf("request Federation daemon status: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return Status{}, responseError(response)
	}
	var status Status
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		return Status{}, fmt.Errorf("parse Federation daemon status: %w", err)
	}
	return status, nil
}

// Post invokes one of the daemon's no-body contribution controls.
func (c Client) Post(ctx context.Context, info DaemonInfo, endpoint string) error {
	request, err := daemonRequest(ctx, http.MethodPost, info, endpoint)
	if err != nil {
		return err
	}
	response, err := c.httpClient().Do(request)
	if err != nil {
		return fmt.Errorf("request Federation daemon control: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return responseError(response)
	}
	return nil
}

func responseError(response *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
	detail := strings.TrimSpace(string(body))
	if detail == "" {
		return fmt.Errorf("Federation daemon returned HTTP %d", response.StatusCode)
	}
	return fmt.Errorf("Federation daemon returned HTTP %d: %s", response.StatusCode, detail)
}

// PollInterval exposes the intentionally low-frequency ambient polling rate.
func PollInterval() time.Duration { return defaultPollInterval }
