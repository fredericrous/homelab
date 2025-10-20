package secrets

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// CrossClusterManager handles cross-cluster secret management for service mesh
type CrossClusterManager struct {
	homelabClient *k8s.Client
	nasClient     *k8s.Client
	projectRoot   string
}

// NewCrossClusterManager creates a new cross-cluster secrets manager
func NewCrossClusterManager(homelabClient *k8s.Client, projectRoot string) (*CrossClusterManager, error) {
	// Try to create NAS client using default kubeconfig path
	nasKubeconfigPath := filepath.Join(projectRoot, "infrastructure", "nas", "kubeconfig.yaml")

	// Check if NAS kubeconfig exists
	if _, err := os.Stat(nasKubeconfigPath); err != nil {
		log.Warn("NAS kubeconfig not found, cross-cluster secrets will be skipped", "path", nasKubeconfigPath)
		return &CrossClusterManager{
			homelabClient: homelabClient,
			nasClient:     nil,
			projectRoot:   projectRoot,
		}, nil
	}

	nasClient, err := k8s.NewClient(nasKubeconfigPath)
	if err != nil {
		log.Warn("Failed to create NAS client, cross-cluster secrets will be skipped", "error", err)
		return &CrossClusterManager{
			homelabClient: homelabClient,
			nasClient:     nil,
			projectRoot:   projectRoot,
		}, nil
	}

	return &CrossClusterManager{
		homelabClient: homelabClient,
		nasClient:     nasClient,
		projectRoot:   projectRoot,
	}, nil
}

// CreateIstioRemoteSecret creates Istio remote secret for cross-cluster service discovery
func (ccm *CrossClusterManager) CreateIstioRemoteSecret(ctx context.Context) error {
	if ccm.nasClient == nil {
		log.Info("NAS client not available, skipping Istio remote secret creation")
		return nil
	}

	log.Info("Creating Istio remote secret for NAS cluster")

	// Check if remote secret already exists
	if ccm.remoteSecretExists(ctx) {
		log.Info("Istio remote secret for NAS already exists")
		return nil
	}

	// Verify NAS cluster connectivity
	if err := ccm.nasClient.IsReady(ctx); err != nil {
		return fmt.Errorf("NAS cluster not accessible: %w", err)
	}

	// Create service account with limited permissions in NAS cluster
	if err := ccm.createIstioServiceAccount(ctx); err != nil {
		return fmt.Errorf("failed to create service account: %w", err)
	}

	// Generate remote secret using istioctl
	if err := ccm.generateAndApplyRemoteSecret(ctx); err != nil {
		return fmt.Errorf("failed to generate remote secret: %w", err)
	}

	log.Info("Istio remote secret created successfully")
	return nil
}

// remoteSecretExists checks if the Istio remote secret already exists
func (ccm *CrossClusterManager) remoteSecretExists(ctx context.Context) bool {
	clientset := ccm.homelabClient.GetClientset()
	_, err := clientset.CoreV1().Secrets("istio-system").Get(ctx, "istio-remote-secret-nas", metav1.GetOptions{})
	return err == nil
}

// createIstioServiceAccount creates a limited service account for Istio cross-cluster discovery
func (ccm *CrossClusterManager) createIstioServiceAccount(ctx context.Context) error {
	log.Info("Creating limited service account in NAS cluster")

	clientset := ccm.nasClient.GetClientset()

	// Create service account
	sa := &corev1.ServiceAccount{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "istio-reader-homelab",
			Namespace: "default",
		},
	}

	_, err := clientset.CoreV1().ServiceAccounts("default").Create(ctx, sa, metav1.CreateOptions{})
	if err != nil && !strings.Contains(err.Error(), "already exists") {
		return fmt.Errorf("failed to create service account: %w", err)
	}

	// Create minimal ClusterRole
	clusterRole := &rbacv1.ClusterRole{
		ObjectMeta: metav1.ObjectMeta{
			Name: "istio-reader-homelab",
		},
		Rules: []rbacv1.PolicyRule{
			{
				APIGroups: []string{""},
				Resources: []string{"nodes", "pods", "services", "endpoints"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"discovery.k8s.io"},
				Resources: []string{"endpointslices"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"networking.istio.io"},
				Resources: []string{"*"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{"security.istio.io"},
				Resources: []string{"*"},
				Verbs:     []string{"get", "list", "watch"},
			},
		},
	}

	_, err = clientset.RbacV1().ClusterRoles().Create(ctx, clusterRole, metav1.CreateOptions{})
	if err != nil && !strings.Contains(err.Error(), "already exists") {
		return fmt.Errorf("failed to create cluster role: %w", err)
	}

	// Create ClusterRoleBinding
	binding := &rbacv1.ClusterRoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name: "istio-reader-homelab",
		},
		Subjects: []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      "istio-reader-homelab",
				Namespace: "default",
			},
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io",
			Kind:     "ClusterRole",
			Name:     "istio-reader-homelab",
		},
	}

	_, err = clientset.RbacV1().ClusterRoleBindings().Create(ctx, binding, metav1.CreateOptions{})
	if err != nil && !strings.Contains(err.Error(), "already exists") {
		return fmt.Errorf("failed to create cluster role binding: %w", err)
	}

	return nil
}

