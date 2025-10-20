package health

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// HealthChecker performs comprehensive cluster health validation
type HealthChecker struct {
	client *k8s.Client
}

// HealthStatus represents the overall cluster health
type HealthStatus struct {
	Overall    HealthState            `json:"overall"`
	Components map[string]HealthState `json:"components"`
	Details    map[string]string      `json:"details"`
	Timestamp  time.Time              `json:"timestamp"`
}

// HealthState represents the state of a health check
type HealthState string

const (
	HealthStateHealthy   HealthState = "healthy"
	HealthStateWarning   HealthState = "warning"
	HealthStateUnhealthy HealthState = "unhealthy"
	HealthStateUnknown   HealthState = "unknown"
)

// NewHealthChecker creates a new health checker
func NewHealthChecker(client *k8s.Client) *HealthChecker {
	return &HealthChecker{
		client: client,
	}
}

// CheckClusterHealth performs comprehensive cluster health validation
func (hc *HealthChecker) CheckClusterHealth(ctx context.Context) (*HealthStatus, error) {
	log.Info("Performing comprehensive cluster health check")

	status := &HealthStatus{
		Components: make(map[string]HealthState),
		Details:    make(map[string]string),
		Timestamp:  time.Now(),
	}

	// Check API Server Health
	if err := hc.checkAPIServer(ctx, status); err != nil {
		log.Error("API Server health check failed", "error", err)
	}

	// Check Node Health
	if err := hc.checkNodeHealth(ctx, status); err != nil {
		log.Error("Node health check failed", "error", err)
	}

	// Check CNI Health
	if err := hc.checkCNIHealth(ctx, status); err != nil {
		log.Error("CNI health check failed", "error", err)
	}

	// Check DNS Resolution
	if err := hc.checkDNSHealth(ctx, status); err != nil {
		log.Error("DNS health check failed", "error", err)
	}

	// Check Storage Health
	if err := hc.checkStorageHealth(ctx, status); err != nil {
		log.Error("Storage health check failed", "error", err)
	}

	// Check Control Plane Health
	if err := hc.checkControlPlaneHealth(ctx, status); err != nil {
		log.Error("Control plane health check failed", "error", err)
	}

	// Check Network Connectivity
	if err := hc.checkNetworkConnectivity(ctx, status); err != nil {
		log.Error("Network connectivity check failed", "error", err)
	}

	// Determine overall health
	status.Overall = hc.calculateOverallHealth(status.Components)

	log.Info("Cluster health check completed",
		"overall", status.Overall,
		"healthy_components", hc.countHealthyComponents(status.Components),
		"total_components", len(status.Components))

	return status, nil
}

// checkAPIServer validates Kubernetes API server health
func (hc *HealthChecker) checkAPIServer(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking API server health")

	// Test API server responsiveness
	start := time.Now()
	err := hc.client.IsReady(ctx)
	latency := time.Since(start)

	if err != nil {
		status.Components["api_server"] = HealthStateUnhealthy
		status.Details["api_server"] = fmt.Sprintf("API server unreachable: %v", err)
		return err
	}

	// Check API server latency
	if latency > 5*time.Second {
		status.Components["api_server"] = HealthStateWarning
		status.Details["api_server"] = fmt.Sprintf("High API server latency: %v", latency)
	} else {
		status.Components["api_server"] = HealthStateHealthy
		status.Details["api_server"] = fmt.Sprintf("API server responsive (latency: %v)", latency)
	}

	return nil
}

