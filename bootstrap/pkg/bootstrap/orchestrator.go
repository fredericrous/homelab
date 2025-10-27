package bootstrap

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/backup"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/flux"
	"github.com/fredericrous/homelab/bootstrap/pkg/health"
	"github.com/fredericrous/homelab/bootstrap/pkg/infra"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"github.com/fredericrous/homelab/bootstrap/pkg/observability"
	"github.com/fredericrous/homelab/bootstrap/pkg/resources"
	"github.com/fredericrous/homelab/bootstrap/pkg/secrets"
	"github.com/fredericrous/homelab/bootstrap/pkg/security"
)

// Orchestrator manages the complete bootstrap process
type Orchestrator struct {
	config         *config.Config
	k8sClient      *k8s.Client
	secretsManager *secrets.Manager
	isNAS          bool
	projectRoot    string
}

// NewOrchestrator creates a new bootstrap orchestrator
func NewOrchestrator(cfg *config.Config, isNAS bool) (*Orchestrator, error) {
	var kubeconfig string

	if isNAS && cfg.NAS != nil {
		kubeconfig = cfg.NAS.Cluster.KubeConfig
	} else if !isNAS && cfg.Homelab != nil {
		kubeconfig = cfg.Homelab.Cluster.KubeConfig
	} else {
		return nil, fmt.Errorf("invalid configuration for orchestrator")
	}

	k8sClient, err := k8s.NewClient(kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create k8s client: %w", err)
	}

	// Determine project root (look for bootstrap directory and go up)
	projectRoot, err := findProjectRoot()
	if err != nil {
		return nil, fmt.Errorf("failed to find project root: %w", err)
	}

	log.Debug("Project root detected", "path", projectRoot)

	secretsManager := secrets.NewManager(k8sClient, projectRoot)

	return &Orchestrator{
		config:         cfg,
		k8sClient:      k8sClient,
		secretsManager: secretsManager,
		isNAS:          isNAS,
		projectRoot:    projectRoot,
	}, nil
}

// BootstrapStep represents a step in the bootstrap process
type BootstrapStep struct {
	Name        string
	Description string
	Required    bool
	Execute     func(ctx context.Context) error
}

// Bootstrap executes the complete bootstrap process
func (o *Orchestrator) Bootstrap(ctx context.Context) error {
	log.Info("Starting bootstrap process", "type", o.getClusterType())

	steps := o.getBootstrapSteps()

	for i, step := range steps {
		log.Info("Executing bootstrap step",
			"step", i+1,
			"total", len(steps),
			"name", step.Name,
			"description", step.Description)

		startTime := time.Now()
		err := step.Execute(ctx)
		duration := time.Since(startTime)

		if err != nil {
			log.Error("Bootstrap step failed",
				"step", step.Name,
				"error", err,
				"duration", duration)

			if step.Required {
				return fmt.Errorf("required step '%s' failed: %w", step.Name, err)
			} else {
				log.Warn("Optional step failed, continuing", "step", step.Name)
			}
		} else {
			log.Info("Bootstrap step completed",
				"step", step.Name,
				"duration", duration)
		}
	}

	log.Info("Bootstrap process completed successfully")
	return nil
}

// getBootstrapSteps returns the steps for bootstrap based on cluster type
func (o *Orchestrator) getBootstrapSteps() []BootstrapStep {
	if o.isNAS {
		return o.getNASBootstrapSteps()
	}
	return o.getHomelabBootstrapSteps()
}

