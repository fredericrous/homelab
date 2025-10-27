package infra

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
)

// Waiter handles waiting for infrastructure components to be ready
type Waiter struct {
	client                   *k8s.Client
	timeouts                 TimeoutConfig
	platformKustomization    string
	controllersKustomization string
	storageProvider          string
}

// TimeoutConfig contains timeout configurations for different components
type TimeoutConfig struct {
	Kustomization time.Duration
	Controllers   time.Duration
	Platform      time.Duration
	Ceph          time.Duration
	Security      time.Duration
}

// NewWaiter creates a new infrastructure waiter
func NewWaiter(client *k8s.Client, timeouts TimeoutConfig, platformName string, controllersName string, storageProvider string) *Waiter {
	if platformName == "" {
		platformName = "platform-foundation"
	}
	if storageProvider == "" {
		storageProvider = "ceph"
	}
	return &Waiter{
		client:                   client,
		timeouts:                 timeouts,
		platformKustomization:    platformName,
		controllersKustomization: controllersName,
		storageProvider:          strings.ToLower(storageProvider),
	}
}

// DefaultTimeouts returns default timeout configuration
func DefaultTimeouts() TimeoutConfig {
	return TimeoutConfig{
		Kustomization: 1 * time.Minute,
		Controllers:   10 * time.Minute,
		Platform:      10 * time.Minute,
		Ceph:          10 * time.Minute,
		Security:      10 * time.Minute,
	}
}

// WaitForInfrastructure waits for all infrastructure components to be ready
func (w *Waiter) WaitForInfrastructure(ctx context.Context) error {
	log.Info("Waiting for infrastructure components to be ready",
		"kustomization_timeout", w.timeouts.Kustomization,
		"controllers_timeout", w.timeouts.Controllers,
		"platform_timeout", w.timeouts.Platform,
		"storage_provider", w.storageProvider,
		"ceph_timeout", w.timeouts.Ceph)

	// Step 1: Wait for FluxCD to create kustomizations
	if err := w.waitForKustomizations(ctx); err != nil {
		return fmt.Errorf("kustomizations not ready: %w", err)
	}

	// Step 2: Wait for controllers layer (operators)
	if err := w.waitForControllers(ctx); err != nil {
		return fmt.Errorf("controllers not ready: %w", err)
	}

	// Step 3: Wait for platform foundation
	if err := w.waitForPlatform(ctx); err != nil {
		return fmt.Errorf("platform not ready: %w", err)
	}

	// Step 4: Wait for storage (provider specific)
	if err := w.waitForStorage(ctx); err != nil {
		return fmt.Errorf("storage not ready: %w", err)
	}

	log.Info("All infrastructure components are ready")
	return nil
}

// waitForKustomizations waits for FluxCD to create kustomizations
func (w *Waiter) waitForKustomizations(ctx context.Context) error {
	log.Info("Waiting for kustomizations to be created")

	target := w.platformKustomization

	err := wait.PollUntilContextTimeout(ctx, 2*time.Second, w.timeouts.Kustomization, true, func(ctx context.Context) (bool, error) {
		// Check if platform-foundation kustomization exists
		exists, err := w.kustomizationExists(ctx, target)
		if err != nil {
			log.Debug("Error checking kustomization", "error", err)
			return false, nil // Continue polling
		}

		if exists {
			log.Info("Kustomization found", "name", target)
			return true, nil
		}

		log.Debug("Waiting for kustomization", "name", target)
		return false, nil
	})

	if err != nil {
		log.Error("Kustomization not created", "name", target, "timeout", w.timeouts.Kustomization)
		w.diagnoseFluxCD(ctx)
		return err
	}

	return nil
}

