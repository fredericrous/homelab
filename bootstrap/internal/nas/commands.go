package nas

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/bootstrap"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/destroy"
	"github.com/fredericrous/homelab/bootstrap/pkg/flux"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"github.com/fredericrous/homelab/bootstrap/pkg/output"
	"github.com/fredericrous/homelab/bootstrap/pkg/prereq"
	"github.com/fredericrous/homelab/bootstrap/pkg/tui"
	"github.com/spf13/cobra"
)

// NewBootstrapCommand creates the bootstrap command for NAS
func NewBootstrapCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Bootstrap the NAS cluster",
		Long:  "Bootstrap a new NAS cluster with K3s, MinIO, and FluxCD",
		RunE: func(cmd *cobra.Command, args []string) error {
			noTui, _ := cmd.Flags().GetBool("no-tui")
			return runBootstrap(cmd.Context(), noTui)
		},
	}

	cmd.Flags().Bool("no-tui", false, "Disable interactive TUI mode")
	return cmd
}

// NewCheckCommand creates the check command for NAS
func NewCheckCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "check",
		Short: "Check NAS prerequisites and status",
		Long:  "Check that all prerequisites are met and validate NAS status",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCheck(cmd.Context())
		},
	}

	return cmd
}

// NewInstallCommand creates the install command for NAS
func NewInstallCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Install NAS infrastructure",
		Long:  "Install and configure NAS infrastructure components",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInstall(cmd.Context())
		},
	}

	return cmd
}

// NewValidateCommand creates the validate command for NAS
func NewValidateCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "validate",
		Short: "Validate NAS deployment",
		Long:  "Validate that all NAS components are working correctly",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runValidate(cmd.Context())
		},
	}

	return cmd
}

// NewDestroyCommand creates the destroy command for NAS
func NewDestroyCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "destroy",
		Short: "Destroy NAS cluster",
		Long:  "Destroy the NAS cluster and clean up resources",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDestroy(cmd.Context())
		},
	}

	return cmd
}

func runBootstrap(ctx context.Context, noTui bool) error {
	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("nas")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.NAS == nil {
		return fmt.Errorf("NAS configuration not found")
	}

	if noTui {
		// Simple non-interactive mode
		log.Info("Starting NAS bootstrap (non-interactive mode)")
		log.Info("Cluster configuration",
			"name", cfg.NAS.Cluster.Name,
			"host", cfg.NAS.Cluster.Host,
			"docker_host", cfg.NAS.Cluster.DockerHost)

		// Create orchestrator and run bootstrap
		orchestrator, err := bootstrap.NewOrchestrator(cfg, true, orchestratorOptions(true))
		if err != nil {
			return fmt.Errorf("failed to create orchestrator: %w", err)
		}

		return orchestrator.Bootstrap(ctx)
	}

	// Start interactive bootstrap TUI
	model := tui.NewBootstrapModel(ctx, cfg, true)
	p := tea.NewProgram(model)

	if _, err := p.Run(); err != nil {
		return fmt.Errorf("bootstrap failed: %w", err)
	}

	return nil
}

func runCheck(ctx context.Context) error {
	log.Info("Checking NAS prerequisites")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("nas")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.NAS == nil {
		return fmt.Errorf("NAS configuration not found")
	}

	// Run comprehensive prerequisite checks
	checker := prereq.NewChecker(cfg, true)
	results, err := checker.CheckAll(ctx)
	if err != nil {
		return fmt.Errorf("failed to run checks: %w", err)
	}

	// Display results
	log.Info("Prerequisite Check Results")
	log.Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	passed := 0
	failed := 0
	warnings := 0

	for _, result := range results {
		switch result.Status {
		case prereq.CheckPassed:
			log.Info("✅ "+result.Description, "details", result.Details)
			passed++
		case prereq.CheckFailed:
			log.Error("❌ "+result.Description, "error", result.Error, "details", result.Details)
			failed++
		case prereq.CheckWarning:
			log.Warn("⚠️ "+result.Description, "error", result.Error, "details", result.Details)
			warnings++
		}
	}

	// Summary
	log.Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Info("Summary", "passed", passed, "warnings", warnings, "failed", failed)

	if failed > 0 {
		log.Error("Some prerequisites failed. Please address the issues above before bootstrapping.")
		return fmt.Errorf("prerequisite checks failed")
	} else if warnings > 0 {
		log.Warn("Some prerequisites have warnings. Bootstrap may still work but could encounter issues.")
	} else {
		log.Info("All prerequisites passed! Ready for bootstrap.")
	}

	return nil
}

func runInstall(ctx context.Context) error {
	log.Info("Installing NAS infrastructure (non-interactive bootstrap)")
	return runBootstrap(ctx, true)
}

