package output

import (
	"io"
	"os"
	"sync"
)

// Manager handles output redirection for TUI compatibility
type Manager struct {
	mu                 sync.RWMutex
	tuiMode            bool
	originalStdout     *os.File
	originalStderr     *os.File
	devNull            *os.File
}

var (
	globalManager *Manager
	once          sync.Once
)

// GetManager returns the global output manager singleton
func GetManager() *Manager {
	once.Do(func() {
		globalManager = &Manager{
			originalStdout: os.Stdout,
			originalStderr: os.Stderr,
		}
	})
	return globalManager
}

// EnableTUIMode redirects all output to prevent TUI interference
func (m *Manager) EnableTUIMode() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.tuiMode {
		return nil // Already in TUI mode
	}

	// Open /dev/null for redirecting output
	devNull, err := os.OpenFile("/dev/null", os.O_WRONLY, 0)
	if err != nil {
		return err
	}

	m.devNull = devNull
	m.tuiMode = true

	// Redirect stdout and stderr
	os.Stdout = devNull
	os.Stderr = devNull

	return nil
}

// DisableTUIMode restores original output streams
func (m *Manager) DisableTUIMode() {
	m.mu.Lock()
	defer m.mu.Unlock()

	if !m.tuiMode {
		return // Already in normal mode
	}

	// Restore original streams
	os.Stdout = m.originalStdout
	os.Stderr = m.originalStderr

	// Close /dev/null
	if m.devNull != nil {
		m.devNull.Close()
		m.devNull = nil
	}

	m.tuiMode = false
}

// IsTUIMode returns whether TUI mode is currently active
func (m *Manager) IsTUIMode() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.tuiMode
}

// GetStdout returns the appropriate stdout stream (original or /dev/null)
func (m *Manager) GetStdout() io.Writer {
	m.mu.RLock()
	defer m.mu.RUnlock()
	
	if m.tuiMode && m.devNull != nil {
		return m.devNull
	}
	return m.originalStdout
}

// GetStderr returns the appropriate stderr stream (original or /dev/null)
func (m *Manager) GetStderr() io.Writer {
	m.mu.RLock()
	defer m.mu.RUnlock()
	
	if m.tuiMode && m.devNull != nil {
		return m.devNull
	}
	return m.originalStderr
}

// GetOriginalStdout returns the original stdout (for emergency use)
func (m *Manager) GetOriginalStdout() *os.File {
	return m.originalStdout
}

// GetOriginalStderr returns the original stderr (for emergency use)
func (m *Manager) GetOriginalStderr() *os.File {
	return m.originalStderr
}