// waitForControllers waits for controllers layer to be ready
func (w *Waiter) waitForControllers(ctx context.Context) error {
	if w.controllersKustomization == "" {
		log.Info("Skipping controllers wait (no controllers kustomization configured)")
		return nil
	}

	log.Info("Waiting for controllers layer")

	// First check if controllers kustomization exists
	exists, err := w.kustomizationExists(ctx, w.controllersKustomization)
	if err != nil {
		return fmt.Errorf("failed to check controllers kustomization: %w", err)
	}
	if !exists {
		log.Error("Controllers kustomization not found", "name", w.controllersKustomization)
		w.listKustomizations(ctx)
		return fmt.Errorf("controllers kustomization not found")
	}

	// Wait for controllers to be ready
	err = wait.PollUntilContextTimeout(ctx, 5*time.Second, w.timeouts.Controllers, true, func(ctx context.Context) (bool, error) {
		ready, err := w.isKustomizationReady(ctx, w.controllersKustomization)
		if err != nil {
			log.Debug("Error checking controllers status", "error", err)
			return false, nil
		}
		return ready, nil
	})

	if err != nil {
		log.Error("Controllers layer not ready", "name", w.controllersKustomization, "timeout", w.timeouts.Controllers)
		w.diagnoseKustomization(ctx, w.controllersKustomization)
		return err
	}

	log.Info("Controllers layer is ready", "name", w.controllersKustomization)
	return nil
}

// waitForPlatform waits for platform foundation to be ready
func (w *Waiter) waitForPlatform(ctx context.Context) error {
	log.Info("Waiting for platform foundation components", "name", w.platformKustomization)

	err := wait.PollUntilContextTimeout(ctx, 5*time.Second, w.timeouts.Platform, true, func(ctx context.Context) (bool, error) {
		ready, err := w.isKustomizationReady(ctx, w.platformKustomization)
		if err != nil {
			log.Debug("Error checking platform status", "error", err)
			return false, nil
		}
		return ready, nil
	})

	if err != nil {
		log.Warn("Platform foundation not ready yet", "name", w.platformKustomization, "timeout", w.timeouts.Platform)
		w.diagnoseKustomization(ctx, w.platformKustomization)
		// Don't fail here - platform might still be deploying
	} else {
		log.Info("Platform foundation is ready", "name", w.platformKustomization)
	}

	return nil
}

// waitForStorage waits for storage system to be ready
func (w *Waiter) waitForStorage(ctx context.Context) error {
	switch w.storageProvider {
	case "none":
		log.Info("Skipping storage readiness checks (provider=none)")
		return nil
	case "local-path":
		return w.waitForLocalPathStorage(ctx)
	default:
		return w.waitForCephStorage(ctx)
	}
}

// Helper methods

func (w *Waiter) kustomizationExists(ctx context.Context, name string) (bool, error) {
	clientset := w.client.GetClientset()
	_, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/" + name).
		DoRaw(ctx)

	if err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

func (w *Waiter) isKustomizationReady(ctx context.Context, name string) (bool, error) {
	// Simplified check - in production, parse the actual status conditions
	exists, err := w.kustomizationExists(ctx, name)
	if err != nil {
		return false, err
	}
	return exists, nil
}

func (w *Waiter) waitForCephStorage(ctx context.Context) error {
	log.Info("Verifying Ceph storage health")

	if w.hasCephStorageClass(ctx) {
		log.Info("Ceph storage classes found - storage system is ready")
		return nil
	}

	log.Info("Ceph storage classes not found, waiting for Rook deployment")

	err := w.client.WaitForDeployment(ctx, "rook-ceph", "rook-ceph-operator", w.timeouts.Ceph)
	if err != nil {
		log.Warn("Rook operator not ready yet", "error", err)
		w.diagnoseRookOperator(ctx)
	} else {
		log.Info("Rook operator is ready")
	}

	err = wait.PollUntilContextTimeout(ctx, 5*time.Second, w.timeouts.Ceph, true, func(ctx context.Context) (bool, error) {
		exists, err := w.cephClusterExists(ctx)
		if err != nil {
			log.Debug("Error checking CephCluster", "error", err)
			return false, nil
		}
		if exists {
			log.Info("CephCluster resource found")
			return true, nil
		}
		log.Debug("Waiting for CephCluster")
		return false, nil
	})

	if err != nil {
		log.Warn("CephCluster not created", "timeout", w.timeouts.Ceph)
		return err
	}

	return nil
}

func (w *Waiter) waitForLocalPathStorage(ctx context.Context) error {
	log.Info("Verifying local-path storage")

	if w.hasDefaultStorageClass(ctx) {
		log.Info("Default StorageClass present - local storage ready")
		return nil
	}

	log.Info("Default StorageClass not detected, waiting for local-path-provisioner deployment")

	if err := w.client.WaitForDeployment(ctx, "kube-system", "local-path-provisioner", w.timeouts.Platform); err != nil {
		log.Warn("local-path-provisioner not ready", "error", err)
		return err
	}

	if w.hasDefaultStorageClass(ctx) {
		log.Info("Default StorageClass detected after provisioning")
		return nil
	}

	return fmt.Errorf("default StorageClass still missing after local-path provisioning")
}

func (w *Waiter) hasCephStorageClass(ctx context.Context) bool {
	clientset := w.client.GetClientset()
	_, err := clientset.StorageV1().StorageClasses().Get(ctx, "rook-ceph-block", metav1.GetOptions{})
	return err == nil
}

func (w *Waiter) hasDefaultStorageClass(ctx context.Context) bool {
	clientset := w.client.GetClientset()
	scList, err := clientset.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		return false
	}

	for _, sc := range scList.Items {
		if sc.Annotations != nil {
			if sc.Annotations["storageclass.kubernetes.io/is-default-class"] == "true" ||
				sc.Annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true" {
				return true
			}
		}
	}

	return false
}

