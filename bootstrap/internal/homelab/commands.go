package homelab

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
	"github.com/fredericrous/homelab/bootstrap/pkg/infra"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"github.com/fredericrous/homelab/bootstrap/pkg/output"
	"github.com/fredericrous/homelab/bootstrap/pkg/prereq"
	"github.com/fredericrous/homelab/bootstrap/pkg/recovery"
	"github.com/fredericrous/homelab/bootstrap/pkg/secrets"
	"github.com/fredericrous/homelab/bootstrap/pkg/tui"
	"github.com/spf13/cobra"
)

// NewBootstrapCommand creates the bootstrap command for homelab
func NewBootstrapCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Bootstrap the homelab cluster",
		Long:  "Bootstrap a new homelab cluster with Talos, Cilium, and FluxCD",
		RunE: func(cmd *cobra.Command, args []string) error {
			noTui, _ := cmd.Flags().GetBool("no-tui")
			return runBootstrap(cmd.Context(), noTui)
		},
	}

	cmd.Flags().Bool("no-tui", false, "Disable interactive TUI mode")
	return cmd
}

// NewCheckCommand creates the check command for homelab
func NewCheckCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "check",
		Short: "Check homelab prerequisites and status",
		Long:  "Check that all prerequisites are met and validate cluster status",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCheck(cmd.Context())
		},
	}

	return cmd
}

// NewInstallCommand creates the install command for homelab
func NewInstallCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Install homelab infrastructure",
		Long:  "Install and configure homelab infrastructure components",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInstall(cmd.Context())
		},
	}

	return cmd
}

// NewValidateCommand creates the validate command for homelab
func NewValidateCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "validate",
		Short: "Validate homelab deployment",
		Long:  "Validate that all homelab components are working correctly",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runValidate(cmd.Context())
		},
	}

	return cmd
}

// NewDestroyCommand creates the destroy command for homelab
func NewDestroyCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "destroy",
		Short: "Destroy homelab cluster",
		Long:  "Destroy the homelab cluster and clean up resources",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runDestroy(cmd.Context())
		},
	}

	return cmd
}

func runBootstrap(ctx context.Context, noTui bool) error {
	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	if noTui {
		// Simple non-interactive mode
		log.Info("Starting homelab bootstrap (non-interactive mode)")
		log.Info("Cluster configuration",
			"name", cfg.Homelab.Cluster.Name,
			"nodes", cfg.Homelab.Cluster.Nodes,
			"distribution", cfg.Homelab.Cluster.Distribution)

		// Create orchestrator and run bootstrap
		orchestrator, err := bootstrap.NewOrchestrator(cfg, false)
		if err != nil {
			return fmt.Errorf("failed to create orchestrator: %w", err)
		}

		return orchestrator.Bootstrap(ctx)
	}

	// Start interactive bootstrap TUI
	model := tui.NewBootstrapModel(ctx, cfg, false)
	p := tea.NewProgram(model)

	if _, err := p.Run(); err != nil {
		return fmt.Errorf("bootstrap failed: %w", err)
	}

	return nil
}

func runCheck(ctx context.Context) error {
	log.Info("Checking homelab prerequisites")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Run comprehensive prerequisite checks
	checker := prereq.NewChecker(cfg, false)
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
	log.Info("Installing homelab infrastructure")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	log.Info("Connecting to cluster", "kubeconfig", cfg.Homelab.Cluster.KubeConfig)
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Install FluxCD
	log.Info("Installing FluxCD", "namespace", "flux-system")
	fluxClient := flux.NewClient(client, &cfg.Homelab.GitOps)
	if err := fluxClient.Install(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to install flux: %w", err)
	}

	log.Info("Installation completed successfully")
	return nil
}

func runValidate(ctx context.Context) error {
	log.Info("Validating homelab deployment")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check flux status
	fluxClient := flux.NewClient(client, &cfg.Homelab.GitOps)
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
	log.Warn("🗑️ Destroying homelab cluster")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Create destroy manager
	destroyManager, err := destroy.NewManager(cfg, false)
	if err != nil {
		return fmt.Errorf("failed to create destroy manager: %w", err)
	}

	// Perform destruction
	if err := destroyManager.DestroyCluster(ctx); err != nil {
		return fmt.Errorf("cluster destruction failed: %w", err)
	}

	log.Info("🎉 Homelab cluster destruction completed successfully")
	return nil
}

