package server

import (
	"fmt"
	"net/http"
	"strings"
	"sync"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/localprocess"
)

// ── Runtime manager ─────────────────────────────────────────────────────────

// localProcessManager owns one host process handle per configured local
// process, keyed by profile + environment + name.
type localProcessManager struct {
	mu      sync.Mutex
	handles map[string]*localprocess.Handle
}

func newLocalProcessManager() *localProcessManager {
	return &localProcessManager{handles: map[string]*localprocess.Handle{}}
}

func lpKey(profile, env, name string) string {
	return profile + "\x00" + env + "\x00" + name
}

func lpPrefix(profile, env string) string {
	return profile + "\x00" + env + "\x00"
}

// reconcile aligns live handles with the persisted configuration, adopting
// processes that survived an engine restart and stopping processes removed
// from the config.
func (m *localProcessManager) reconcile(profile, env string, procs []config.LocalProcess) {
	wanted := make(map[string]config.LocalProcess, len(procs))
	for _, lp := range procs {
		wanted[lpKey(profile, env, lp.Name)] = lp
	}

	m.mu.Lock()
	var stale []*localprocess.Handle
	for k, h := range m.handles {
		if !strings.HasPrefix(k, lpPrefix(profile, env)) {
			continue
		}
		if _, ok := wanted[k]; !ok {
			stale = append(stale, h)
			delete(m.handles, k)
		}
	}
	for k, lp := range wanted {
		if h, ok := m.handles[k]; ok {
			h.UpdateConfig(lp)
			continue
		}
		pidPath := localprocess.PIDPath(profile, env, lp.Name)
		h := localprocess.NewHandle(lp, pidPath)
		if pid, ok := localprocess.ReadPIDFile(pidPath); ok && localprocess.Alive(pid) {
			h.Adopt(pid)
		}
		m.handles[k] = h
	}
	m.mu.Unlock()

	for _, h := range stale {
		_ = h.Stop()
	}
}

func (m *localProcessManager) get(profile, env, name string) (*localprocess.Handle, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.handles[lpKey(profile, env, name)]
	return h, ok
}

type lpRuntime struct {
	State string `json:"state"`
	PID   int    `json:"pid,omitempty"`
}

func (m *localProcessManager) snapshot(profile, env string) map[string]lpRuntime {
	m.mu.Lock()
	handles := make(map[string]*localprocess.Handle, len(m.handles))
	for k, h := range m.handles {
		if strings.HasPrefix(k, lpPrefix(profile, env)) {
			handles[k] = h
		}
	}
	m.mu.Unlock()

	out := make(map[string]lpRuntime, len(handles))
	for k, h := range handles {
		name := strings.TrimPrefix(k, lpPrefix(profile, env))
		running, pid := h.Snapshot()
		state := "stopped"
		if running {
			state = "running"
		}
		out[name] = lpRuntime{State: state, PID: pid}
	}
	return out
}

func (m *localProcessManager) start(profile, env, name string) (lpRuntime, error) {
	h, ok := m.get(profile, env, name)
	if !ok {
		return lpRuntime{}, fmt.Errorf("local process %q not found", name)
	}
	if err := h.Start(); err != nil {
		return lpRuntime{State: "failed"}, err
	}
	running, pid := h.Snapshot()
	state := "stopped"
	if running {
		state = "running"
	}
	return lpRuntime{State: state, PID: pid}, nil
}

func (m *localProcessManager) stop(profile, env, name string) (lpRuntime, error) {
	h, ok := m.get(profile, env, name)
	if !ok {
		return lpRuntime{}, fmt.Errorf("local process %q not found", name)
	}
	if err := h.Stop(); err != nil {
		return lpRuntime{State: "failed"}, err
	}
	return lpRuntime{State: "stopped"}, nil
}

func (m *localProcessManager) startAll(profile, env string) {
	m.mu.Lock()
	var handles []*localprocess.Handle
	for k, h := range m.handles {
		if strings.HasPrefix(k, lpPrefix(profile, env)) {
			handles = append(handles, h)
		}
	}
	m.mu.Unlock()
	for _, h := range handles {
		_ = h.Start()
	}
}

func (m *localProcessManager) stopAll(profile, env string) {
	m.mu.Lock()
	var handles []*localprocess.Handle
	for k, h := range m.handles {
		if strings.HasPrefix(k, lpPrefix(profile, env)) {
			handles = append(handles, h)
		}
	}
	m.mu.Unlock()
	for _, h := range handles {
		_ = h.Stop()
	}
}

func (m *localProcessManager) remove(profile, env, name string) {
	h, ok := m.get(profile, env, name)
	if !ok {
		return
	}
	_ = h.Stop()
	m.mu.Lock()
	delete(m.handles, lpKey(profile, env, name))
	m.mu.Unlock()
}

func (m *localProcessManager) removeProfile(profile string) {
	prefix := profile + "\x00"
	m.mu.Lock()
	var handles []*localprocess.Handle
	for k, h := range m.handles {
		if strings.HasPrefix(k, prefix) {
			handles = append(handles, h)
			delete(m.handles, k)
		}
	}
	m.mu.Unlock()
	for _, h := range handles {
		_ = h.Stop()
	}
}

func (m *localProcessManager) stopAllGlobal() {
	m.mu.Lock()
	handles := make([]*localprocess.Handle, 0, len(m.handles))
	for _, h := range m.handles {
		handles = append(handles, h)
	}
	m.mu.Unlock()
	for _, h := range handles {
		_ = h.Stop()
	}
}

// ── Handlers: CRUD ──────────────────────────────────────────────────────────

type localProcessRequest struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	WorkDir string `json:"workDir"`
}

func (s *Server) handleAddLocalProcess(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")

	var req localProcessRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}
	name = config.SanitizeComposeName(name)
	command := strings.TrimSpace(req.Command)
	if command == "" {
		writeError(w, http.StatusBadRequest, "command is required")
		return
	}
	for _, svc := range env.Services {
		if svc.Name == name {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("a service named %q already exists", name))
			return
		}
	}
	for _, lp := range env.LocalProcesses {
		if lp.Name == name {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("a local process named %q already exists", name))
			return
		}
	}

	lp := config.LocalProcess{Name: name, Command: command, WorkDir: strings.TrimSpace(req.WorkDir)}
	err = s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		_, err := c.AddLocalProcess(p.Name, envName, lp)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	s.lp.reconcile(profileName, envName, append(env.LocalProcesses, lp))
	detail, err := s.environmentDetail(profileName, envName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, detail)
}

func (s *Server) handleDeleteLocalProcess(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	name := r.PathValue("name")

	s.lp.remove(profileName, envName, name)

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		_, err := c.DeleteLocalProcess(p.Name, envName, name)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Handlers: actions ───────────────────────────────────────────────────────

func (s *Server) handleLocalProcessAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	name := r.PathValue("name")
	action := r.PathValue("action")

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	s.lp.reconcile(profileName, envName, env.LocalProcesses)

	var runtime lpRuntime
	switch action {
	case "start":
		runtime, err = s.lp.start(profileName, envName, name)
	case "stop":
		runtime, err = s.lp.stop(profileName, envName, name)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown local process action %q", action))
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, runtime)
}

func (s *Server) handleLocalProcessesAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	action := r.PathValue("action")

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	s.lp.reconcile(profileName, envName, env.LocalProcesses)

	switch action {
	case "start":
		s.lp.startAll(profileName, envName)
	case "stop":
		s.lp.stopAll(profileName, envName)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown local process action %q", action))
		return
	}

	detail, err := s.environmentDetail(profileName, envName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, detail)
}
