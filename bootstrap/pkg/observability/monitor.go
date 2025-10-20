package observability

import (
	"context"
	"fmt"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ObservabilityMonitor validates monitoring and observability stack
type ObservabilityMonitor struct {
	client *k8s.Client
}

// ObservabilityStatus represents the status of observability components
type ObservabilityStatus struct {
	PrometheusHealthy bool                   `json:"prometheus_healthy"`
	GrafanaHealthy    bool                   `json:"grafana_healthy"`
	AlertManagerReady bool                   `json:"alertmanager_ready"`
	JaegerHealthy     bool                   `json:"jaeger_healthy"`
	LoggingHealthy    bool                   `json:"logging_healthy"`
	ServiceMesh       bool                   `json:"service_mesh_observability"`
	Metrics           map[string]interface{} `json:"metrics"`
	ActiveAlerts      int                    `json:"active_alerts"`
}

// NewObservabilityMonitor creates a new observability monitor
func NewObservabilityMonitor(client *k8s.Client) *ObservabilityMonitor {
	return &ObservabilityMonitor{
		client: client,
	}
}

// ValidateObservabilityStack checks the health of monitoring and observability
func (om *ObservabilityMonitor) ValidateObservabilityStack(ctx context.Context) (*ObservabilityStatus, error) {
	log.Info("Validating observability and monitoring stack")

	status := &ObservabilityStatus{
		Metrics: make(map[string]interface{}),
	}

	// Check Prometheus
	if err := om.checkPrometheus(ctx, status); err != nil {
		log.Warn("Prometheus validation failed", "error", err)
	}

	// Check Grafana
	if err := om.checkGrafana(ctx, status); err != nil {
		log.Warn("Grafana validation failed", "error", err)
	}

	// Check AlertManager
	if err := om.checkAlertManager(ctx, status); err != nil {
		log.Warn("AlertManager validation failed", "error", err)
	}

	// Check Jaeger (distributed tracing)
	if err := om.checkJaeger(ctx, status); err != nil {
		log.Warn("Jaeger validation failed", "error", err)
	}

	// Check logging stack (Loki/ELK)
	if err := om.checkLoggingStack(ctx, status); err != nil {
		log.Warn("Logging stack validation failed", "error", err)
	}

	// Check service mesh observability
	if err := om.checkServiceMeshObservability(ctx, status); err != nil {
		log.Warn("Service mesh observability validation failed", "error", err)
	}

	return status, nil
}

// checkPrometheus validates Prometheus installation and health
func (om *ObservabilityMonitor) checkPrometheus(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check Prometheus deployment
	deployments, err := clientset.AppsV1().Deployments("monitoring").List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=prometheus",
	})
	if err != nil {
		// Try alternative namespace
		deployments, err = clientset.AppsV1().Deployments("prometheus").List(ctx, metav1.ListOptions{
			LabelSelector: "app=prometheus",
		})
		if err != nil {
			status.PrometheusHealthy = false
			return fmt.Errorf("prometheus deployment not found: %w", err)
		}
	}

	if len(deployments.Items) > 0 {
		prometheus := deployments.Items[0]
		if prometheus.Status.ReadyReplicas > 0 {
			status.PrometheusHealthy = true
			status.Metrics["prometheus_replicas"] = prometheus.Status.ReadyReplicas
			log.Info("Prometheus is healthy", "replicas", prometheus.Status.ReadyReplicas)
		} else {
			status.PrometheusHealthy = false
			log.Warn("Prometheus deployment exists but not ready")
		}
	}

	return nil
}

// checkGrafana validates Grafana installation and dashboards
func (om *ObservabilityMonitor) checkGrafana(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check Grafana deployment
	deployments, err := clientset.AppsV1().Deployments("monitoring").List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=grafana",
	})
	if err != nil {
		deployments, err = clientset.AppsV1().Deployments("grafana").List(ctx, metav1.ListOptions{
			LabelSelector: "app=grafana",
		})
		if err != nil {
			status.GrafanaHealthy = false
			return fmt.Errorf("grafana deployment not found: %w", err)
		}
	}

	if len(deployments.Items) > 0 {
		grafana := deployments.Items[0]
		if grafana.Status.ReadyReplicas > 0 {
			status.GrafanaHealthy = true
			log.Info("Grafana is healthy")

			// Check for ConfigMaps with dashboards
			configMaps, err := clientset.CoreV1().ConfigMaps("monitoring").List(ctx, metav1.ListOptions{
				LabelSelector: "grafana_dashboard=1",
			})
			if err == nil {
				status.Metrics["grafana_dashboards"] = len(configMaps.Items)
				log.Info("Grafana dashboards found", "count", len(configMaps.Items))
			}
		} else {
			status.GrafanaHealthy = false
			log.Warn("Grafana deployment exists but not ready")
		}
	}

	return nil
}

// checkAlertManager validates AlertManager for alert handling
func (om *ObservabilityMonitor) checkAlertManager(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check AlertManager StatefulSet
	statefulSets, err := clientset.AppsV1().StatefulSets("monitoring").List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=alertmanager",
	})
	if err != nil {
		status.AlertManagerReady = false
		return fmt.Errorf("alertmanager not found: %w", err)
	}

	if len(statefulSets.Items) > 0 {
		alertManager := statefulSets.Items[0]
		if alertManager.Status.ReadyReplicas > 0 {
			status.AlertManagerReady = true
			log.Info("AlertManager is ready")

			// Mock active alerts count (would query AlertManager API in reality)
			status.ActiveAlerts = 0
		} else {
			status.AlertManagerReady = false
			log.Warn("AlertManager exists but not ready")
		}
	}

	return nil
}

