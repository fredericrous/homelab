package secrets

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// EnvFile provides read/write helpers for simple KEY=VALUE env files.
type EnvFile struct {
	path string

	mu   sync.Mutex
	vars map[string]string
}

// NewEnvFile loads (or initialises) an env file at the provided path.
func NewEnvFile(path string) (*EnvFile, error) {
	ef := &EnvFile{
		path: filepath.Clean(path),
		vars: make(map[string]string),
	}

	if err := ef.reload(); err != nil {
		return nil, err
	}

	return ef, nil
}

// Path returns the absolute path to the env file.
func (e *EnvFile) Path() string {
	return e.path
}

// Get retrieves a value by key.
func (e *EnvFile) Get(key string) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.vars[strings.TrimSpace(key)]
}

// Set stores a value for the provided key. Returns true when a change occurred.
func (e *EnvFile) Set(key, value string) bool {
	key = strings.TrimSpace(key)
	if key == "" {
		return false
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	value = strings.TrimSpace(value)
	if value == "" {
		if _, ok := e.vars[key]; ok {
			delete(e.vars, key)
			return true
		}
		return false
	}

	if existing, ok := e.vars[key]; ok && existing == value {
		return false
	}

	e.vars[key] = value
	return true
}

// All returns a defensive copy of current key/value pairs.
func (e *EnvFile) All() map[string]string {
	e.mu.Lock()
	defer e.mu.Unlock()

	out := make(map[string]string, len(e.vars))
	for k, v := range e.vars {
		out[k] = v
	}
	return out
}

// Write persists current contents to disk (creating the file if missing).
func (e *EnvFile) Write() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if len(e.vars) == 0 {
		if err := os.Remove(e.path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(e.path), 0o755); err != nil {
		return fmt.Errorf("failed to create env dir %s: %w", filepath.Dir(e.path), err)
	}

	keys := make([]string, 0, len(e.vars))
	for key := range e.vars {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(key)
		builder.WriteString("=")
		builder.WriteString(e.vars[key])
		builder.WriteString("\n")
	}

	return os.WriteFile(e.path, []byte(builder.String()), 0o600)
}

// reload refreshes the cache from disk (silently ignoring missing files).
func (e *EnvFile) reload() error {
	e.mu.Lock()
	defer e.mu.Unlock()

	file, err := os.Open(e.path)
	if err != nil {
		if os.IsNotExist(err) {
			e.vars = make(map[string]string)
			return nil
		}
		return fmt.Errorf("failed to open env file %s: %w", e.path, err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	vars := make(map[string]string)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		key := strings.TrimSpace(parts[0])
		value := ""
		if len(parts) == 2 {
			value = strings.TrimSpace(parts[1])
		}

		if key == "" || value == "" {
			continue
		}

		value = strings.Trim(value, `"'`)
		vars[key] = value
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("failed to scan env file %s: %w", e.path, err)
	}

	e.vars = vars
	return nil
}
