package server

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
)

// Store owns the single in-process view of ~/.stackr/config.yaml.
//
// The CLI may be editing the same file at any time, so every read checks the
// file's mtime and reloads before answering. Writes go through Update, which
// re-reads, mutates and atomically saves, so the engine never clobbers a
// change the CLI made while the app was open.
type Store struct {
	mu    sync.Mutex
	cfg   *config.Config
	mtime time.Time
	path  string
}

func NewStore() (*Store, error) {
	s := &Store{path: filepath.Join(config.StackrDir(), "config.yaml")}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.refreshLocked(); err != nil {
		return nil, err
	}
	return s, nil
}

// View runs fn with the freshest copy of the config while holding the lock.
// fn must only read or copy data; it must not perform I/O.
func (s *Store) View(fn func(*config.Config) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.refreshLocked(); err != nil {
		return err
	}
	return fn(s.cfg)
}

// Update runs fn against the freshest config and saves the result atomically.
func (s *Store) Update(fn func(*config.Config) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.refreshLocked(); err != nil {
		return err
	}
	if err := fn(s.cfg); err != nil {
		return err
	}
	if err := s.cfg.Save(); err != nil {
		return err
	}
	if info, err := os.Stat(s.path); err == nil {
		s.mtime = info.ModTime()
	}
	return nil
}

func (s *Store) refreshLocked() error {
	info, err := os.Stat(s.path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("stat config: %w", err)
	}
	if s.cfg != nil && err == nil && info.ModTime().Equal(s.mtime) {
		return nil
	}
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	s.cfg = cfg
	if info, statErr := os.Stat(s.path); statErr == nil {
		s.mtime = info.ModTime()
	}
	return nil
}
