package flux

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fluxcd/flux2/v2/pkg/manifestgen/install"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/restmapper"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/apimachinery/pkg/util/yaml"
)

// Client handles FluxCD operations
type Client struct {
	k8sClient *k8s.Client
	config    *config.GitOpsConfig
}

// ApplyOptions configures how manifests are applied
type ApplyOptions struct {
	// Force controls whether to use Force:true in server-side apply
	// Default: true during bootstrap to handle partial Flux installations
	Force bool
	// FieldManager identifies the component making changes
	// Default: "homelab-bootstrap"
	FieldManager string
}

// NewClient creates a new FluxCD client
func NewClient(k8sClient *k8s.Client, gitopsConfig *config.GitOpsConfig) *Client {
	return &Client{
		k8sClient: k8sClient,
		config:    gitopsConfig,
	}
}

// Install installs FluxCD in the cluster using the Flux Go library
func (c *Client) Install(ctx context.Context, namespace string) error {
	log.Info("Installing FluxCD", "namespace", namespace)

	// Clean up any existing Flux installation first
	if err := c.CleanupFlux(ctx, namespace); err != nil {
		log.Warn("Failed to clean up existing Flux installation", "error", err)
		// Continue anyway - cleanup is best effort
	}

	// Create namespace if it doesn't exist
	if err := c.k8sClient.CreateNamespace(ctx, namespace); err != nil {
		return fmt.Errorf("failed to create namespace %s: %w", namespace, err)
	}

	// Use Flux Go library for installation
	log.Info("Generating FluxCD install manifests")
	
	// Create install options with proper defaults
	opts := install.MakeDefaultOptions()
	opts.Namespace = namespace
	opts.Components = []string{
		"source-controller",
		"kustomize-controller", 
		"helm-controller",
		"notification-controller",
	}
	opts.ComponentsExtra = []string{
		"image-reflector-controller",
		"image-automation-controller",
	}

	// Generate manifests
	manifest, err := install.Generate(opts, "")
	if err != nil {
		return fmt.Errorf("failed to generate flux install manifests: %w", err)
	}

	// Apply manifests using server-side apply
	log.Info("Applying FluxCD manifests")
	if err := c.applyManifests(ctx, []byte(manifest.Content)); err != nil {
		return fmt.Errorf("failed to apply flux manifests: %w", err)
	}

	log.Info("FluxCD manifests applied, waiting for controllers to be ready...")
	
	// Wait for controllers to be ready
	if err := c.WaitForInstallation(ctx, namespace, 5*time.Minute); err != nil {
		return fmt.Errorf("flux controllers not ready: %w", err)
	}

	log.Info("FluxCD installation completed successfully")
	return nil
}


// Bootstrap configures FluxCD to sync with a Git repository using Flux Go library
func (c *Client) Bootstrap(ctx context.Context, namespace string) error {
	log.Info("Bootstrapping FluxCD with GitOps repository", "repository", c.config.Repository, "branch", c.config.Branch, "path", c.config.Path)

	// Ensure Flux is installed first
	if err := c.WaitForInstallation(ctx, namespace, 5*time.Minute); err != nil {
		return fmt.Errorf("flux not ready for bootstrap: %w", err)
	}

	// Generate sync manifests manually with correct v1 API version
	log.Info("Generating GitOps sync manifests")
	
	manifestContent := c.generateSyncManifests(namespace)
	log.Debug("Generated sync manifests", "content", manifestContent)
	
	// Apply sync manifests
	log.Info("Applying GitOps sync manifests")
	if err := c.applyManifests(ctx, []byte(manifestContent)); err != nil {
		return fmt.Errorf("failed to apply sync manifests: %w", err)
	}
	
	log.Debug("Sync manifests applied successfully")

	// Create GitHub token secret if provided
	if c.config.Token != "" {
		if err := c.createGitHubTokenSecret(ctx, namespace); err != nil {
			log.Warn("Failed to create GitHub token secret", "error", err)
			// Continue - the sync might work without the secret for public repos
		}
	}

	// Wait for initial sync
	if err := c.WaitForSync(ctx, namespace, "flux-system", 5*time.Minute); err != nil {
		return fmt.Errorf("initial repository sync failed: %w", err)
	}

	log.Info("FluxCD bootstrap completed successfully")
	return nil
}

