package recovery

import (
	"context"
	"fmt"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// DiagnosticResult represents the result of a diagnostic check
type DiagnosticResult struct {
	Component   string
	Status      string // "healthy", "warning", "error"
	Message     string
	Recoverable bool
}

// DiagnosticManager performs system diagnostics for recovery
type DiagnosticManager struct {
	cfg           *config.Config
	isNAS         bool
	homelabClient *k8s.Client
	nasClient     *k8s.Client
}

// NewDiagnosticManager creates a new diagnostic manager
func NewDiagnosticManager(cfg *config.Config, isNAS bool) (*DiagnosticManager, error) {
	dm := &DiagnosticManager{
		cfg:   cfg,
		isNAS: isNAS,
	}

	// Connect to homelab cluster if configuration exists
	if cfg.Homelab != nil {
		client, err := k8s.NewClient(cfg.Homelab.Cluster.KubeConfig)
		if err != nil {
			log.Warn("Failed to connect to homelab cluster", "error", err)
		} else {
			dm.homelabClient = client
		}
	}

	// Connect to NAS cluster if configuration exists
	if cfg.NAS != nil {
		client, err := k8s.NewClient(cfg.NAS.Cluster.KubeConfig)
		if err != nil {
			log.Warn("Failed to connect to NAS cluster", "error", err)
		} else {
			dm.nasClient = client
		}
	}

	return dm, nil
}

// DiagnoseSystem performs comprehensive system diagnostics
func (dm *DiagnosticManager) DiagnoseSystem(ctx context.Context) ([]*DiagnosticResult, error) {
	log.Info("🔍 Diagnosing current system state...")

	var results []*DiagnosticResult

	// Diagnose homelab cluster
	if dm.homelabClient != nil {
		homelabResults, err := dm.diagnoseCluster(ctx, dm.homelabClient, "homelab")
		if err != nil {
			log.Warn("Failed to diagnose homelab cluster", "error", err)
		} else {
			results = append(results, homelabResults...)
		}
	} else {
		results = append(results, &DiagnosticResult{
			Component:   "homelab-connectivity",
			Status:      "error",
			Message:     "Cannot connect to homelab cluster",
			Recoverable: true,
		})
	}

	// Diagnose NAS cluster
	if dm.nasClient != nil {
		nasResults, err := dm.diagnoseCluster(ctx, dm.nasClient, "nas")
		if err != nil {
			log.Warn("Failed to diagnose NAS cluster", "error", err)
		} else {
			results = append(results, nasResults...)
		}
	} else {
		results = append(results, &DiagnosticResult{
			Component:   "nas-connectivity",
			Status:      "warning",
			Message:     "Cannot connect to NAS cluster",
			Recoverable: true,
		})
	}

	return results, nil
}

func (dm *DiagnosticManager) diagnoseCluster(ctx context.Context, client *k8s.Client, clusterType string) ([]*DiagnosticResult, error) {
	var results []*DiagnosticResult

	// Check cluster accessibility
	if err := client.IsReady(ctx); err != nil {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-api-server", clusterType),
			Status:      "error",
			Message:     fmt.Sprintf("API server not accessible: %v", err),
			Recoverable: false,
		})
		return results, nil
	}

	results = append(results, &DiagnosticResult{
		Component:   fmt.Sprintf("%s-api-server", clusterType),
		Status:      "healthy",
		Message:     "API server is accessible",
		Recoverable: true,
	})

	// Check nodes
	nodes, err := client.GetNodes(ctx)
	if err != nil {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-nodes", clusterType),
			Status:      "error",
			Message:     fmt.Sprintf("Failed to get nodes: %v", err),
			Recoverable: true,
		})
	} else {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-nodes", clusterType),
			Status:      "healthy",
			Message:     fmt.Sprintf("Found %d nodes: %v", len(nodes), nodes),
			Recoverable: true,
		})
	}

	// Check FluxCD
	fluxResults := dm.diagnoseFluxCD(ctx, client, clusterType)
	results = append(results, fluxResults...)

	// Check Istio (homelab only)
	if clusterType == "homelab" {
		istioResults := dm.diagnoseIstio(ctx, client, clusterType)
		results = append(results, istioResults...)
	}

	return results, nil
}

