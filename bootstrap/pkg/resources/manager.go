package resources

import (
	"context"
	"fmt"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ResourceManager validates resource management and autoscaling
type ResourceManager struct {
	client *k8s.Client
}

// ResourceStatus represents cluster resource management status
type ResourceStatus struct {
	MetricsServerHealthy bool                   `json:"metrics_server_healthy"`
	HPAConfigured        bool                   `json:"hpa_configured"`
	VPAAvailable         bool                   `json:"vpa_available"`
	ClusterAutoscaler    bool                   `json:"cluster_autoscaler"`
	ResourceQuotas       bool                   `json:"resource_quotas"`
	LimitRanges          bool                   `json:"limit_ranges"`
	NodeUtilization      map[string]interface{} `json:"node_utilization"`
	ResourcePressure     []ResourceAlert        `json:"resource_pressure"`
}

// ResourceAlert represents a resource pressure alert
type ResourceAlert struct {
	Resource    string `json:"resource"`
	Node        string `json:"node,omitempty"`
	Namespace   string `json:"namespace,omitempty"`
	Severity    string `json:"severity"`
	Description string `json:"description"`
}

// NewResourceManager creates a new resource manager
func NewResourceManager(client *k8s.Client) *ResourceManager {
	return &ResourceManager{
		client: client,
	}
}

// ValidateResourceManagement checks resource management and autoscaling setup
func (rm *ResourceManager) ValidateResourceManagement(ctx context.Context) (*ResourceStatus, error) {
	log.Info("Validating resource management and autoscaling")

	status := &ResourceStatus{
		NodeUtilization:  make(map[string]interface{}),
		ResourcePressure: []ResourceAlert{},
	}

	// Check Metrics Server
	if err := rm.checkMetricsServer(ctx, status); err != nil {
		log.Warn("Metrics Server validation failed", "error", err)
	}

	// Check Horizontal Pod Autoscaler
	if err := rm.checkHPA(ctx, status); err != nil {
		log.Warn("HPA validation failed", "error", err)
	}

	// Check Vertical Pod Autoscaler
	if err := rm.checkVPA(ctx, status); err != nil {
		log.Warn("VPA validation failed", "error", err)
	}

	// Check Cluster Autoscaler
	if err := rm.checkClusterAutoscaler(ctx, status); err != nil {
		log.Warn("Cluster Autoscaler validation failed", "error", err)
	}

	// Check Resource Quotas
	if err := rm.checkResourceQuotas(ctx, status); err != nil {
		log.Warn("Resource Quota validation failed", "error", err)
	}

	// Check Limit Ranges
	if err := rm.checkLimitRanges(ctx, status); err != nil {
		log.Warn("Limit Range validation failed", "error", err)
	}

	// Check Node Resource Utilization
	if err := rm.checkNodeUtilization(ctx, status); err != nil {
		log.Warn("Node utilization check failed", "error", err)
	}

	return status, nil
}

// checkMetricsServer validates metrics server installation
func (rm *ResourceManager) checkMetricsServer(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check metrics server deployment
	deployment, err := clientset.AppsV1().Deployments("kube-system").Get(ctx, "metrics-server", metav1.GetOptions{})
	if err != nil {
		status.MetricsServerHealthy = false
		status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
			Resource:    "metrics-server",
			Severity:    "High",
			Description: "Metrics Server not found - autoscaling will not work",
		})
		return fmt.Errorf("metrics server not found: %w", err)
	}

	if deployment.Status.ReadyReplicas > 0 {
		status.MetricsServerHealthy = true
		log.Info("Metrics Server is healthy")
	} else {
		status.MetricsServerHealthy = false
		status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
			Resource:    "metrics-server",
			Severity:    "High",
			Description: "Metrics Server deployment exists but not ready",
		})
	}

	return nil
}

// checkHPA validates Horizontal Pod Autoscaler configuration
func (rm *ResourceManager) checkHPA(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check for HPA resources across all namespaces
	hpas, err := clientset.AutoscalingV2().HorizontalPodAutoscalers("").List(ctx, metav1.ListOptions{})
	if err != nil {
		status.HPAConfigured = false
		return fmt.Errorf("failed to list HPAs: %w", err)
	}

	if len(hpas.Items) > 0 {
		status.HPAConfigured = true
		log.Info("Horizontal Pod Autoscalers configured", "count", len(hpas.Items))

		// Check HPA health
		for _, hpa := range hpas.Items {
			if hpa.Status.CurrentReplicas == 0 {
				status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
					Resource:    "hpa",
					Namespace:   hpa.Namespace,
					Severity:    "Medium",
					Description: fmt.Sprintf("HPA %s/%s has no current replicas", hpa.Namespace, hpa.Name),
				})
			}
		}
	} else {
		status.HPAConfigured = false
		log.Info("No Horizontal Pod Autoscalers found")
	}

	return nil
}