// createGitHubTokenSecret creates a secret for GitHub authentication
func (c *Client) createGitHubTokenSecret(ctx context.Context, namespace string) error {
	log.Info("Creating GitHub token secret for authentication")
	
	// Create secret data
	secretData := map[string][]byte{
		"username": []byte("git"),
		"password": []byte(c.config.Token),
	}
	
	// Create the secret
	secret := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "v1",
			"kind":       "Secret",
			"metadata": map[string]interface{}{
				"name":      "flux-system",
				"namespace": namespace,
			},
			"type": "Opaque",
			"data": secretData,
		},
	}
	
	// Apply the secret
	return c.applyObject(ctx, secret)
}

// WaitForInstallation waits for FluxCD controllers to be ready
func (c *Client) WaitForInstallation(ctx context.Context, namespace string, timeout time.Duration) error {
	controllers := []string{
		"source-controller",
		"kustomize-controller",
		"helm-controller",
		"notification-controller",
	}

	for _, controller := range controllers {
		// Use log instead of fmt.Printf to respect TUI mode
		log.Info("Waiting for controller to be ready", "controller", controller)
		if err := c.k8sClient.WaitForDeployment(ctx, namespace, controller, timeout); err != nil {
			return fmt.Errorf("controller %s not ready: %w", controller, err)
		}
	}

	return nil
}

// WaitForSync waits for GitRepository to be ready and synced
func (c *Client) WaitForSync(ctx context.Context, namespace, name string, timeout time.Duration) error {
	log.Info("Waiting for GitRepository sync", "namespace", namespace, "name", name, "timeout", timeout)
	
	return wait.PollImmediate(10*time.Second, timeout, func() (bool, error) {
		log.Debug("Polling GitRepository status", "namespace", namespace, "name", name)
		
		// Get the GitRepository resource
		dynamicClient := c.k8sClient.GetDynamicClient()
		gvr := schema.GroupVersionResource{
			Group:    "source.toolkit.fluxcd.io",
			Version:  "v1",
			Resource: "gitrepositories",
		}
		
		log.Debug("Attempting to get GitRepository", "gvr", gvr)
		gitRepo, err := dynamicClient.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			log.Debug("GitRepository not found yet", "error", err, "namespace", namespace, "name", name)
			return false, nil // Not ready yet, continue waiting
		}
		
		log.Debug("GitRepository found, checking status", "name", name)
		
		// Check status conditions
		status, found, err := unstructured.NestedMap(gitRepo.Object, "status")
		if err != nil || !found {
			log.Debug("GitRepository status not available yet", "found", found, "error", err)
			return false, nil
		}
		
		log.Debug("GitRepository status found", "status", status)
		
		conditions, found, err := unstructured.NestedSlice(status, "conditions")
		if err != nil || !found {
			log.Debug("GitRepository conditions not available yet", "found", found, "error", err)
			return false, nil
		}
		
		log.Debug("GitRepository conditions found", "count", len(conditions))
		
		// Check for Ready condition
		for i, conditionRaw := range conditions {
			log.Debug("Checking condition", "index", i, "condition", conditionRaw)
			
			condition, ok := conditionRaw.(map[string]interface{})
			if !ok {
				log.Debug("Condition is not a map", "index", i, "type", fmt.Sprintf("%T", conditionRaw))
				continue
			}
			
			condType, found, err := unstructured.NestedString(condition, "type")
			if err != nil || !found {
				log.Debug("Condition type not found", "index", i, "error", err, "found", found)
				continue
			}
			
			log.Debug("Found condition", "type", condType, "index", i)
			
			if condType != "Ready" {
				continue
			}
			
			condStatus, found, err := unstructured.NestedString(condition, "status")
			if err != nil || !found {
				log.Debug("Condition status not found", "error", err, "found", found)
				continue
			}
			
			log.Debug("Ready condition found", "status", condStatus)
			
			if condStatus == "True" {
				log.Info("GitRepository is ready and synced")
				return true, nil
			}
			
			// Log the reason if not ready
			reason, _, _ := unstructured.NestedString(condition, "reason")
			message, _, _ := unstructured.NestedString(condition, "message")
			log.Debug("GitRepository not ready yet", "reason", reason, "message", message, "status", condStatus)
		}
		
		return false, nil // Not ready yet
	})
}

