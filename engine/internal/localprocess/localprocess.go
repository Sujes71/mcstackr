// Package localprocess runs the host commands declared in an environment's
// local_processes list. It mirrors the Stackr CLI runtime: each process runs in
// its own process group, its PID is persisted under
// ~/.stackr/<profile>/<env>/procs/ so a restarted engine can adopt orphans, and
// stopping a process kills the whole group.
package localprocess

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
)

// Handle owns a single local process.
type Handle struct {
	mu      sync.Mutex
	cfg     config.LocalProcess
	pidPath string
	cmd     *exec.Cmd
	pid     int
	running bool
	done    chan struct{}
}

// NewHandle builds a handle for a configured process. The process is not
// started until Start is called.
func NewHandle(cfg config.LocalProcess, pidPath string) *Handle {
	return &Handle{cfg: cfg, pidPath: pidPath}
}

// PIDPath returns the PID file location for a configured local process.
func PIDPath(profile, env, name string) string {
	return filepath.Join(config.ProfileDir(profile), env, "procs", name+".pid")
}

// Config returns the current configuration of the process.
func (h *Handle) Config() config.LocalProcess {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.cfg
}

// UpdateConfig refreshes the stored configuration. A running process keeps its
// original command line until it is restarted.
func (h *Handle) UpdateConfig(cfg config.LocalProcess) {
	h.mu.Lock()
	h.cfg = cfg
	h.mu.Unlock()
}

// Snapshot reports whether the process is currently running and its PID.
func (h *Handle) Snapshot() (running bool, pid int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.running && h.cmd != nil && h.cmd.ProcessState != nil {
		h.running = false
	}
	return h.running, h.pid
}

// Adopt marks an already-running PID (found through a PID file) as tracked.
func (h *Handle) Adopt(pid int) {
	h.mu.Lock()
	h.pid = pid
	h.running = true
	h.cmd = nil
	h.done = nil
	h.mu.Unlock()
}

// Start launches the configured command. A running process is stopped first so
// start is idempotent, matching the CLI.
func (h *Handle) Start() error {
	if running, _ := h.Snapshot(); running {
		if err := h.Stop(); err != nil {
			return err
		}
	}

	h.mu.Lock()
	cfg := h.cfg
	h.mu.Unlock()

	if strings.TrimSpace(cfg.Command) == "" {
		return fmt.Errorf("local process %q has an empty command", cfg.Name)
	}

	cmd := shellCommand(cfg.Command)
	setNewProcessGroup(cmd)
	if cfg.WorkDir != "" {
		cmd.Dir = expandHome(cfg.WorkDir)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", cfg.Name, err)
	}

	done := make(chan struct{})
	h.mu.Lock()
	h.cmd = cmd
	h.pid = cmd.Process.Pid
	h.running = true
	h.done = done
	pidPath := h.pidPath
	h.mu.Unlock()

	writePIDFile(pidPath, cmd.Process.Pid)
	go h.wait(cmd, done, pidPath, cmd.Process.Pid)
	return nil
}

func (h *Handle) wait(cmd *exec.Cmd, done chan struct{}, pidPath string, pid int) {
	_ = cmd.Wait()

	h.mu.Lock()
	if h.cmd == cmd {
		h.running = false
		h.cmd = nil
		h.pid = 0
		h.done = nil
	}
	h.mu.Unlock()

	removePIDFileIf(pidPath, pid)
	close(done)
}

// Stop kills the process group and waits up to five seconds for it to exit.
func (h *Handle) Stop() error {
	h.mu.Lock()
	pid := h.pid
	cmd := h.cmd
	done := h.done
	running := h.running
	h.running = false
	h.cmd = nil
	h.pid = 0
	h.done = nil
	h.mu.Unlock()

	if !running || pid == 0 {
		removePIDFile(h.pidPath)
		return nil
	}

	killGroup(pid)
	if cmd != nil && done != nil {
		select {
		case <-done:
		case <-time.After(5 * time.Second):
		}
	}
	removePIDFile(h.pidPath)
	return nil
}

// ReadPIDFile returns the PID persisted for a local process, if any.
func ReadPIDFile(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

func writePIDFile(path string, pid int) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(path, []byte(strconv.Itoa(pid)+"\n"), 0o644)
}

func removePIDFile(path string) {
	_ = os.Remove(path)
}

// removePIDFileIf removes the PID file only when it still belongs to pid, so a
// fast restart does not delete the new process' file.
func removePIDFileIf(path string, pid int) {
	if current, ok := ReadPIDFile(path); !ok || current != pid {
		return
	}
	removePIDFile(path)
}
