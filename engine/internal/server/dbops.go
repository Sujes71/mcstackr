package server

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/docker"
)

// dbOpsInfoResponse describes the DB operations available for one service.
type dbOpsInfoResponse struct {
	Service  string         `json:"service"`
	DBType   string         `json:"dbType"`
	Running  bool           `json:"running"`
	SyncEnvs []dbSyncEnvDTO `json:"syncEnvs"`
}

type dbSyncEnvDTO struct {
	Name          string              `json:"name"`
	DBType        string              `json:"dbType"`
	Host          string              `json:"host"`
	Port          string              `json:"port"`
	User          string              `json:"user"`
	Database      string              `json:"database"`
	AuthDB        string              `json:"authDb,omitempty"`
	ToolImage     string              `json:"toolImage"`
	Actions       []dbActionDTO       `json:"actions"`
	CustomActions []dbCustomActionDTO `json:"customActions"`
	Dumps         []dbDumpDTO         `json:"dumps"`
}

type dbCustomActionDTO struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

type dbActionDTO struct {
	ID             string `json:"id"`
	Label          string `json:"label"`
	Group          string `json:"group"`
	Enabled        bool   `json:"enabled"`
	DisabledReason string `json:"disabledReason,omitempty"`
	Destructive    bool   `json:"destructive,omitempty"`
}

type dbDumpDTO struct {
	File       string `json:"file"`
	Kind       string `json:"kind"`
	Size       int64  `json:"size"`
	ModifiedAt string `json:"modifiedAt"`
}

type dbOpRequest struct {
	SyncEnv string `json:"syncEnv"`
}

type dbJobDTO struct {
	ID         string `json:"id"`
	State      string `json:"state"`
	Output     string `json:"output,omitempty"`
	Error      string `json:"error,omitempty"`
	StartedAt  string `json:"startedAt"`
	FinishedAt string `json:"finishedAt,omitempty"`
}

// dbJobRegistry keeps the in-flight and recent DB operations in memory.
type dbJobRegistry struct {
	mu   sync.Mutex
	jobs map[string]*dbJobDTO
	seq  []string
}

const dbJobHistory = 50

func newDBJobRegistry() *dbJobRegistry {
	return &dbJobRegistry{jobs: map[string]*dbJobDTO{}}
}

