// Command gateway is the tinyinfer data plane: an OpenAI-compatible streaming proxy.
// main only wires things together; the HTTP layer lives in internal/gateway.
package main

import (
	"log/slog"
	"os"

	"github.com/harikrish19924/mini-infer/internal/gateway"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":9090" // not 8080: k3d maps the Mac's 8080 to the cluster ingress
	}

	// TODO(phase 2, step 5): read models from the TINYINFER_CONFIG file.
	// These match deploy/helm/vllm's --served-model-name and --max-model-len.
	models := []gateway.Model{
		{Name: "qwen-0.5b", MaxModelLen: 4096},
	}

	srv := gateway.New(addr, models)

	slog.Info("gateway listening", "addr", addr)
	if err := srv.Run(); err != nil {
		slog.Error("gateway stopped", "err", err)
		os.Exit(1)
	}
}
