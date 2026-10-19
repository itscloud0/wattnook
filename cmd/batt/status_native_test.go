package main

import (
	"bytes"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlie0129/batt/pkg/client"
)

func TestNativeStatusReadsActualLimit(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "wn-api-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	socket := filepath.Join(directory, "api.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	responses := map[string]string{
		"/compatibility": `{"chargingControl":true,"chargeControlMode":"native"}`,
		"/plugged-in":    "true", "/current-charge": "87", "/battery-info": `{}`,
		"/config": `{"limit":60,"lowerLimitDelta":2,"heatProtectionEnabled":true}`,
		"/limit":  "90", "/heat-protection": `{"enabled":false}`,
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := responses[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(body))
	})}
	go server.Serve(listener)
	defer server.Close()
	previous := apiClient
	defer func() { apiClient = previous }()
	apiClient = client.NewClient(socket)
	data, err := fetchStatusData()
	if err != nil {
		t.Fatal(err)
	}
	if *data.config.Limit != 90 || *data.config.HeatProtectionEnabled {
		t.Fatalf("status showed unenforced saved config: %+v", data.config)
	}
	command := NewStatusCommand()
	var output bytes.Buffer
	command.SetOut(&output)
	if err := command.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "Apple native") || strings.Contains(output.String(), "adapter is disabled") || strings.Contains(output.String(), "Allow charging:") {
		t.Fatal("native mode described as legacy SMC charging", output.String())
	}
	responses["/limit"] = `"unavailable"`
	if _, err := fetchStatusData(); err == nil {
		t.Fatal("read error reported as active limit")
	}
}
