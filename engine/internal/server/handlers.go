package server

import (
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/docker"
	"github.com/mcstackr/mcstackr/engine/internal/hub"
)

// ── DTOs ────────────────────────────────────────────────────────────────────

type profileDTO struct {
	Name         string           `json:"name"`
	Description  string           `json:"description,omitempty"`
	ActiveEnv    string           `json:"activeEnv"`
	Environments []environmentDTO `json:"environments"`
}

type environmentDTO struct {
	Name           string `json:"name"`
	ServiceCount   int    `json:"serviceCount"`
	PortForwards   int    `json:"portForwardCount"`
	LocalProcesses int    `json:"localProcessCount"`
}

type serviceDTO struct {
	Name      string   `json:"name"`
	Image     string   `json:"image"`
	Tag       string   `json:"tag"`
	FullImage string   `json:"fullImage"`
	DBType    string   `json:"dbType,omitempty"`
	QueueType string   `json:"queueType,omitempty"`
	MockType  string   `json:"mockType,omitempty"`
	Ports     []string `json:"ports"`
}

type serviceStatusDTO struct {
	Name      string `json:"name"`
	Container string `json:"container"`
	FullImage string `json:"fullImage"`
	DBType    string `json:"dbType,omitempty"`
	State     string `json:"state"`
	Health    string `json:"health,omitempty"`
	Ports     string `json:"ports,omitempty"`
}

type statusResponse struct {
	DockerAvailable bool               `json:"dockerAvailable"`
	Error           string             `json:"error,omitempty"`
	Services        []serviceStatusDTO `json:"services"`
	RefreshedAt     time.Time          `json:"refreshedAt"`
}

type hubResultDTO struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Official    bool   `json:"official"`
	Stars       int    `json:"stars"`
	Pulls       int    `json:"pulls"`
}

type imageDTO struct {
	Repository string `json:"repository"`
	Tag        string `json:"tag"`
	ID         string `json:"id"`
	Size       string `json:"size"`
}

type createProfileRequest struct {
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	Environments []string `json:"environments"`
}

type createEnvironmentRequest struct {
	Name string `json:"name"`
}

type createServiceRequest struct {
	Name  string          `json:"name"`
	Image string          `json:"image"`
	Tag   string          `json:"tag"`
	Ports []portMappingIn `json:"ports"`
}

type portMappingIn struct {
	Host      string `json:"host"`
	Container string `json:"container"`
}

// ── Health ──────────────────────────────────────────────────────────────────

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "ok",
		"version":         s.version,
		"dockerAvailable": docker.DaemonAvailable(),
		"configPath":      config.StackrDir(),
	})
}

// ── Profiles ────────────────────────────────────────────────────────────────

func (s *Server) handleListProfiles(w http.ResponseWriter, r *http.Request) {
	profiles := make([]profileDTO, 0)
	err := s.store.View(func(c *config.Config) error {
		for _, p := range c.Profiles {
			profiles = append(profiles, toProfileDTO(p))
		}
		return nil
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, profiles)
}

func toProfileDTO(p config.Profile) profileDTO {
	envs := make([]environmentDTO, 0, len(p.Environments))
	for _, e := range p.Environments {
		envs = append(envs, environmentDTO{
			Name:           e.Name,
			ServiceCount:   len(e.Services),
			PortForwards:   len(e.PortForwards),
			LocalProcesses: len(e.LocalProcesses),
		})
	}
	return profileDTO{
		Name:         p.Name,
		Description:  p.Description,
		ActiveEnv:    p.ActiveEnv,
		Environments: envs,
	}
}

func (s *Server) handleCreateProfile(w http.ResponseWriter, r *http.Request) {
	var req createProfileRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "profile name is required")
		return
	}
	if config.SanitizeComposeName(name) != name {
		writeError(w, http.StatusBadRequest, "profile name may only contain letters, numbers, _, . and -")
		return
	}

	envNames := make([]string, 0, len(req.Environments))
	seen := map[string]bool{}
	for _, raw := range req.Environments {
		env := strings.TrimSpace(raw)
		if env == "" || seen[env] {
			continue
		}
		if config.SanitizeComposeName(env) != env {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("environment %q has invalid characters", env))
			return
		}
		seen[env] = true
		envNames = append(envNames, env)
	}
	if len(envNames) == 0 {
		envNames = []string{"local"}
	}
	if len(envNames) > 5 {
		writeError(w, http.StatusBadRequest, "a profile supports at most 5 environments")
		return
	}

	now := time.Now()
	environments := make([]config.Environment, 0, len(envNames))
	for _, env := range envNames {
		environments = append(environments, config.Environment{Name: env})
	}
	profile := config.Profile{
		Name:         name,
		Description:  strings.TrimSpace(req.Description),
		CreatedAt:    now,
		UpdatedAt:    now,
		Environments: environments,
		ActiveEnv:    envNames[0],
	}

	err := s.store.Update(func(c *config.Config) error {
		if err := c.AddProfile(profile); err != nil {
			return err
		}
		if _, err := config.GenerateCompose(profile, envNames[0]); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, toProfileDTO(profile))
}

