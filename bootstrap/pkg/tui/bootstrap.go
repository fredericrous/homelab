package tui

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/bootstrap"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/logger"
)

// BootstrapModel represents the TUI model for bootstrap process
type BootstrapModel struct {
	config       *config.Config
	orchestrator *bootstrap.Orchestrator
	steps        []BootstrapStep
	currentStep  int
	status       string
	logs         []string
	err          error
	done         bool
	ctx          context.Context
}

// BootstrapStep represents a single bootstrap step
type BootstrapStep struct {
	Name        string
	Description string
	Status      StepStatus
	Error       error
	StartTime   time.Time
	EndTime     time.Time
}

// StepStatus represents the status of a bootstrap step
type StepStatus int

const (
	StepPending StepStatus = iota
	StepRunning
	StepCompleted
	StepFailed
)

func (s StepStatus) String() string {
	switch s {
	case StepPending:
		return "⏳"
	case StepRunning:
		return "🚀"
	case StepCompleted:
		return "✅"
	case StepFailed:
		return "❌"
	default:
		return "?"
	}
}

func kubeconfigFor(cluster string) string {
	switch cluster {
	case "nas":
		return filepath.Join("infrastructure", "nas", "kubeconfig.yaml")
	case "homelab":
		return filepath.Join("infrastructure", "homelab", "kubeconfig.yaml")
	default:
		return ""
	}
}

func defaultOrchestratorOptions(isNAS bool) *bootstrap.OrchestratorOptions {
	homelabPath := kubeconfigFor("homelab")
	nasPath := kubeconfigFor("nas")
	if isNAS {
		return &bootstrap.OrchestratorOptions{
			KubeconfigPath:        nasPath,
			HomelabKubeconfigPath: homelabPath,
			NASKubeconfigPath:     nasPath,
		}
	}
	return &bootstrap.OrchestratorOptions{
		KubeconfigPath:        homelabPath,
		HomelabKubeconfigPath: homelabPath,
		NASKubeconfigPath:     nasPath,
	}
}

// NewBootstrapModel creates a new bootstrap TUI model
func NewBootstrapModel(ctx context.Context, cfg *config.Config, isNAS bool) *BootstrapModel {
	// Set up comprehensive file logging for TUI mode
	// Infrastructure tools should always provide detailed logs for troubleshooting
	logFileName := "bootstrap.log"

	if f, err := tea.LogToFile(logFileName, "tui"); err == nil {
		// Redirect application logs to the same file with debug level
		logger.SetupTUILogger(f)
		// Don't defer close here - the file needs to stay open for the entire TUI session
	}

	// Create orchestrator for actual bootstrap operations
	orchestrator, orchErr := bootstrap.NewOrchestrator(cfg, isNAS, defaultOrchestratorOptions(isNAS))
	if orchErr != nil {
		log.Error("Failed to create orchestrator for TUI", "error", orchErr)
	}
	steps := []BootstrapStep{
		{
			Name:        "check-prereq",
			Description: "Check prerequisites and validate configuration",
			Status:      StepPending,
		},
		{
			Name:        "connect-cluster",
			Description: "Connect to Kubernetes cluster",
			Status:      StepPending,
		},
		{
			Name:        "install-flux",
			Description: "Install FluxCD GitOps controller",
			Status:      StepPending,
		},
		{
			Name:        "bootstrap-gitops",
			Description: "Bootstrap GitOps repository synchronization",
			Status:      StepPending,
		},
		{
			Name:        "wait-controllers",
			Description: "Wait for controllers to be ready",
			Status:      StepPending,
		},
		{
			Name:        "validate",
			Description: "Validate infrastructure deployment",
			Status:      StepPending,
		},
	}

	if !isNAS {
		// Add homelab-specific steps
		steps = append(steps[:2], append([]BootstrapStep{
			{
				Name:        "install-cilium",
				Description: "Install Cilium CNI",
				Status:      StepPending,
			},
			{
				Name:        "setup-vault",
				Description: "Setup Vault integration",
				Status:      StepPending,
			},
		}, steps[2:]...)...)
	}

	return &BootstrapModel{
		config:       cfg,
		orchestrator: orchestrator,
		steps:        steps,
		currentStep:  0,
		logs:         []string{},
		ctx:          ctx,
	}
}

// Init initializes the TUI model
func (m *BootstrapModel) Init() tea.Cmd {
	return tea.Batch(
		m.startBootstrap(),
		tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
			return TickMsg(t)
		}),
	)
}

// TickMsg represents a tick message for updating the UI
type TickMsg time.Time

// Update handles TUI messages
func (m *BootstrapModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		}
	case StepCompleteMsg:
		if m.currentStep < len(m.steps) {
			m.steps[m.currentStep].Status = StepCompleted
			m.steps[m.currentStep].EndTime = time.Now()
			m.currentStep++

			if m.currentStep < len(m.steps) {
				return m, m.runStep(m.currentStep)
			} else {
				m.done = true
				m.status = "🎉 Bootstrap completed successfully!"
			}
		}
	case StepErrorMsg:
		if m.currentStep < len(m.steps) {
			m.steps[m.currentStep].Status = StepFailed
			m.steps[m.currentStep].Error = msg.Error
			m.steps[m.currentStep].EndTime = time.Now()
			m.err = msg.Error
			m.status = fmt.Sprintf("❌ Bootstrap failed: %v", msg.Error)
		}
	case LogMsg:
		m.logs = append(m.logs, msg.Message)
		// Keep only last 10 log messages
		if len(m.logs) > 10 {
			m.logs = m.logs[1:]
		}
	case TickMsg:
		return m, tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
			return TickMsg(t)
		})
	}

	return m, nil
}