// NewUpCommand creates the up command for homelab infrastructure
func NewUpCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "up",
		Short: "Create homelab cluster infrastructure",
		Long:  "Create cluster infrastructure (VMs + Talos, ready for CNI)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runUp(cmd.Context())
		},
	}

	return cmd
}

// NewInstallCiliumCommand creates the install-cilium command
func NewInstallCiliumCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "install-cilium",
		Short: "Install Cilium CNI",
		Long:  "Install Cilium CNI (required before workers can join)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runInstallCilium(cmd.Context())
		},
	}

	return cmd
}

// NewSyncSecretsCommand creates the sync-secrets command
func NewSyncSecretsCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "sync-secrets",
		Short: "Sync environment secrets",
		Long:  "Sync environment variables to cluster-vars secret and setup cross-cluster connectivity",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSyncSecrets(cmd.Context())
		},
	}

	return cmd
}

// NewSuspendCommand creates the suspend command
func NewSuspendCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "suspend",
		Short: "Suspend Flux reconciliation",
		Long:  "Suspend Flux reconciliation (services keep running)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runSuspend(cmd.Context())
		},
	}

	return cmd
}

// NewResumeCommand creates the resume command
func NewResumeCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "resume",
		Short: "Resume Flux reconciliation",
		Long:  "Resume Flux reconciliation",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runResume(cmd.Context())
		},
	}

	return cmd
}

// NewUninstallCommand creates the uninstall command
func NewUninstallCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "Uninstall homelab cluster",
		Long:  "Uninstall everything (cluster + VMs + configs)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runUninstall(cmd.Context())
		},
	}

	return cmd
}

// NewStatusCommand creates the status command
func NewStatusCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Check homelab status",
		Long:  "Check status of homelab cluster and components",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatus(cmd.Context())
		},
	}

	return cmd
}

func runUp(ctx context.Context) error {
	log.Info("🚀 Creating homelab cluster infrastructure (VMs + Talos)")
	
	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "homelab", "up")
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

func runInstallCilium(ctx context.Context) error {
	log.Info("🌐 Installing Cilium CNI")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check if cluster is accessible
	if err := client.IsReady(ctx); err != nil {
		return fmt.Errorf("cluster not ready: %w", err)
	}

	// Create Cilium installer
	ciliumInstaller := infra.NewCiliumInstaller(client)

	// Configure Cilium
	ciliumConfig := infra.CiliumConfig{
		ClusterPodCIDR: "10.244.0.0/16", // Default pod CIDR
		Hubble:         true,             // Enable Hubble observability
		LoadBalancer:   false,            // Use with MetalLB instead
	}

	// Override with config values if available
	if cfg.Homelab.Infrastructure != nil && cfg.Homelab.Infrastructure.PodCIDR != "" {
		ciliumConfig.ClusterPodCIDR = cfg.Homelab.Infrastructure.PodCIDR
	}

	// Install Cilium
	if err := ciliumInstaller.Install(ctx, ciliumConfig); err != nil {
		return fmt.Errorf("failed to install Cilium: %w", err)
	}

	log.Info("✅ Cilium CNI installation completed")
	return nil
}

func runSyncSecrets(ctx context.Context) error {
	log.Info("🔐 Syncing environment secrets")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check if cluster is accessible
	if err := client.IsReady(ctx); err != nil {
		return fmt.Errorf("cluster not ready: %w", err)
	}

	// Find project root for secrets manager
	wd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("failed to get working directory: %w", err)
	}
	
	projectRoot := findProjectRoot(wd)
	if projectRoot == "" {
		return fmt.Errorf("project root not found - ensure you're running from within the homelab project")
	}

	// Create secrets manager
	secretsManager := secrets.NewManager(client, projectRoot)

	// Create cluster-vars secret
	log.Info("Creating cluster-vars secret from .env")
	if err := secretsManager.CreateClusterVarsSecret(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to create cluster-vars secret: %w", err)
	}

	// Setup cross-cluster connectivity
	log.Info("Setting up cross-cluster connectivity with NAS")
	crossClusterManager, err := secrets.NewCrossClusterManager(client, projectRoot)
	if err != nil {
		return fmt.Errorf("failed to create cross-cluster manager: %w", err)
	}
	if err := crossClusterManager.CreateIstioRemoteSecret(ctx); err != nil {
		return fmt.Errorf("failed to setup cross-cluster connectivity: %w", err)
	}

	log.Info("✅ Environment secrets synced successfully")
	return nil
}

