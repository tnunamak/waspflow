package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"fyne.io/systray"
	"github.com/pkg/browser"

	"github.com/tnunamak/waspflow/federation-tray/internal/federationtray"
)

const applicationName = "Waspflow Federation"

type trayApp struct {
	infoPath string
	client   federationtray.Client

	mu    sync.Mutex
	info  federationtray.DaemonInfo
	state federationtray.VisualState
}

func main() {
	infoPath, err := federationtray.DaemonInfoPath()
	if err != nil {
		fmt.Fprintln(os.Stderr, "waspflow-federation-tray:", err)
		os.Exit(1)
	}
	app := &trayApp{infoPath: infoPath, state: federationtray.VisualSetup}
	systray.Run(app.onReady, func() {})
}

func (app *trayApp) onReady() {
	systray.SetTitle(applicationName)
	statusItem := systray.AddMenuItem("Federation daemon is not running", "Current Federation state")
	statusItem.Disable()
	systray.AddSeparator()
	openItem := systray.AddMenuItem("Open Waspflow Federation", "Open the local Federation web UI")
	contributeItem := systray.AddMenuItem("Resume contributing", "Start or resume contributing through the local daemon")
	startItem := systray.AddMenuItem("Start Federation daemon", "Run waspflow federation daemon")
	systray.AddSeparator()
	quitItem := systray.AddMenuItem("Quit", "Quit the tray helper")

	app.applyVisualState(federationtray.VisualSetup, false, "", statusItem, contributeItem, startItem)
	go app.poll(statusItem, contributeItem, startItem)
	go app.handleMenu(openItem, contributeItem, startItem, quitItem)
}

func (app *trayApp) handleMenu(openItem, contributeItem, startItem, quitItem *systray.MenuItem) {
	for {
		select {
		case <-openItem.ClickedCh:
			app.open()
		case <-contributeItem.ClickedCh:
			app.toggleContributing()
		case <-startItem.ClickedCh:
			if err := startDaemon(); err != nil {
				fmt.Fprintln(os.Stderr, "waspflow-federation-tray: start daemon:", err)
			}
		case <-quitItem.ClickedCh:
			systray.Quit()
			return
		}
	}
}

func (app *trayApp) poll(statusItem, contributeItem, startItem *systray.MenuItem) {
	ticker := time.NewTicker(federationtray.PollInterval())
	defer ticker.Stop()
	for {
		app.refresh(statusItem, contributeItem, startItem)
		<-ticker.C
	}
}

func (app *trayApp) refresh(statusItem, contributeItem, startItem *systray.MenuItem) {
	// "Daemon unreachable" (no record, or /status errors) is a genuinely
	// different situation from "daemon up but not yet contributing" — the tray
	// used to collapse both into VisualSetup and then label everything
	// "daemon is not running", which lied whenever the daemon was in fact up and
	// waiting (e.g. pending_approval). Carry daemonUp so the same setup icon can
	// show honest, situation-specific copy.
	info, err := federationtray.ReadDaemonInfo(app.infoPath)
	if err != nil {
		app.applyVisualState(federationtray.VisualSetup, false, "", statusItem, contributeItem, startItem)
		return
	}
	context, cancel := context.WithTimeout(context.Background(), time.Second)
	status, err := app.client.Status(context, info)
	cancel()
	if err != nil {
		app.applyVisualState(federationtray.VisualSetup, false, "", statusItem, contributeItem, startItem)
		return
	}
	app.mu.Lock()
	app.info = info
	previousState := app.state
	app.mu.Unlock()
	visualState := federationtray.VisualStateForDaemonState(status.State)
	app.applyVisualState(visualState, true, status.State, statusItem, contributeItem, startItem)
	if visualState == federationtray.VisualAttention && previousState != federationtray.VisualAttention {
		_ = browser.OpenURL(federationtray.FederationURL(info))
	}
}

func (app *trayApp) applyVisualState(state federationtray.VisualState, daemonUp bool, daemonState string, statusItem, contributeItem, startItem *systray.MenuItem) {
	app.mu.Lock()
	app.state = state
	app.mu.Unlock()
	systray.SetIcon(federationtray.IconPNG(state))
	systray.SetTooltip(federationtray.TooltipForVisualState(state))
	switch state {
	case federationtray.VisualActive:
		statusItem.SetTitle("Contributing")
		contributeItem.SetTitle("Pause contributing")
		contributeItem.Enable()
		startItem.Hide()
	case federationtray.VisualIdle:
		statusItem.SetTitle("Paused or idle")
		contributeItem.SetTitle("Resume contributing")
		contributeItem.Enable()
		startItem.Hide()
	case federationtray.VisualAttention:
		statusItem.SetTitle("Action needed — open Federation to continue")
		contributeItem.SetTitle("Resume contributing")
		contributeItem.Disable()
		startItem.Hide()
	default:
		// VisualSetup covers two very different truths. Only offer to start the
		// daemon when it is actually down; when it is up (setup/pending), say so
		// and never claim it is "not running".
		if daemonUp {
			statusItem.SetTitle(federationtray.SetupStatusTitle(daemonState))
			startItem.Hide()
		} else {
			statusItem.SetTitle("Federation daemon is not running")
			startItem.Show()
		}
		contributeItem.SetTitle("Resume contributing")
		contributeItem.Disable()
	}
}

func (app *trayApp) open() {
	info, err := federationtray.ReadDaemonInfo(app.infoPath)
	if err != nil {
		return
	}
	_ = browser.OpenURL(federationtray.FederationURL(info))
}

func (app *trayApp) toggleContributing() {
	app.mu.Lock()
	info, state := app.info, app.state
	app.mu.Unlock()
	if info.Port == 0 {
		return
	}
	endpoint := "/contribute/start"
	if state == federationtray.VisualActive {
		endpoint = "/contribute/stop"
	}
	context, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := app.client.Post(context, info, endpoint); err != nil {
		fmt.Fprintln(os.Stderr, "waspflow-federation-tray: contribute control:", err)
	}
}

// startDaemon uses the installed CLI and deliberately leaves supervision to
// the daemon itself. The tray never embeds or reimplements its logic.
//
// A GUI/autostart-launched tray does not inherit an interactive shell's PATH,
// so a bare "waspflow" often fails to resolve and the menu item silently does
// nothing. Resolve the binary explicitly — PATH first, then the standard
// user-local install dir — and return a real error if it cannot be found.
func startDaemon() error {
	bin, err := waspflowBinary()
	if err != nil {
		return err
	}
	command := exec.Command(bin, "federation", "daemon")
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		return err
	}
	go func() { _ = command.Wait() }()
	return nil
}

func waspflowBinary() (string, error) {
	if path, err := exec.LookPath("waspflow"); err == nil {
		return path, nil
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidate := filepath.Join(home, ".local", "bin", "waspflow")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("waspflow CLI not found on PATH or in ~/.local/bin")
}
