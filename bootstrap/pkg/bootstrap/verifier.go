package bootstrap

import (
	"context"
	"errors"
	"fmt"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/discovery"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// VerifyMesh runs acceptance checks across the homelab and NAS clusters.
func VerifyMesh(ctx context.Context) error {
	projectRoot, err := findProjectRoot()
	if err != nil {
		return err
	}
	return verifyMeshWithRoot(ctx, projectRoot)
}

func verifyMeshWithRoot(ctx context.Context, projectRoot string) error {
	discoveryService := discovery.NewClusterDiscovery(projectRoot)
	contexts, err := discoveryService.ListContexts(ctx)
	if err != nil {
		return fmt.Errorf("failed to list kube contexts: %w", err)
	}

	nasInfo, ok := contexts["nas"]
	if !ok {
		return fmt.Errorf("nas context not found; run bootstrap nas install first")
	}
	homelabInfo, ok := contexts["homelab"]
	if !ok {
		return fmt.Errorf("homelab context not found; run bootstrap homelab install first")
	}

	nasClient, err := k8s.NewClientWithContext(nasInfo.Kubeconfig, nasInfo.Context)
	if err != nil {
		return fmt.Errorf("failed to build NAS Kubernetes client: %w", err)
	}
	homelabClient, err := k8s.NewClientWithContext(homelabInfo.Kubeconfig, homelabInfo.Context)
	if err != nil {
		return fmt.Errorf("failed to build homelab Kubernetes client: %w", err)
	}

	var errs []error

	if err := verifyDeploymentReady(ctx, nasClient, istioNamespace, "istiod", "nas"); err != nil {
		errs = append(errs, err)
	}
	if err := verifyDeploymentReady(ctx, nasClient, istioNamespace, eastWestServiceName, "nas"); err != nil {
		errs = append(errs, err)
	}
	if err := verifyGatewayPods(ctx, nasClient, "nas"); err != nil {
		errs = append(errs, err)
	}
	if err := verifySecretExists(ctx, nasClient, "istio-remote-secret-homelab", "nas"); err != nil {
		errs = append(errs, err)
	}
	if err := verifySecretExists(ctx, nasClient, eastWestGatewayTLSSecretName, "nas"); err != nil {
		errs = append(errs, err)
	}

	if err := verifyDeploymentReady(ctx, homelabClient, istioNamespace, "istiod", "homelab"); err != nil {
		errs = append(errs, err)
	}
	if err := verifyDeploymentReady(ctx, homelabClient, istioNamespace, eastWestServiceName, "homelab"); err != nil {
		errs = append(errs, err)
	}
	if err := verifyGatewayPods(ctx, homelabClient, "homelab"); err != nil {
		errs = append(errs, err)
	}
	if err := verifySecretExists(ctx, homelabClient, "istio-remote-secret-nas", "homelab"); err != nil {
		errs = append(errs, err)
	}
	if err := verifySecretExists(ctx, homelabClient, eastWestGatewayTLSSecretName, "homelab"); err != nil {
		errs = append(errs, err)
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	log.Info("Mesh verification completed successfully")
	return nil
}

func verifyDeploymentReady(ctx context.Context, client *k8s.Client, namespace, name, cluster string) error {
	deployment, err := client.GetClientset().AppsV1().Deployments(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("%s: failed to get deployment %s/%s: %w", cluster, namespace, name, err)
	}
	desired := int32(1)
	if deployment.Spec.Replicas != nil {
		desired = *deployment.Spec.Replicas
	}
	if deployment.Status.ReadyReplicas < desired {
		return fmt.Errorf("%s: deployment %s/%s not ready (%d/%d)", cluster, namespace, name, deployment.Status.ReadyReplicas, desired)
	}
	return nil
}

func verifyGatewayPods(ctx context.Context, client *k8s.Client, cluster string) error {
	selector := fmt.Sprintf("app=%s", eastWestServiceName)
	pods, err := client.GetClientset().CoreV1().Pods(istioNamespace).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return fmt.Errorf("%s: failed to list gateway pods: %w", cluster, err)
	}
	if len(pods.Items) == 0 {
		return fmt.Errorf("%s: no east-west gateway pods found", cluster)
	}
	for _, pod := range pods.Items {
		if len(pod.Spec.Containers) != 1 {
			return fmt.Errorf("%s: gateway pod %s has %d containers (expected 1)", cluster, pod.Name, len(pod.Spec.Containers))
		}
	}
	return nil
}

func verifySecretExists(ctx context.Context, client *k8s.Client, name, cluster string) error {
	secret, err := client.GetClientset().CoreV1().Secrets(istioNamespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("%s: failed to read secret %s/%s: %w", cluster, istioNamespace, name, err)
	}
	if len(secret.Data) == 0 {
		return fmt.Errorf("%s: secret %s/%s has no data", cluster, istioNamespace, name)
	}
	return nil
}