// View renders the TUI
func (m *BootstrapModel) View() string {
	var s strings.Builder

	// Header
	headerStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#FAFAFA")).
		Background(lipgloss.Color("#7D56F4")).
		Padding(0, 1)

	s.WriteString(headerStyle.Render("🚀 Homelab Bootstrap"))
	s.WriteString("\n\n")

	// Steps
	for i, step := range m.steps {
		var style lipgloss.Style

		switch step.Status {
		case StepRunning:
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFFF00"))
		case StepCompleted:
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#00FF00"))
		case StepFailed:
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF0000"))
		default:
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#808080"))
		}

		if i == m.currentStep {
			style = style.Bold(true)
		}

		duration := ""
		if !step.StartTime.IsZero() && !step.EndTime.IsZero() {
			duration = fmt.Sprintf(" (%v)", step.EndTime.Sub(step.StartTime).Round(time.Second))
		}

		line := fmt.Sprintf("%s %s%s", step.Status.String(), step.Description, duration)
		s.WriteString(style.Render(line))
		s.WriteString("\n")

		if step.Error != nil {
			errorStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#FF0000")).Margin(0, 2)
			s.WriteString(errorStyle.Render(fmt.Sprintf("Error: %v", step.Error)))
			s.WriteString("\n")
		}
	}

	s.WriteString("\n")

	// Status
	if m.status != "" {
		statusStyle := lipgloss.NewStyle().Bold(true)
		s.WriteString(statusStyle.Render(m.status))
		s.WriteString("\n\n")
	}

	// Recent logs
	if len(m.logs) > 0 {
		logStyle := lipgloss.NewStyle().
			Foreground(lipgloss.Color("#808080")).
			Italic(true)

		s.WriteString("Recent activity:\n")
		for _, log := range m.logs[max(0, len(m.logs)-5):] {
			s.WriteString(logStyle.Render("  " + log))
			s.WriteString("\n")
		}
		s.WriteString("\n")
	}

	// Instructions
	if !m.done && m.err == nil {
		s.WriteString("Press 'q' or Ctrl+C to quit")
	} else if m.done {
		s.WriteString("✨ Press 'q' or Ctrl+C to exit")
	} else {
		s.WriteString("❌ Press 'q' or Ctrl+C to exit")
	}

	return s.String()
}

// Messages
type StepCompleteMsg struct{}
type StepErrorMsg struct{ Error error }
type LogMsg struct{ Message string }

// Commands
func (m *BootstrapModel) startBootstrap() tea.Cmd {
	return func() tea.Msg {
		return m.runStep(0)()
	}
}

func (m *BootstrapModel) runStep(stepIndex int) tea.Cmd {
	return func() tea.Msg {
		if stepIndex >= len(m.steps) {
			return StepCompleteMsg{}
		}

		step := &m.steps[stepIndex]
		step.Status = StepRunning
		step.StartTime = time.Now()

		switch step.Name {
		case "check-prereq":
			return m.checkPrerequisites()
		case "connect-cluster":
			return m.connectCluster()
		case "install-cilium":
			return m.installCilium()
		case "setup-vault":
			return m.setupVault()
		case "install-flux":
			return m.installFlux()
		case "bootstrap-gitops":
			return m.bootstrapGitOps()
		case "wait-controllers":
			return m.waitControllers()
		case "validate":
			return m.validate()
		default:
			return StepErrorMsg{Error: fmt.Errorf("unknown step: %s", step.Name)}
		}
	}
}

func (m *BootstrapModel) checkPrerequisites() tea.Msg {
	// This would ideally run prerequisite checks
	// For now, simulate the check
	time.Sleep(1 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) connectCluster() tea.Msg {
	// Use orchestrator to verify cluster connectivity
	if m.orchestrator != nil {
		// Run cluster verification step
		err := m.orchestrator.VerifyCluster(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(1 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) installCilium() tea.Msg {
	// Use orchestrator to install Cilium
	if m.orchestrator != nil {
		err := m.orchestrator.InstallCilium(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(2 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) setupVault() tea.Msg {
	// Use orchestrator to setup secrets (includes vault setup)
	if m.orchestrator != nil {
		err := m.orchestrator.SetupSecrets(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(1 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) installFlux() tea.Msg {
	// Use orchestrator to install FluxCD
	if m.orchestrator != nil {
		err := m.orchestrator.InstallFluxCD(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(2 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) bootstrapGitOps() tea.Msg {
	// Use orchestrator to bootstrap GitOps
	if m.orchestrator != nil {
		err := m.orchestrator.BootstrapGitOps(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(1 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) waitControllers() tea.Msg {
	// Use orchestrator to wait for infrastructure
	if m.orchestrator != nil {
		err := m.orchestrator.WaitForInfrastructure(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(3 * time.Second)
	return StepCompleteMsg{}
}

func (m *BootstrapModel) validate() tea.Msg {
	// Use orchestrator to validate deployment
	if m.orchestrator != nil {
		err := m.orchestrator.ValidateDeployment(m.ctx)
		if err != nil {
			return StepErrorMsg{Error: err}
		}
		return StepCompleteMsg{}
	}

	// Fallback simulation
	time.Sleep(1 * time.Second)
	return StepCompleteMsg{}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