// getHomelabBootstrapSteps returns homelab-specific bootstrap steps
func (o *Orchestrator) getHomelabBootstrapSteps() []BootstrapStep {
	return []BootstrapStep{
		{
			Name:        "verify-cluster",
			Description: "Verify cluster connectivity and readiness",
			Required:    true,
			Execute:     o.verifyCluster,
		},
		{
			Name:        "install-cilium",
			Description: "Install Cilium CNI",
			Required:    true,
			Execute:     o.installCilium,
		},
		{
			Name:        "wait-nodes",
			Description: "Wait for all nodes to be ready",
			Required:    true,
			Execute:     o.waitForNodes,
		},
		{
			Name:        "install-fluxcd",
			Description: "Install FluxCD GitOps controller",
			Required:    true,
			Execute:     o.installFluxCD,
		},
		{
			Name:        "bootstrap-gitops",
			Description: "Bootstrap GitOps repository sync",
			Required:    true,
			Execute:     o.bootstrapGitOps,
		},
		{
			Name:        "setup-secrets",
			Description: "Setup cluster secrets and configurations",
			Required:    true,
			Execute:     o.setupSecrets,
		},
		{
			Name:        "ensure-istio-prereqs",
			Description: "Ensure Istio certificates and remote secrets are in place",
			Required:    true,
			Execute:     o.ensureIstioPrereqs,
		},
		{
			Name:        "wait-infrastructure",
			Description: "Wait for infrastructure components to be ready",
			Required:    false,
			Execute:     o.waitForInfrastructure,
		},
		{
			Name:        "finalize-istio-mesh",
			Description: "Publish gateway endpoints and verify cross-cluster readiness",
			Required:    true,
			Execute:     o.finalizeIstioMesh,
		},
		{
			Name:        "validate-deployment",
			Description: "Validate complete deployment",
			Required:    false,
			Execute:     o.validateDeployment,
		},
		{
			Name:        "comprehensive-health-check",
			Description: "Perform comprehensive cluster health validation",
			Required:    false,
			Execute:     o.comprehensiveHealthCheck,
		},
	}
}

// getNASBootstrapSteps returns NAS-specific bootstrap steps
func (o *Orchestrator) getNASBootstrapSteps() []BootstrapStep {
	return []BootstrapStep{
		{
			Name:        "verify-cluster",
			Description: "Verify NAS cluster connectivity",
			Required:    true,
			Execute:     o.verifyCluster,
		},
		{
			Name:        "install-fluxcd",
			Description: "Install FluxCD GitOps controller",
			Required:    true,
			Execute:     o.installFluxCD,
		},
		{
			Name:        "bootstrap-gitops",
			Description: "Bootstrap GitOps repository sync",
			Required:    true,
			Execute:     o.bootstrapGitOps,
		},
		{
			Name:        "setup-secrets",
			Description: "Setup NAS secrets and configurations",
			Required:    true,
			Execute:     o.setupSecrets,
		},
		{
			Name:        "ensure-istio-prereqs",
			Description: "Ensure Istio certificates and remote secrets are in place",
			Required:    true,
			Execute:     o.ensureIstioPrereqs,
		},
		{
			Name:        "wait-infrastructure",
			Description: "Wait for NAS infrastructure to be ready",
			Required:    false,
			Execute:     o.waitForInfrastructure,
		},
		{
			Name:        "finalize-istio-mesh",
			Description: "Publish gateway endpoints and verify cross-cluster readiness",
			Required:    true,
			Execute:     o.finalizeIstioMesh,
		},
		{
			Name:        "validate-deployment",
			Description: "Validate NAS deployment",
			Required:    false,
			Execute:     o.validateDeployment,
		},
	}
}

// Public methods for TUI integration

// VerifyCluster verifies cluster connectivity (public method for TUI)
func (o *Orchestrator) VerifyCluster(ctx context.Context) error {
	return o.verifyCluster(ctx)
}

// InstallCilium installs Cilium CNI (public method for TUI)
func (o *Orchestrator) InstallCilium(ctx context.Context) error {
	return o.installCilium(ctx)
}

// InstallFluxCD installs FluxCD (public method for TUI)
func (o *Orchestrator) InstallFluxCD(ctx context.Context) error {
	return o.installFluxCD(ctx)
}

