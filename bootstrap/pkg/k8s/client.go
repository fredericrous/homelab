package k8s

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

// Client wraps Kubernetes client with common operations
type Client struct {
	clientset     *kubernetes.Clientset
	dynamicClient dynamic.Interface
	config        *rest.Config
	kubeconfig    string
    contextName  string
}

// NewClient creates a new Kubernetes client
func NewClient(kubeconfig string) (*Client, error) {
	return NewClientWithContext(kubeconfig, "")
}

// NewClientWithContext creates a Kubernetes client for a specific context.
func NewClientWithContext(kubeconfig, context string) (*Client, error) {
	var config *rest.Config
	var err error

	if kubeconfig == "" {
		config, err = rest.InClusterConfig()
		if err != nil {
			if home := homedir.HomeDir(); home != "" {
				kubeconfig = filepath.Join(home, ".kube", "config")
			}
		}
	}

	if config == nil {
		loadingRules := &clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfig}
		overrides := &clientcmd.ConfigOverrides{}
		if context != "" {
			overrides.CurrentContext = context
		}

		clientConfig := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, overrides)
		config, err = clientConfig.ClientConfig()
		if err != nil {
			return nil, fmt.Errorf("failed to build kubeconfig: %w", err)
		}
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create kubernetes client: %w", err)
	}

	// Create the dynamic client
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create dynamic client: %w", err)
	}

	return &Client{
		clientset:     clientset,
		dynamicClient: dynamicClient,
		config:        config,
		kubeconfig:    kubeconfig,
		contextName:   context,
	}, nil
}

// GetClientset returns the underlying Kubernetes clientset
func (c *Client) GetClientset() *kubernetes.Clientset {
	return c.clientset
}

// GetDynamicClient returns the underlying dynamic client
func (c *Client) GetDynamicClient() dynamic.Interface {
	return c.dynamicClient
}

// GetConfig returns the rest config
func (c *Client) GetConfig() *rest.Config {
	return c.config
}

// IsReady checks if the Kubernetes API server is ready
func (c *Client) IsReady(ctx context.Context) error {
	_, err := c.clientset.Discovery().ServerVersion()
	if err != nil {
		return fmt.Errorf("kubernetes API not ready: %w", err)
	}
	return nil
}

// WaitForReady waits for the Kubernetes API server to be ready
func (c *Client) WaitForReady(ctx context.Context, timeout time.Duration) error {
	return wait.PollImmediate(5*time.Second, timeout, func() (bool, error) {
		if err := c.IsReady(ctx); err != nil {
			return false, nil // Keep trying
		}
		return true, nil
	})
}

// NamespaceExists checks if a namespace exists
func (c *Client) NamespaceExists(ctx context.Context, name string) (bool, error) {
	_, err := c.clientset.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// CreateNamespace creates a namespace if it doesn't exist
func (c *Client) CreateNamespace(ctx context.Context, name string) error {
	exists, err := c.NamespaceExists(ctx, name)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}

	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
	}

	_, err = c.clientset.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("failed to create namespace %s: %w", name, err)
	}

	return nil
}

// WaitForNamespace waits for a namespace to exist and be ready
func (c *Client) WaitForNamespace(ctx context.Context, name string, timeout time.Duration) error {
	return wait.PollImmediate(2*time.Second, timeout, func() (bool, error) {
		exists, err := c.NamespaceExists(ctx, name)
		if err != nil {
			return false, err
		}
		return exists, nil
	})
}

// GetNodes returns all cluster nodes
func (c *Client) GetNodes(ctx context.Context) ([]string, error) {
	nodes, err := c.clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list nodes: %w", err)
	}

	var nodeNames []string
	for _, node := range nodes.Items {
		nodeNames = append(nodeNames, node.Name)
	}

	return nodeNames, nil
}

// WaitForNodes waits for the specified number of nodes to be ready
func (c *Client) WaitForNodes(ctx context.Context, expectedCount int, timeout time.Duration) error {
	return wait.PollImmediate(10*time.Second, timeout, func() (bool, error) {
		nodes, err := c.clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
		if err != nil {
			return false, nil // Keep trying
		}

		readyNodes := 0
		for _, node := range nodes.Items {
			for _, condition := range node.Status.Conditions {
				if condition.Type == "Ready" && condition.Status == "True" {
					readyNodes++
					break
				}
			}
		}

		return readyNodes >= expectedCount, nil
	})
}

