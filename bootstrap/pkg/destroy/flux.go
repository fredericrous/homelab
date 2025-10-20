package destroy

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

// FluxDestroyer handles FluxCD resource cleanup
type FluxDestroyer struct {
	client        kubernetes.Interface
	dynamicClient dynamic.Interface
}

// NewFluxDestroyer creates a new FluxDestroyer
func NewFluxDestroyer(client kubernetes.Interface, dynamicClient dynamic.Interface) *FluxDestroyer {
	return &FluxDestroyer{
		client:        client,
		dynamicClient: dynamicClient,
	}
}

// Destroy performs complete FluxCD cleanup
func (fd *FluxDestroyer) Destroy(ctx context.Context, namespace string) error {
	log.Info("🗑️ Starting FluxCD destruction process", "namespace", namespace)

	// Check if flux-system namespace exists
	if !fd.namespaceExists(ctx, namespace) {
		log.Info("FluxCD is not installed", "namespace", namespace)
		return nil
	}

	// Step 1: Suspend all Flux reconciliations
	if err := fd.suspendReconciliations(ctx, namespace); err != nil {
		log.Warn("Failed to suspend reconciliations", "error", err)
		// Continue anyway
	}

	// Step 2: Delete kustomizations in reverse order
	if err := fd.deleteKustomizations(ctx, namespace); err != nil {
		log.Warn("Failed to delete kustomizations", "error", err)
		// Continue anyway
	}

	// Step 3: Clean up Rook-Ceph resources
	if err := fd.cleanupRookCeph(ctx); err != nil {
		log.Warn("Failed to cleanup Rook-Ceph", "error", err)
		// Continue anyway
	}

	// Step 4: Clean up all non-system namespaces
	if err := fd.cleanupNamespaces(ctx); err != nil {
		log.Warn("Failed to cleanup namespaces", "error", err)
		// Continue anyway
	}

	// Step 5: Clean up PersistentVolumes
	if err := fd.cleanupPersistentVolumes(ctx); err != nil {
		log.Warn("Failed to cleanup persistent volumes", "error", err)
		// Continue anyway
	}

	// Step 6: Clean up CRDs
	if err := fd.cleanupCRDs(ctx); err != nil {
		log.Warn("Failed to cleanup CRDs", "error", err)
		// Continue anyway
	}

	// Step 7: Force cleanup flux-system namespace
	if err := fd.forceCleanupFluxNamespace(ctx, namespace); err != nil {
		log.Warn("Failed to force cleanup flux namespace", "error", err)
		// Continue anyway
	}

	log.Info("✅ FluxCD destruction completed", "namespace", namespace)
	return nil
}

func (fd *FluxDestroyer) namespaceExists(ctx context.Context, namespace string) bool {
	_, err := fd.client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	return err == nil
}

func (fd *FluxDestroyer) suspendReconciliations(ctx context.Context, namespace string) error {
	log.Info("⏸️ Suspending Flux reconciliations", "namespace", namespace)

	// Suspend GitRepositories
	if err := fd.suspendResources(ctx, namespace, "source.toolkit.fluxcd.io", "v1", "gitrepositories"); err != nil {
		log.Warn("Failed to suspend GitRepositories", "error", err)
	}

	// Suspend HelmRepositories
	if err := fd.suspendResources(ctx, namespace, "source.toolkit.fluxcd.io", "v1beta2", "helmrepositories"); err != nil {
		log.Warn("Failed to suspend HelmRepositories", "error", err)
	}

	// Suspend HelmReleases
	if err := fd.suspendResources(ctx, namespace, "helm.toolkit.fluxcd.io", "v2beta1", "helmreleases"); err != nil {
		log.Warn("Failed to suspend HelmReleases", "error", err)
	}

	// Suspend Kustomizations
	if err := fd.suspendResources(ctx, namespace, "kustomize.toolkit.fluxcd.io", "v1", "kustomizations"); err != nil {
		log.Warn("Failed to suspend Kustomizations", "error", err)
	}

	// Wait for reconciliations to stop
	log.Info("⏳ Waiting for reconciliations to stop...")
	time.Sleep(5 * time.Second)

	return nil
}

