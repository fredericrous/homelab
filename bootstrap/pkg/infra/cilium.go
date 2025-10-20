package infra

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	corev1 "k8s.io/api/core/v1"
)

// CiliumInstaller handles Cilium CNI installation using Helm (matching original bash script)
type CiliumInstaller struct {
	client *k8s.Client
}

// NewCiliumInstaller creates a new Cilium installer
func NewCiliumInstaller(client *k8s.Client) *CiliumInstaller {
	return &CiliumInstaller{
		client: client,
	}
}

// CiliumConfig represents Cilium installation configuration
type CiliumConfig struct {
	ControlPlaneIP string
	ClusterPodCIDR string
	NodeEncryption bool
	Hubble         bool
	LoadBalancer   bool
}

// Install installs Cilium CNI using Helm (matching original bash script)
func (c *CiliumInstaller) Install(ctx context.Context, config CiliumConfig) error {
	log.Info("Installing Cilium CNI using Helm")

	// Check if Helm is available
	if !c.isHelmAvailable() {
		return fmt.Errorf("helm CLI not found - install with: brew install helm")
	}

	// Get control plane IP if not provided
	if config.ControlPlaneIP == "" {
		ip, err := c.getControlPlaneIP(ctx)
		if err != nil {
			log.Warn("Could not detect control plane IP", "error", err)
			return fmt.Errorf("control plane IP required: %w", err)
		} else {
			config.ControlPlaneIP = ip
			log.Info("Using detected control plane IP", "ip", ip)
		}
	}

	// Set default ClusterPodCIDR if not provided
	if config.ClusterPodCIDR == "" {
		config.ClusterPodCIDR = "10.244.0.0/16"
		log.Info("Using default cluster pod CIDR", "cidr", config.ClusterPodCIDR)
	}

	// Check if Cilium is already installed
	if c.isCiliumInstalled(ctx) {
		log.Info("Cilium is already installed")
		return c.waitForCilium(ctx)
	}

	// Add Cilium Helm repository
	if err := c.addCiliumHelmRepo(ctx); err != nil {
		return fmt.Errorf("failed to add Cilium Helm repo: %w", err)
	}

	// Install Cilium using Helm
	if err := c.installCiliumWithHelm(ctx, config); err != nil {
		return fmt.Errorf("failed to install Cilium with Helm: %w", err)
	}

	// Wait for Cilium to be ready
	if err := c.waitForCilium(ctx); err != nil {
		return fmt.Errorf("Cilium not ready: %w", err)
	}

	// Validate installation
	if err := c.validateCiliumWithKubectl(ctx); err != nil {
		log.Warn("Cilium validation completed with warnings", "error", err)
		// Don't fail on validation warnings
	}

	log.Info("Cilium CNI installed and validated successfully")
	return nil
}

// isHelmAvailable checks if helm CLI is available
func (c *CiliumInstaller) isHelmAvailable() bool {
	_, err := exec.LookPath("helm")
	return err == nil
}

// isCiliumInstalled checks if Cilium is already installed
func (c *CiliumInstaller) isCiliumInstalled(ctx context.Context) bool {
	// Check if cilium-operator deployment exists
	clientset := c.client.GetClientset()
	_, err := clientset.AppsV1().Deployments("kube-system").Get(ctx, "cilium-operator", metav1.GetOptions{})
	return err == nil
}

// getControlPlaneIP attempts to detect the control plane IP
func (c *CiliumInstaller) getControlPlaneIP(ctx context.Context) (string, error) {
	// Get nodes and look for control plane
	nodes, err := c.client.GetClientset().CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return "", err
	}

	for _, node := range nodes.Items {
		// Check if node is control plane
		if _, exists := node.Labels["node-role.kubernetes.io/control-plane"]; exists {
			// Get internal IP
			for _, addr := range node.Status.Addresses {
				if addr.Type == "InternalIP" {
					return addr.Address, nil
				}
			}
		}
	}

	return "", fmt.Errorf("could not detect control plane IP")
}