// WaitForDeployment waits for a deployment to be ready
func (c *Client) WaitForDeployment(ctx context.Context, namespace, name string, timeout time.Duration) error {
	return wait.PollImmediate(5*time.Second, timeout, func() (bool, error) {
		deployment, err := c.clientset.AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil // Keep waiting
			}
			return false, err
		}

		return deployment.Status.ReadyReplicas == deployment.Status.Replicas &&
			deployment.Status.ReadyReplicas > 0, nil
	})
}

// WaitForDaemonSet waits for a daemonset to be ready
func (c *Client) WaitForDaemonSet(ctx context.Context, namespace, name string, timeout time.Duration) error {
	return wait.PollImmediate(5*time.Second, timeout, func() (bool, error) {
		daemonset, err := c.clientset.AppsV1().DaemonSets(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			if apierrors.IsNotFound(err) {
				return false, nil // Keep waiting
			}
			return false, err
		}

		return daemonset.Status.NumberReady == daemonset.Status.DesiredNumberScheduled &&
			daemonset.Status.NumberReady > 0, nil
	})
}

// GetPods returns pods in a namespace
func (c *Client) GetPods(ctx context.Context, namespace string, labelSelector string) ([]string, error) {
	pods, err := c.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: labelSelector,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to list pods: %w", err)
	}

	var podNames []string
	for _, pod := range pods.Items {
		podNames = append(podNames, pod.Name)
	}

	return podNames, nil
}

// WaitForPods waits for pods matching a label selector to be ready
func (c *Client) WaitForPods(ctx context.Context, namespace, labelSelector string, expectedCount int, timeout time.Duration) error {
	return wait.PollImmediate(5*time.Second, timeout, func() (bool, error) {
		pods, err := c.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: labelSelector,
		})
		if err != nil {
			return false, nil // Keep trying
		}

		readyPods := 0
		for _, pod := range pods.Items {
			if pod.Status.Phase == "Running" {
				allContainersReady := true
				for _, condition := range pod.Status.Conditions {
					if condition.Type == "Ready" && condition.Status != "True" {
						allContainersReady = false
						break
					}
				}
				if allContainersReady {
					readyPods++
				}
			}
		}

		return readyPods >= expectedCount, nil
	})
}

// GetSecret gets a secret by name and namespace
func (c *Client) GetSecret(ctx context.Context, namespace, name string) (*corev1.Secret, error) {
	return c.clientset.CoreV1().Secrets(namespace).Get(ctx, name, metav1.GetOptions{})
}

// GetService gets a service by name and namespace
func (c *Client) GetService(ctx context.Context, namespace, name string) (*corev1.Service, error) {
	return c.clientset.CoreV1().Services(namespace).Get(ctx, name, metav1.GetOptions{})
}

// CreateOrUpdateSecret creates or updates a secret
func (c *Client) CreateOrUpdateSecret(ctx context.Context, secret *corev1.Secret) error {
	secretsClient := c.clientset.CoreV1().Secrets(secret.Namespace)

	// Try to get existing secret
	_, err := secretsClient.Get(ctx, secret.Name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			// Create new secret
			_, err = secretsClient.Create(ctx, secret, metav1.CreateOptions{})
			if err != nil {
				return fmt.Errorf("failed to create secret %s: %w", secret.Name, err)
			}
			return nil
		}
		return fmt.Errorf("failed to check secret %s: %w", secret.Name, err)
	}

	// Update existing secret
	_, err = secretsClient.Update(ctx, secret, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("failed to update secret %s: %w", secret.Name, err)
	}

	return nil
}

// ApplyManifest applies a Kubernetes manifest (placeholder for more complex implementation)
func (c *Client) ApplyManifest(ctx context.Context, manifest string) error {
	// This is a simplified version - in practice, you'd use server-side apply
	// or a proper YAML parser with the dynamic client
	return fmt.Errorf("manifest application not yet implemented - use kubectl apply for now")
}