func (r *dbJobRegistry) start() *dbJobDTO {
	var raw [8]byte
	_, _ = rand.Read(raw[:])
	job := &dbJobDTO{
		ID:        hex.EncodeToString(raw[:]),
		State:     "running",
		StartedAt: time.Now().UTC().Format(time.RFC3339),
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.jobs[job.ID] = job
	r.seq = append(r.seq, job.ID)
	for len(r.seq) > dbJobHistory {
		delete(r.jobs, r.seq[0])
		r.seq = r.seq[1:]
	}
	return job
}

func (r *dbJobRegistry) finish(id, output string, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	job, ok := r.jobs[id]
	if !ok {
		return
	}
	job.FinishedAt = time.Now().UTC().Format(time.RFC3339)
	if err != nil {
		job.State = "error"
		job.Error = err.Error()
		return
	}
	job.State = "done"
	job.Output = output
}

func (r *dbJobRegistry) get(id string) (dbJobDTO, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	job, ok := r.jobs[id]
	if !ok {
		return dbJobDTO{}, false
	}
	return *job, true
}

// ── Info ─────────────────────────────────────────────────────────────────────

func (s *Server) handleDBOpsInfo(w http.ResponseWriter, r *http.Request) {
	info, status, err := s.dbOpsInfo(
		r.PathValue("profile"),
		r.PathValue("env"),
		r.PathValue("service"),
	)
	if err != nil {
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) dbOpsInfo(profileName, envName, serviceName string) (dbOpsInfoResponse, int, error) {
	var (
		svc     config.Service
		profile config.Profile
		env     config.Environment
	)
	if err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		var e config.Environment
		foundEnv := false
		for _, candidate := range p.Environments {
			if candidate.Name == envName {
				e, foundEnv = candidate, true
				break
			}
		}
		if !foundEnv {
			return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
		}
		found := false
		for _, candidate := range e.Services {
			if candidate.Name == serviceName {
				svc, found = candidate, true
				break
			}
		}
		if !found {
			return fmt.Errorf("service %q not found in %s/%s", serviceName, profileName, envName)
		}
		profile, env = *p, e
		return nil
	}); err != nil {
		return dbOpsInfoResponse{}, http.StatusNotFound, err
	}

	dbType := svc.DBType()
	if dbType == "" {
		return dbOpsInfoResponse{}, http.StatusBadRequest,
			fmt.Errorf("service %q is not a supported database", serviceName)
	}

	daemon := docker.DaemonAvailable()
	running := false
	if daemon {
		container := docker.ContainerName(profile.Name, env.Name, svc.Name)
		if statuses, err := docker.Status(profile.Name, env.Name); err == nil {
			for _, st := range statuses {
				if st.Name == container && strings.EqualFold(st.State, "running") {
					running = true
					break
				}
			}
		}
	}

	info := dbOpsInfoResponse{
		Service:  svc.Name,
		DBType:   dbType,
		Running:  running,
		SyncEnvs: make([]dbSyncEnvDTO, 0, len(svc.SyncEnvs)),
	}
	for _, se := range svc.SyncEnvs {
		dumps := listDumps(se.DumpDir(profile.Name, env.Name, svc.Name), dbType)
		info.SyncEnvs = append(info.SyncEnvs, dbSyncEnvDTO{
			Name:          se.Name,
			DBType:        se.DBType,
			Host:          se.Host,
			Port:          se.Port,
			User:          se.User,
			Database:      se.Database,
			AuthDB:        se.AuthDB,
			ToolImage:     docker.ToolImage(&se),
			Actions:       dbActions(dbType, daemon, running, dumps),
			CustomActions: customActionsDTO(se),
			Dumps:         dumps,
		})
	}
	return info, http.StatusOK, nil
}

func customActionsDTO(se config.SyncEnv) []dbCustomActionDTO {
	actions := make([]dbCustomActionDTO, 0, len(se.CustomActions))
	for _, action := range se.CustomActions {
		actions = append(actions, dbCustomActionDTO{Name: action.Name, Command: action.Command})
	}
	return actions
}

func dbActions(dbType string, daemon, running bool, dumps []dbDumpDTO) []dbActionDTO {
	hasSchema := hasDumpKind(dumps, "schema")
	hasData := hasDumpKind(dumps, "data")

	exportReason := ""
	if !daemon {
		exportReason = "Docker is not running"
	}
	containerReason := ""
	if !running {
		containerReason = "start the service first"
	}

	actions := make([]dbActionDTO, 0, 5)
	if dbType == "postgres" {
		actions = append(actions, dbActionDTO{
			ID: "export-schema", Label: "Export schema", Group: "Export",
			Enabled: exportReason == "", DisabledReason: exportReason,
		})
	}
	actions = append(actions, dbActionDTO{
		ID: "export-data", Label: "Export data", Group: "Export",
		Enabled: exportReason == "", DisabledReason: exportReason,
	})

	if dbType == "postgres" {
		actions = append(actions, dbActionDTO{
			ID: "import-schema", Label: "Import schema (reset)", Group: "Import",
			Enabled: running && hasSchema, DisabledReason: firstReason(containerReason, disabledUnless(hasSchema, "no schema dump")),
			Destructive: true,
		})
	}
	actions = append(actions, dbActionDTO{
		ID: "import-data", Label: "Import data", Group: "Import",
		Enabled: running && hasData, DisabledReason: firstReason(containerReason, disabledUnless(hasData, "no data dump")),
		Destructive: true,
	})
	actions = append(actions, dbActionDTO{
		ID: "truncate", Label: "Truncate tables", Group: "Actions",
		Enabled: running, DisabledReason: containerReason,
		Destructive: true,
	})
	return actions
}