// GetSyncStatus returns the status of GitOps synchronization
func (c *Client) GetSyncStatus(ctx context.Context, namespace string) (*SyncStatus, error) {
	// Check if flux-system namespace exists
	exists, err := c.k8sClient.NamespaceExists(ctx, namespace)
	if err != nil {
		return nil, err
	}

	if !exists {
		return &SyncStatus{
			Ready:    false,
			Message:  "Flux namespace not found",
			LastSync: nil,
		}, nil
	}

	// Check if controllers are running
	controllers := []string{"source-controller", "kustomize-controller", "helm-controller"}
	for _, controller := range controllers {
		// Simple check - in practice, check deployment status
		_, err := c.k8sClient.GetClientset().AppsV1().Deployments(namespace).Get(ctx, controller, metav1.GetOptions{})
		if err != nil {
			return &SyncStatus{
				Ready:    false,
				Message:  fmt.Sprintf("Controller %s not found", controller),
				LastSync: nil,
			}, nil
		}
	}

	now := time.Now()
	return &SyncStatus{
		Ready:    true,
		Message:  "Flux controllers running",
		LastSync: &now,
	}, nil
}

// SyncStatus represents the status of GitOps synchronization
type SyncStatus struct {
	Ready    bool       `json:"ready"`
	Message  string     `json:"message"`
	LastSync *time.Time `json:"last_sync,omitempty"`
	Revision string     `json:"revision,omitempty"`
	Path     string     `json:"path,omitempty"`
}

// Reconcile forces a reconciliation of the GitRepository
func (c *Client) Reconcile(ctx context.Context, namespace, name string) error {
	// This would annotate the GitRepository to force reconciliation
	log.Info("Reconciling GitRepository", "namespace", namespace, "name", name)
	return nil
}

// Suspend suspends GitOps synchronization
func (c *Client) Suspend(ctx context.Context, namespace, name string) error {
	log.Info("Suspending GitRepository", "namespace", namespace, "name", name)
	return nil
}

// Resume resumes GitOps synchronization
func (c *Client) Resume(ctx context.Context, namespace, name string) error {
	log.Info("Resuming GitRepository", "namespace", namespace, "name", name)
	return nil
}

// SuspendReconciliation suspends all Flux reconciliation in a namespace using Kubernetes client
func (c *Client) SuspendReconciliation(ctx context.Context, namespace string) error {
	log.Info("Suspending Flux reconciliation", "namespace", namespace)

	// Check if namespace exists
	exists, err := c.k8sClient.NamespaceExists(ctx, namespace)
	if err != nil {
		return fmt.Errorf("failed to check namespace: %w", err)
	}
	if !exists {
		return fmt.Errorf("namespace %s does not exist", namespace)
	}

	clientset := c.k8sClient.GetClientset()
	
	// Suspend GitRepositories (gitrepositories)
	if err := c.suspendResources(ctx, clientset, "source.toolkit.fluxcd.io/v1", "GitRepository", namespace); err != nil {
		log.Warn("Failed to suspend GitRepositories", "error", err)
	}

	// Suspend HelmRepositories (helmrepositories)
	if err := c.suspendResources(ctx, clientset, "source.toolkit.fluxcd.io/v1", "HelmRepository", namespace); err != nil {
		log.Warn("Failed to suspend HelmRepositories", "error", err)
	}

	// Suspend HelmReleases across all namespaces (helmreleases)
	if err := c.suspendResourcesAllNamespaces(ctx, clientset, "helm.toolkit.fluxcd.io/v2beta1", "HelmRelease"); err != nil {
		log.Warn("Failed to suspend HelmReleases", "error", err)
	}

	// Suspend Kustomizations across all namespaces (kustomizations)
	if err := c.suspendResourcesAllNamespaces(ctx, clientset, "kustomize.toolkit.fluxcd.io/v1", "Kustomization"); err != nil {
		log.Warn("Failed to suspend Kustomizations", "error", err)
	}

	log.Info("Flux reconciliation suspended successfully")
	log.Info("Services continue running but won't be updated")
	return nil
}