// BootstrapGitOps bootstraps GitOps repository sync (public method for TUI)
func (o *Orchestrator) BootstrapGitOps(ctx context.Context) error {
	return o.bootstrapGitOps(ctx)
}

// SetupSecrets sets up cluster secrets (public method for TUI)
func (o *Orchestrator) SetupSecrets(ctx context.Context) error {
	return o.setupSecrets(ctx)
}

// WaitForInfrastructure waits for infrastructure to be ready (public method for TUI)
func (o *Orchestrator) WaitForInfrastructure(ctx context.Context) error {
	return o.waitForInfrastructure(ctx)
}

// ValidateDeployment validates the deployment (public method for TUI)
func (o *Orchestrator) ValidateDeployment(ctx context.Context) error {
	return o.validateDeployment(ctx)
}

// Step implementations

func (o *Orchestrator) verifyCluster(ctx context.Context) error {
	log.Info("Verifying cluster connectivity")

	if err := o.k8sClient.IsReady(ctx); err != nil {
		return fmt.Errorf("cluster not ready: %w", err)
	}

	nodes, err := o.k8sClient.GetNodes(ctx)
	if err != nil {
		return fmt.Errorf("failed to get nodes: %w", err)
	}

	log.Info("Cluster verification successful", "node_count", len(nodes))
	return nil
}

func (o *Orchestrator) installCilium(ctx context.Context) error {
	if o.isNAS {
		log.Debug("Skipping Cilium installation for NAS (using different CNI)")
		return nil
	}

	log.Info("Installing Cilium CNI")

	installer := infra.NewCiliumInstaller(o.k8sClient)

	ciliumConfig := infra.CiliumConfig{
		ClusterPodCIDR: o.config.Homelab.Cluster.Networking.PodCIDR,
		NodeEncryption: false, // TODO: make configurable
		Hubble:         true,  // TODO: make configurable
		LoadBalancer:   true,  // TODO: make configurable
	}

	return installer.Install(ctx, ciliumConfig)
}

func (o *Orchestrator) waitForNodes(ctx context.Context) error {
	log.Info("Waiting for all nodes to be ready")

	var expectedNodes int
	if o.isNAS {
		expectedNodes = 1 // NAS typically has 1 node
	} else {
		expectedNodes = len(o.config.Homelab.Cluster.Nodes)
	}

	timeout := 10 * time.Minute
	return o.k8sClient.WaitForNodes(ctx, expectedNodes, timeout)
}

func (o *Orchestrator) installFluxCD(ctx context.Context) error {
	log.Info("Installing FluxCD")

	var gitopsConfig *config.GitOpsConfig
	if o.isNAS {
		gitopsConfig = &o.config.NAS.GitOps
	} else {
		gitopsConfig = &o.config.Homelab.GitOps
	}

	fluxClient := flux.NewClient(o.k8sClient, gitopsConfig)
	return fluxClient.Install(ctx, "flux-system")
}

func (o *Orchestrator) bootstrapGitOps(ctx context.Context) error {
	log.Info("Bootstrapping GitOps repository sync")

	var gitopsConfig *config.GitOpsConfig
	if o.isNAS {
		gitopsConfig = &o.config.NAS.GitOps
	} else {
		gitopsConfig = &o.config.Homelab.GitOps
	}

	fluxClient := flux.NewClient(o.k8sClient, gitopsConfig)
	return fluxClient.Bootstrap(ctx, "flux-system")
}