func runValidate(ctx context.Context) error {
	log.Info("Validating NAS deployment")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("nas")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.NAS == nil {
		return fmt.Errorf("NAS configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.NAS.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check flux status
	fluxClient := flux.NewClient(client, &cfg.NAS.GitOps)
	status, err := fluxClient.GetSyncStatus(ctx, "flux-system")
	if err != nil {
		return fmt.Errorf("failed to get flux status: %w", err)
	}

	if status.Ready {
		log.Info("FluxCD is running", "status", "ready")
	} else {
		log.Error("FluxCD issue", "message", status.Message)
	}

	log.Info("Validation completed")
	return nil
}

func runDestroy(ctx context.Context) error {
	log.Warn("🗑️ Destroying NAS cluster")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("nas")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.NAS == nil {
		return fmt.Errorf("NAS configuration not found")
	}

	// Create destroy manager
	destroyManager, err := destroy.NewManager(cfg, true)
	if err != nil {
		return fmt.Errorf("failed to create destroy manager: %w", err)
	}

	// Perform destruction
	if err := destroyManager.DestroyCluster(ctx); err != nil {
		return fmt.Errorf("cluster destruction failed: %w", err)
	}

	log.Info("🎉 NAS cluster destruction completed successfully")
	return nil
}

// NewUpCommand creates the up command for NAS infrastructure
func NewUpCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "up",
		Short: "Create NAS cluster infrastructure",
		Long:  "Create K3s cluster infrastructure (Docker Compose + K3s)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runNASUp(cmd.Context())
		},
	}

	return cmd
}

// NewStatusCommand creates the status command for NAS
func NewStatusCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Check NAS status",
		Long:  "Check status of NAS cluster and GitOps",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runNASStatus(cmd.Context())
		},
	}

	return cmd
}

// NewUninstallCommand creates the uninstall command for NAS
func NewUninstallCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "Uninstall NAS cluster",
		Long:  "Uninstall everything (K3s cluster + containers + configs)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runNASUninstall(cmd.Context())
		},
	}

	return cmd
}

// NewVaultSetupCommand creates the vault-setup command for NAS
func NewVaultSetupCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "vault-setup",
		Short: "Setup Vault secrets and configuration",
		Long:  "Setup Vault secrets for MinIO and AWS, configure PKI and transit backend",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runVaultSetup(cmd.Context())
		},
	}

	return cmd
}

func runNASUp(ctx context.Context) error {
	log.Info("🚀 Creating NAS cluster infrastructure (Docker Compose + K3s)")

	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "nas", "up")
}

// runInfrastructureTask executes a task in the specified infrastructure Taskfile
func runInfrastructureTask(ctx context.Context, infra, task string) error {
	// Find project root to work from both repo root and bootstrap directory
	wd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("failed to get working directory: %w", err)
	}

	projectRoot := findProjectRoot(wd)
	if projectRoot == "" {
		return fmt.Errorf("project root not found - ensure you're running from within the homelab project")
	}

	// Determine the infrastructure directory relative to project root
	infrastructureDir := filepath.Join(projectRoot, "infrastructure", infra)

	// Check if the Taskfile exists
	taskfilePath := filepath.Join(infrastructureDir, "Taskfile.yml")
	if _, err := os.Stat(taskfilePath); os.IsNotExist(err) {
		return fmt.Errorf("infrastructure Taskfile not found: %s", taskfilePath)
	}

	// Execute the task using the task command
	cmd := exec.CommandContext(ctx, "task", "-d", infrastructureDir, task)

	// Use output manager to respect TUI mode
	outputMgr := output.GetManager()
	cmd.Stdout = outputMgr.GetStdout()
	cmd.Stderr = outputMgr.GetStderr()
	cmd.Stdin = os.Stdin

	log.Debug("Executing infrastructure task", "infra", infra, "task", task, "dir", infrastructureDir, "projectRoot", projectRoot)

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("infrastructure task failed: %w", err)
	}

	return nil
}

// findProjectRoot finds the project root directory by looking for common project files
func findProjectRoot(startDir string) string {
	current := startDir
	for {
		// Check for project indicators
		indicators := []string{".git", "go.mod", "bootstrap", "Taskfile.yml"}
		for _, indicator := range indicators {
			if _, err := os.Stat(filepath.Join(current, indicator)); err == nil {
				return current
			}
		}

		// Move up one directory
		parent := filepath.Dir(current)
		if parent == current {
			// Reached filesystem root
			break
		}
		current = parent
	}

	return "" // Project root not found
}

func orchestratorOptions(isNAS bool) *bootstrap.OrchestratorOptions {
	if isNAS {
		return &bootstrap.OrchestratorOptions{
			KubeconfigPath:        kubeconfigFor("nas"),
			HomelabKubeconfigPath: kubeconfigFor("homelab"),
			NASKubeconfigPath:     kubeconfigFor("nas"),
		}
	}
	return &bootstrap.OrchestratorOptions{
		KubeconfigPath:        kubeconfigFor("homelab"),
		HomelabKubeconfigPath: kubeconfigFor("homelab"),
		NASKubeconfigPath:     kubeconfigFor("nas"),
	}
}

func kubeconfigFor(cluster string) string {
	return filepath.Join("infrastructure", cluster, "kubeconfig.yaml")
}

func runNASStatus(ctx context.Context) error {
	log.Info("🔍 Checking NAS status")

	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "nas", "status")
}

func runNASUninstall(ctx context.Context) error {
	log.Warn("🗑️ Uninstalling NAS cluster")

	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "nas", "uninstall")
}

func runVaultSetup(ctx context.Context) error {
	log.Info("🔐 Setting up Vault secrets and configuration")

	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "nas", "vault-setup")
}