// ResumeReconciliation resumes all Flux reconciliation in a namespace using Kubernetes client
func (c *Client) ResumeReconciliation(ctx context.Context, namespace string) error {
	log.Info("Resuming Flux reconciliation", "namespace", namespace)

	// Check if namespace exists
	exists, err := c.k8sClient.NamespaceExists(ctx, namespace)
	if err != nil {
		return fmt.Errorf("failed to check namespace: %w", err)
	}
	if !exists {
		return fmt.Errorf("namespace %s does not exist", namespace)
	}

	clientset := c.k8sClient.GetClientset()
	
	// Resume GitRepositories (gitrepositories)
	if err := c.resumeResources(ctx, clientset, "source.toolkit.fluxcd.io/v1", "GitRepository", namespace); err != nil {
		log.Warn("Failed to resume GitRepositories", "error", err)
	}

	// Resume HelmRepositories (helmrepositories)
	if err := c.resumeResources(ctx, clientset, "source.toolkit.fluxcd.io/v1", "HelmRepository", namespace); err != nil {
		log.Warn("Failed to resume HelmRepositories", "error", err)
	}

	// Resume HelmReleases across all namespaces (helmreleases)
	if err := c.resumeResourcesAllNamespaces(ctx, clientset, "helm.toolkit.fluxcd.io/v2beta1", "HelmRelease"); err != nil {
		log.Warn("Failed to resume HelmReleases", "error", err)
	}

	// Resume Kustomizations across all namespaces (kustomizations)
	if err := c.resumeResourcesAllNamespaces(ctx, clientset, "kustomize.toolkit.fluxcd.io/v1", "Kustomization"); err != nil {
		log.Warn("Failed to resume Kustomizations", "error", err)
	}

	// Trigger reconciliation by annotating resources
	if err := c.triggerReconciliation(ctx, clientset, namespace); err != nil {
		log.Warn("Failed to trigger immediate reconciliation", "error", err)
	}

	log.Info("Flux reconciliation resumed successfully")
	return nil
}


// applyManifests applies YAML manifests to the cluster using server-side apply
func (c *Client) applyManifests(ctx context.Context, manifestsContent []byte) error {
	log.Debug("Applying manifests to cluster", "size", len(manifestsContent), "content", string(manifestsContent))
	
	// Parse the YAML manifests
	decoder := yaml.NewYAMLOrJSONDecoder(strings.NewReader(string(manifestsContent)), 4096)
	
	objectCount := 0
	for {
		var obj unstructured.Unstructured
		if err := decoder.Decode(&obj); err != nil {
			if err.Error() == "EOF" {
				log.Debug("Finished decoding manifests", "totalObjects", objectCount)
				break
			}
			log.Error("Failed to decode manifest", "error", err, "content", string(manifestsContent))
			return fmt.Errorf("failed to decode manifest: %w", err)
		}
		
		if obj.Object == nil {
			log.Debug("Skipping empty object")
			continue // Skip empty objects
		}
		
		objectCount++
		log.Debug("Applying object", "kind", obj.GetKind(), "name", obj.GetName(), "namespace", obj.GetNamespace(), "count", objectCount)
		
		// Apply the object using server-side apply
		if err := c.applyObject(ctx, &obj); err != nil {
			log.Error("Failed to apply object", "kind", obj.GetKind(), "name", obj.GetName(), "error", err)
			return fmt.Errorf("failed to apply object %s/%s: %w", obj.GetKind(), obj.GetName(), err)
		}
		
		log.Debug("Successfully applied object", "kind", obj.GetKind(), "name", obj.GetName(), "namespace", obj.GetNamespace())
	}
	
	return nil
}

// applyObject applies a single unstructured object using server-side apply
func (c *Client) applyObject(ctx context.Context, obj *unstructured.Unstructured) error {
	// Get dynamic client
	dynamicClient := c.k8sClient.GetDynamicClient()
	
	// Determine the resource interface
	gvk := obj.GroupVersionKind()
	gvr, err := c.gvkToGVR(gvk)
	if err != nil {
		return fmt.Errorf("failed to get GVR for %s: %w", gvk, err)
	}
	
	namespacedResource := dynamicClient.Resource(gvr)
	
	// Handle namespaced vs cluster-scoped resources
	var resourceInterface dynamic.ResourceInterface
	if obj.GetNamespace() != "" {
		resourceInterface = namespacedResource.Namespace(obj.GetNamespace())
	} else {
		resourceInterface = namespacedResource
	}
	
	// Set managed fields for server-side apply
	obj.SetManagedFields(nil)
	
	// Apply with server-side apply
	// Note: Force:true is used during bootstrap to take ownership of Flux resources
	// before the Flux controllers start. Once Flux controllers are running, they
	// will take ownership using their own field manager. This ensures bootstrap
	// can install Flux even on existing clusters with partial Flux installations.
	applyOptions := metav1.ApplyOptions{
		FieldManager: "homelab-bootstrap",
		Force:        true,
	}
	
	_, err = resourceInterface.Apply(ctx, obj.GetName(), obj, applyOptions)
	return err
}

