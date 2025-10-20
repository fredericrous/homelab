package prereq

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
)

// Checker validates prerequisites for bootstrap
type Checker struct {
	config *config.Config
	isNAS  bool
}

// NewChecker creates a new prerequisite checker
func NewChecker(cfg *config.Config, isNAS bool) *Checker {
	return &Checker{
		config: cfg,
		isNAS:  isNAS,
	}
}

// CheckResult represents the result of a prerequisite check
type CheckResult struct {
	Name        string
	Description string
	Status      CheckStatus
	Error       error
	Details     string
}

// CheckStatus represents the status of a prerequisite check
type CheckStatus int

const (
	CheckPassed CheckStatus = iota
	CheckFailed
	CheckWarning
)

func (s CheckStatus) String() string {
	switch s {
	case CheckPassed:
		return "✅"
	case CheckFailed:
		return "❌"
	case CheckWarning:
		return "⚠️"
	default:
		return "?"
	}
}

// CheckAll performs all prerequisite checks
func (c *Checker) CheckAll(ctx context.Context) ([]CheckResult, error) {
	var results []CheckResult

	// Common checks
	results = append(results, c.checkCommandExists("yq", "yq is required for YAML processing"))
	results = append(results, c.checkCommandExists("kubectl", "kubectl is required for Kubernetes operations"))

	if !c.isNAS {
		// Homelab-specific checks
		results = append(results, c.checkCommandExists("talosctl", "talosctl is required for Talos cluster management"))
		results = append(results, c.checkCommandExists("cilium", "cilium CLI is required for CNI operations"))
		results = append(results, c.checkCommandExists("istioctl", "istioctl is required for service mesh"))
	} else {
		// NAS-specific checks
		results = append(results, c.checkDockerAccess())
	}

	// GitOps checks
	results = append(results, c.checkCommandExists("flux", "flux CLI is required for GitOps operations"))
	results = append(results, c.checkGitHubToken())

	// Environment checks
	results = append(results, c.checkEnvFile())
	results = append(results, c.checkVaultConfig())

	// Cluster connectivity
	results = append(results, c.checkClusterConnectivity(ctx))

	return results, nil
}

// checkCommandExists verifies a required command is available
func (c *Checker) checkCommandExists(command, description string) CheckResult {
	_, err := exec.LookPath(command)
	if err != nil {
		return CheckResult{
			Name:        fmt.Sprintf("command-%s", command),
			Description: description,
			Status:      CheckFailed,
			Error:       fmt.Errorf("command '%s' not found in PATH", command),
			Details:     c.getInstallInstructions(command),
		}
	}

	return CheckResult{
		Name:        fmt.Sprintf("command-%s", command),
		Description: description,
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Found %s", command),
	}
}

// getInstallInstructions provides installation instructions for missing commands
func (c *Checker) getInstallInstructions(command string) string {
	switch command {
	case "yq":
		return "Install with: brew install yq"
	case "kubectl":
		return "Install with: brew install kubectl"
	case "talosctl":
		return "Install with: curl -sL https://talos.dev/install | sh"
	case "cilium":
		return "Install with: brew install cilium-cli"
	case "istioctl":
		return "Install with: curl -L https://istio.io/downloadIstio | sh -"
	case "flux":
		return "Install with: curl -s https://fluxcd.io/install.sh | sudo bash"
	default:
		return fmt.Sprintf("Please install %s", command)
	}
}

// checkDockerAccess verifies Docker access for NAS
func (c *Checker) checkDockerAccess() CheckResult {
	if c.config.NAS == nil {
		return CheckResult{
			Name:        "docker-access",
			Description: "Docker access for NAS operations",
			Status:      CheckFailed,
			Error:       fmt.Errorf("NAS configuration not found"),
		}
	}

	// Check if docker command exists
	if _, err := exec.LookPath("docker"); err != nil {
		return CheckResult{
			Name:        "docker-access",
			Description: "Docker access for NAS operations",
			Status:      CheckFailed,
			Error:       fmt.Errorf("docker command not found"),
			Details:     "Install Docker Desktop or docker CLI",
		}
	}

	// Check if we can connect to NAS Docker host
	env := []string{
		fmt.Sprintf("DOCKER_HOST=%s", c.config.NAS.Cluster.DockerHost),
		fmt.Sprintf("DOCKER_CERT_PATH=%s", c.config.NAS.Cluster.CertPath),
		"DOCKER_TLS_VERIFY=1",
	}

	cmd := exec.Command("docker", "version")
	cmd.Env = append(os.Environ(), env...)

	if err := cmd.Run(); err != nil {
		return CheckResult{
			Name:        "docker-access",
			Description: "Docker access for NAS operations",
			Status:      CheckWarning,
			Error:       fmt.Errorf("cannot connect to NAS Docker: %w", err),
			Details:     fmt.Sprintf("Check Docker host: %s", c.config.NAS.Cluster.DockerHost),
		}
	}

	return CheckResult{
		Name:        "docker-access",
		Description: "Docker access for NAS operations",
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Connected to %s", c.config.NAS.Cluster.DockerHost),
	}
}