func (dm *DiagnosticManager) diagnoseFluxCD(ctx context.Context, client *k8s.Client, clusterType string) []*DiagnosticResult {
	var results []*DiagnosticResult

	// Check flux-system namespace
	exists, err := client.NamespaceExists(ctx, "flux-system")
	if err != nil {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-flux-namespace", clusterType),
			Status:      "error",
			Message:     fmt.Sprintf("Failed to check flux-system namespace: %v", err),
			Recoverable: true,
		})
		return results
	}

	if !exists {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-flux-namespace", clusterType),
			Status:      "error",
			Message:     "FluxCD namespace does not exist",
			Recoverable: true,
		})
		return results
	}

	results = append(results, &DiagnosticResult{
		Component:   fmt.Sprintf("%s-flux-namespace", clusterType),
		Status:      "healthy",
		Message:     "FluxCD namespace exists",
		Recoverable: true,
	})

	// Check FluxCD controllers
	controllers := []string{"source-controller", "kustomize-controller", "helm-controller"}
	readyControllers := 0

	for _, controller := range controllers {
		deployment, err := client.GetClientset().AppsV1().Deployments("flux-system").Get(ctx, controller, metav1.GetOptions{})
		if err != nil {
			results = append(results, &DiagnosticResult{
				Component:   fmt.Sprintf("%s-flux-%s", clusterType, controller),
				Status:      "error",
				Message:     fmt.Sprintf("%s is missing", controller),
				Recoverable: true,
			})
			continue
		}

		if deployment.Status.ReadyReplicas == deployment.Status.Replicas && deployment.Status.ReadyReplicas > 0 {
			results = append(results, &DiagnosticResult{
				Component:   fmt.Sprintf("%s-flux-%s", clusterType, controller),
				Status:      "healthy",
				Message:     fmt.Sprintf("%s is ready", controller),
				Recoverable: true,
			})
			readyControllers++
		} else {
			results = append(results, &DiagnosticResult{
				Component:   fmt.Sprintf("%s-flux-%s", clusterType, controller),
				Status:      "warning",
				Message:     fmt.Sprintf("%s exists but not ready", controller),
				Recoverable: true,
			})
		}
	}

	// Overall FluxCD health
	if readyControllers == len(controllers) {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-flux-overall", clusterType),
			Status:      "healthy",
			Message:     "All FluxCD controllers are healthy",
			Recoverable: true,
		})
	} else {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-flux-overall", clusterType),
			Status:      "warning",
			Message:     fmt.Sprintf("Only %d/%d FluxCD controllers are ready", readyControllers, len(controllers)),
			Recoverable: true,
		})
	}

	return results
}

func (dm *DiagnosticManager) diagnoseIstio(ctx context.Context, client *k8s.Client, clusterType string) []*DiagnosticResult {
	var results []*DiagnosticResult

	// Check istio-system namespace
	exists, err := client.NamespaceExists(ctx, "istio-system")
	if err != nil {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-istio-namespace", clusterType),
			Status:      "error",
			Message:     fmt.Sprintf("Failed to check istio-system namespace: %v", err),
			Recoverable: true,
		})
		return results
	}

	if !exists {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-istio-namespace", clusterType),
			Status:      "warning",
			Message:     "Istio namespace does not exist",
			Recoverable: true,
		})
		return results
	}

	results = append(results, &DiagnosticResult{
		Component:   fmt.Sprintf("%s-istio-namespace", clusterType),
		Status:      "healthy",
		Message:     "Istio namespace exists",
		Recoverable: true,
	})

	// Check istiod pods
	pods, err := client.GetClientset().CoreV1().Pods("istio-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=istiod",
	})
	if err != nil {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-istio-control-plane", clusterType),
			Status:      "error",
			Message:     fmt.Sprintf("Failed to check istiod pods: %v", err),
			Recoverable: true,
		})
		return results
	}

	runningPods := 0
	for _, pod := range pods.Items {
		if pod.Status.Phase == "Running" {
			runningPods++
		}
	}

	if runningPods > 0 {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-istio-control-plane", clusterType),
			Status:      "healthy",
			Message:     fmt.Sprintf("Istio control plane is running (%d pods)", runningPods),
			Recoverable: true,
		})
	} else {
		results = append(results, &DiagnosticResult{
			Component:   fmt.Sprintf("%s-istio-control-plane", clusterType),
			Status:      "warning",
			Message:     "Istio control plane is not ready",
			Recoverable: true,
		})
	}

	return results
}

// PrintDiagnostics prints diagnostic results in a user-friendly format
func (dm *DiagnosticManager) PrintDiagnostics(results []*DiagnosticResult) {
	log.Info("📊 Diagnostic Results:")
	log.Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

	healthy := 0
	warnings := 0
	errors := 0

	for _, result := range results {
		switch result.Status {
		case "healthy":
			log.Info("✅ " + result.Component + ": " + result.Message)
			healthy++
		case "warning":
			log.Warn("⚠️ " + result.Component + ": " + result.Message)
			warnings++
		case "error":
			log.Error("❌ " + result.Component + ": " + result.Message)
			errors++
		}
	}

	log.Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	log.Info("Summary", "healthy", healthy, "warnings", warnings, "errors", errors)

	if errors > 0 {
		log.Error("System has critical issues that need attention")
	} else if warnings > 0 {
		log.Warn("System has some issues but is mostly functional")
	} else {
		log.Info("✅ All components are healthy!")
	}
}