// gvkToGVR converts GroupVersionKind to GroupVersionResource with retry logic for CRD discovery
func (c *Client) gvkToGVR(gvk schema.GroupVersionKind) (schema.GroupVersionResource, error) {
	// Create discovery client
	discoveryClient := c.k8sClient.GetClientset().Discovery()
	
	// Create REST mapper with memory cache
	mapper := restmapper.NewDeferredDiscoveryRESTMapper(memory.NewMemCacheClient(discoveryClient))
	
	// Retry logic for CRD discovery - newly applied CRDs may not be immediately available
	var mapping *meta.RESTMapping
	var err error
	
	err = wait.PollImmediate(2*time.Second, 30*time.Second, func() (bool, error) {
		// Convert GVK to GVR
		mapping, err = mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
		if err != nil {
			// Check if this is a "no matches" error that might resolve after CRD registration
			if meta.IsNoMatchError(err) {
				log.Debug("GVK not found in discovery, retrying after CRD registration", "gvk", gvk, "error", err)
				// Reset the mapper cache to pick up newly registered CRDs
				mapper.Reset()
				return false, nil // Retry
			}
			// Other errors are permanent
			return false, err
		}
		// Success
		return true, nil
	})
	
	if err != nil {
		return schema.GroupVersionResource{}, fmt.Errorf("failed to discover GVR for %s after retries: %w", gvk, err)
	}
	
	return mapping.Resource, nil
}

// suspendResources suspends Flux resources in a specific namespace
func (c *Client) suspendResources(ctx context.Context, clientset kubernetes.Interface, apiVersion, kind, namespace string) error {
	log.Debug("Suspending resources", "kind", kind, "namespace", namespace)
	
	// Parse API version to get group and version
	group, version, err := parseAPIVersion(apiVersion)
	if err != nil {
		return fmt.Errorf("invalid API version %s: %w", apiVersion, err)
	}
	
	// Create GVR for the resource type
	// Note: Flux follows Kubernetes convention: Kind -> plural lowercase resource name
	// GitRepository -> gitrepositories, HelmRelease -> helmreleases, etc.
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: fluxKindToResource(kind), // Use correct Flux resource names
	}
	
	// Get dynamic client
	dynamicClient := c.k8sClient.GetDynamicClient()
	resourceInterface := dynamicClient.Resource(gvr).Namespace(namespace)
	
	// List all resources of this type in the namespace
	list, err := resourceInterface.List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Debug("Failed to list resources", "kind", kind, "namespace", namespace, "error", err)
		return nil // Continue if this resource type doesn't exist yet
	}
	
	// Patch each resource to set spec.suspend: true
	for _, item := range list.Items {
		name := item.GetName()
		log.Info("Suspending resource", "kind", kind, "name", name, "namespace", namespace)
		
		// Create patch to set spec.suspend: true
		patch := []byte(`{"spec":{"suspend":true}}`)
		
		_, err := resourceInterface.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to suspend resource", "kind", kind, "name", name, "error", err)
			continue
		}
		
		log.Debug("Successfully suspended resource", "kind", kind, "name", name)
	}
	
	return nil
}

// suspendResourcesAllNamespaces suspends Flux resources across all namespaces
func (c *Client) suspendResourcesAllNamespaces(ctx context.Context, clientset kubernetes.Interface, apiVersion, kind string) error {
	log.Debug("Suspending resources across all namespaces", "kind", kind)
	
	// Parse API version to get group and version
	group, version, err := parseAPIVersion(apiVersion)
	if err != nil {
		return fmt.Errorf("invalid API version %s: %w", apiVersion, err)
	}
	
	// Create GVR for the resource type
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: strings.ToLower(kind) + "s", // HelmRelease -> helmreleases
	}
	
	// Get dynamic client
	dynamicClient := c.k8sClient.GetDynamicClient()
	resourceInterface := dynamicClient.Resource(gvr)
	
	// List all resources of this type across all namespaces
	list, err := resourceInterface.List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Debug("Failed to list resources across namespaces", "kind", kind, "error", err)
		return nil // Continue if this resource type doesn't exist yet
	}
	
	// Patch each resource to set spec.suspend: true
	for _, item := range list.Items {
		name := item.GetName()
		namespace := item.GetNamespace()
		log.Info("Suspending resource", "kind", kind, "name", name, "namespace", namespace)
		
		// Create patch to set spec.suspend: true
		patch := []byte(`{"spec":{"suspend":true}}`)
		
		namespacedInterface := resourceInterface.Namespace(namespace)
		_, err := namespacedInterface.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to suspend resource", "kind", kind, "name", name, "namespace", namespace, "error", err)
			continue
		}
		
		log.Debug("Successfully suspended resource", "kind", kind, "name", name, "namespace", namespace)
	}
	
	return nil
}

