package server

import (
	"context"
	"fmt"
	"net/http"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/docker"
)

// customActionRequest is the payload for creating or updating a custom action.
type customActionRequest struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

type customActionRunRequest struct {
	SyncEnv string            `json:"syncEnv"`
	Params  map[string]string `json:"params"`
}

var customParamRe = regexp.MustCompile(`\{([a-zA-Z_][a-zA-Z0-9_]*)\}`)

// autoVarNames are replaced without asking the user for a value.
var autoVarNames = map[string]bool{
	"host": true, "user": true, "password": true,
	"database": true, "db": true, "env": true,
	"local_user": true, "local_pass": true, "local_db": true,
	"se_db": true, "se_user": true, "se_password": true,
}

// missingCustomParams returns the placeholders the caller still has to fill.
func missingCustomParams(command string, params map[string]string) []string {
	var missing []string
	seen := map[string]bool{}
	for _, match := range customParamRe.FindAllStringSubmatch(command, -1) {
		name := match[1]
		if autoVarNames[name] || seen[name] {
			continue
		}
		seen[name] = true
		if _, ok := params[name]; !ok {
			missing = append(missing, name)
		}
	}
	return missing
}

// ── CRUD ─────────────────────────────────────────────────────────────────────

func (s *Server) handleCreateCustomAction(w http.ResponseWriter, r *http.Request) {
	s.mutateCustomActions(w, r, func(env *config.SyncEnv) error {
		var req customActionRequest
		if err := decodeJSON(r, &req); err != nil {
			return err
		}
		name := strings.TrimSpace(req.Name)
		command := strings.TrimSpace(req.Command)
		if name == "" {
			return fmt.Errorf("action name is required")
		}
		if command == "" {
			return fmt.Errorf("action command is required")
		}
		if findCustomAction(env, name) != nil {
			return fmt.Errorf("action %q already exists", name)
		}
		env.CustomActions = append(env.CustomActions, config.CustomAction{Name: name, Command: command})
		return nil
	})
}

func (s *Server) handleUpdateCustomAction(w http.ResponseWriter, r *http.Request) {
	s.mutateCustomActions(w, r, func(env *config.SyncEnv) error {
		var req customActionRequest
		if err := decodeJSON(r, &req); err != nil {
			return err
		}
		name := strings.TrimSpace(req.Name)
		command := strings.TrimSpace(req.Command)
		if name == "" {
			return fmt.Errorf("action name is required")
		}
		if command == "" {
			return fmt.Errorf("action command is required")
		}
		orig := r.PathValue("action")
		idx := -1
		for i := range env.CustomActions {
			if env.CustomActions[i].Name == orig {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("action %q not found", orig)
		}
		if name != orig && findCustomAction(env, name) != nil {
			return fmt.Errorf("action %q already exists", name)
		}
		env.CustomActions[idx] = config.CustomAction{Name: name, Command: command}
		return nil
	})
}

func (s *Server) handleDeleteCustomAction(w http.ResponseWriter, r *http.Request) {
	s.mutateCustomActions(w, r, func(env *config.SyncEnv) error {
		name := r.PathValue("action")
		idx := -1
		for i := range env.CustomActions {
			if env.CustomActions[i].Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("action %q not found", name)
		}
		env.CustomActions = append(env.CustomActions[:idx], env.CustomActions[idx+1:]...)
		return nil
	})
}

// mutateCustomActions loads the sync environment, applies mutate, saves, and
// answers with the refreshed DB operations payload.
func (s *Server) mutateCustomActions(w http.ResponseWriter, r *http.Request, mutate func(*config.SyncEnv) error) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	syncEnvName := r.PathValue("syncenv")

	err := s.store.Update(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		se := svc.FindSyncEnv(syncEnvName)
		if se == nil {
			return notFoundf("sync environment %q not found", syncEnvName)
		}
		if err := mutate(se); err != nil {
			return err
		}
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		profile.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	info, status, err := s.dbOpsInfo(profileName, envName, serviceName)
	if err != nil {
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func findCustomAction(env *config.SyncEnv, name string) *config.CustomAction {
	for i := range env.CustomActions {
		if env.CustomActions[i].Name == name {
			return &env.CustomActions[i]
		}
	}
	return nil
}

// ── Run ──────────────────────────────────────────────────────────────────────

func (s *Server) handleRunCustomAction(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	actionName := r.PathValue("action")

	var req customActionRunRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
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
		loaded, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		svc = *loaded
		se = svc.FindSyncEnv(req.SyncEnv)
		if se == nil {
			return notFoundf("sync environment %q not found", req.SyncEnv)
		}
		return nil
	}); err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	action := findCustomAction(se, actionName)
	if action == nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q not found", actionName))
		return
	}
	if missing := missingCustomParams(action.Command, req.Params); len(missing) > 0 {
		writeError(w, http.StatusBadRequest, "missing values for "+strings.Join(missing, ", "))
		return
	}

	job := s.dbJobs.start(profileName, serviceName, req.SyncEnv, "custom:"+actionName, actionName)
	syncEnv := *se
	params := req.Params
	go func() {
		output, err := runCustomAction(profileName, envName, svc, syncEnv, action.Command, params)
		s.dbJobs.finish(job.ID, output, err)
	}()

	writeJSON(w, http.StatusAccepted, job)
}