func runSuspend(ctx context.Context) error {
	log.Info("⏸️ Suspending Flux reconciliation")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check if cluster is accessible
	if err := client.IsReady(ctx); err != nil {
		return fmt.Errorf("cluster not ready: %w", err)
	}

	fluxClient := flux.NewClient(client, &cfg.Homelab.GitOps)
	if err := fluxClient.SuspendReconciliation(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to suspend Flux reconciliation: %w", err)
	}

	log.Info("✅ Flux reconciliation suspended")
	log.Info("ℹ️  Services continue running but won't be updated")
	log.Info("ℹ️  Run 'bootstrap homelab resume' to re-enable reconciliation")

	return nil
}

func runResume(ctx context.Context) error {
	log.Info("▶️ Resuming Flux reconciliation")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check if cluster is accessible
	if err := client.IsReady(ctx); err != nil {
		return fmt.Errorf("cluster not ready: %w", err)
	}

	fluxClient := flux.NewClient(client, &cfg.Homelab.GitOps)
	if err := fluxClient.ResumeReconciliation(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to resume Flux reconciliation: %w", err)
	}

	log.Info("✅ Flux reconciliation resumed")
	return nil
}

func runUninstall(ctx context.Context) error {
	log.Warn("🗑️ Uninstalling homelab cluster")
	
	// Delegate to infrastructure Taskfile
	return runInfrastructureTask(ctx, "homelab", "uninstall")
}

func runStatus(ctx context.Context) error {
	log.Info("🔍 Checking homelab status")

	// Load configuration
	loader := config.NewLoader()
	cfg, err := loader.LoadConfig("homelab")
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	if cfg.Homelab == nil {
		return fmt.Errorf("homelab configuration not found")
	}

	// Try to connect to cluster
	client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
	if err != nil {
		log.Error("❌ Cannot connect to cluster", "error", err)
		return fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Check if cluster is accessible
	if err := client.IsReady(ctx); err != nil {
		log.Error("❌ Cluster API not ready", "error", err)
		return fmt.Errorf("cluster not ready: %w", err)
	}

	log.Info("✅ Cluster API is accessible")

	// Check nodes
	nodes, err := client.GetNodes(ctx)
	if err != nil {
		log.Error("❌ Failed to get nodes", "error", err)
	} else {
		log.Info("📋 Nodes", "count", len(nodes), "nodes", nodes)
	}

	// Check FluxCD
	exists, err := client.NamespaceExists(ctx, "flux-system")
	if err != nil {
		log.Error("❌ Failed to check flux-system namespace", "error", err)
	} else if !exists {
		log.Warn("⚠️ FluxCD is not installed (flux-system namespace missing)")
	} else {
		log.Info("✅ FluxCD namespace exists")

		// Check Flux status
		fluxClient := flux.NewClient(client, &cfg.Homelab.GitOps)
		status, err := fluxClient.GetSyncStatus(ctx, "flux-system")
		if err != nil {
			log.Error("❌ Failed to get Flux status", "error", err)
		} else {
			if status.Ready {
				log.Info("✅ FluxCD is synced and ready")
			} else {
				log.Warn("⚠️ FluxCD sync issues", "message", status.Message)
			}
		}
	}

	// Use recovery diagnostic manager for detailed status
	diagnosticManager, err := recovery.NewDiagnosticManager(cfg, false)
	if err != nil {
		log.Warn("Failed to create diagnostic manager", "error", err)
		return nil
	}

	results, err := diagnosticManager.DiagnoseSystem(ctx)
	if err != nil {
		log.Warn("Failed to run diagnostics", "error", err)
		return nil
	}

	// Print detailed diagnostics
	log.Info("📊 Detailed System Status:")
	diagnosticManager.PrintDiagnostics(results)

	return nil
}