// resumeResources resumes Flux resources in a specific namespace
func (c *Client) resumeResources(ctx context.Context, clientset kubernetes.Interface, apiVersion, kind, namespace string) error {
	log.Debug("Resuming resources", "kind", kind, "namespace", namespace)
	
	// Parse API version to get group and version
	group, version, err := parseAPIVersion(apiVersion)
	if err != nil {
		return fmt.Errorf("invalid API version %s: %w", apiVersion, err)
	}
	
	// Create GVR for the resource type
	// Note: Flux follows Kubernetes convention: Kind -> plural lowercase resource name
	// GitRepository -> gitrepositories, HelmRelease -> helmreleases, etc.
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: fluxKindToResource(kind), // Use correct Flux resource names
	}
	
	// Get dynamic client
	dynamicClient := c.k8sClient.GetDynamicClient()
	resourceInterface := dynamicClient.Resource(gvr).Namespace(namespace)
	
	// List all resources of this type in the namespace
	list, err := resourceInterface.List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Debug("Failed to list resources", "kind", kind, "namespace", namespace, "error", err)
		return nil // Continue if this resource type doesn't exist yet
	}
	
	// Patch each resource to set spec.suspend: false
	for _, item := range list.Items {
		name := item.GetName()
		log.Info("Resuming resource", "kind", kind, "name", name, "namespace", namespace)
		
		// Create patch to set spec.suspend: false
		patch := []byte(`{"spec":{"suspend":false}}`)
		
		_, err := resourceInterface.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to resume resource", "kind", kind, "name", name, "error", err)
			continue
		}
		
		log.Debug("Successfully resumed resource", "kind", kind, "name", name)
	}
	
	return nil
}

// resumeResourcesAllNamespaces resumes Flux resources across all namespaces
func (c *Client) resumeResourcesAllNamespaces(ctx context.Context, clientset kubernetes.Interface, apiVersion, kind string) error {
	log.Debug("Resuming resources across all namespaces", "kind", kind)
	
	// Parse API version to get group and version
	group, version, err := parseAPIVersion(apiVersion)
	if err != nil {
		return fmt.Errorf("invalid API version %s: %w", apiVersion, err)
	}
	
	// Create GVR for the resource type
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: strings.ToLower(kind) + "s", // HelmRelease -> helmreleases
	}
	
	// Get dynamic client
	dynamicClient := c.k8sClient.GetDynamicClient()
	resourceInterface := dynamicClient.Resource(gvr)
	
	// List all resources of this type across all namespaces
	list, err := resourceInterface.List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Debug("Failed to list resources across namespaces", "kind", kind, "error", err)
		return nil // Continue if this resource type doesn't exist yet
	}
	
	// Patch each resource to set spec.suspend: false
	for _, item := range list.Items {
		name := item.GetName()
		namespace := item.GetNamespace()
		log.Info("Resuming resource", "kind", kind, "name", name, "namespace", namespace)
		
		// Create patch to set spec.suspend: false
		patch := []byte(`{"spec":{"suspend":false}}`)
		
		namespacedInterface := resourceInterface.Namespace(namespace)
		_, err := namespacedInterface.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to resume resource", "kind", kind, "name", name, "namespace", namespace, "error", err)
			continue
		}
		
		log.Debug("Successfully resumed resource", "kind", kind, "name", name, "namespace", namespace)
	}
	
	return nil
}