func (s *Server) handleCreateEnvironment(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	var req createEnvironmentRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeError(w, http.StatusBadRequest, "environment name is required")
		return
	}
	if config.SanitizeComposeName(name) != name {
		writeError(w, http.StatusBadRequest, "environment name may only contain letters, numbers, _, . and -")
		return
	}

	var updated config.Profile
	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		if len(p.Environments) >= 5 {
			return errors.New("a profile supports at most 5 environments")
		}
		for _, e := range p.Environments {
			if e.Name == name {
				return fmt.Errorf("environment %q already exists", name)
			}
		}
		p.Environments = append(p.Environments, config.Environment{Name: name})
		p.UpdatedAt = time.Now()
		updated = *p
		return nil
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, toProfileDTO(updated))
}

// ── Status ──────────────────────────────────────────────────────────────────

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")

	var env config.Environment
	var profile config.Profile
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		for _, e := range p.Environments {
			if e.Name == envName {
				env = e
				profile = *p
				return nil
			}
		}
		return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
	})
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	resp := statusResponse{RefreshedAt: time.Now(), Services: []serviceStatusDTO{}}
	if len(env.Services) > 0 {
		resp.DockerAvailable = docker.DaemonAvailable()
		if resp.DockerAvailable {
			statuses, err := docker.Status(profile.Name, env.Name)
			if err != nil {
				resp.Error = err.Error()
			}
			resp.Services = mergeStatuses(profile, env, statuses)
		} else {
			resp.Error = "Docker daemon is not running"
			resp.Services = mergeStatuses(profile, env, nil)
		}
	} else {
		resp.DockerAvailable = docker.DaemonAvailable()
	}
	writeJSON(w, http.StatusOK, resp)
}

func mergeStatuses(profile config.Profile, env config.Environment, statuses []docker.ServiceStatus) []serviceStatusDTO {
	byContainer := make(map[string]docker.ServiceStatus, len(statuses))
	for _, st := range statuses {
		byContainer[st.Name] = st
	}
	out := make([]serviceStatusDTO, 0, len(env.Services))
	for _, svc := range env.Services {
		container := docker.ContainerName(profile.Name, env.Name, svc.Name)
		st, ok := byContainer[container]
		state := "not_created"
		health := ""
		ports := ""
		if ok {
			state = st.State
			health = st.Health
			ports = st.Ports
		}
		out = append(out, serviceStatusDTO{
			Name:      svc.Name,
			Container: container,
			FullImage: svc.FullImage(),
			DBType:    svc.DBType(),
			State:     state,
			Health:    health,
			Ports:     ports,
		})
	}
	return out
}

func (s *Server) handleCompose(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")

	var yaml string
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		cp := *p
		generated, err := config.GenerateCompose(cp, envName)
		if err != nil {
			return err
		}
		yaml = generated
		return nil
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"yaml": yaml})
}

// ── Actions ─────────────────────────────────────────────────────────────────

func (s *Server) handleEnvAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	action := r.PathValue("action")

	if err := s.ensureCompose(profileName, envName); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var err error
	switch action {
	case "up":
		err = docker.Up(profileName, envName)
	case "down":
		err = docker.Down(profileName, envName)
	case "restart":
		err = docker.RestartEnv(profileName, envName)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown environment action %q", action))
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "action": action})
}

func (s *Server) handleServiceAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	service := r.PathValue("service")
	action := r.PathValue("action")

	if err := s.ensureCompose(profileName, envName); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var err error
	switch action {
	case "up":
		err = docker.UpService(profileName, envName, service)
	case "down", "rm":
		err = docker.DownService(profileName, envName, service)
	case "stop":
		err = docker.StopService(profileName, envName, service)
	case "restart":
		err = docker.Restart(profileName, envName, service)
	default:
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown service action %q", action))
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "action": action})
}

