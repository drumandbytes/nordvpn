// Replaces entrypoint.sh + healthcheck.sh — distroless has no shell to run
// either as scripts. See README.md for why (multi-stage build copying just
// the binaries/libraries this needs onto gcr.io/distroless/base-debian12).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const nordvpnBin = "/usr/bin/nordvpn"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	run()
}

// Same check as the old healthcheck.sh: pass if either a regular VPN
// tunnel is connected or Meshnet is enabled.
func healthcheck() int {
	if cliOutputContains("status", "status: connected") {
		return 0
	}
	if cliOutputContains("settings", "meshnet: enabled") {
		return 0
	}
	return 1
}

func cliOutputContains(subcmd, want string) bool {
	out, err := exec.Command(nordvpnBin, subcmd).CombinedOutput()
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(out)), want)
}

func run() {
	// nordvpnd watches this file at startup to pick a log level, and
	// defaults to its most verbose ("debug") when the file — and the
	// /run/nordvpn directory it lives in — don't exist, which they never
	// do in a fresh container. Every "Response: HTTP/1.1 200 - map[...]"
	// full-header dump and JSON config blob seen throughout this image's
	// logs has been at that level. "info" is nordvpnd's own default
	// outside a container; NORDVPN_LOG_LEVEL overrides it for anyone who
	// wants debug output back temporarily.
	level := "info"
	if l := os.Getenv("NORDVPN_LOG_LEVEL"); l != "" {
		level = l
	}
	if err := os.MkdirAll("/run/nordvpn", 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "warning: creating /run/nordvpn failed:", err)
	} else if err := os.WriteFile("/run/nordvpn/loglevel", []byte(level), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "warning: setting log level failed:", err)
	}

	cmd := exec.Command("/usr/sbin/nordvpnd")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "failed to start nordvpnd:", err)
		os.Exit(1)
	}
	daemonPID := cmd.Process.Pid

	// We're PID 1 — forward termination signals to nordvpnd.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		_ = cmd.Process.Signal(sig)
	}()

	waitForDaemon()

	// Not opt-in, unlike everything below: on first run the CLI blocks any
	// command behind an interactive "Do you allow us to collect app
	// performance data? (y/n)" consent prompt, reading from stdin — which
	// doesn't exist in a detached/non-interactive container (docker run -d,
	// a Kubernetes pod with no stdin attached). Without this, `login` just
	// hangs forever with no error, silently. Declining is also the
	// consistent choice with everything else here defaulting to off.
	runCLI("declining analytics consent failed", "set", "analytics", "off")

	if token := os.Getenv("NORDVPN_TOKEN"); token != "" {
		// Retried, unlike everything else here: a single transient timeout
		// on NordVPN's own credentials API (observed in production, not
		// hypothetical) permanently fails login for the container's entire
		// life otherwise, since nothing downstream re-attempts it - meshnet
		// and connect both just stay in "not logged in" forever regardless
		// of how patient the liveness probe is.
		runCLIRetry("login failed", 5, 10*time.Second, "login", "--token", token)
	}

	// Everything below is opt-in — this image is a plain NordVPN client,
	// usable for a regular VPN tunnel, Meshnet, or both at once. Nothing
	// is assumed. Each is allowed to fail without taking nordvpnd down
	// with it: e.g. NORDVPN_CONNECT set without a successful login yet
	// (normal during interactive setup — start the container, then exec
	// in to log in and connect by hand) shouldn't crash the container
	// before there's ever a chance to fix it interactively.

	if fw := os.Getenv("NORDVPN_FIREWALL"); fw != "" {
		runCLI("setting firewall failed", "set", "firewall", fw)
	}

	if connect, ok := os.LookupEnv("NORDVPN_CONNECT"); ok {
		// Empty value picks the recommended server. A value can be a
		// country, city, server, or group — anything the CLI's own
		// `connect` argument accepts, including multi-word values like
		// "Hungary Budapest" that need to reach the CLI as separate args.
		args := append([]string{"connect"}, strings.Fields(connect)...)
		runCLI("connect failed (not logged in yet?)", args...)
	}

	if os.Getenv("NORDVPN_MESHNET") == "on" {
		runCLI("enabling meshnet failed", "set", "meshnet", "on")
		if nick := os.Getenv("NORDVPN_NICKNAME"); nick != "" {
			setNicknameRetry(nick, 6, 5*time.Second)
		}
	}

	os.Exit(waitAndReap(daemonPID))
}

// We started nordvpnd with cmd.Start(), not cmd.Run()/cmd.Wait(), so we own
// reaping it — and as PID 1, also anything nordvpnd itself spawns and
// abandons (nordfileshare, norduserd, openvpn), which would otherwise pile
// up as zombies. One wait loop handles both: keep reaping until nordvpnd's
// own PID shows up exited, then mirror its exit code.
func waitAndReap(daemonPID int) int {
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, 0, nil)
		if err != nil {
			return 1 // ECHILD: no children left, including nordvpnd — unexpected, but nothing left to wait for
		}
		if pid == daemonPID {
			return status.ExitStatus()
		}
	}
}

func waitForDaemon() {
	for range 30 {
		if err := exec.Command(nordvpnBin, "status").Run(); err == nil {
			return
		}
		time.Sleep(time.Second)
	}
}

func runCLI(warnMsg string, args ...string) {
	if out, err := exec.Command(nordvpnBin, args...).CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: %s: %s\n", warnMsg, strings.TrimSpace(string(out)))
	}
}

// `meshnet set nickname` returns success even when the device isn't fully
// registered yet, silently no-oping instead of erroring — so unlike
// runCLIRetry, success here means actually checking the nickname stuck via
// `meshnet peer list`, not trusting the set command's own exit code.
func setNicknameRetry(nick string, attempts int, delay time.Duration) {
	for i := 0; i < attempts; i++ {
		_, _ = exec.Command(nordvpnBin, "meshnet", "set", "nickname", nick).CombinedOutput()
		out, err := exec.Command(nordvpnBin, "meshnet", "peer", "list").CombinedOutput()
		if err == nil && strings.Contains(string(out), "Nickname: "+nick) {
			return
		}
		if i < attempts-1 {
			time.Sleep(delay)
		}
	}
	fmt.Fprintf(os.Stderr, "warning: setting nickname %q never took effect after %d attempts\n", nick, attempts)
}

func runCLIRetry(warnMsg string, attempts int, delay time.Duration, args ...string) {
	var out []byte
	var err error
	for i := 0; i < attempts; i++ {
		out, err = exec.Command(nordvpnBin, args...).CombinedOutput()
		if err == nil {
			return
		}
		if i < attempts-1 {
			time.Sleep(delay)
		}
	}
	fmt.Fprintf(os.Stderr, "warning: %s: %s\n", warnMsg, strings.TrimSpace(string(out)))
}
