//go:build !windows

package localprocess

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// setNewProcessGroup puts the command in its own process group so stopping it
// also terminates the children it spawns.
func setNewProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killGroup sends SIGKILL to the whole process group.
func killGroup(pid int) {
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}

// Alive reports whether a PID is still running.
func Alive(pid int) bool {
	return pid > 0 && syscall.Kill(pid, syscall.Signal(0)) == nil
}

func shellCommand(command string) *exec.Cmd {
	return exec.Command("sh", "-c", command)
}

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return path
		}
		if path == "~" {
			return home
		}
		return home + path[1:]
	}
	return path
}