func (s *Server) handleAddService(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")

	var req createServiceRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	name := strings.TrimSpace(req.Name)
	image := strings.TrimSpace(req.Image)
	if name == "" || image == "" {
		writeError(w, http.StatusBadRequest, "service name and image are required")
		return
	}
	if config.SanitizeComposeName(name) != name {
		writeError(w, http.StatusBadRequest, "service name may only contain letters, numbers, _, . and -")
		return
	}

	svc := config.Service{
		Name:  name,
		Image: image,
		Tag:   strings.TrimSpace(req.Tag),
	}
	for _, p := range req.Ports {
		if strings.TrimSpace(p.Host) == "" || strings.TrimSpace(p.Container) == "" {
			continue
		}
		svc.Ports = append(svc.Ports, config.PortMapping{
			Host:      strings.TrimSpace(p.Host),
			Container: strings.TrimSpace(p.Container),
		})
	}

	var updated config.Profile
	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		idx := indexOfEnv(*p, envName)
		if idx < 0 {
			return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
		}
		for _, existing := range p.Environments[idx].Services {
			if existing.Name == name {
				return fmt.Errorf("service %q already exists", name)
			}
		}
		p.Environments[idx].Services = append(p.Environments[idx].Services, svc)
		p.UpdatedAt = time.Now()
		updated = *p
		_, err := config.GenerateCompose(*p, envName)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, toProfileDTO(updated))
}

func (s *Server) handleDeleteService(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	service := r.PathValue("service")

	var updated config.Profile
	err := s.store.Update(func(c *config.Config) error {
		p, err := c.DeleteService(profileName, envName, service)
		if err != nil {
			return err
		}
		updated = *p
		_, err = config.GenerateCompose(*p, envName)
		return err
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, toProfileDTO(updated))
}

// ── Logs (SSE) ──────────────────────────────────────────────────────────────

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	service := strings.TrimSpace(r.URL.Query().Get("service"))
	follow := r.URL.Query().Get("follow") != "false"

	if err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		for _, e := range p.Environments {
			if e.Name == envName {
				return nil
			}
		}
		return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
	}); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming is not supported")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "retry: 1000\n\n")
	flusher.Flush()

	lines := make(chan string, 128)
	done := make(chan struct{})
	var svcArg []string
	if service != "" {
		svcArg = []string{service}
	}
	go docker.Logs(profileName, envName, follow, lines, done, svcArg...)
	defer close(done)

	for {
		select {
		case <-r.Context().Done():
			return
		case line, ok := <-lines:
			if !ok {
				fmt.Fprint(w, "event: end\ndata: \n\n")
				flusher.Flush()
				return
			}
			fmt.Fprintf(w, "data: %s\n\n", line)
			flusher.Flush()
		}
	}
}

// ── Docker / Hub helpers ────────────────────────────────────────────────────

func (s *Server) handleHubSearch(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeJSON(w, http.StatusOK, []hubResultDTO{})
		return
	}
	results, err := hub.Search(query, 12)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	out := make([]hubResultDTO, 0, len(results))
	for _, res := range results {
		out = append(out, hubResultDTO{
			Name:        res.Name,
			Description: res.Description,
			Official:    res.IsOfficial,
			Stars:       res.StarCount,
			Pulls:       res.PullCount,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleImages(w http.ResponseWriter, r *http.Request) {
	images, err := docker.LocalImages()
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	out := make([]imageDTO, 0, len(images))
	for _, img := range images {
		out = append(out, imageDTO{
			Repository: img.Repository,
			Tag:        img.Tag,
			ID:         img.ID,
			Size:       img.Size,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleLaunchDocker(w http.ResponseWriter, r *http.Request) {
	if docker.DaemonAvailable() {
		writeJSON(w, http.StatusOK, map[string]any{"available": true})
		return
	}

	if _, err := exec.LookPath("colima"); err == nil {
		cmd := exec.Command("colima", "start")
		_ = cmd.Start()
	} else {
		_ = exec.Command("open", "-a", "Docker").Run()
	}

	for i := 0; i < 45; i++ {
		time.Sleep(time.Second)
		if docker.DaemonAvailable() {
			writeJSON(w, http.StatusOK, map[string]any{"available": true})
			return
		}
	}
	writeJSON(w, http.StatusServiceUnavailable, map[string]any{
		"available": false,
		"error":     "Docker daemon did not become available",
	})
}

// ── Internals ───────────────────────────────────────────────────────────────

func (s *Server) ensureCompose(profileName, envName string) error {
	var profile config.Profile
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		profile = *p
		return nil
	})
	if err != nil {
		return err
	}
	_, err = config.GenerateCompose(profile, envName)
	return err
}

func indexOfEnv(p config.Profile, name string) int {
	for i := range p.Environments {
		if p.Environments[i].Name == name {
			return i
		}
	}
	return -1
}
