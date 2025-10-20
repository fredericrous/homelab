package destroy

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/charmbracelet/log"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

// NamespaceCleanup handles aggressive namespace cleanup for stuck namespaces
type NamespaceCleanup struct {
	client        kubernetes.Interface
	dynamicClient dynamic.Interface
}

// NewNamespaceCleanup creates a new NamespaceCleanup
func NewNamespaceCleanup(client kubernetes.Interface, dynamicClient dynamic.Interface) *NamespaceCleanup {
	return &NamespaceCleanup{
		client:        client,
		dynamicClient: dynamicClient,
	}
}

// ForceCleanupTerminatingNamespaces cleans up all terminating namespaces
func (nc *NamespaceCleanup) ForceCleanupTerminatingNamespaces(ctx context.Context) error {
	log.Info("🔧 Starting aggressive namespace cleanup...")

	// Get all terminating namespaces
	namespaces, err := nc.client.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list namespaces: %w", err)
	}

	var terminatingNamespaces []string
	for _, ns := range namespaces.Items {
		if ns.Status.Phase == "Terminating" {
			terminatingNamespaces = append(terminatingNamespaces, ns.Name)
		}
	}

	if len(terminatingNamespaces) == 0 {
		log.Info("No terminating namespaces found")
	} else {
		log.Info("Found terminating namespaces", "count", len(terminatingNamespaces), "namespaces", terminatingNamespaces)
		for _, ns := range terminatingNamespaces {
			if err := nc.forceDeleteNamespace(ctx, ns); err != nil {
				log.Warn("Failed to force delete namespace", "namespace", ns, "error", err)
			}
		}
	}

	// Special handling for flux-system if it exists
	if nc.namespaceExists(ctx, "flux-system") {
		log.Info("🔧 flux-system namespace found, forcing deletion...")
		if err := nc.forceDeleteNamespace(ctx, "flux-system"); err != nil {
			log.Warn("Failed to force delete flux-system", "error", err)
		}
	}

	// Final verification
	time.Sleep(2 * time.Second)
	log.Info("Checking final namespace status...")

	finalNamespaces, err := nc.client.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list final namespaces: %w", err)
	}

	remainingTerminating := 0
	for _, ns := range finalNamespaces.Items {
		if ns.Status.Phase == "Terminating" {
			remainingTerminating++
			log.Warn("Namespace still terminating", "namespace", ns.Name)
		}
	}

	if remainingTerminating > 0 {
		log.Warn("Still have terminating namespaces", "count", remainingTerminating)
		log.Warn("You may need to restart the kube-apiserver or check for webhook issues")
	} else {
		log.Info("✅ All namespaces cleaned up successfully!")
	}

	return nil
}

// forceDeleteNamespace performs aggressive cleanup of a single namespace
func (nc *NamespaceCleanup) forceDeleteNamespace(ctx context.Context, namespace string) error {
	log.Info("Force deleting namespace", "namespace", namespace)

	// Step 1: Delete all resources in the namespace
	log.Info("Deleting all resources", "namespace", namespace)
	if err := nc.deleteAllResourcesInNamespace(ctx, namespace); err != nil {
		log.Warn("Failed to delete all resources", "namespace", namespace, "error", err)
	}

	// Step 2: Patch all resources to remove finalizers
	log.Info("Removing finalizers from all resources", "namespace", namespace)
	if err := nc.removeAllFinalizersInNamespace(ctx, namespace); err != nil {
		log.Warn("Failed to remove finalizers", "namespace", namespace, "error", err)
	}

	// Step 3: Remove namespace finalizers
	log.Info("Removing namespace finalizers", "namespace", namespace)
	patch := []byte(`{"metadata":{"finalizers":null}}`)
	_, err := nc.client.CoreV1().Namespaces().Patch(
		ctx, namespace, types.MergePatchType, patch, metav1.PatchOptions{})
	if err != nil {
		log.Warn("Failed to patch namespace finalizers", "namespace", namespace, "error", err)
	}

	// Step 4: Force finalize via API
	log.Info("Force finalizing namespace via API", "namespace", namespace)
	if err := nc.finalizeNamespaceViaAPI(ctx, namespace); err != nil {
		log.Warn("Failed to finalize via API", "namespace", namespace, "error", err)
	}

	return nil
}

