package server

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/portforward"
)

// ── Runtime manager ─────────────────────────────────────────────────────────

// portForwardManager owns one kubectl port-forward handle per configured
// forward. Handles are keyed by profile + environment + forward name because a
// single engine can serve every workspace at once.
type portForwardManager struct {
	mu      sync.Mutex
	handles map[string]*portforward.PortForwardHandle
}

func newPortForwardManager() *portForwardManager {
	return &portForwardManager{handles: map[string]*portforward.PortForwardHandle{}}
}

func pfKey(profile, env, name string) string {
	return profile + "\x00" + env + "\x00" + name
}

func pfPrefix(profile, env string) string {
	return profile + "\x00" + env + "\x00"
}

// reconcile aligns the live handles with the persisted configuration. It is
// called before every environment read so a CLI edit of config.yaml is picked
// up without restarting the engine.
func (m *portForwardManager) reconcile(profile, env string, forwards []config.PortForward) {
	wanted := make(map[string]config.PortForward, len(forwards))
	for _, pf := range forwards {
		wanted[pfKey(profile, env, pf.Name)] = pf
	}

	m.mu.Lock()
	var stale []*portforward.PortForwardHandle
	for k, h := range m.handles {
		if !strings.HasPrefix(k, pfPrefix(profile, env)) {
			continue
		}
		if _, ok := wanted[k]; !ok {
			stale = append(stale, h)
			delete(m.handles, k)
		}
	}
	for k, pf := range wanted {
		if h, ok := m.handles[k]; ok {
			state, _ := h.Snapshot()
			if state != portforward.ForwardRunning && state != portforward.ForwardStarting {
				h.UpdateConfig(pf)
			}
			continue
		}
		m.handles[k] = portforward.NewHandle(pf)
	}
	m.mu.Unlock()

	for _, h := range stale {
		_ = h.Stop()
	}
}

func (m *portForwardManager) get(profile, env, name string) (*portforward.PortForwardHandle, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	h, ok := m.handles[pfKey(profile, env, name)]
	return h, ok
}

func (m *portForwardManager) handlesFor(profile, env string) []*portforward.PortForwardHandle {
	m.mu.Lock()
	defer m.mu.Unlock()
	prefix := pfPrefix(profile, env)
	out := make([]*portforward.PortForwardHandle, 0)
	for k, h := range m.handles {
		if strings.HasPrefix(k, prefix) {
			out = append(out, h)
		}
	}
	return out
}

func (m *portForwardManager) remove(profile, env, name string) {
	m.mu.Lock()
	h, ok := m.handles[pfKey(profile, env, name)]
	if ok {
		delete(m.handles, pfKey(profile, env, name))
	}
	m.mu.Unlock()
	if ok {
		_ = h.Stop()
	}
}

func (m *portForwardManager) removeProfile(profile string) {
	prefix := profile + "\x00"
	m.mu.Lock()
	var stale []*portforward.PortForwardHandle
	for k, h := range m.handles {
		if strings.HasPrefix(k, prefix) {
			stale = append(stale, h)
			delete(m.handles, k)
		}
	}
	m.mu.Unlock()
	for _, h := range stale {
		_ = h.Stop()
	}
}

// snapshot returns the live state of every forward in an environment, running
// a non-blocking liveness check first so a kubectl process that died between
// polls shows up as failed.
func (m *portForwardManager) snapshot(profile, env string) map[string]pfRuntime {
	out := make(map[string]pfRuntime)
	for _, h := range m.handlesFor(profile, env) {
		state, errMsg := h.Snapshot()
		if state == portforward.ForwardRunning || state == portforward.ForwardStarting {
			state, errMsg = h.Snapshot()
			state = h.CheckAlive()
			if state == portforward.ForwardFailed {
				_, errMsg = h.Snapshot()
			}
		}
		cfg := h.ConfigCopy()
		out[cfg.Name] = pfRuntime{State: state.String(), Error: strings.TrimSpace(errMsg)}
	}
	return out
}

func (m *portForwardManager) start(profile, env, name string) (pfRuntime, error) {
	h, ok := m.get(profile, env, name)
	if !ok {
		return pfRuntime{}, fmt.Errorf("port-forward %q is not configured", name)
	}
	_ = h.Start()
	state, errMsg := h.Snapshot()
	return pfRuntime{State: state.String(), Error: strings.TrimSpace(errMsg)}, nil
}

func (m *portForwardManager) stop(profile, env, name string) (pfRuntime, error) {
	h, ok := m.get(profile, env, name)
	if !ok {
		return pfRuntime{}, fmt.Errorf("port-forward %q is not configured", name)
	}
	_ = h.Stop()
	state, errMsg := h.Snapshot()
	return pfRuntime{State: state.String(), Error: strings.TrimSpace(errMsg)}, nil
}