// addCiliumHelmRepo adds the Cilium Helm repository
func (c *CiliumInstaller) addCiliumHelmRepo(ctx context.Context) error {
	log.Info("Adding Cilium Helm repository")

	// Add repo
	addCmd := exec.CommandContext(ctx, "helm", "repo", "add", "cilium", "https://helm.cilium.io")
	if output, err := addCmd.CombinedOutput(); err != nil {
		// Ignore error if repo already exists
		if !strings.Contains(string(output), "already exists") {
			log.Error("Failed to add Cilium Helm repo", "error", err, "output", string(output))
			return fmt.Errorf("failed to add helm repo: %w", err)
		}
		log.Info("Cilium Helm repo already exists")
	}

	// Update repo
	updateCmd := exec.CommandContext(ctx, "helm", "repo", "update")
	if output, err := updateCmd.CombinedOutput(); err != nil {
		log.Error("Failed to update Helm repos", "error", err, "output", string(output))
		return fmt.Errorf("failed to update helm repos: %w", err)
	}

	log.Info("Cilium Helm repository added and updated")
	return nil
}

// installCiliumWithHelm installs Cilium using Helm with configuration matching the original bash script
func (c *CiliumInstaller) installCiliumWithHelm(ctx context.Context, config CiliumConfig) error {
	log.Info("Installing Cilium with Helm configuration")

	// Create temporary values file (matching original bash script)
	valuesFile, err := c.createCiliumValuesFile(config)
	if err != nil {
		return fmt.Errorf("failed to create values file: %w", err)
	}
	defer os.Remove(valuesFile)

	// Install Cilium with Helm
	args := []string{
		"install", "cilium", "cilium/cilium",
		"--version", "1.18.1",
		"--namespace", "kube-system",
		"--values", valuesFile,
	}

	cmd := exec.CommandContext(ctx, "helm", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		log.Error("Cilium Helm installation failed", "error", err, "output", string(output))
		return fmt.Errorf("helm install failed: %w", err)
	}

	log.Info("Cilium Helm installation command completed")
	return nil
}

// createCiliumValuesFile creates a values file matching the original bash script configuration
func (c *CiliumInstaller) createCiliumValuesFile(config CiliumConfig) (string, error) {
	valuesContent := fmt.Sprintf(`# Cilium bootstrap configuration for homelab (matching original bash script)
routingMode: "native"
ipv4NativeRoutingCIDR: "%s"
autoDirectNodeRoutes: true
endpointRoutes:
  enabled: true

kubeProxyReplacement: true
k8sServiceHost: "%s"
k8sServicePort: 6443

bandwidthManager:
  enabled: true
  bbr: true

bpf:
  masquerade: true
  tproxy: true
  hostRouting: false

ipam:
  mode: "kubernetes"
  operator:
    clusterPoolIPv4PodCIDRList: ["%s"]
    clusterPoolIPv4MaskSize: 24

dnsProxy:
  enabled: true
  enableTransparentMode: true
  minTTL: 3600
  maxTTL: 86400

mtu: 1450

hubble:
  enabled: %t
  relay:
    enabled: %t
  ui:
    enabled: %t
  metrics:
    enabled:
      - dns:query
      - drop
      - tcp
      - flow
      - icmp
      - http

operator:
  replicas: 1
  prometheus:
    enabled: true

healthChecking: true
healthPort: 9879

sysctlfix:
  enabled: false

securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE

prometheus:
  enabled: true
  serviceMonitor:
    enabled: false

socketLB:
  hostNamespaceOnly: true

cni:
  exclusive: false
`, config.ClusterPodCIDR, config.ControlPlaneIP, config.ClusterPodCIDR, config.Hubble, config.Hubble, config.Hubble)

	// Create temporary file
	tmpFile, err := os.CreateTemp("", "cilium-bootstrap-values-*.yaml")
	if err != nil {
		return "", fmt.Errorf("failed to create temp file: %w", err)
	}

	if _, err := tmpFile.WriteString(valuesContent); err != nil {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("failed to write values file: %w", err)
	}

	if err := tmpFile.Close(); err != nil {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("failed to close values file: %w", err)
	}

	log.Info("Created Cilium values file", "path", tmpFile.Name())
	return tmpFile.Name(), nil
}

