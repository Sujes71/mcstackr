package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Server is the loopback HTTP API consumed by the native macOS app.
type Server struct {
	version string
	token   string
	store   *Store
	mux     *http.ServeMux
}

func New(token, version string) (*Server, error) {
	store, err := NewStore()
	if err != nil {
		return nil, err
	}
	s := &Server{
		version: version,
		token:   token,
		store:   store,
		mux:     http.NewServeMux(),
	}
	s.routes()
	return s, nil
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /api/health", s.handleHealth)

	s.mux.HandleFunc("GET /api/profiles", s.handleListProfiles)
	s.mux.HandleFunc("POST /api/profiles", s.handleCreateProfile)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs", s.handleCreateEnvironment)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/status", s.handleStatus)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/compose", s.handleCompose)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/logs", s.handleLogs)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/actions/{action}", s.handleEnvAction)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services", s.handleAddService)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/services/{service}", s.handleDeleteService)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/actions/{action}", s.handleServiceAction)

	s.mux.HandleFunc("GET /api/hub/search", s.handleHubSearch)
	s.mux.HandleFunc("GET /api/images", s.handleImages)
	s.mux.HandleFunc("POST /api/docker/launch", s.handleLaunchDocker)
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		w.Header().Set("Content-Type", "application/json")
	}
	s.mux.ServeHTTP(w, r)
}

func (s *Server) authorized(r *http.Request) bool {
	provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if len(provided) != len(s.token) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) == 1
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func decodeJSON(r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	return nil
}