// runCustomAction executes a custom action inside the service container.
func runCustomAction(profileName, envName string, svc config.Service, se config.SyncEnv, command string, params map[string]string) (string, error) {
	container := docker.ContainerName(profileName, envName, svc.Name)
	localUser, localPass, localDB := localDBCredentials(svc, se.DBType)

	pass, _ := se.GetPassword()
	vars := map[string]string{
		"host":        se.Host,
		"user":        se.User,
		"password":    pass,
		"database":    localDB,
		"db":          localDB,
		"env":         envName,
		"local_user":  localUser,
		"local_pass":  localPass,
		"local_db":    localDB,
		"se_db":       se.Database,
		"se_user":     se.User,
		"se_password": pass,
	}

	shellCmd := command
	for key, value := range params {
		shellCmd = strings.ReplaceAll(shellCmd, "{"+key+"}", value)
	}
	for key, value := range vars {
		if value != "" {
			shellCmd = strings.ReplaceAll(shellCmd, "{"+key+"}", value)
		}
	}

	// Wrap raw SQL in the matching client when the command is not already a
	// shell command.
	needsSqlplus := false
	if !hasClientPrefix(shellCmd) {
		switch se.DBType {
		case "postgres":
			shellCmd = fmt.Sprintf(`psql -h localhost -U %s -d %s -c "%s"`, localUser, localDB, strings.ReplaceAll(shellCmd, `"`, `\"`))
		case "mongo":
			shellCmd = fmt.Sprintf(`mongo -u %s -p %s --authenticationDatabase admin %s --eval '%s'`, localUser, localPass, localDB, strings.ReplaceAll(shellCmd, "'", `'\''`))
		case "mysql":
			shellCmd = fmt.Sprintf(`mysql -h localhost -u %s -p%s %s -e "%s"`, localUser, localPass, localDB, strings.ReplaceAll(shellCmd, `"`, `\"`))
		case "mssql":
			shellCmd = fmt.Sprintf(`sqlcmd -S localhost -U %s -P %s -d %s -Q "%s"`, localUser, localPass, localDB, strings.ReplaceAll(shellCmd, `"`, `\"`))
		case "oracle":
			needsSqlplus = true
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	if needsSqlplus {
		out, err := docker.OracleExecSQL(ctx, container, localUser, localPass, localDB, shellCmd)
		if err != nil {
			return strings.TrimSpace(out), fmt.Errorf("custom action: %s: %w", strings.TrimSpace(out), err)
		}
		return strings.TrimSpace(out), nil
	}

	out, err := exec.CommandContext(ctx, "docker", "exec", "-i", container, "sh", "-c", shellCmd).CombinedOutput()
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		if trimmed == "" {
			return "", fmt.Errorf("custom action: %w", err)
		}
		return trimmed, fmt.Errorf("custom action: %s: %w", trimmed, err)
	}
	return trimmed, nil
}

func hasClientPrefix(command string) bool {
	for _, prefix := range []string{"psql", "mysql", "mongo", "mongosh", "sqlcmd", "sqlplus", "sh ", "bash "} {
		if strings.HasPrefix(command, prefix) {
			return true
		}
	}
	return false
}

// localDBCredentials reads the local container credentials from the service's
// environment, with the same fallbacks the original runtime uses.
func localDBCredentials(svc config.Service, dbType string) (user, pass, db string) {
	env := make(map[string]string, len(svc.EnvVars))
	for _, e := range svc.EnvVars {
		env[e.Key] = e.Value
	}

	switch dbType {
	case "postgres":
		user = env["POSTGRES_USER"]
		if user == "" {
			user = "postgres"
		}
		pass = env["POSTGRES_PASSWORD"]
		db = env["POSTGRES_DB"]
		if db == "" {
			db = "postgres"
		}
	case "mongo":
		user = env["MONGO_INITDB_ROOT_USERNAME"]
		if user == "" {
			user = "admin"
		}
		pass = env["MONGO_INITDB_ROOT_PASSWORD"]
		db = env["MONGO_INITDB_DATABASE"]
		if db == "" {
			db = "admin"
		}
	case "mysql":
		user = "root"
		pass = env["MYSQL_ROOT_PASSWORD"]
		db = env["MYSQL_DATABASE"]
		if db == "" {
			db = "mysql"
		}
	case "mssql":
		user = "sa"
		pass = env["MSSQL_SA_PASSWORD"]
		db = env["MSSQL_DB"]
		if db == "" {
			db = "master"
		}
	case "oracle":
		user = env["ORACLE_USER"]
		if user == "" {
			user = "system"
		}
		pass = env["ORACLE_PASSWORD"]
		db = env["ORACLE_PDB"]
		if db == "" {
			db = "XEPDB1"
		}
	}
	return user, pass, db
}