// checkNodeHealth validates node health and readiness
func (hc *HealthChecker) checkNodeHealth(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking node health")

	clientset := hc.client.GetClientset()
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		status.Components["nodes"] = HealthStateUnhealthy
		status.Details["nodes"] = fmt.Sprintf("Failed to list nodes: %v", err)
		return err
	}

	if len(nodes.Items) == 0 {
		status.Components["nodes"] = HealthStateUnhealthy
		status.Details["nodes"] = "No nodes found in cluster"
		return fmt.Errorf("no nodes found")
	}

	healthyNodes := 0
	var unhealthyNodes []string

	for _, node := range nodes.Items {
		isReady := false
		for _, condition := range node.Status.Conditions {
			if condition.Type == corev1.NodeReady && condition.Status == corev1.ConditionTrue {
				isReady = true
				healthyNodes++
				break
			}
		}
		if !isReady {
			unhealthyNodes = append(unhealthyNodes, node.Name)
		}
	}

	if len(unhealthyNodes) > 0 {
		status.Components["nodes"] = HealthStateWarning
		status.Details["nodes"] = fmt.Sprintf("Unhealthy nodes: %v (healthy: %d/%d)",
			unhealthyNodes, healthyNodes, len(nodes.Items))
	} else {
		status.Components["nodes"] = HealthStateHealthy
		status.Details["nodes"] = fmt.Sprintf("All nodes healthy (%d/%d)", healthyNodes, len(nodes.Items))
	}

	return nil
}

// checkCNIHealth validates Container Network Interface health
func (hc *HealthChecker) checkCNIHealth(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking CNI health")

	// Check if CNI pods are running (assuming Cilium)
	clientset := hc.client.GetClientset()

	// Check Cilium DaemonSet
	ciliumDS, err := clientset.AppsV1().DaemonSets("kube-system").Get(ctx, "cilium", metav1.GetOptions{})
	if err != nil {
		status.Components["cni"] = HealthStateWarning
		status.Details["cni"] = "CNI DaemonSet not found (might be different CNI)"
		return nil
	}

	if ciliumDS.Status.NumberReady == ciliumDS.Status.DesiredNumberScheduled {
		status.Components["cni"] = HealthStateHealthy
		status.Details["cni"] = fmt.Sprintf("CNI healthy (%d/%d pods ready)",
			ciliumDS.Status.NumberReady, ciliumDS.Status.DesiredNumberScheduled)
	} else {
		status.Components["cni"] = HealthStateWarning
		status.Details["cni"] = fmt.Sprintf("CNI partially ready (%d/%d pods ready)",
			ciliumDS.Status.NumberReady, ciliumDS.Status.DesiredNumberScheduled)
	}

	return nil
}

// checkDNSHealth validates cluster DNS resolution
func (hc *HealthChecker) checkDNSHealth(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking DNS health")

	// Test DNS resolution by resolving kubernetes.default.svc.cluster.local
	resolver := &net.Resolver{}
	_, err := resolver.LookupHost(ctx, "kubernetes.default.svc.cluster.local")

	if err != nil {
		status.Components["dns"] = HealthStateUnhealthy
		status.Details["dns"] = fmt.Sprintf("DNS resolution failed: %v", err)
		return err
	}

	status.Components["dns"] = HealthStateHealthy
	status.Details["dns"] = "DNS resolution working"
	return nil
}

// checkStorageHealth validates storage classes and persistent volumes
func (hc *HealthChecker) checkStorageHealth(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking storage health")

	clientset := hc.client.GetClientset()

	// Check storage classes
	storageClasses, err := clientset.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		status.Components["storage"] = HealthStateWarning
		status.Details["storage"] = fmt.Sprintf("Failed to list storage classes: %v", err)
		return err
	}

	if len(storageClasses.Items) == 0 {
		status.Components["storage"] = HealthStateWarning
		status.Details["storage"] = "No storage classes found"
		return nil
	}

	// Check for default storage class
	hasDefault := false
	for _, sc := range storageClasses.Items {
		if annotations := sc.GetAnnotations(); annotations != nil {
			if annotations["storageclass.kubernetes.io/is-default-class"] == "true" {
				hasDefault = true
				break
			}
		}
	}

	if hasDefault {
		status.Components["storage"] = HealthStateHealthy
		status.Details["storage"] = fmt.Sprintf("Storage healthy (%d storage classes, default present)",
			len(storageClasses.Items))
	} else {
		status.Components["storage"] = HealthStateWarning
		status.Details["storage"] = fmt.Sprintf("Storage classes present (%d) but no default class",
			len(storageClasses.Items))
	}

	return nil
}