func (nc *NamespaceCleanup) deleteAllResourcesInNamespace(ctx context.Context, namespace string) error {
	// Get all API resources
	apiGroups, err := nc.client.Discovery().ServerGroups()
	if err != nil {
		return err
	}

	gracePeriod := int64(0)
	deletePolicy := metav1.DeletePropagationForeground

	for _, group := range apiGroups.Groups {
		for _, version := range group.Versions {
			resourceList, err := nc.client.Discovery().ServerResourcesForGroupVersion(version.GroupVersion)
			if err != nil {
				continue
			}

			for _, resource := range resourceList.APIResources {
				if !resource.Namespaced || !contains(resource.Verbs, "delete") || !contains(resource.Verbs, "list") {
					continue
				}

				gv, err := schema.ParseGroupVersion(version.GroupVersion)
				if err != nil {
					continue
				}

				gvr := schema.GroupVersionResource{
					Group:    gv.Group,
					Version:  gv.Version,
					Resource: resource.Name,
				}

				// Force delete all resources of this type
				err = nc.dynamicClient.Resource(gvr).Namespace(namespace).DeleteCollection(ctx, metav1.DeleteOptions{
					PropagationPolicy:  &deletePolicy,
					GracePeriodSeconds: &gracePeriod,
				}, metav1.ListOptions{})
				if err != nil {
					// Ignore errors, best effort
					continue
				}
			}
		}
	}

	return nil
}

func (nc *NamespaceCleanup) removeAllFinalizersInNamespace(ctx context.Context, namespace string) error {
	// Get all API resources
	apiGroups, err := nc.client.Discovery().ServerGroups()
	if err != nil {
		return err
	}

	for _, group := range apiGroups.Groups {
		for _, version := range group.Versions {
			resourceList, err := nc.client.Discovery().ServerResourcesForGroupVersion(version.GroupVersion)
			if err != nil {
				continue
			}

			for _, resource := range resourceList.APIResources {
				if !resource.Namespaced || !contains(resource.Verbs, "patch") || !contains(resource.Verbs, "list") {
					continue
				}

				gv, err := schema.ParseGroupVersion(version.GroupVersion)
				if err != nil {
					continue
				}

				gvr := schema.GroupVersionResource{
					Group:    gv.Group,
					Version:  gv.Version,
					Resource: resource.Name,
				}

				// Get all resources and remove finalizers
				resources, err := nc.dynamicClient.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
				if err != nil {
					continue
				}

				for _, item := range resources.Items {
					// Remove finalizers using JSON patch to handle edge cases better
					patch := []byte(`[{"op": "remove", "path": "/metadata/finalizers"}]`)
					_, err := nc.dynamicClient.Resource(gvr).Namespace(namespace).Patch(
						ctx, item.GetName(), types.JSONPatchType, patch, metav1.PatchOptions{})
					if err != nil {
						// Try merge patch as fallback
						mergePatch := []byte(`{"metadata":{"finalizers":null}}`)
						_, err := nc.dynamicClient.Resource(gvr).Namespace(namespace).Patch(
							ctx, item.GetName(), types.MergePatchType, mergePatch, metav1.PatchOptions{})
						if err != nil {
							// Ignore errors, best effort
							continue
						}
					}
				}
			}
		}
	}

	return nil
}

func (nc *NamespaceCleanup) finalizeNamespaceViaAPI(ctx context.Context, namespace string) error {
	// Get the namespace
	ns, err := nc.client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		return nil // Already gone
	}

	// Create finalize request
	finalizeNS := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"kind":       "Namespace",
			"apiVersion": "v1",
			"metadata": map[string]interface{}{
				"name":       ns.Name,
				"finalizers": []interface{}{},
			},
			"spec":   map[string]interface{}{},
			"status": map[string]interface{}{},
		},
	}

	finalizeData, err := json.Marshal(finalizeNS.Object)
	if err != nil {
		return err
	}

	// Use raw client to finalize
	result := nc.client.CoreV1().RESTClient().Put().
		AbsPath(fmt.Sprintf("/api/v1/namespaces/%s/finalize", namespace)).
		Body(finalizeData).
		Do(ctx)

	return result.Error()
}

func (nc *NamespaceCleanup) namespaceExists(ctx context.Context, namespace string) bool {
	_, err := nc.client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	return err == nil
}
