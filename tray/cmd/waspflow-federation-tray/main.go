package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
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

	app.applyVisualState(federationtray.VisualSetup, statusItem, contributeItem, startItem)
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
	info, err := federationtray.ReadDaemonInfo(app.infoPath)
	if err != nil {
		app.applyVisualState(federationtray.VisualSetup, statusItem, contributeItem, startItem)
		return
	}
	context, cancel := context.WithTimeout(context.Background(), time.Second)
	status, err := app.client.Status(context, info)
	cancel()
	if err != nil {
		app.applyVisualState(federationtray.VisualSetup, statusItem, contributeItem, startItem)
		return
	}
	app.mu.Lock()
	app.info = info
	previousState := app.state
	app.mu.Unlock()
	visualState := federationtray.VisualStateForDaemonState(status.State)
	app.applyVisualState(visualState, statusItem, contributeItem, startItem)
	if visualState == federationtray.VisualAttention && previousState != federationtray.VisualAttention {
		_ = browser.OpenURL(federationtray.FederationURL(info))
	}
}

func (app *trayApp) applyVisualState(state federationtray.VisualState, statusItem, contributeItem, startItem *systray.MenuItem) {
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
		statusItem.SetTitle("Federation daemon is not running")
		contributeItem.SetTitle("Resume contributing")
		contributeItem.Disable()
		startItem.Show()
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
func startDaemon() error {
	command := exec.Command("waspflow", "federation", "daemon")
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		return err
	}
	go func() { _ = command.Wait() }()
	return nil
}