// checkGitHubToken verifies GitHub token for GitOps
func (c *Checker) checkGitHubToken() CheckResult {
	token := os.Getenv("GITHUB_TOKEN")
	if token == "" {
		return CheckResult{
			Name:        "github-token",
			Description: "GitHub token for GitOps operations",
			Status:      CheckFailed,
			Error:       fmt.Errorf("GITHUB_TOKEN environment variable not set"),
			Details:     "Set GITHUB_TOKEN environment variable with your GitHub personal access token",
		}
	}

	if len(token) < 20 {
		return CheckResult{
			Name:        "github-token",
			Description: "GitHub token for GitOps operations",
			Status:      CheckWarning,
			Error:       fmt.Errorf("GitHub token seems too short (got %d characters)", len(token)),
			Details:     "GitHub tokens are typically 40+ characters",
		}
	}

	return CheckResult{
		Name:        "github-token",
		Description: "GitHub token for GitOps operations",
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Token found (%d characters)", len(token)),
	}
}

// checkEnvFile verifies .env file exists and is readable
func (c *Checker) checkEnvFile() CheckResult {
	envPath := filepath.Join("../..", ".env")

	if _, err := os.Stat(envPath); os.IsNotExist(err) {
		return CheckResult{
			Name:        "env-file",
			Description: "Environment configuration file",
			Status:      CheckFailed,
			Error:       fmt.Errorf(".env file not found at %s", envPath),
			Details:     "Copy .env.example to .env and update with your values",
		}
	}

	// Try to read the file
	content, err := os.ReadFile(envPath)
	if err != nil {
		return CheckResult{
			Name:        "env-file",
			Description: "Environment configuration file",
			Status:      CheckFailed,
			Error:       fmt.Errorf("cannot read .env file: %w", err),
		}
	}

	// Count non-empty, non-comment lines
	lines := strings.Split(string(content), "\n")
	varCount := 0
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") && strings.Contains(line, "=") {
			varCount++
		}
	}

	return CheckResult{
		Name:        "env-file",
		Description: "Environment configuration file",
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Found .env with %d variables", varCount),
	}
}

// checkVaultConfig verifies Vault configuration
func (c *Checker) checkVaultConfig() CheckResult {
	var vaultAddr string

	if c.config.Homelab != nil && c.config.Homelab.Security.Vault.Enabled {
		vaultAddr = c.config.Homelab.Security.Vault.Address
	} else if c.config.NAS != nil && c.config.NAS.Security.Vault.Enabled {
		vaultAddr = c.config.NAS.Security.Vault.Address
	} else {
		return CheckResult{
			Name:        "vault-config",
			Description: "Vault configuration",
			Status:      CheckWarning,
			Details:     "Vault is not enabled in configuration",
		}
	}

	vaultToken := os.Getenv("VAULT_TOKEN")
	if vaultToken == "" {
		return CheckResult{
			Name:        "vault-config",
			Description: "Vault configuration",
			Status:      CheckWarning,
			Error:       fmt.Errorf("VAULT_TOKEN environment variable not set"),
			Details:     fmt.Sprintf("Vault address: %s", vaultAddr),
		}
	}

	return CheckResult{
		Name:        "vault-config",
		Description: "Vault configuration",
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Vault configured at %s", vaultAddr),
	}
}

// checkClusterConnectivity verifies cluster is accessible
func (c *Checker) checkClusterConnectivity(ctx context.Context) CheckResult {
	var kubeconfig string

	if c.config.Homelab != nil {
		kubeconfig = c.config.Homelab.Cluster.KubeConfig
	} else if c.config.NAS != nil {
		kubeconfig = c.config.NAS.Cluster.KubeConfig
	} else {
		return CheckResult{
			Name:        "cluster-connectivity",
			Description: "Kubernetes cluster connectivity",
			Status:      CheckFailed,
			Error:       fmt.Errorf("no cluster configuration found"),
		}
	}

	// Check if kubeconfig file exists
	if _, err := os.Stat(kubeconfig); os.IsNotExist(err) {
		return CheckResult{
			Name:        "cluster-connectivity",
			Description: "Kubernetes cluster connectivity",
			Status:      CheckWarning,
			Error:       fmt.Errorf("kubeconfig not found at %s", kubeconfig),
			Details:     "Cluster may not be created yet",
		}
	}

	// Try to connect to cluster
	client, err := k8s.NewClient(kubeconfig)
	if err != nil {
		return CheckResult{
			Name:        "cluster-connectivity",
			Description: "Kubernetes cluster connectivity",
			Status:      CheckWarning,
			Error:       fmt.Errorf("failed to create k8s client: %w", err),
			Details:     fmt.Sprintf("Kubeconfig: %s", kubeconfig),
		}
	}

	if err := client.IsReady(ctx); err != nil {
		return CheckResult{
			Name:        "cluster-connectivity",
			Description: "Kubernetes cluster connectivity",
			Status:      CheckWarning,
			Error:       fmt.Errorf("cluster not ready: %w", err),
			Details:     "Cluster may be starting up",
		}
	}

	// Get node count
	nodes, err := client.GetNodes(ctx)
	if err != nil {
		return CheckResult{
			Name:        "cluster-connectivity",
			Description: "Kubernetes cluster connectivity",
			Status:      CheckPassed,
			Details:     "Cluster accessible (node count unavailable)",
		}
	}

	return CheckResult{
		Name:        "cluster-connectivity",
		Description: "Kubernetes cluster connectivity",
		Status:      CheckPassed,
		Details:     fmt.Sprintf("Cluster accessible with %d nodes", len(nodes)),
	}
}