func (m *portForwardManager) startAll(profile, env string) {
	hs := m.handlesFor(profile, env)
	var wg sync.WaitGroup
	for _, h := range hs {
		state, _ := h.Snapshot()
		if state == portforward.ForwardRunning || state == portforward.ForwardStarting {
			continue
		}
		wg.Add(1)
		go func(h *portforward.PortForwardHandle) {
			defer wg.Done()
			_ = h.Start()
		}(h)
	}
	wg.Wait()
}

func (m *portForwardManager) stopAll(profile, env string) {
	hs := m.handlesFor(profile, env)
	var wg sync.WaitGroup
	for _, h := range hs {
		state, _ := h.Snapshot()
		if state == portforward.ForwardStopped {
			continue
		}
		wg.Add(1)
		go func(h *portforward.PortForwardHandle) {
			defer wg.Done()
			_ = h.Stop()
		}(h)
	}
	wg.Wait()
}

// stopAllGlobal tears down every handle; used on engine shutdown so a crashed
// app never leaves kubectl processes behind.
func (m *portForwardManager) stopAllGlobal() {
	m.mu.Lock()
	hs := make([]*portforward.PortForwardHandle, 0, len(m.handles))
	for _, h := range m.handles {
		hs = append(hs, h)
	}
	m.handles = map[string]*portforward.PortForwardHandle{}
	m.mu.Unlock()
	for _, h := range hs {
		_ = h.Stop()
	}
}

// Shutdown stops every live port-forward. Safe to call more than once.
func (s *Server) Shutdown() {
	s.pf.stopAllGlobal()
	s.lp.stopAllGlobal()
}

// ── DTOs ────────────────────────────────────────────────────────────────────

type pfRuntime struct {
	State string `json:"state"`
	Error string `json:"error,omitempty"`
}

type portForwardRequest struct {
	Name         string `json:"name"`
	LocalPort    int    `json:"localPort"`
	RemotePort   int    `json:"remotePort"`
	K8sContext   string `json:"k8sContext"`
	K8sNamespace string `json:"k8sNamespace"`
	K8sService   string `json:"k8sService"`
}

type discoveredServiceDTO struct {
	Name       string `json:"name"`
	RemotePort int    `json:"remotePort"`
}

// ── Helpers ─────────────────────────────────────────────────────────────────

func (s *Server) loadEnvironment(profileName, envName string) (config.Environment, error) {
	var env config.Environment
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		idx := indexOfEnv(*p, envName)
		if idx < 0 {
			return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
		}
		env = p.Environments[idx]
		return nil
	})
	return env, err
}

func (s *Server) environmentDetail(profileName, envName string) (environmentDetailDTO, error) {
	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		return environmentDetailDTO{}, err
	}
	s.pf.reconcile(profileName, envName, env.PortForwards)
	s.lp.reconcile(profileName, envName, env.LocalProcesses)
	return toEnvironmentDetailDTO(env, s.pf.snapshot(profileName, envName), s.lp.snapshot(profileName, envName)), nil
}

func validatePortForward(req portForwardRequest, others []config.PortForward) (config.PortForward, error) {
	pf := config.PortForward{
		Name:         strings.TrimSpace(req.Name),
		LocalPort:    req.LocalPort,
		RemotePort:   req.RemotePort,
		K8sContext:   strings.TrimSpace(req.K8sContext),
		K8sNamespace: strings.TrimSpace(req.K8sNamespace),
		K8sService:   strings.TrimSpace(req.K8sService),
	}
	if pf.Name == "" {
		return pf, fmt.Errorf("port-forward name is required")
	}
	if config.SanitizeComposeName(pf.Name) != pf.Name {
		return pf, fmt.Errorf("port-forward name may only contain letters, numbers, _, . and -")
	}
	if pf.K8sContext == "" || pf.K8sNamespace == "" || pf.K8sService == "" {
		return pf, fmt.Errorf("context, namespace and service are required")
	}
	if pf.LocalPort < 1 || pf.LocalPort > 65535 {
		return pf, fmt.Errorf("local port must be between 1 and 65535")
	}
	if pf.RemotePort < 1 || pf.RemotePort > 65535 {
		return pf, fmt.Errorf("remote port must be between 1 and 65535")
	}
	for _, other := range others {
		if other.Name == pf.Name {
			continue
		}
		if other.LocalPort == pf.LocalPort {
			return pf, fmt.Errorf("local port %d is already used by %q", pf.LocalPort, other.Name)
		}
	}
	return pf, nil
}