func disabledUnless(ok bool, reason string) string {
	if ok {
		return ""
	}
	return reason
}

func firstReason(reasons ...string) string {
	for _, reason := range reasons {
		if reason != "" {
			return reason
		}
	}
	return ""
}

func hasDumpKind(dumps []dbDumpDTO, kind string) bool {
	for _, d := range dumps {
		if d.Kind == kind {
			return true
		}
	}
	return false
}

func listDumps(dir, dbType string) []dbDumpDTO {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return []dbDumpDTO{}
	}

	dumps := make([]dbDumpDTO, 0, len(entries))
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}

		if entry.IsDir() {
			if dbType != "mongo" {
				continue
			}
			dumps = append(dumps, dbDumpDTO{
				File:       entry.Name(),
				Kind:       "data",
				Size:       dirSize(path),
				ModifiedAt: info.ModTime().UTC().Format(time.RFC3339),
			})
			continue
		}

		kind := "data"
		if strings.HasPrefix(entry.Name(), "schema-") {
			kind = "schema"
		}
		dumps = append(dumps, dbDumpDTO{
			File:       entry.Name(),
			Kind:       kind,
			Size:       info.Size(),
			ModifiedAt: info.ModTime().UTC().Format(time.RFC3339),
		})
	}

	sort.Slice(dumps, func(i, j int) bool { return dumps[i].ModifiedAt > dumps[j].ModifiedAt })
	return dumps
}

func dirSize(path string) int64 {
	var total int64
	_ = filepath.Walk(path, func(_ string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

// ── Run ──────────────────────────────────────────────────────────────────────

func (s *Server) handleDBOp(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	action := r.PathValue("action")

	var req dbOpRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	req.SyncEnv = strings.TrimSpace(req.SyncEnv)
	if req.SyncEnv == "" {
		writeError(w, http.StatusBadRequest, "syncEnv is required")
		return
	}

	var (
		svc config.Service
		se  *config.SyncEnv
	)
	if err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		var e config.Environment
		foundEnv := false
		for _, candidate := range p.Environments {
			if candidate.Name == envName {
				e, foundEnv = candidate, true
				break
			}
		}
		if !foundEnv {
			return fmt.Errorf("environment %q not found in profile %q", envName, profileName)
		}
		found := false
		for _, candidate := range e.Services {
			if candidate.Name == serviceName {
				svc, found = candidate, true
				break
			}
		}
		if !found {
			return fmt.Errorf("service %q not found in %s/%s", serviceName, profileName, envName)
		}
		se = svc.FindSyncEnv(req.SyncEnv)
		if se == nil {
			return fmt.Errorf("sync environment %q not found for %q", req.SyncEnv, serviceName)
		}
		return nil
	}); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	dbType := svc.DBType()
	if dbType == "" {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("service %q is not a supported database", serviceName))
		return
	}
	if err := validateDBOp(action, dbType); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	job := s.dbJobs.start()
	syncEnv := *se
	go func() {
		output, err := runDBOp(profileName, envName, svc, syncEnv, action)
		s.dbJobs.finish(job.ID, output, err)
	}()

	writeJSON(w, http.StatusAccepted, job)
}

