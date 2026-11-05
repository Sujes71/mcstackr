package server

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Server is the loopback HTTP API consumed by the native macOS app.
type Server struct {
	version string
	token   string
	store   *Store
	mux     *http.ServeMux
	pf      *portForwardManager
	lp      *localProcessManager
	dbJobs  *dbJobRegistry
	// The cancel of the request runs that are in flight.
	requestCancels sync.Map
	// The last execution of every request.
	requestRuns sync.Map
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
		pf:      newPortForwardManager(),
		lp:      newLocalProcessManager(),
		dbJobs:  newDBJobRegistry(),
	}
	s.routes()
	return s, nil
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /api/health", s.handleHealth)

	s.mux.HandleFunc("GET /api/profiles", s.handleListProfiles)
	s.mux.HandleFunc("POST /api/profiles", s.handleCreateProfile)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}", s.handleUpdateProfile)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}", s.handleDeleteProfile)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs", s.handleCreateEnvironment)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}", s.handleGetEnvironment)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/status", s.handleStatus)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/services/{service}", s.handleGetService)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/envs/{env}/services/{service}", s.handleUpdateService)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/compose", s.handleCompose)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/logs", s.handleLogs)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/actions/{action}", s.handleEnvAction)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services", s.handleAddService)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/services/{service}", s.handleDeleteService)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/actions/{action}", s.handleServiceAction)
	s.mux.HandleFunc("GET /api/profiles/{profile}/requests", s.handleRequests)
	s.mux.HandleFunc("POST /api/profiles/{profile}/requests/run", s.handleRunRequest)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/requests/run", s.handleCancelRequest)
	s.mux.HandleFunc("POST /api/profiles/{profile}/requests/folders", s.handleAddFolder)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/requests/folders/{folder}", s.handleUpdateFolder)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/requests/folders/{folder}", s.handleDeleteFolder)
	s.mux.HandleFunc("POST /api/profiles/{profile}/requests/items", s.handleAddRequestItem)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/requests/items/{name}", s.handleUpdateRequestItem)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/requests/items/{name}", s.handleDeleteRequestItem)
	s.mux.HandleFunc("POST /api/profiles/{profile}/requests/envs", s.handleAddRequestEnv)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/requests/envs/{name}", s.handleDeleteRequestEnv)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/services/{service}/dbops", s.handleDBOpsInfo)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/dbops/{action}", s.handleDBOp)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/services/{service}/dbops/jobs/{id}", s.handleDBJob)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs", s.handleCreateSyncEnv)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs/{syncenv}", s.handleUpdateSyncEnv)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs/{syncenv}", s.handleDeleteSyncEnv)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs/{syncenv}/custom-actions", s.handleCreateCustomAction)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs/{syncenv}/custom-actions/{action}", s.handleUpdateCustomAction)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/services/{service}/sync-envs/{syncenv}/custom-actions/{action}", s.handleDeleteCustomAction)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/services/{service}/dbops/custom/{action}", s.handleRunCustomAction)
	s.mux.HandleFunc("GET /api/profiles/{profile}/envs/{env}/services/{service}/dbops/jobs", s.handleDBJobs)

	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/local-processes", s.handleAddLocalProcess)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/local-processes/{name}", s.handleDeleteLocalProcess)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/local-processes/actions/{action}", s.handleLocalProcessesAction)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/local-processes/{name}/actions/{action}", s.handleLocalProcessAction)

	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/port-forwards", s.handleAddPortForward)
	s.mux.HandleFunc("PATCH /api/profiles/{profile}/envs/{env}/port-forwards/{name}", s.handleUpdatePortForward)
	s.mux.HandleFunc("DELETE /api/profiles/{profile}/envs/{env}/port-forwards/{name}", s.handleDeletePortForward)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/port-forwards/actions/{action}", s.handlePortForwardsAction)
	s.mux.HandleFunc("POST /api/profiles/{profile}/envs/{env}/port-forwards/{name}/actions/{action}", s.handlePortForwardAction)

	s.mux.HandleFunc("GET /api/k8s/status", s.handleK8sStatus)
	s.mux.HandleFunc("GET /api/k8s/contexts", s.handleK8sContexts)
	s.mux.HandleFunc("GET /api/k8s/namespaces", s.handleK8sNamespaces)
	s.mux.HandleFunc("GET /api/k8s/services", s.handleK8sServices)

	s.mux.HandleFunc("GET /api/hub/catalog", s.handleCatalog)
	s.mux.HandleFunc("GET /api/hub/tags", s.handleHubTags)
	s.mux.HandleFunc("GET /api/hub/search", s.handleHubSearch)
	s.mux.HandleFunc("GET /api/images", s.handleImages)
	s.mux.HandleFunc("POST /api/docker/launch", s.handleLaunchDocker)
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	debug := os.Getenv("MCSTACKR_DEBUG") == "1"
	if !debug {
		s.serve(w, r)
		return
	}

	started := time.Now()
	recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	s.serve(recorder, r)
	log.Printf("%s %s -> %d (%s)", r.Method, r.URL.Path, recorder.status, time.Since(started).Round(time.Millisecond))
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if strings.HasPrefix(r.URL.Path, "/api/") {
		w.Header().Set("Content-Type", "application/json")
	}
	s.mux.ServeHTTP(w, r)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
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