func (fd *FluxDestroyer) suspendResources(ctx context.Context, namespace, group, version, resource string) error {
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: resource,
	}

	resources, err := fd.dynamicClient.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		// Resource type might not exist
		return nil
	}

	for _, item := range resources.Items {
		patch := map[string]interface{}{
			"spec": map[string]interface{}{
				"suspend": true,
			},
		}

		patchData, err := json.Marshal(patch)
		if err != nil {
			continue
		}

		_, err = fd.dynamicClient.Resource(gvr).Namespace(namespace).Patch(
			ctx, item.GetName(), types.MergePatchType, patchData, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to suspend resource", "resource", item.GetName(), "error", err)
		}
	}

	return nil
}

func (fd *FluxDestroyer) deleteKustomizations(ctx context.Context, namespace string) error {
	log.Info("🗑️ Deleting Kustomizations in reverse order", "namespace", namespace)

	gvr := schema.GroupVersionResource{
		Group:    "kustomize.toolkit.fluxcd.io",
		Version:  "v1",
		Resource: "kustomizations",
	}

	// Delete in reverse dependency order
	kustomizationOrder := []string{"apps", "infrastructure", "infrastructure-core"}

	deletePolicy := metav1.DeletePropagationBackground
	for _, name := range kustomizationOrder {
		log.Info("Deleting kustomization", "name", name)
		err := fd.dynamicClient.Resource(gvr).Namespace(namespace).Delete(ctx, name, metav1.DeleteOptions{
			PropagationPolicy: &deletePolicy,
		})
		if err != nil {
			log.Warn("Failed to delete kustomization", "name", name, "error", err)
		}
	}

	// Delete any remaining kustomizations
	err := fd.dynamicClient.Resource(gvr).Namespace(namespace).DeleteCollection(ctx, metav1.DeleteOptions{
		PropagationPolicy: &deletePolicy,
	}, metav1.ListOptions{})
	if err != nil {
		log.Warn("Failed to delete remaining kustomizations", "error", err)
	}

	return nil
}

func (fd *FluxDestroyer) cleanupRookCeph(ctx context.Context) error {
	log.Info("🗑️ Cleaning up Rook-Ceph resources")

	rookNamespace := "rook-ceph"
	if !fd.namespaceExists(ctx, rookNamespace) {
		log.Info("Rook-Ceph namespace not found, skipping cleanup")
		return nil
	}

	// Step 1: Remove finalizers from dependent resources
	log.Info("Removing finalizers from Ceph dependent resources")

	cephResources := []struct {
		group    string
		version  string
		resource string
	}{
		{"ceph.rook.io", "v1", "cephblockpools"},
		{"ceph.rook.io", "v1", "cephfilesystems"},
		{"ceph.rook.io", "v1", "cephobjectstores"},
	}

	for _, res := range cephResources {
		if err := fd.removeFinalizers(ctx, rookNamespace, res.group, res.version, res.resource); err != nil {
			log.Warn("Failed to remove finalizers", "resource", res.resource, "error", err)
		}
		if err := fd.forceDeleteResources(ctx, rookNamespace, res.group, res.version, res.resource); err != nil {
			log.Warn("Failed to force delete", "resource", res.resource, "error", err)
		}
	}

	// Wait for dependent resources to be removed
	time.Sleep(5 * time.Second)

	// Step 2: Remove finalizers from CephCluster and delete
	log.Info("Removing finalizers from CephCluster")
	if err := fd.removeFinalizers(ctx, rookNamespace, "ceph.rook.io", "v1", "cephclusters"); err != nil {
		log.Warn("Failed to remove CephCluster finalizers", "error", err)
	}
	if err := fd.forceDeleteResources(ctx, rookNamespace, "ceph.rook.io", "v1", "cephclusters"); err != nil {
		log.Warn("Failed to force delete CephCluster", "error", err)
	}

	// Step 3: Clean up OSD prepare jobs and pods
	log.Info("Cleaning up stuck OSD prepare jobs")
	deletePolicy := metav1.DeletePropagationForeground
	gracePeriod := int64(0)

	// Delete jobs
	err := fd.client.BatchV1().Jobs(rookNamespace).DeleteCollection(ctx, metav1.DeleteOptions{
		PropagationPolicy:  &deletePolicy,
		GracePeriodSeconds: &gracePeriod,
	}, metav1.ListOptions{})
	if err != nil {
		log.Warn("Failed to delete jobs", "error", err)
	}

	// Delete OSD prepare pods
	err = fd.client.CoreV1().Pods(rookNamespace).DeleteCollection(ctx, metav1.DeleteOptions{
		PropagationPolicy:  &deletePolicy,
		GracePeriodSeconds: &gracePeriod,
	}, metav1.ListOptions{
		LabelSelector: "app=rook-ceph-osd-prepare",
	})
	if err != nil {
		log.Warn("Failed to delete OSD prepare pods", "error", err)
	}

	return nil
}

