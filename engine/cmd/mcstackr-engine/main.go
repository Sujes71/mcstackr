// Command mcstackr-engine runs the local Stackr engine.
//
// The engine owns all domain work (config, docker, kubectl, git) and exposes
// it to the native macOS UI over a token-authenticated loopback HTTP API.
// It prints a single handshake line on stdout so the app can discover the
// ephemeral port and bearer token:
//
//	MCSTACKR_READY <port> <token>
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/server"
)

const version = "0.1.0"

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.SetPrefix("mcstackr-engine ")

	token, err := randomToken()
	if err != nil {
		log.Fatalf("generate token: %v", err)
	}

	srv, err := server.New(token, version)
	if err != nil {
		log.Fatalf("init server: %v", err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}

	port := ln.Addr().(*net.TCPAddr).Port
	if _, err := fmt.Fprintf(os.Stdout, "MCSTACKR_READY %d %s\n", port, token); err != nil {
		log.Fatalf("write handshake: %v", err)
	}
	_ = os.Stdout.Sync()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigCh
		cancel()
	}()

	// The app sets this so a crashed or force-quit UI cannot leave an orphan
	// engine behind holding port-forwards and log streams.
	if os.Getenv("MCSTACKR_EXIT_ON_STDIN_EOF") == "1" {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			cancel()
		}()
	}

	httpSrv := &http.Server{
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
			return
		}
		serveErr <- nil
	}()

	log.Printf("listening on 127.0.0.1:%d", port)

	select {
	case <-ctx.Done():
		log.Printf("shutting down")
	case err := <-serveErr:
		if err != nil {
			log.Printf("serve: %v", err)
		}
	}

	// Stop kubectl port-forward subprocesses before the process disappears.
	srv.Shutdown()

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer shutdownCancel()
	_ = httpSrv.Shutdown(shutdownCtx)
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