func (o *Orchestrator) setupSecrets(ctx context.Context) error {
	log.Info("Setting up cluster secrets and configurations")

	// Create flux-system namespace if it doesn't exist
	if err := o.k8sClient.CreateNamespace(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to create flux-system namespace: %w", err)
	}

	// Create cluster-vars secret from .env file
	log.Info("Creating cluster-vars secret from .env file")
	if err := o.secretsManager.CreateClusterVarsSecret(ctx, "flux-system"); err != nil {
		return fmt.Errorf("failed to create cluster-vars secret: %w", err)
	}

	// Create vault-transit-token secret (only for homelab)
	if !o.isNAS {
		log.Info("Creating vault-transit-token secret")
		if err := o.secretsManager.CreateVaultTransitTokenSecret(ctx, ""); err != nil {
			log.Warn("Failed to create vault-transit-token secret", "error", err)
			log.Info("This is not critical for initial bootstrap - you can set up vault integration later")
			// Continue - vault might not be available during initial bootstrap
		}
	}

	// Setup cross-cluster secrets (only for homelab)
	if !o.isNAS {
		log.Info("Setting up cross-cluster secrets")
		ccManager, err := secrets.NewCrossClusterManager(o.k8sClient, o.projectRoot)
		if err != nil {
			log.Warn("Failed to create cross-cluster manager", "error", err)
		} else {
			if err := ccManager.CreateIstioRemoteSecret(ctx); err != nil {
				log.Warn("Failed to create Istio remote secret", "error", err)
				// Continue - this is not critical for initial bootstrap
			}
		}
	}

	log.Info("Secret setup completed")
	return nil
}

func (o *Orchestrator) waitForInfrastructure(ctx context.Context) error {
	log.Info("Waiting for infrastructure components to be ready")

	timeouts := infra.DefaultTimeouts()

	// Override timeouts from configuration
	if o.isNAS && o.config.NAS != nil {
		// Use NAS timeouts
		timeouts.Controllers = o.parseDuration(o.config.NAS.Cluster.Timeouts.Infrastructure, timeouts.Controllers)
		timeouts.Platform = o.parseDuration(o.config.NAS.Cluster.Timeouts.Application, timeouts.Platform)
	} else if !o.isNAS && o.config.Homelab != nil {
		// Use homelab timeouts
		timeouts.Controllers = o.parseDuration(o.config.Homelab.Cluster.Timeouts.Infrastructure, timeouts.Controllers)
		timeouts.Platform = o.parseDuration(o.config.Homelab.Cluster.Timeouts.Application, timeouts.Platform)
	}

	platformName := "platform-foundation"
	controllersName := "controllers"
	if o.isNAS {
		platformName = "nas-platform-foundation"
		controllersName = ""
	}

	waiter := infra.NewWaiter(o.k8sClient, timeouts, platformName, controllersName)
	return waiter.WaitForInfrastructure(ctx)
}

func (o *Orchestrator) validateDeployment(ctx context.Context) error {
	log.Info("Validating deployment")

	// Check FluxCD status
	var gitopsConfig *config.GitOpsConfig
	if o.isNAS {
		gitopsConfig = &o.config.NAS.GitOps
	} else {
		gitopsConfig = &o.config.Homelab.GitOps
	}

	fluxClient := flux.NewClient(o.k8sClient, gitopsConfig)
	status, err := fluxClient.GetSyncStatus(ctx, "flux-system")
	if err != nil {
		return fmt.Errorf("failed to get flux status: %w", err)
	}

	if status.Ready {
		log.Info("FluxCD validation passed", "status", "ready")
	} else {
		return fmt.Errorf("FluxCD validation failed: %s", status.Message)
	}

	log.Info("Deployment validation completed")
	return nil
}