func (fd *FluxDestroyer) removeFinalizers(ctx context.Context, namespace, group, version, resource string) error {
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: resource,
	}

	resources, err := fd.dynamicClient.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}

	for _, item := range resources.Items {
		// Remove finalizers
		patch := []byte(`{"metadata":{"finalizers":[]}}`)
		_, err := fd.dynamicClient.Resource(gvr).Namespace(namespace).Patch(
			ctx, item.GetName(), types.MergePatchType, patch, metav1.PatchOptions{})
		if err != nil {
			log.Warn("Failed to remove finalizers", "resource", item.GetName(), "error", err)
		}
	}

	return nil
}

func (fd *FluxDestroyer) forceDeleteResources(ctx context.Context, namespace, group, version, resource string) error {
	gvr := schema.GroupVersionResource{
		Group:    group,
		Version:  version,
		Resource: resource,
	}

	deletePolicy := metav1.DeletePropagationForeground
	gracePeriod := int64(0)

	err := fd.dynamicClient.Resource(gvr).Namespace(namespace).DeleteCollection(ctx, metav1.DeleteOptions{
		PropagationPolicy:  &deletePolicy,
		GracePeriodSeconds: &gracePeriod,
	}, metav1.ListOptions{})

	return err
}

func (fd *FluxDestroyer) cleanupNamespaces(ctx context.Context) error {
	log.Info("🗑️ Cleaning up resources in all non-system namespaces")

	namespaces, err := fd.client.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list namespaces: %w", err)
	}

	systemNamespaces := []string{"kube-system", "kube-public", "kube-node-lease", "default"}

	for _, ns := range namespaces.Items {
		nsName := ns.Name

		// Skip system namespaces
		if contains(systemNamespaces, nsName) {
			continue
		}

		log.Info("Cleaning namespace", "namespace", nsName)

		// Force delete all pods first
		gracePeriod := int64(0)
		deletePolicy := metav1.DeletePropagationForeground

		err := fd.client.CoreV1().Pods(nsName).DeleteCollection(ctx, metav1.DeleteOptions{
			PropagationPolicy:  &deletePolicy,
			GracePeriodSeconds: &gracePeriod,
		}, metav1.ListOptions{})
		if err != nil {
			log.Warn("Failed to delete pods", "namespace", nsName, "error", err)
		}

		// Remove finalizers from all resources in the namespace
		if err := fd.removeAllFinalizersInNamespace(ctx, nsName); err != nil {
			log.Warn("Failed to remove finalizers", "namespace", nsName, "error", err)
		}

		// Delete the namespace
		if nsName != "flux-system" { // Handle flux-system separately
			err := fd.client.CoreV1().Namespaces().Delete(ctx, nsName, metav1.DeleteOptions{})
			if err != nil {
				log.Warn("Failed to delete namespace", "namespace", nsName, "error", err)
			}
		}
	}

	return nil
}