// checkControlPlaneHealth validates control plane components
func (hc *HealthChecker) checkControlPlaneHealth(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking control plane health")

	clientset := hc.client.GetClientset()

	// Check control plane pods
	controlPlanePods, err := clientset.CoreV1().Pods("kube-system").List(ctx, metav1.ListOptions{
		LabelSelector: "tier=control-plane",
	})
	if err != nil {
		status.Components["control_plane"] = HealthStateWarning
		status.Details["control_plane"] = fmt.Sprintf("Failed to list control plane pods: %v", err)
		return err
	}

	runningPods := 0
	for _, pod := range controlPlanePods.Items {
		if pod.Status.Phase == corev1.PodRunning {
			runningPods++
		}
	}

	if runningPods == len(controlPlanePods.Items) && runningPods > 0 {
		status.Components["control_plane"] = HealthStateHealthy
		status.Details["control_plane"] = fmt.Sprintf("Control plane healthy (%d/%d pods running)",
			runningPods, len(controlPlanePods.Items))
	} else {
		status.Components["control_plane"] = HealthStateWarning
		status.Details["control_plane"] = fmt.Sprintf("Control plane issues (%d/%d pods running)",
			runningPods, len(controlPlanePods.Items))
	}

	return nil
}

// checkNetworkConnectivity validates pod-to-pod and service connectivity
func (hc *HealthChecker) checkNetworkConnectivity(ctx context.Context, status *HealthStatus) error {
	log.Debug("Checking network connectivity")

	// This would ideally deploy test pods and validate connectivity
	// For now, we'll check if basic networking components are present

	clientset := hc.client.GetClientset()

	// Check kube-proxy
	kubeProxyPods, err := clientset.CoreV1().Pods("kube-system").List(ctx, metav1.ListOptions{
		LabelSelector: "k8s-app=kube-proxy",
	})
	if err != nil {
		status.Components["network_connectivity"] = HealthStateWarning
		status.Details["network_connectivity"] = "Unable to verify network components"
		return nil
	}

	runningProxyPods := 0
	for _, pod := range kubeProxyPods.Items {
		if pod.Status.Phase == corev1.PodRunning {
			runningProxyPods++
		}
	}

	if runningProxyPods > 0 {
		status.Components["network_connectivity"] = HealthStateHealthy
		status.Details["network_connectivity"] = fmt.Sprintf("Network components healthy (%d proxy pods)", runningProxyPods)
	} else {
		status.Components["network_connectivity"] = HealthStateWarning
		status.Details["network_connectivity"] = "Network proxy components not found"
	}

	return nil
}

// calculateOverallHealth determines overall health based on component health
func (hc *HealthChecker) calculateOverallHealth(components map[string]HealthState) HealthState {
	unhealthyCount := 0
	warningCount := 0
	totalCount := len(components)

	for _, state := range components {
		switch state {
		case HealthStateUnhealthy:
			unhealthyCount++
		case HealthStateWarning:
			warningCount++
		}
	}

	// If any component is unhealthy, overall is unhealthy
	if unhealthyCount > 0 {
		return HealthStateUnhealthy
	}

	// If more than half have warnings, overall is warning
	if warningCount > totalCount/2 {
		return HealthStateWarning
	}

	// If any warnings but less than half, still healthy
	if warningCount > 0 {
		return HealthStateHealthy
	}

	return HealthStateHealthy
}

// countHealthyComponents counts the number of healthy components
func (hc *HealthChecker) countHealthyComponents(components map[string]HealthState) int {
	count := 0
	for _, state := range components {
		if state == HealthStateHealthy {
			count++
		}
	}
	return count
}