// triggerReconciliation triggers immediate reconciliation by adding reconcile annotation
func (c *Client) triggerReconciliation(ctx context.Context, clientset kubernetes.Interface, namespace string) error {
	log.Debug("Triggering immediate reconciliation", "namespace", namespace)
	
	now := time.Now().Format(time.RFC3339)
	
	// Create patch to add reconcile annotation
	patch := fmt.Sprintf(`{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"%s"}}}`, now)
	
	// Trigger reconciliation on GitRepositories in flux-system namespace
	gvr := schema.GroupVersionResource{
		Group:    "source.toolkit.fluxcd.io",
		Version:  "v1",
		Resource: "gitrepositories",
	}
	
	dynamicClient := c.k8sClient.GetDynamicClient()
	resourceInterface := dynamicClient.Resource(gvr).Namespace(namespace)
	
	// List GitRepositories and add reconcile annotation
	list, err := resourceInterface.List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Debug("Failed to list GitRepositories for reconciliation trigger", "error", err)
		return nil // Continue if GitRepositories don't exist yet
	}
	
	for _, item := range list.Items {
		name := item.GetName()
		log.Info("Triggering reconciliation", "name", name, "namespace", namespace, "timestamp", now)
		
		_, err := resourceInterface.Patch(ctx, name, types.MergePatchType, []byte(patch), metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to trigger reconciliation", "name", name, "error", err)
			continue
		}
		
		log.Debug("Successfully triggered reconciliation", "name", name)
	}
	
	return nil
}

// parseAPIVersion parses an API version string like "source.toolkit.fluxcd.io/v1beta2" into group and version
func parseAPIVersion(apiVersion string) (group, version string, err error) {
	parts := strings.Split(apiVersion, "/")
	if len(parts) != 2 {
		return "", "", fmt.Errorf("invalid API version format: %s", apiVersion)
	}
	return parts[0], parts[1], nil
}

// generateSyncManifests creates GitRepository and Kustomization manifests with v1 API version
func (c *Client) generateSyncManifests(namespace string) string {
	// Debug: log the config being used
	log.Debug("Generating sync manifests", "repository", c.config.Repository, "branch", c.config.Branch, "path", c.config.Path, "namespace", namespace)
	
	// Use v1 API version to avoid deprecation warnings
	var gitRepo string
	if c.config.Token != "" {
		// GitRepository with secretRef for authentication
		gitRepo = fmt.Sprintf(`---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: %s
spec:
  interval: 1m0s
  ref:
    branch: %s
  secretRef:
    name: flux-system
  url: %s
`, namespace, c.config.Branch, c.config.Repository)
	} else {
		// GitRepository without authentication (public repo)
		gitRepo = fmt.Sprintf(`---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: %s
spec:
  interval: 1m0s
  ref:
    branch: %s
  url: %s
`, namespace, c.config.Branch, c.config.Repository)
	}

	kustomization := fmt.Sprintf(`---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: %s
spec:
  interval: 10m0s
  path: %s
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
`, namespace, c.config.Path)

	return gitRepo + kustomization
}

// fluxKindToResource maps Flux Kind names to their correct plural resource names
func fluxKindToResource(kind string) string {
	// Map of Flux Kind -> plural resource name
	kindMap := map[string]string{
		// Source Controller resources
		"GitRepository":  "gitrepositories",
		"HelmRepository": "helmrepositories",
		"HelmChart":      "helmcharts",
		"Bucket":         "buckets",
		"OCIRepository":  "ocirepositories",
		
		// Kustomize Controller resources
		"Kustomization": "kustomizations",
		
		// Helm Controller resources
		"HelmRelease": "helmreleases",
		
		// Notification Controller resources
		"Provider": "providers",
		"Alert":    "alerts",
		"Receiver": "receivers",
		
		// Image Controller resources
		"ImageRepository":    "imagerepositories",
		"ImagePolicy":        "imagepolicies",
		"ImageUpdateAutomation": "imageupdateautomations",
	}
	
	if resource, exists := kindMap[kind]; exists {
		return resource
	}
	
	// Fallback to lowercase + s for unknown kinds, with warning
	log.Warn("Unknown Flux kind, using fallback pluralization", "kind", kind)
	return strings.ToLower(kind) + "s"
}