func (o *Orchestrator) comprehensiveHealthCheck(ctx context.Context) error {
	log.Info("Performing comprehensive platform health validation")

	// Health Check
	healthChecker := health.NewHealthChecker(o.k8sClient)
	healthStatus, err := healthChecker.CheckClusterHealth(ctx)
	if err != nil {
		log.Warn("Health check completed with errors", "error", err)
	} else {
		log.Info("Cluster health validated",
			"overall", healthStatus.Overall,
			"healthy_components", len(healthStatus.Components))
	}

	// Security Validation
	securityValidator := security.NewSecurityValidator(o.k8sClient)
	securityStatus, err := securityValidator.ValidateClusterSecurity(ctx)
	if err != nil {
		log.Warn("Security validation completed with errors", "error", err)
	} else {
		log.Info("Security validation completed",
			"rbac_enabled", securityStatus.RBACEnabled,
			"vulnerabilities", len(securityStatus.Vulnerabilities))
	}

	// Resource Management Validation
	resourceManager := resources.NewResourceManager(o.k8sClient)
	resourceStatus, err := resourceManager.ValidateResourceManagement(ctx)
	if err != nil {
		log.Warn("Resource management validation completed with errors", "error", err)
	} else {
		log.Info("Resource management validated",
			"metrics_server", resourceStatus.MetricsServerHealthy,
			"hpa_configured", resourceStatus.HPAConfigured)
	}

	// Observability Validation
	obsMonitor := observability.NewObservabilityMonitor(o.k8sClient)
	obsStatus, err := obsMonitor.ValidateObservabilityStack(ctx)
	if err != nil {
		log.Warn("Observability validation completed with errors", "error", err)
	} else {
		log.Info("Observability validated",
			"prometheus", obsStatus.PrometheusHealthy,
			"grafana", obsStatus.GrafanaHealthy)
	}

	// Backup Validation (optional)
	backupValidator := backup.NewBackupValidator(o.k8sClient)
	backupStatus, err := backupValidator.ValidateBackupSystems(ctx)
	if err != nil {
		log.Debug("Backup validation completed with warnings", "error", err)
	} else {
		log.Info("Backup systems validated",
			"velero", backupStatus.VeleroHealthy,
			"etcd_backup", backupStatus.EtcdBackup)
	}

	log.Info("Comprehensive platform health check completed")
	return nil
}

// Helper methods

func (o *Orchestrator) getClusterType() string {
	if o.isNAS {
		return "NAS"
	}
	return "homelab"
}

func (o *Orchestrator) parseDuration(s string, defaultDuration time.Duration) time.Duration {
	if s == "" {
		return defaultDuration
	}

	d, err := time.ParseDuration(s)
	if err != nil {
		log.Warn("Failed to parse duration, using default", "input", s, "default", defaultDuration)
		return defaultDuration
	}

	return d
}

// findProjectRoot finds the project root directory by looking for common project files
func findProjectRoot() (string, error) {
	// Get current working directory
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to get working directory: %w", err)
	}

	// Look for project indicators (prioritize .git over go.mod to find actual repo root)
	current := wd
	for {
		log.Debug("Checking directory for project root", "path", current)

		// Check for .git directory first (main project root)
		gitPath := filepath.Join(current, ".git")
		if _, err := os.Stat(gitPath); err == nil {
			log.Debug("Found .git directory", "path", gitPath)
			return current, nil
		}

		// Check for bootstrap directory (our specific project structure)
		bootstrapPath := filepath.Join(current, "bootstrap")
		if stat, err := os.Stat(bootstrapPath); err == nil && stat.IsDir() {
			log.Debug("Found bootstrap directory", "path", bootstrapPath)
			return current, nil
		}

		// Check for go.mod as fallback (but this might be in subdirectory)
		goModPath := filepath.Join(current, "go.mod")
		envPath := filepath.Join(current, ".env")
		if _, err := os.Stat(goModPath); err == nil {
			log.Debug("Found go.mod", "path", goModPath)
			// Only accept go.mod if we also have .env file (indicating main project)
			if _, err := os.Stat(envPath); err == nil {
				log.Debug("Found .env with go.mod", "path", envPath)
				return current, nil
			} else {
				log.Debug(".env not found with go.mod, continuing", "envPath", envPath)
			}
		}

		// Move up one directory
		parent := filepath.Dir(current)
		if parent == current {
			// Reached filesystem root
			break
		}
		log.Debug("Moving up directory", "from", current, "to", parent)
		current = parent
	}

	// Fail if project root cannot be found
	return "", fmt.Errorf("project root not found - ensure you're running from within the homelab project")
}