// checkVPA validates Vertical Pod Autoscaler availability
func (rm *ResourceManager) checkVPA(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check for VPA CRDs
	_, err := clientset.CoreV1().RESTClient().
		Get().
		AbsPath("/apis/autoscaling.k8s.io/v1/verticalpodautoscalers").
		DoRaw(ctx)

	if err != nil {
		status.VPAAvailable = false
		log.Debug("Vertical Pod Autoscaler not available", "error", err)
		return nil
	}

	status.VPAAvailable = true
	log.Info("Vertical Pod Autoscaler is available")
	return nil
}

// checkClusterAutoscaler validates cluster autoscaler installation
func (rm *ResourceManager) checkClusterAutoscaler(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check for cluster autoscaler deployment
	deployments, err := clientset.AppsV1().Deployments("kube-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=cluster-autoscaler",
	})
	if err != nil {
		status.ClusterAutoscaler = false
		return fmt.Errorf("failed to check cluster autoscaler: %w", err)
	}

	if len(deployments.Items) > 0 {
		ca := deployments.Items[0]
		if ca.Status.ReadyReplicas > 0 {
			status.ClusterAutoscaler = true
			log.Info("Cluster Autoscaler is healthy")
		} else {
			status.ClusterAutoscaler = false
			status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
				Resource:    "cluster-autoscaler",
				Severity:    "Medium",
				Description: "Cluster Autoscaler exists but not ready",
			})
		}
	} else {
		status.ClusterAutoscaler = false
		log.Info("Cluster Autoscaler not found")
	}

	return nil
}

// checkResourceQuotas validates resource quota configuration
func (rm *ResourceManager) checkResourceQuotas(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check for resource quotas across namespaces
	quotas, err := clientset.CoreV1().ResourceQuotas("").List(ctx, metav1.ListOptions{})
	if err != nil {
		status.ResourceQuotas = false
		return fmt.Errorf("failed to list resource quotas: %w", err)
	}

	if len(quotas.Items) > 0 {
		status.ResourceQuotas = true
		log.Info("Resource Quotas configured", "count", len(quotas.Items))

		// Check for quota violations
		for _, quota := range quotas.Items {
			for resourceName, used := range quota.Status.Used {
				if hard, exists := quota.Status.Hard[resourceName]; exists {
					if used.Cmp(hard) >= 0 {
						status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
							Resource:    string(resourceName),
							Namespace:   quota.Namespace,
							Severity:    "High",
							Description: fmt.Sprintf("Resource quota exceeded for %s in namespace %s", resourceName, quota.Namespace),
						})
					}
				}
			}
		}
	} else {
		status.ResourceQuotas = false
		log.Info("No Resource Quotas configured")
	}

	return nil
}

// checkLimitRanges validates limit range configuration
func (rm *ResourceManager) checkLimitRanges(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Check for limit ranges across namespaces
	limitRanges, err := clientset.CoreV1().LimitRanges("").List(ctx, metav1.ListOptions{})
	if err != nil {
		status.LimitRanges = false
		return fmt.Errorf("failed to list limit ranges: %w", err)
	}

	if len(limitRanges.Items) > 0 {
		status.LimitRanges = true
		log.Info("Limit Ranges configured", "count", len(limitRanges.Items))
	} else {
		status.LimitRanges = false
		log.Info("No Limit Ranges configured")
	}

	return nil
}

// checkNodeUtilization checks node resource utilization
func (rm *ResourceManager) checkNodeUtilization(ctx context.Context, status *ResourceStatus) error {
	clientset := rm.client.GetClientset()

	// Get nodes
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list nodes: %w", err)
	}

	totalCPU := resource.NewQuantity(0, resource.DecimalSI)
	totalMemory := resource.NewQuantity(0, resource.BinarySI)

	for _, node := range nodes.Items {
		// Get node capacity
		if cpu, exists := node.Status.Capacity["cpu"]; exists {
			totalCPU.Add(cpu)
		}
		if memory, exists := node.Status.Capacity["memory"]; exists {
			totalMemory.Add(memory)
		}

		// Check node conditions for pressure
		for _, condition := range node.Status.Conditions {
			if condition.Status == "True" {
				switch condition.Type {
				case "MemoryPressure":
					status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
						Resource:    "memory",
						Node:        node.Name,
						Severity:    "High",
						Description: fmt.Sprintf("Node %s experiencing memory pressure", node.Name),
					})
				case "DiskPressure":
					status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
						Resource:    "disk",
						Node:        node.Name,
						Severity:    "High",
						Description: fmt.Sprintf("Node %s experiencing disk pressure", node.Name),
					})
				case "PIDPressure":
					status.ResourcePressure = append(status.ResourcePressure, ResourceAlert{
						Resource:    "pid",
						Node:        node.Name,
						Severity:    "Medium",
						Description: fmt.Sprintf("Node %s experiencing PID pressure", node.Name),
					})
				}
			}
		}
	}

	status.NodeUtilization["total_cpu_cores"] = totalCPU.Value()
	status.NodeUtilization["total_memory_bytes"] = totalMemory.Value()
	status.NodeUtilization["node_count"] = len(nodes.Items)

	log.Info("Node utilization checked",
		"nodes", len(nodes.Items),
		"total_cpu", totalCPU.String(),
		"total_memory", totalMemory.String(),
		"pressure_alerts", len(status.ResourcePressure))

	return nil
}