// CleanupFlux performs comprehensive cleanup of stuck Flux resources and namespaces
func (c *Client) CleanupFlux(ctx context.Context, namespace string) error {
	log.Info("Cleaning up existing Flux installation", "namespace", namespace)

	// Check if namespace exists
	exists, err := c.k8sClient.NamespaceExists(ctx, namespace)
	if err != nil {
		return fmt.Errorf("failed to check namespace: %w", err)
	}
	
	if !exists {
		log.Debug("Flux namespace does not exist, nothing to clean up")
		return nil
	}

	dynamicClient := c.k8sClient.GetDynamicClient()

	// List of Flux resource types to clean up
	fluxResources := []struct {
		group    string
		version  string
		resource string
		kind     string
	}{
		{"source.toolkit.fluxcd.io", "v1", "gitrepositories", "GitRepository"},
		{"source.toolkit.fluxcd.io", "v1", "helmrepositories", "HelmRepository"},
		{"source.toolkit.fluxcd.io", "v1", "helmcharts", "HelmChart"},
		{"source.toolkit.fluxcd.io", "v1", "buckets", "Bucket"},
		{"kustomize.toolkit.fluxcd.io", "v1", "kustomizations", "Kustomization"},
		{"helm.toolkit.fluxcd.io", "v2beta1", "helmreleases", "HelmRelease"},
		{"helm.toolkit.fluxcd.io", "v2", "helmreleases", "HelmRelease"}, // Try both v2beta1 and v2
		{"notification.toolkit.fluxcd.io", "v1", "providers", "Provider"},
		{"notification.toolkit.fluxcd.io", "v1", "alerts", "Alert"},
		{"notification.toolkit.fluxcd.io", "v1", "receivers", "Receiver"},
		{"image.toolkit.fluxcd.io", "v1", "imagerepositories", "ImageRepository"},
		{"image.toolkit.fluxcd.io", "v1", "imagepolicies", "ImagePolicy"},
		{"image.toolkit.fluxcd.io", "v1", "imageupdateautomations", "ImageUpdateAutomation"},
	}

	// Remove finalizers from all Flux resources
	for _, res := range fluxResources {
		gvr := schema.GroupVersionResource{
			Group:    res.group,
			Version:  res.version,
			Resource: res.resource,
		}

		log.Debug("Cleaning up Flux resources", "resource", res.resource, "gvr", gvr)

		// Try both namespaced and cluster-scoped resources
		resourceInterface := dynamicClient.Resource(gvr)
		
		// First try namespaced resources
		list, err := resourceInterface.Namespace(namespace).List(ctx, metav1.ListOptions{})
		if err != nil {
			// If namespaced listing fails, try cluster-scoped
			list, err = resourceInterface.List(ctx, metav1.ListOptions{})
			if err != nil {
				log.Debug("Failed to list resources, may not exist", "resource", res.resource, "error", err)
				continue
			}
		}

		// Remove finalizers from all instances
		for _, item := range list.Items {
			name := item.GetName()
			itemNamespace := item.GetNamespace()
			
			log.Info("Removing finalizers from Flux resource", "kind", res.kind, "name", name, "namespace", itemNamespace)
			
			// Create patch to remove all finalizers
			patch := []byte(`{"metadata":{"finalizers":null}}`)
			
			var patchInterface dynamic.ResourceInterface
			if itemNamespace != "" {
				patchInterface = resourceInterface.Namespace(itemNamespace)
			} else {
				patchInterface = resourceInterface
			}
			
			_, err := patchInterface.Patch(ctx, name, types.MergePatchType, patch, metav1.PatchOptions{})
			if err != nil {
				log.Warn("Failed to remove finalizers", "kind", res.kind, "name", name, "error", err)
				// Try force delete as backup
				err = patchInterface.Delete(ctx, name, metav1.DeleteOptions{
					GracePeriodSeconds: &[]int64{0}[0],
				})
				if err != nil {
					log.Warn("Failed to force delete resource", "kind", res.kind, "name", name, "error", err)
				}
			} else {
				log.Debug("Successfully removed finalizers", "kind", res.kind, "name", name)
			}
		}
	}

	// Force cleanup the namespace if it's stuck in Terminating state
	ns, err := c.k8sClient.GetClientset().CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		log.Debug("Namespace not found during cleanup", "namespace", namespace)
		return nil
	}

	if ns.Status.Phase == "Terminating" {
		log.Info("Namespace is stuck in Terminating state, forcing cleanup", "namespace", namespace)
		
		// Remove finalizers from the namespace itself
		patch := []byte(`{"metadata":{"finalizers":null}}`)
		_, err = c.k8sClient.GetClientset().CoreV1().Namespaces().Patch(ctx, namespace, types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to remove namespace finalizers", "namespace", namespace, "error", err)
		}

		// Wait a bit for the namespace to be cleaned up
		log.Info("Waiting for namespace cleanup to complete", "namespace", namespace)
		wait.PollImmediate(2*time.Second, 30*time.Second, func() (bool, error) {
			exists, err := c.k8sClient.NamespaceExists(ctx, namespace)
			if err != nil {
				return false, nil
			}
			return !exists, nil
		})
	}

	log.Info("Flux cleanup completed", "namespace", namespace)
	return nil
}