func (fd *FluxDestroyer) removeAllFinalizersInNamespace(ctx context.Context, namespace string) error {
	// Get all API resources
	apiGroups, err := fd.client.Discovery().ServerGroups()
	if err != nil {
		return err
	}

	for _, group := range apiGroups.Groups {
		for _, version := range group.Versions {
			resourceList, err := fd.client.Discovery().ServerResourcesForGroupVersion(version.GroupVersion)
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

				// Try to remove finalizers from all resources of this type
				resources, err := fd.dynamicClient.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{})
				if err != nil {
					continue
				}

				for _, item := range resources.Items {
					finalizers := item.GetFinalizers()
					if len(finalizers) > 0 {
						patch := []byte(`{"metadata":{"finalizers":null}}`)
						_, err := fd.dynamicClient.Resource(gvr).Namespace(namespace).Patch(
							ctx, item.GetName(), types.MergePatchType, patch, metav1.PatchOptions{})
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

func (fd *FluxDestroyer) cleanupPersistentVolumes(ctx context.Context) error {
	log.Info("🗑️ Cleaning up stuck PersistentVolumes")

	pvs, err := fd.client.CoreV1().PersistentVolumes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list persistent volumes: %w", err)
	}

	for _, pv := range pvs.Items {
		if pv.Status.Phase == "Released" || pv.Status.Phase == "Terminating" {
			log.Info("Removing finalizers from PV", "name", pv.Name, "phase", pv.Status.Phase)

			patch := []byte(`{"metadata":{"finalizers":[]}}`)
			_, err := fd.client.CoreV1().PersistentVolumes().Patch(
				ctx, pv.Name, types.MergePatchType, patch, metav1.PatchOptions{})
			if err != nil {
				log.Warn("Failed to patch PV", "name", pv.Name, "error", err)
			}
		}
	}

	return nil
}

func (fd *FluxDestroyer) cleanupCRDs(ctx context.Context) error {
	log.Info("🗑️ Cleaning up CRDs")

	crdGVR := schema.GroupVersionResource{
		Group:    "apiextensions.k8s.io",
		Version:  "v1",
		Resource: "customresourcedefinitions",
	}

	crds, err := fd.dynamicClient.Resource(crdGVR).List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list CRDs: %w", err)
	}

	// Core Kubernetes CRDs to preserve
	corePatterns := []string{
		"k8s.io",
		"kubernetes.io",
		"metrics.k8s.io",
		"apiregistration.k8s.io",
		"admissionregistration.k8s.io",
	}

	for _, crd := range crds.Items {
		crdName := crd.GetName()

		// Skip core Kubernetes CRDs
		isCore := false
		for _, pattern := range corePatterns {
			if strings.Contains(crdName, pattern) {
				isCore = true
				break
			}
		}

		if isCore {
			continue
		}

		log.Info("Deleting CRD", "name", crdName)
		err := fd.dynamicClient.Resource(crdGVR).Delete(ctx, crdName, metav1.DeleteOptions{})
		if err != nil {
			log.Warn("Failed to delete CRD", "name", crdName, "error", err)
		}
	}

	return nil
}

func (fd *FluxDestroyer) forceCleanupFluxNamespace(ctx context.Context, namespace string) error {
	log.Info("🗑️ Final cleanup of flux-system namespace", "namespace", namespace)

	if !fd.namespaceExists(ctx, namespace) {
		log.Info("Flux namespace already removed", "namespace", namespace)
		return nil
	}

	// Get all namespaced resources and delete them
	if err := fd.removeAllFinalizersInNamespace(ctx, namespace); err != nil {
		log.Warn("Failed to remove finalizers in flux namespace", "error", err)
	}

	// Remove finalizers from the namespace itself
	patch := []byte(`{"metadata":{"finalizers":null}}`)
	_, err := fd.client.CoreV1().Namespaces().Patch(
		ctx, namespace, types.MergePatchType, patch, metav1.PatchOptions{})
	if err != nil {
		log.Warn("Failed to remove namespace finalizers", "error", err)
	}

	// Force finalize using the API if still stuck
	ns, err := fd.client.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
	if err != nil {
		return nil // Already gone
	}

	// Clear spec and status, remove finalizers
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

	finalizeData, err := finalizeNS.MarshalJSON()
	if err != nil {
		return err
	}

	// Use raw client to finalize
	result := fd.client.CoreV1().RESTClient().Put().
		AbsPath(fmt.Sprintf("/api/v1/namespaces/%s/finalize", namespace)).
		Body(finalizeData).
		Do(ctx)

	if result.Error() != nil {
		log.Warn("Failed to finalize namespace via API", "error", result.Error())
	}

	// Wait and check if it's gone
	time.Sleep(2 * time.Second)
	if fd.namespaceExists(ctx, namespace) {
		log.Warn("Flux namespace could not be fully removed - may need API server restart", "namespace", namespace)
	} else {
		log.Info("Flux namespace successfully removed", "namespace", namespace)
	}

	return nil
}

// Helper function to check if slice contains string
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}