// checkJaeger validates distributed tracing with Jaeger
func (om *ObservabilityMonitor) checkJaeger(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check Jaeger deployment
	deployments, err := clientset.AppsV1().Deployments("istio-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=jaeger",
	})
	if err != nil {
		// Try observability namespace
		deployments, err = clientset.AppsV1().Deployments("observability").List(ctx, metav1.ListOptions{
			LabelSelector: "app.kubernetes.io/name=jaeger",
		})
		if err != nil {
			status.JaegerHealthy = false
			return fmt.Errorf("jaeger deployment not found: %w", err)
		}
	}

	if len(deployments.Items) > 0 {
		jaeger := deployments.Items[0]
		if jaeger.Status.ReadyReplicas > 0 {
			status.JaegerHealthy = true
			log.Info("Jaeger tracing is healthy")
		} else {
			status.JaegerHealthy = false
			log.Warn("Jaeger deployment exists but not ready")
		}
	}

	return nil
}

// checkLoggingStack validates centralized logging (Loki, ELK, etc.)
func (om *ObservabilityMonitor) checkLoggingStack(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check for Loki
	lokiDeployments, err := clientset.AppsV1().Deployments("logging").List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/name=loki",
	})
	if err == nil && len(lokiDeployments.Items) > 0 {
		loki := lokiDeployments.Items[0]
		if loki.Status.ReadyReplicas > 0 {
			status.LoggingHealthy = true
			log.Info("Loki logging stack is healthy")
			return nil
		}
	}

	// Check for Elasticsearch
	esDeployments, err := clientset.AppsV1().Deployments("elastic-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=elasticsearch",
	})
	if err == nil && len(esDeployments.Items) > 0 {
		es := esDeployments.Items[0]
		if es.Status.ReadyReplicas > 0 {
			status.LoggingHealthy = true
			log.Info("Elasticsearch logging stack is healthy")
			return nil
		}
	}

	// Check for Fluent Bit/Fluentd DaemonSets
	daemonSets, err := clientset.AppsV1().DaemonSets("kube-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=fluent-bit",
	})
	if err == nil && len(daemonSets.Items) > 0 {
		fluentBit := daemonSets.Items[0]
		if fluentBit.Status.NumberReady > 0 {
			status.LoggingHealthy = true
			log.Info("Fluent Bit logging agent is healthy")
			return nil
		}
	}

	status.LoggingHealthy = false
	log.Warn("No healthy logging stack found")
	return nil
}

// checkServiceMeshObservability validates Istio/service mesh observability
func (om *ObservabilityMonitor) checkServiceMeshObservability(ctx context.Context, status *ObservabilityStatus) error {
	clientset := om.client.GetClientset()

	// Check Istio telemetry components
	deployments, err := clientset.AppsV1().Deployments("istio-system").List(ctx, metav1.ListOptions{})
	if err != nil {
		status.ServiceMesh = false
		return fmt.Errorf("istio-system namespace not accessible: %w", err)
	}

	// Check for Istio observability components
	observabilityComponents := []string{"kiali", "jaeger", "prometheus"}
	healthyComponents := 0

	for _, deployment := range deployments.Items {
		for _, component := range observabilityComponents {
			if deployment.Labels["app"] == component && deployment.Status.ReadyReplicas > 0 {
				healthyComponents++
				break
			}
		}
	}

	if healthyComponents > 0 {
		status.ServiceMesh = true
		status.Metrics["service_mesh_components"] = healthyComponents
		log.Info("Service mesh observability components found", "healthy", healthyComponents)
	} else {
		status.ServiceMesh = false
		log.Warn("No healthy service mesh observability components found")
	}

	return nil
}

// CollectMetrics collects cluster metrics for monitoring
func (om *ObservabilityMonitor) CollectMetrics(ctx context.Context) (map[string]interface{}, error) {
	log.Info("Collecting cluster metrics")

	metrics := make(map[string]interface{})
	clientset := om.client.GetClientset()

	// Collect node metrics
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err == nil {
		metrics["node_count"] = len(nodes.Items)

		readyNodes := 0
		for _, node := range nodes.Items {
			for _, condition := range node.Status.Conditions {
				if condition.Type == "Ready" && condition.Status == "True" {
					readyNodes++
					break
				}
			}
		}
		metrics["ready_nodes"] = readyNodes
	}

	// Collect pod metrics
	pods, err := clientset.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err == nil {
		metrics["total_pods"] = len(pods.Items)

		runningPods := 0
		for _, pod := range pods.Items {
			if pod.Status.Phase == "Running" {
				runningPods++
			}
		}
		metrics["running_pods"] = runningPods
	}

	// Collect namespace metrics
	namespaces, err := clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err == nil {
		metrics["namespace_count"] = len(namespaces.Items)
	}

	metrics["collection_timestamp"] = time.Now().Unix()

	log.Info("Metrics collected", "node_count", metrics["node_count"],
		"running_pods", metrics["running_pods"])

	return metrics, nil
}
