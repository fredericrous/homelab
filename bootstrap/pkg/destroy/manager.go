package destroy

import (
	"context"
	"fmt"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Manager coordinates the complete cluster destruction process
type Manager struct {
	cfg           *config.Config
	isNAS         bool
	client        *k8s.Client
	fluxDestroyer *FluxDestroyer
	nsCleanup     *NamespaceCleanup
}

// NewManager creates a new destroy manager
func NewManager(cfg *config.Config, isNAS bool) (*Manager, error) {
	var kubeconfig string
	if isNAS {
		if cfg.NAS == nil {
			return nil, fmt.Errorf("NAS configuration not found")
		}
		kubeconfig = cfg.NAS.Cluster.KubeConfig
	} else {
		if cfg.Homelab == nil {
			return nil, fmt.Errorf("homelab configuration not found")
		}
		kubeconfig = cfg.Homelab.Cluster.KubeConfig
	}

	// Connect to cluster
	client, err := k8s.NewClient(kubeconfig)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to cluster: %w", err)
	}

	// Create destroyers
	fluxDestroyer := NewFluxDestroyer(client.GetClientset(), client.GetDynamicClient())
	nsCleanup := NewNamespaceCleanup(client.GetClientset(), client.GetDynamicClient())

	return &Manager{
		cfg:           cfg,
		isNAS:         isNAS,
		client:        client,
		fluxDestroyer: fluxDestroyer,
		nsCleanup:     nsCleanup,
	}, nil
}

// DestroyCluster performs complete cluster destruction
func (m *Manager) DestroyCluster(ctx context.Context) error {
	clusterType := "homelab"
	if m.isNAS {
		clusterType = "NAS"
	}

	log.Info("🗑️ Starting cluster destruction", "type", clusterType)

	// Step 1: Destroy FluxCD and all deployed resources
	log.Info("Step 1: Destroying FluxCD and deployed resources")
	if err := m.fluxDestroyer.Destroy(ctx, "flux-system"); err != nil {
		log.Error("Failed to destroy FluxCD", "error", err)
		return fmt.Errorf("FluxCD destruction failed: %w", err)
	}

	// Step 2: Force cleanup any remaining terminating namespaces
	log.Info("Step 2: Force cleaning up terminating namespaces")
	if err := m.nsCleanup.ForceCleanupTerminatingNamespaces(ctx); err != nil {
		log.Error("Failed to cleanup terminating namespaces", "error", err)
		return fmt.Errorf("namespace cleanup failed: %w", err)
	}

	// Step 3: Verify destruction
	log.Info("Step 3: Verifying destruction")
	if err := m.verifyDestruction(ctx); err != nil {
		log.Warn("Verification found remaining resources", "error", err)
		// Don't fail, just warn
	}

	log.Info("✅ Cluster destruction completed successfully", "type", clusterType)
	log.Info("ℹ️ Run 'bootstrap deploy' to reinstall")

	return nil
}

// ForceCleanupNamespaces only cleans up stuck namespaces (for standalone use)
func (m *Manager) ForceCleanupNamespaces(ctx context.Context) error {
	log.Info("🔧 Starting namespace force cleanup")

	if err := m.nsCleanup.ForceCleanupTerminatingNamespaces(ctx); err != nil {
		return fmt.Errorf("namespace cleanup failed: %w", err)
	}

	log.Info("✅ Namespace cleanup completed")
	return nil
}

func (m *Manager) verifyDestruction(ctx context.Context) error {
	log.Info("Verifying cluster destruction...")

	// Check for remaining flux resources
	namespaces, err := m.client.GetClientset().CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list namespaces: %w", err)
	}

	remainingFluxResources := 0
	problemNamespaces := []string{}

	for _, ns := range namespaces.Items {
		if ns.Status.Phase == "Terminating" {
			problemNamespaces = append(problemNamespaces, ns.Name)
		}

		// Check for flux-related resources in any namespace
		if ns.Name == "flux-system" && ns.Status.Phase != "Terminating" {
			// flux-system still exists
			problemNamespaces = append(problemNamespaces, "flux-system (still exists)")
		}
	}

	// Check for remaining flux-related resources across all namespaces
	// This is a simplified check - in reality we'd inspect all resources
	pods, err := m.client.GetClientset().CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err == nil {
		for _, pod := range pods.Items {
			if contains([]string{"flux-system", "rook-ceph", "metallb-system"}, pod.Namespace) {
				remainingFluxResources++
			}
		}
	}

	if len(problemNamespaces) > 0 {
		log.Warn("Found problematic namespaces", "namespaces", problemNamespaces)
	}

	if remainingFluxResources > 0 {
		log.Warn("Found remaining flux-related resources", "count", remainingFluxResources)
	}

	if len(problemNamespaces) == 0 && remainingFluxResources == 0 {
		log.Info("✅ All resources successfully removed")
	}

	return nil
}