// waitForCilium waits for Cilium to be ready (matching original bash script logic)
func (c *CiliumInstaller) waitForCilium(ctx context.Context) error {
	log.Info("Waiting for Cilium to be ready")

	// Give Cilium a moment to initialize
	time.Sleep(5 * time.Second)

	// Wait for cilium-operator deployment
	if err := c.client.WaitForDeployment(ctx, "kube-system", "cilium-operator", 5*time.Minute); err != nil {
		return fmt.Errorf("cilium-operator not ready: %w", err)
	}

	// Wait for cilium daemonset
	if err := c.client.WaitForDaemonSet(ctx, "kube-system", "cilium", 5*time.Minute); err != nil {
		return fmt.Errorf("cilium daemonset not ready: %w", err)
	}

	log.Info("Cilium components are ready")
	return nil
}

// validateCiliumWithKubectl validates the Cilium installation using kubectl (no CLI dependency)
func (c *CiliumInstaller) validateCiliumWithKubectl(ctx context.Context) error {
	log.Info("Validating Cilium installation")

	// Get cilium pods using clientset directly
	clientset := c.client.GetClientset()
	podList, err := clientset.CoreV1().Pods("kube-system").List(ctx, metav1.ListOptions{
		LabelSelector: "k8s-app=cilium",
	})
	if err != nil {
		return fmt.Errorf("failed to get cilium pods: %w", err)
	}

	if len(podList.Items) == 0 {
		return fmt.Errorf("no cilium pods found")
	}

	readyCount := 0
	for _, pod := range podList.Items {
		for _, condition := range pod.Status.Conditions {
			if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
				readyCount++
				break
			}
		}
	}

	log.Info("Cilium pod status", "ready", readyCount, "total", len(podList.Items))

	if readyCount == 0 {
		return fmt.Errorf("no cilium pods are ready")
	}

	// Get nodes to validate coverage
	nodes, err := c.client.GetNodes(ctx)
	if err == nil && len(nodes) > 0 {
		log.Info("Cluster validation", "nodes", len(nodes), "cilium_pods", len(podList.Items))
		if len(podList.Items) < len(nodes) {
			log.Warn("Cilium pod count less than node count", "pods", len(podList.Items), "nodes", len(nodes))
		}
	}

	log.Info("Cilium validation completed successfully")
	return nil
}

// GetStatus returns the current Cilium status
func (c *CiliumInstaller) GetStatus(ctx context.Context) (*CiliumStatus, error) {
	status := &CiliumStatus{}

	// Check if installed
	status.Installed = c.isCiliumInstalled(ctx)
	if !status.Installed {
		return status, nil
	}

	// Check operator status
	err := c.client.WaitForDeployment(ctx, "kube-system", "cilium-operator", 10*time.Second)
	status.OperatorReady = err == nil

	// Check daemonset status
	err = c.client.WaitForDaemonSet(ctx, "kube-system", "cilium", 10*time.Second)
	status.DaemonSetReady = err == nil

	// Get pod count
	pods, err := c.client.GetPods(ctx, "kube-system", "k8s-app=cilium")
	if err == nil {
		status.PodCount = len(pods)
	}

	// Overall ready status
	status.Ready = status.Installed && status.OperatorReady && status.DaemonSetReady && status.PodCount > 0

	return status, nil
}

// CiliumStatus represents the status of Cilium
type CiliumStatus struct {
	Installed      bool
	Ready          bool
	OperatorReady  bool
	DaemonSetReady bool
	PodCount       int
}