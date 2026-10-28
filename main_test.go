package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestEntries(t *testing.T) {
	tests := []struct {
		value string
		want  [][]string
	}{
		{"", nil},
		{"  ;; ", nil},
		{"killswitch on", [][]string{{"killswitch", "on"}}},
		{"killswitch on; protocol nordlynx ;", [][]string{{"killswitch", "on"}, {"protocol", "nordlynx"}}},
		{"subnet 10.244.0.0/16;port 8191 protocol TCP", [][]string{{"subnet", "10.244.0.0/16"}, {"port", "8191", "protocol", "TCP"}}},
	}
	for _, test := range tests {
		if got := entries(test.value); !reflect.DeepEqual(got, test.want) {
			t.Errorf("entries(%q) = %q, want %q", test.value, got, test.want)
		}
	}
}

func TestAlreadyDone(t *testing.T) {
	for out, want := range map[string]bool{
		"You are already logged in.":                        true,
		"Meshnet is already enabled.":                       true,
		"Subnet 10.244.0.0/16 is already on the allowlist.": true,
		"Kill Switch is already set to 'enabled'.":          true,
		"Whoops! Connection failed.":                        false,
	} {
		if got := alreadyDone([]byte(out)); got != want {
			t.Errorf("alreadyDone(%q) = %v, want %v", out, got, want)
		}
	}
}

func TestSysctlApplied(t *testing.T) {
	root := t.TempDir()
	key := filepath.Join(root, "net/ipv6/conf/all")
	if err := os.MkdirAll(key, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(key, "disable_ipv6"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		args []string
		want bool
	}{
		{[]string{"-w", "net.ipv6.conf.all.disable_ipv6=1"}, true},
		{[]string{"net.ipv6.conf.all.disable_ipv6=1"}, true},
		{[]string{"-w", "net.ipv6.conf.all.disable_ipv6=0"}, false},
		{[]string{"-w", "net.ipv6.conf.all.missing=1"}, false},
		{[]string{"-n", "net.ipv6.conf.all.disable_ipv6"}, false},
		{nil, false},
	} {
		if got := sysctlApplied(test.args, root); got != test.want {
			t.Errorf("sysctlApplied(%q) = %v, want %v", test.args, got, test.want)
		}
	}
}