// generateAndApplyRemoteSecret generates the remote secret using istioctl and applies it
func (ccm *CrossClusterManager) generateAndApplyRemoteSecret(ctx context.Context) error {
	// Check if istioctl is available
	if !ccm.isIstioCtlAvailable() {
		return fmt.Errorf("istioctl not found - required for remote secret generation")
	}

	// Generate remote secret
	nasKubeconfigPath := filepath.Join(ccm.projectRoot, "infrastructure", "nas", "kubeconfig.yaml")

	log.Info("Generating remote secret with istioctl")
	cmd := exec.CommandContext(ctx, "istioctl", "x", "create-remote-secret",
		"--name", "nas",
		"--service-account", "istio-reader-homelab",
		"--kubeconfig", nasKubeconfigPath)

	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to generate remote secret: %w", err)
	}

	// Apply the secret to homelab cluster
	return ccm.applyRemoteSecretManifest(ctx, string(output))
}

// applyRemoteSecretManifest applies the remote secret manifest to the homelab cluster
func (ccm *CrossClusterManager) applyRemoteSecretManifest(ctx context.Context, manifest string) error {
	// Ensure istio-system namespace exists
	if err := ccm.homelabClient.CreateNamespace(ctx, "istio-system"); err != nil {
		return fmt.Errorf("failed to create istio-system namespace: %w", err)
	}

	// Use kubectl to apply the manifest (simplest approach)
	cmd := exec.CommandContext(ctx, "kubectl", "apply", "-f", "-")
	cmd.Stdin = strings.NewReader(manifest)
	cmd.Env = append(os.Environ(), fmt.Sprintf("KUBECONFIG=%s", ccm.getHomelabKubeconfig()))

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("failed to apply remote secret manifest: %w", err)
	}

	// Validate the secret was created and test connectivity
	return ccm.validateRemoteSecret(ctx)
}

// validateRemoteSecret validates that the remote secret can access the NAS cluster
func (ccm *CrossClusterManager) validateRemoteSecret(ctx context.Context) error {
	log.Info("Validating remote secret connectivity")

	// Wait for secret to be available
	for i := 0; i < 10; i++ {
		if ccm.remoteSecretExists(ctx) {
			break
		}
		log.Debug("Waiting for remote secret to be created", "attempt", i+1)
		time.Sleep(1 * time.Second)
	}

	if !ccm.remoteSecretExists(ctx) {
		return fmt.Errorf("remote secret was not created successfully")
	}

	// Extract kubeconfig from secret and test connectivity
	clientset := ccm.homelabClient.GetClientset()
	secret, err := clientset.CoreV1().Secrets("istio-system").Get(ctx, "istio-remote-secret-nas", metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("failed to get remote secret: %w", err)
	}

	kubeconfigData, exists := secret.Data["nas"]
	if !exists {
		return fmt.Errorf("remote secret missing kubeconfig data")
	}

	// Test connectivity using the extracted kubeconfig
	return ccm.testRemoteConnectivity(ctx, kubeconfigData)
}

// testRemoteConnectivity tests if the remote secret can access the NAS cluster
func (ccm *CrossClusterManager) testRemoteConnectivity(ctx context.Context, kubeconfigData []byte) error {
	// Create temporary kubeconfig file
	tmpFile, err := os.CreateTemp("", "remote-kubeconfig-*.yaml")
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.Write(kubeconfigData); err != nil {
		return fmt.Errorf("failed to write kubeconfig: %w", err)
	}
	tmpFile.Close()

	// Test connectivity with timeout
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "kubectl", "--kubeconfig", tmpFile.Name(), "get", "nodes")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("remote secret cannot access NAS cluster: %w", err)
	}

	log.Info("Remote secret connectivity validated successfully")
	return nil
}

// isIstioCtlAvailable checks if istioctl command is available
func (ccm *CrossClusterManager) isIstioCtlAvailable() bool {
	_, err := exec.LookPath("istioctl")
	return err == nil
}

// getHomelabKubeconfig returns the homelab kubeconfig path
func (ccm *CrossClusterManager) getHomelabKubeconfig() string {
	// This should match the kubeconfig used by the homelab client
	// For now, use KUBECONFIG environment variable or default
	if kubeconfig := os.Getenv("KUBECONFIG"); kubeconfig != "" {
		return kubeconfig
	}
	return filepath.Join(os.Getenv("HOME"), ".kube", "config")
}