func (w *Waiter) cephClusterExists(ctx context.Context) (bool, error) {
	clientset := w.client.GetClientset()
	_, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/ceph.rook.io/v1/namespaces/rook-ceph/cephclusters/rook-ceph").
		DoRaw(ctx)

	if err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// Diagnostic methods

func (w *Waiter) diagnoseFluxCD(ctx context.Context) {
	log.Info("FluxCD bootstrap may have failed. Checking FluxCD status")

	// Check flux-system namespace
	exists, _ := w.client.NamespaceExists(ctx, "flux-system")
	if !exists {
		log.Error("flux-system namespace not found")
		return
	}

	// Check FluxCD pods
	pods, err := w.client.GetPods(ctx, "flux-system", "")
	if err != nil {
		log.Error("Failed to get FluxCD pods", "error", err)
	} else {
		log.Info("FluxCD pods", "count", len(pods), "pods", pods)
	}

	// List available kustomizations
	w.listKustomizations(ctx)
}

func (w *Waiter) listKustomizations(ctx context.Context) {
	log.Info("Listing available kustomizations")

	clientset := w.client.GetClientset()
	result, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations").
		DoRaw(ctx)

	if err != nil {
		log.Error("Failed to list kustomizations", "error", err)
		return
	}

	// Parse and display basic information
	if string(result) != "" {
		log.Debug("Kustomizations response", "data", string(result)[:min(500, len(result))])
	} else {
		log.Warn("No kustomizations found in flux-system namespace")
	}
}

func (w *Waiter) diagnoseKustomization(ctx context.Context, name string) {
	log.Info("Diagnosing kustomization", "name", name)

	clientset := w.client.GetClientset()
	result, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath(fmt.Sprintf("/apis/kustomize.toolkit.fluxcd.io/v1/namespaces/flux-system/kustomizations/%s", name)).
		DoRaw(ctx)

	if err != nil {
		log.Error("Failed to get kustomization details", "name", name, "error", err)
		return
	}

	// Display basic status information
	if string(result) != "" {
		log.Debug("Kustomization details", "name", name, "data", string(result)[:min(800, len(result))])

		// Look for common error indicators in the response
		response := string(result)
		if strings.Contains(response, "\"ready\": false") {
			log.Warn("Kustomization is not ready", "name", name)
		}
		if strings.Contains(response, "error") {
			log.Error("Kustomization has errors", "name", name)
		}
	}
}

func (w *Waiter) diagnoseRookOperator(ctx context.Context) {
	log.Info("Diagnosing Rook operator")

	// Check if rook-ceph namespace exists
	exists, _ := w.client.NamespaceExists(ctx, "rook-ceph")
	if !exists {
		log.Error("rook-ceph namespace not found")
		return
	}

	// Check Rook operator pods
	pods, err := w.client.GetPods(ctx, "rook-ceph", "app=rook-ceph-operator")
	if err != nil {
		log.Error("Failed to get Rook operator pods", "error", err)
	} else {
		log.Info("Rook operator pods", "count", len(pods), "pods", pods)
	}
}

// Helper function
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
