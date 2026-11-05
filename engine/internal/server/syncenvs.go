package server

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
)

// syncEnvRequest is the payload for creating or updating a sync environment.
// Password is a pointer so an update can keep the stored password when the
// field is omitted, and clear it when it is sent as an empty string.
type syncEnvRequest struct {
	Name      string  `json:"name"`
	Host      string  `json:"host"`
	Port      string  `json:"port"`
	User      string  `json:"user"`
	Password  *string `json:"password"`
	Database  string  `json:"database"`
	AuthDB    string  `json:"authDb"`
	ToolImage string  `json:"toolImage"`
}

func (req syncEnvRequest) toSyncEnv(dbType string) config.SyncEnv {
	se := config.SyncEnv{
		Name:      strings.TrimSpace(req.Name),
		DBType:    dbType,
		Host:      strings.TrimSpace(req.Host),
		Port:      strings.TrimSpace(req.Port),
		User:      strings.TrimSpace(req.User),
		Database:  strings.TrimSpace(req.Database),
		ToolImage: strings.TrimSpace(req.ToolImage),
	}
	if dbType == "mongo" {
		se.AuthDB = strings.TrimSpace(req.AuthDB)
	}
	return se
}

func validateSyncEnv(se config.SyncEnv) error {
	errs := se.Validate()
	if len(errs) == 0 {
		return nil
	}
	// Keep the message deterministic so the UI shows a stable first error.
	for _, key := range []string{"name", "host", "port", "user", "database", "db_type"} {
		if msg, ok := errs[key]; ok {
			return fmt.Errorf("%s", msg)
		}
	}
	for _, msg := range errs {
		return fmt.Errorf("%s", msg)
	}
	return nil
}

func (s *Server) handleCreateSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var req syncEnvRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		dbType := svc.DBType()
		if dbType == "" {
			return fmt.Errorf("service %q is not a supported database", serviceName)
		}
		se := req.toSyncEnv(dbType)
		if err := validateSyncEnv(se); err != nil {
			return err
		}
		if svc.FindSyncEnv(se.Name) != nil {
			return fmt.Errorf("sync environment %q already exists", se.Name)
		}
		if req.Password != nil {
			if err := se.SetPassword(*req.Password); err != nil {
				return err
			}
		}
		svc.SyncEnvs = append(svc.SyncEnvs, se)
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
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
	writeJSON(w, http.StatusCreated, info)
}

func (s *Server) handleUpdateSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	origName := r.PathValue("syncenv")

	var req syncEnvRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	newName := origName
	err := s.store.Update(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		dbType := svc.DBType()
		if dbType == "" {
			return fmt.Errorf("service %q is not a supported database", serviceName)
		}
		idx := -1
		for i := range svc.SyncEnvs {
			if svc.SyncEnvs[i].Name == origName {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("sync environment %q not found", origName)
		}
		se := req.toSyncEnv(dbType)
		// The request only carries the connection fields. The custom actions
		// of a sync environment are managed separately, so an edit of the
		// connection details must not drop them.
		se.CustomActions = svc.SyncEnvs[idx].CustomActions
		if err := validateSyncEnv(se); err != nil {
			return err
		}
		if se.Name != origName && svc.FindSyncEnv(se.Name) != nil {
			return fmt.Errorf("sync environment %q already exists", se.Name)
		}
		newName = se.Name
		if req.Password != nil {
			if err := se.SetPassword(*req.Password); err != nil {
				return err
			}
		} else {
			se.Password = svc.SyncEnvs[idx].Password
		}
		svc.SyncEnvs[idx] = se
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
		}
		profile.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	// The dumps live in a folder named after the sync environment. When it is
	// renamed, that folder has to follow, or the dumps stay behind under the
	// old name and the service looks like it lost them.
	if newName != origName {
		migrateDumpDir(profileName, envName, serviceName, origName, newName)
	}

	info, status, err := s.dbOpsInfo(profileName, envName, serviceName)
	if err != nil {
		writeError(w, status, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

// migrateDumpDir moves the dumps of a renamed sync environment to the folder
// of its new name.
func migrateDumpDir(profileName, envName, serviceName, origName, newName string) {
	oldDir := config.SyncEnv{Name: origName}.DumpDir(profileName, envName, serviceName)
	newDir := config.SyncEnv{Name: newName}.DumpDir(profileName, envName, serviceName)
	info, err := os.Stat(oldDir)
	if err != nil || !info.IsDir() {
		return
	}
	if _, err := os.Stat(newDir); err == nil {
		// The target already has dumps: keep both, moving the old files in.
		entries, err := os.ReadDir(oldDir)
		if err != nil {
			return
		}
		for _, entry := range entries {
			if err := os.Rename(filepath.Join(oldDir, entry.Name()), filepath.Join(newDir, entry.Name())); err != nil {
				log.Printf("migrate dump %s: %v", entry.Name(), err)
			}
		}
		_ = os.Remove(oldDir)
		return
	}
	if err := os.Rename(oldDir, newDir); err != nil {
		log.Printf("rename dump dir %s -> %s: %v", oldDir, newDir, err)
	}
}

func (s *Server) handleDeleteSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	name := r.PathValue("syncenv")

	err := s.store.Update(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		idx := -1
		for i := range svc.SyncEnvs {
			if svc.SyncEnvs[i].Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("sync environment %q not found", name)
		}
		svc.SyncEnvs = append(svc.SyncEnvs[:idx], svc.SyncEnvs[idx+1:]...)
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return fmt.Errorf("profile %q not found", profileName)
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

// notFoundError marks an error that maps to HTTP 404.
type notFoundError struct{ msg string }

func (e notFoundError) Error() string { return e.msg }

func notFoundf(format string, args ...any) error {
	return notFoundError{msg: fmt.Sprintf(format, args...)}
}

func statusForError(err error) int {
	var nf notFoundError
	if errors.As(err, &nf) {
		return http.StatusNotFound
	}
	return http.StatusBadRequest
}

// findService returns the mutable service inside the loaded config.
func findService(c *config.Config, profileName, envName, serviceName string) (*config.Service, error) {
	p, ok := c.GetProfile(profileName)
	if !ok {
		return nil, notFoundf("profile %q not found", profileName)
	}
	for i := range p.Environments {
		if p.Environments[i].Name != envName {
			continue
		}
		env := &p.Environments[i]
		for j := range env.Services {
			if env.Services[j].Name == serviceName {
				return &env.Services[j], nil
			}
		}
		return nil, notFoundf("service %q not found in %s/%s", serviceName, profileName, envName)
	}
	return nil, notFoundf("environment %q not found in profile %q", envName, profileName)
}
