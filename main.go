// Replaces entrypoint.sh + healthcheck.sh: distroless has no shell.
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

// healthy if a VPN tunnel is connected or Meshnet is enabled
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
	// nordvpnd defaults to "debug" (full HTTP header dumps) when this file is
	// missing, which it always is in a fresh container. NORDVPN_LOG_LEVEL overrides.
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

	// PID 1: forward termination signals to nordvpnd
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-sigCh
		_ = cmd.Process.Signal(sig)
	}()

	waitForDaemon()

	// Not opt-in: on first run the CLI blocks every command on an analytics
	// y/n prompt from stdin, which a detached container doesn't have, so login
	// hangs silently. Decline.
	runCLI("declining analytics consent failed", "set", "analytics", "off")

	if token := os.Getenv("NORDVPN_TOKEN"); token != "" {
		// retried: one transient timeout on NordVPN's credentials API (seen in
		// prod) otherwise leaves the container logged out for its whole life
		runCLIRetry("login failed", 5, 10*time.Second, "login", "--token", token)
	}

	// Everything below is opt-in and allowed to fail without killing nordvpnd,
	// e.g. NORDVPN_CONNECT before login during interactive setup.

	if fw := os.Getenv("NORDVPN_FIREWALL"); fw != "" {
		runCLI("setting firewall failed", "set", "firewall", fw)
	}

	if connect, ok := os.LookupEnv("NORDVPN_CONNECT"); ok {
		// empty = recommended server; multi-word values ("Hungary Budapest")
		// must reach the CLI as separate args
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

// As PID 1 we reap nordvpnd and anything it abandons (nordfileshare,
// norduserd, openvpn) until nordvpnd itself exits, then mirror its code.
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
		// the CLI exits non-zero when the state is already the one asked for
		// (e.g. meshnet already on from the persisted PVC)
		if alreadyDone(out) {
			return
		}
		fmt.Fprintf(os.Stderr, "warning: %s: %s\n", warnMsg, strings.TrimSpace(string(out)))
	}
}

func alreadyDone(out []byte) bool {
	s := strings.ToLower(string(out))
	return strings.Contains(s, "already logged in") || strings.Contains(s, "already enabled")
}

// `meshnet set nickname` succeeds silently before the device is registered,
// so success means `meshnet peer list` shows the nickname, not the exit code.
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
		// non-zero exit on an already-satisfied precondition (e.g. already logged
		// in); without this it burns the retry budget and warns misleadingly
		outStr := strings.ToLower(string(out))
		if strings.Contains(outStr, "already logged in") || strings.Contains(outStr, "already enabled") {
			return
		}
		if i < attempts-1 {
			time.Sleep(delay)
		}
	}
	fmt.Fprintf(os.Stderr, "warning: %s: %s\n", warnMsg, strings.TrimSpace(string(out)))
}