func (s *Server) handleDBJob(w http.ResponseWriter, r *http.Request) {
	job, ok := s.dbJobs.get(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

// usesToolImage reports whether the action runs a one-shot tool container
// instead of executing inside the service container.
func usesToolImage(action, dbType string) bool {
	switch action {
	case "export-schema", "export-data":
		return true
	case "import-data":
		return dbType == "mssql"
	default:
		return false
	}
}

func validateDBOp(action, dbType string) error {
	switch action {
	case "export-schema":
		if dbType != "postgres" {
			return fmt.Errorf("schema export is only available for postgres")
		}
	case "export-data", "import-data", "truncate":
	case "import-schema":
		if dbType != "postgres" {
			return fmt.Errorf("schema import is only available for postgres")
		}
	default:
		return fmt.Errorf("unknown DB operation %q", action)
	}
	return nil
}

func runDBOp(profileName, envName string, svc config.Service, se config.SyncEnv, action string) (string, error) {
	dumpDir := se.DumpDir(profileName, envName, svc.Name)
	dbType := svc.DBType()

	if usesToolImage(action, dbType) {
		if err := docker.EnsureImage(docker.ToolImage(&se)); err != nil {
			return "", fmt.Errorf("prepare tool image: %w", err)
		}
	}

	switch action {
	case "export-schema":
		if err := os.MkdirAll(dumpDir, 0o755); err != nil {
			return "", fmt.Errorf("create dump dir: %w", err)
		}
		outPath := filepath.Join(dumpDir, "schema-"+dbTimestamp()+".sql")
		if err := docker.PgDump(&se, outPath, "-s"); err != nil {
			return "", fmt.Errorf("export schema: %w", err)
		}
		return "Schema exported to " + filepath.Base(outPath), nil

	case "export-data":
		if err := os.MkdirAll(dumpDir, 0o755); err != nil {
			return "", fmt.Errorf("create dump dir: %w", err)
		}
		switch dbType {
		case "postgres":
			outPath := filepath.Join(dumpDir, "data-"+dbTimestamp()+".sql")
			if err := docker.PgDump(&se, outPath, "-a"); err != nil {
				return "", fmt.Errorf("export data: %w", err)
			}
			return "Data exported to " + filepath.Base(outPath), nil
		case "mongo":
			outDir := filepath.Join(dumpDir, dbTimestamp())
			if err := docker.MongoDump(&se, outDir); err != nil {
				_ = os.RemoveAll(outDir)
				return "", fmt.Errorf("export mongo: %w", err)
			}
			return "Data exported to " + filepath.Base(outDir), nil
		case "mysql":
			outPath := filepath.Join(dumpDir, "data-"+dbTimestamp()+".sql")
			if err := docker.MySqlDump(&se, outPath); err != nil {
				return "", fmt.Errorf("export mysql: %w", err)
			}
			return "Data exported to " + filepath.Base(outPath), nil
		case "mssql":
			outPath := filepath.Join(dumpDir, "data-"+dbTimestamp()+".bacpac")
			if err := docker.SqlPackageExport(&se, outPath); err != nil {
				return "", fmt.Errorf("export mssql: %w", err)
			}
			return "Data exported to " + filepath.Base(outPath), nil
		case "oracle":
			outPath := filepath.Join(dumpDir, "data-"+dbTimestamp()+".dmp")
			if err := docker.OracleExport(profileName, envName, svc.Name, outPath); err != nil {
				return "", fmt.Errorf("export oracle: %w", err)
			}
			return "Data exported to " + filepath.Base(outPath), nil
		default:
			return "", fmt.Errorf("unknown db type: %s", dbType)
		}

	case "import-schema":
		latest, err := docker.FindLatestDump(dumpDir, "schema-*.sql")
		if err != nil {
			return "", fmt.Errorf("no schema dump: %w", err)
		}
		if err := docker.PgDropSchema(profileName, envName, svc.Name); err != nil {
			return "", fmt.Errorf("import schema: %w", err)
		}
		if err := docker.ExecPgRestore(profileName, envName, svc.Name, latest); err != nil {
			return "", fmt.Errorf("import schema: %w", err)
		}
		return "Schema re-imported from " + filepath.Base(latest), nil

	case "import-data":
		switch dbType {
		case "postgres":
			latest, err := docker.FindLatestDump(dumpDir, "data-*.sql")
			if err != nil {
				return "", fmt.Errorf("no data dump: %w", err)
			}
			if err := docker.ExecPgRestore(profileName, envName, svc.Name, latest); err != nil {
				return "", fmt.Errorf("import postgres: %w", err)
			}
			return "Data imported from " + filepath.Base(latest), nil
		case "mongo":
			latest, err := docker.FindLatestDump(dumpDir, "")
			if err != nil {
				return "", fmt.Errorf("no mongo dump: %w", err)
			}
			if err := docker.ExecMongoRestore(profileName, envName, svc.Name, latest); err != nil {
				return "", fmt.Errorf("import mongo: %w", err)
			}
			return "Data imported from " + filepath.Base(latest), nil
		case "mysql":
			latest, err := docker.FindLatestDump(dumpDir, "data-*.sql")
			if err != nil {
				return "", fmt.Errorf("no data dump: %w", err)
			}
			if err := docker.ExecMySqlRestore(profileName, envName, svc.Name, latest); err != nil {
				return "", fmt.Errorf("import mysql: %w", err)
			}
			return "Data imported from " + filepath.Base(latest), nil
		case "mssql":
			latest, err := docker.FindLatestDump(dumpDir, "data-*.bacpac")
			if err != nil {
				return "", fmt.Errorf("no .bacpac file: %w", err)
			}
			if err := docker.SqlPackageImport(profileName, envName, svc.Name, latest, mssqlHostPort(profileName, envName, svc.Name), docker.ToolImage(&se)); err != nil {
				return "", fmt.Errorf("import mssql: %w", err)
			}
			return "Data imported from " + filepath.Base(latest), nil
		case "oracle":
			latest, err := docker.FindLatestDump(dumpDir, "data-*.dmp")
			if err != nil {
				return "", fmt.Errorf("no .dmp file: %w", err)
			}
			if err := docker.OracleImport(profileName, envName, svc.Name, latest); err != nil {
				return "", fmt.Errorf("import oracle: %w", err)
			}
			return "Data imported from " + filepath.Base(latest), nil
		default:
			return "", fmt.Errorf("unknown db type: %s", dbType)
		}

	case "truncate":
		switch dbType {
		case "postgres":
			if err := docker.PgTruncate(profileName, envName, svc.Name); err != nil {
				return "", fmt.Errorf("truncate postgres: %w", err)
			}
		case "mongo":
			if err := docker.MongoTruncate(profileName, envName, svc.Name); err != nil {
				return "", fmt.Errorf("truncate mongo: %w", err)
			}
		case "mysql":
			if err := docker.MySqlTruncate(profileName, envName, svc.Name); err != nil {
				return "", fmt.Errorf("truncate mysql: %w", err)
			}
		case "mssql":
			if err := docker.MsSqlTruncate(profileName, envName, svc.Name, se.Database); err != nil {
				return "", fmt.Errorf("truncate mssql: %w", err)
			}
		case "oracle":
			if err := docker.OracleTruncate(profileName, envName, svc.Name); err != nil {
				return "", fmt.Errorf("truncate oracle: %w", err)
			}
		default:
			return "", fmt.Errorf("unknown db type: %s", dbType)
		}
		return "All tables truncated", nil
	}

	return "", fmt.Errorf("unknown DB operation %q", action)
}

func dbTimestamp() string {
	return time.Now().Format("20060102-150405")
}

// mssqlHostPort returns the host port mapped to the container's 1433/tcp.
func mssqlHostPort(profileName, envName, serviceName string) string {
	container := docker.ContainerName(profileName, envName, serviceName)
	out, err := exec.Command("docker", "inspect", container,
		"--format", `{{(index (index .NetworkSettings.Ports "1433/tcp") 0).HostPort}}`).Output()
	if err != nil {
		return "1433"
	}
	port := strings.TrimSpace(string(out))
	if port == "" {
		return "1433"
	}
	return port
}