func toDiscoveredServices(forwards []config.PortForward) []discoveredServiceDTO {
	out := make([]discoveredServiceDTO, 0, len(forwards))
	for _, pf := range forwards {
		out = append(out, discoveredServiceDTO{Name: pf.Name, RemotePort: pf.RemotePort})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// ── Handlers: CRUD ──────────────────────────────────────────────────────────

func (s *Server) handleAddPortForward(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")

	var req portForwardRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	pf, err := validatePortForward(req, env.PortForwards)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	for _, existing := range env.PortForwards {
		if existing.Name == pf.Name {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("port-forward %q already exists", pf.Name))
			return
		}
	}

	err = s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		_, err := c.AddPortForward(p.Name, envName, pf)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	s.pf.reconcile(profileName, envName, append(env.PortForwards, pf))
	detail, err := s.environmentDetail(profileName, envName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, detail)
}

func (s *Server) handleUpdatePortForward(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	name := r.PathValue("name")

	var req portForwardRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = name

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	var previous config.PortForward
	found := false
	for _, existing := range env.PortForwards {
		if existing.Name == name {
			previous = existing
			found = true
			break
		}
	}
	if !found {
		writeError(w, http.StatusNotFound, fmt.Sprintf("port-forward %q not found", name))
		return
	}
	pf, err := validatePortForward(req, env.PortForwards)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	wasRunning := false
	if h, ok := s.pf.get(profileName, envName, name); ok {
		state, _ := h.Snapshot()
		wasRunning = state == portforward.ForwardRunning || state == portforward.ForwardStarting
		_ = h.Stop()
	}

	err = s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		_, err := c.UpdatePortForward(p.Name, envName, name, pf)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	s.pf.reconcile(profileName, envName, replaceForward(env.PortForwards, previous.Name, pf))
	if wasRunning {
		_, _ = s.pf.start(profileName, envName, name)
	}

	detail, err := s.environmentDetail(profileName, envName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

func replaceForward(list []config.PortForward, name string, updated config.PortForward) []config.PortForward {
	out := make([]config.PortForward, 0, len(list))
	for _, pf := range list {
		if pf.Name == name {
			out = append(out, updated)
			continue
		}
		out = append(out, pf)
	}
	return out
}

func (s *Server) handleDeletePortForward(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	name := r.PathValue("name")

	s.pf.remove(profileName, envName, name)

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		_, err := c.DeletePortForward(p.Name, envName, name)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Handlers: actions ───────────────────────────────────────────────────────

func (s *Server) handlePortForwardAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	name := r.PathValue("name")
	action := r.PathValue("action")

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	s.pf.reconcile(profileName, envName, env.PortForwards)

	var runtime pfRuntime
	switch action {
	case "start":
		runtime, err = s.pf.start(profileName, envName, name)
	case "stop":
		runtime, err = s.pf.stop(profileName, envName, name)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown port-forward action %q", action))
		return
	}
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, runtime)
}

func (s *Server) handlePortForwardsAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	action := r.PathValue("action")

	env, err := s.loadEnvironment(profileName, envName)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	s.pf.reconcile(profileName, envName, env.PortForwards)

	switch action {
	case "start":
		s.pf.startAll(profileName, envName)
	case "stop":
		s.pf.stopAll(profileName, envName)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown port-forward action %q", action))
		return
	}

	detail, err := s.environmentDetail(profileName, envName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

// ── Handlers: discovery ─────────────────────────────────────────────────────

func (s *Server) handleK8sStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"available": portforward.CheckKubectl()})
}

func (s *Server) handleK8sContexts(w http.ResponseWriter, r *http.Request) {
	contexts, err := portforward.DiscoverContexts()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if contexts == nil {
		contexts = []string{}
	}
	writeJSON(w, http.StatusOK, contexts)
}

func (s *Server) handleK8sNamespaces(w http.ResponseWriter, r *http.Request) {
	contextName := strings.TrimSpace(r.URL.Query().Get("context"))
	if contextName == "" {
		writeError(w, http.StatusBadRequest, "context is required")
		return
	}
	namespaces, err := portforward.DiscoverNamespaces(contextName)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if namespaces == nil {
		namespaces = []string{}
	}
	writeJSON(w, http.StatusOK, namespaces)
}

func (s *Server) handleK8sServices(w http.ResponseWriter, r *http.Request) {
	contextName := strings.TrimSpace(r.URL.Query().Get("context"))
	namespace := strings.TrimSpace(r.URL.Query().Get("namespace"))
	if contextName == "" || namespace == "" {
		writeError(w, http.StatusBadRequest, "context and namespace are required")
		return
	}
	forwards, err := portforward.DiscoverServices(contextName, namespace)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, toDiscoveredServices(forwards))
}

// ── Wiring helpers ──────────────────────────────────────────────────────────
