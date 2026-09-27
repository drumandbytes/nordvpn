package main

import (
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
		{"killswitch on; technology nordlynx ;", [][]string{{"killswitch", "on"}, {"technology", "nordlynx"}}},
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
