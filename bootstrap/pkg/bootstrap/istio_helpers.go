package bootstrap

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/log"
	"github.com/fredericrous/homelab/bootstrap/pkg/config"
	"github.com/fredericrous/homelab/bootstrap/pkg/discovery"
	"github.com/fredericrous/homelab/bootstrap/pkg/flux"
	"github.com/fredericrous/homelab/bootstrap/pkg/istio"
	"github.com/fredericrous/homelab/bootstrap/pkg/k8s"
	admissionv1 "k8s.io/api/admissionregistration/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/pointer"
	"sigs.k8s.io/yaml"
)

const (
	istioNamespace               = "istio-system"
	clusterVarsSecretName        = "cluster-vars"
	eastWestServiceName          = "istio-eastwestgateway"
	eastWestGatewayTLSSecretName = "istio-eastwestgateway-certs"
	sidecarWebhookName           = "istio-sidecar-injector"
)

func (o *Orchestrator) ensureIstioPrereqs(ctx context.Context) error {
	if !o.isServiceMeshEnabled() {
		log.Debug("Service mesh disabled, skipping Istio prerequisites")
		return nil
	}

	if err := o.ensureCACerts(ctx); err != nil {
		return err
	}

	if err := o.ensureRemoteSecret(ctx); err != nil {
		return err
	}

	return nil
}

func (o *Orchestrator) finalizeIstioMesh(ctx context.Context) error {
	if !o.isServiceMeshEnabled() {
		log.Debug("Service mesh disabled, skipping Istio mesh finalization")
		return nil
	}

	if err := o.ensureGatewayTLSSecret(ctx, o.k8sClient, o.localClusterName()); err != nil {
		log.Warn("Failed to ensure east-west TLS secret", "error", err)
	}

	if err := o.ensureWebhookTargetsService(ctx, o.k8sClient, o.localClusterName()); err != nil {
		log.Warn("Failed to reconcile mutating webhook", "error", err)
	}

	updates := map[string]string{}

	localEndpoint, err := o.waitForGatewayEndpoint(ctx, o.k8sClient, o.localGatewayFallbacks(), true)
	if err != nil {
		return fmt.Errorf("failed to detect local east-west gateway address: %w", err)
	}

	localAddrKey, localPortKey := o.localGatewayVarKeys()
	updates[localAddrKey] = localEndpoint.Host
	updates[localPortKey] = strconv.Itoa(int(localEndpoint.Port))

	if peerClient, err := o.buildPeerClient(); err == nil {
		if err := o.ensureGatewayTLSSecret(ctx, peerClient, o.peerClusterName()); err != nil {
			log.Warn("Failed to ensure peer TLS secret", "peer", o.peerClusterName(), "error", err)
		}
		if err := o.ensureWebhookTargetsService(ctx, peerClient, o.peerClusterName()); err != nil {
			log.Warn("Failed to reconcile peer webhook", "peer", o.peerClusterName(), "error", err)
		}
		if peerEndpoint, err := o.waitForGatewayEndpoint(ctx, peerClient, o.peerGatewayFallbacks(), false); err == nil {
			peerAddrKey, peerPortKey := o.peerGatewayVarKeys()
			updates[peerAddrKey] = peerEndpoint.Host
			updates[peerPortKey] = strconv.Itoa(int(peerEndpoint.Port))
		} else {
			log.Warn("Unable to discover peer gateway", "peer", o.peerClusterName(), "error", err)
		}
	} else {
		log.Warn("Peer kubeconfig unavailable", "peer", o.peerClusterName(), "error", err)
	}

	if len(updates) > 0 {
		if err := o.secretsManager.UpdateClusterVars(ctx, "flux-system", updates); err != nil {
			return fmt.Errorf("failed to update gateway variables: %w", err)
		}
		if err := o.secretsManager.UpdateGeneratedEnv(updates); err != nil {
			log.Warn("Failed to persist gateway variables to .env.generated", "error", err)
		}
	}

	fluxClient, err := o.newFluxClient()
	if err != nil {
		return err
	}

	for _, name := range o.reconcileTargets() {
		if err := fluxClient.TriggerReconcile(ctx, "flux-system", name); err != nil {
			return fmt.Errorf("failed to reconcile %s: %w", name, err)
		}
	}

	if err := o.k8sClient.WaitForDeployment(ctx, istioNamespace, "istiod", 5*time.Minute); err != nil {
		return fmt.Errorf("istiod not ready: %w", err)
	}

	if err := o.k8sClient.WaitForDeployment(ctx, istioNamespace, eastWestServiceName, 5*time.Minute); err != nil {
		return fmt.Errorf("east-west gateway not ready: %w", err)
	}

	if err := o.k8sClient.WaitForDaemonSet(ctx, istioNamespace, "ztunnel", 5*time.Minute); err != nil {
		log.Warn("ztunnel not ready", "error", err)
	}

	log.Info("Istio mesh finalized", "gateway", localEndpoint.Host, "port", localEndpoint.Port)

	if !o.isNAS {
		if err := verifyMeshWithRoot(ctx, o.projectRoot); err != nil {
			log.Warn("Mesh verification reported issues", "error", err)
		} else {
			log.Info("Mesh verification succeeded")
		}
	}
	return nil
}

func (o *Orchestrator) ensureCACerts(ctx context.Context) error {
	// First check if cacerts already exists
	secret, err := o.k8sClient.GetSecret(ctx, istioNamespace, "cacerts")
	if err != nil {
		if !apierrors.IsNotFound(err) {
			return fmt.Errorf("failed to read cacerts secret: %w", err)
		}

		// Secret doesn't exist, check if we can read from directory
		data, readErr := o.readCACertsFromDir()
		if readErr == nil {
			// Create secret from directory files
			secret = &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "cacerts",
					Namespace: istioNamespace,
				},
				Data: data,
				Type: corev1.SecretTypeOpaque,
			}
			if err := o.k8sClient.CreateOrUpdateSecret(ctx, secret); err != nil {
				return fmt.Errorf("failed to create cacerts secret: %w", err)
			}
			log.Info("Created cacerts secret from directory", "namespace", istioNamespace)
		} else {
			// No existing secret and no directory files, CA bootstrap will handle it
			log.Info("No existing CA certificates found, CA bootstrap job will generate them")
			return nil
		}
	}

	// Validate existing CA
	if len(secret.Data["root-cert.pem"]) == 0 || len(secret.Data["key.pem"]) == 0 {
		log.Warn("Existing cacerts secret is incomplete, CA bootstrap will regenerate")
		return nil
	}

	fp := fingerprint(secret.Data["root-cert.pem"])
	log.Info("Istio root CA found", "fingerprint", fp)

	// Check peer cluster CA for consistency
	peerPath := o.peerKubeconfigPath()
	peerContext := ""
	if discoveryService := discovery.NewClusterDiscovery(o.projectRoot); discoveryService != nil {
		if info, err := discoveryService.GetCluster(o.peerClusterName()); err == nil {
			if peerPath == "" {
				peerPath = info.Kubeconfig
			}
			peerContext = info.Context
		}
	}
	if peerPath == "" {
		return nil
	}

	if _, err := os.Stat(peerPath); err != nil {
		return nil
	}

	peerClient, err := k8s.NewClientWithContext(peerPath, peerContext)
	if err != nil {
		log.Warn("Unable to connect to peer cluster for CA comparison", "peer", o.peerClusterName(), "error", err)
		return nil
	}

	peerSecret, err := peerClient.GetSecret(ctx, istioNamespace, "cacerts")
	if err != nil {
		if apierrors.IsNotFound(err) {
			log.Warn("Peer cluster is missing cacerts secret", "peer", o.peerClusterName())
			// Try to copy our CA to peer cluster
			if err := o.syncCAToPeer(ctx, peerClient, secret); err != nil {
				log.Warn("Failed to sync CA to peer cluster", "peer", o.peerClusterName(), "error", err)
			}
			return nil
		}
		log.Warn("Failed to fetch peer cacerts", "peer", o.peerClusterName(), "error", err)
		return nil
	}

	peerFP := fingerprint(peerSecret.Data["root-cert.pem"])
	if fp != peerFP {
		return fmt.Errorf("cacerts mismatch between clusters: local=%s peer=%s", fp, peerFP)
	}

	return nil
}

func (o *Orchestrator) ensureRemoteSecret(ctx context.Context) error {
	log.Info("Ensuring cross-cluster remote secrets")

	// Apply any cached remote secret payload for the peer cluster if present
	if envKey := fmt.Sprintf("ISTIO_REMOTE_SECRET_%s_B64", strings.ToUpper(o.peerClusterName())); true {
		if payload, err := o.secretsManager.GetGeneratedEnvValue(envKey); err == nil {
			if strings.TrimSpace(payload) != "" {
				if secret, decodeErr := secretFromBase64(payload); decodeErr != nil {
					log.Warn("Failed to decode cached remote secret", "peer", o.peerClusterName(), "error", decodeErr)
				} else {
					if secret.Namespace == "" {
						secret.Namespace = istioNamespace
					}
					if err := o.k8sClient.CreateOrUpdateSecret(ctx, secret); err != nil {
						log.Warn("Failed to apply cached remote secret", "peer", o.peerClusterName(), "error", err)
					} else {
						log.Debug("Applied cached remote secret", "peer", o.peerClusterName())
					}
				}
			}
		}
	}

	// Create multi-cluster manager
	mcManager := istio.NewMultiClusterManager(o.k8sClient)

	// Create remote secret for local cluster (this will be installed in peer)
	localSecret, err := mcManager.CreateRemoteSecret(ctx, o.localClusterName())
	if err != nil {
		return fmt.Errorf("failed to create local cluster remote secret: %w", err)
	}

	if istioctlSecret, cmdErr := o.remoteSecretFromIstioctl(ctx, o.kubeconfigPath, o.kubeContext, o.localClusterName()); cmdErr != nil {
		log.Debug("Failed to render remote secret via istioctl", "cluster", o.localClusterName(), "error", cmdErr)
	} else {
		localSecret = istioctlSecret
	}

	localSecretB64, err := secretToBase64(localSecret)
	if err != nil {
		log.Warn("Failed to encode local remote secret", "error", err)
	} else {
		key := fmt.Sprintf("ISTIO_REMOTE_SECRET_%s_B64", strings.ToUpper(o.localClusterName()))
		if err := o.secretsManager.UpdateGeneratedEnv(map[string]string{key: localSecretB64}); err != nil {
			log.Warn("Failed to record local remote secret", "error", err)
		}
	}

	// Try to connect to peer cluster if available
	peerPath := o.peerKubeconfigPath()
	if peerPath == "" {
		log.Info("Peer cluster not configured, storing pending remote secret")
		if localSecretB64 != "" {
			if err := o.secretsManager.StorePendingRemoteSecret(ctx, o.peerClusterName(), localSecretB64); err != nil {
				log.Warn("Failed to store pending remote secret", "peer", o.peerClusterName(), "error", err)
			}
		}
		return nil
	}

	if peerPath != "" && !filepath.IsAbs(peerPath) {
		if absPeer, err := filepath.Abs(peerPath); err == nil {
			peerPath = absPeer
		}
	}

	// Check if peer kubeconfig exists
	if _, err := os.Stat(peerPath); os.IsNotExist(err) {
		log.Info("Peer kubeconfig not found yet, deferring remote secret sync", "path", peerPath)
		if localSecretB64 != "" {
			if err := o.secretsManager.StorePendingRemoteSecret(ctx, o.peerClusterName(), localSecretB64); err != nil {
				log.Warn("Failed to store pending remote secret", "peer", o.peerClusterName(), "error", err)
			}
		}
		return nil
	}

	// Connect to peer cluster
	peerClient, err := k8s.NewClient(peerPath)
	if err != nil {
		log.Warn("Failed to connect to peer cluster", "peer", o.peerClusterName(), "error", err)
		if localSecretB64 != "" {
			if err := o.secretsManager.StorePendingRemoteSecret(ctx, o.peerClusterName(), localSecretB64); err != nil {
				log.Warn("Failed to store pending remote secret", "peer", o.peerClusterName(), "error", err)
			}
		}
		return nil
	}

	// Create peer's multi-cluster manager
	peerMCManager := istio.NewMultiClusterManager(peerClient)

	// Create remote secret for peer cluster (to be installed locally)
	peerSecret, err := peerMCManager.CreateRemoteSecret(ctx, o.peerClusterName())
	if err != nil {
		log.Warn("Failed to create peer cluster remote secret", "peer", o.peerClusterName(), "error", err)
	} else {
		if istioctlSecret, cmdErr := o.remoteSecretFromIstioctl(ctx, peerPath, peerContext, o.peerClusterName()); cmdErr != nil {
			log.Debug("Failed to render peer remote secret via istioctl", "peer", o.peerClusterName(), "error", cmdErr)
		} else {
			peerSecret = istioctlSecret
		}
		if peerSecretB64, encErr := secretToBase64(peerSecret); encErr == nil {
			key := fmt.Sprintf("ISTIO_REMOTE_SECRET_%s_B64", strings.ToUpper(o.peerClusterName()))
			if err := o.secretsManager.UpdateGeneratedEnv(map[string]string{key: peerSecretB64}); err != nil {
				log.Warn("Failed to record peer remote secret", "peer", o.peerClusterName(), "error", err)
			}
		} else {
			log.Warn("Failed to encode peer remote secret", "peer", o.peerClusterName(), "error", encErr)
		}
		// Install peer's remote secret in local cluster
		if err := o.k8sClient.CreateOrUpdateSecret(ctx, peerSecret); err != nil {
			return fmt.Errorf("failed to install peer remote secret locally: %w", err)
		}
		log.Info("Installed peer remote secret in local cluster", "peer", o.peerClusterName())
	}

	// Install local remote secret in peer cluster
	if err := peerClient.CreateOrUpdateSecret(ctx, localSecret); err != nil {
		log.Warn("Failed to install local remote secret in peer cluster", "error", err)
		if localSecretB64 != "" {
			if err := o.secretsManager.StorePendingRemoteSecret(ctx, o.peerClusterName(), localSecretB64); err != nil {
				log.Warn("Failed to store pending remote secret", "peer", o.peerClusterName(), "error", err)
			}
		}
	} else {
		log.Info("Installed local remote secret in peer cluster", "local", o.localClusterName())
		if err := o.secretsManager.ClearPendingRemoteSecret(ctx, o.peerClusterName()); err != nil {
			log.Warn("Failed to clear pending remote secret", "peer", o.peerClusterName(), "error", err)
		}
	}

	log.Info("Cross-cluster remote secrets configuration complete")
	return nil
}

func (o *Orchestrator) remoteSecretFromIstioctl(ctx context.Context, kubeconfig, kubeContext, clusterName string) (*corev1.Secret, error) {
	if strings.TrimSpace(kubeconfig) == "" {
		return nil, fmt.Errorf("kubeconfig path not provided for %s", clusterName)
	}

	args := []string{"x", "create-remote-secret", "--kubeconfig", kubeconfig, "--name", clusterName}
	if strings.TrimSpace(kubeContext) != "" {
		args = append(args, "--context", kubeContext)
	}

	cmdCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(cmdCtx, "istioctl", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("istioctl x create-remote-secret: %w (output: %s)", err, strings.TrimSpace(string(output)))
	}

	var secret corev1.Secret
	if err := yaml.Unmarshal(output, &secret); err != nil {
		return nil, fmt.Errorf("failed to parse remote secret manifest: %w", err)
	}
	if secret.Namespace == "" {
		secret.Namespace = istioNamespace
	}
	return &secret, nil
}

func (o *Orchestrator) waitForGatewayEndpoint(ctx context.Context, client *k8s.Client, fallbacks []string, allowFallback bool) (*gatewayEndpoint, error) {
	deadline := time.Now().Add(5 * time.Minute)
	fallbackAfter := time.Now().Add(2 * time.Minute)

	for {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}

		svc, err := client.GetService(ctx, istioNamespace, eastWestServiceName)
		if err != nil {
			if apierrors.IsNotFound(err) {
				if time.Now().After(deadline) {
					return nil, fmt.Errorf("gateway service %s not created", eastWestServiceName)
				}
				time.Sleep(5 * time.Second)
				continue
			}
			return nil, err
		}

		endpoint := endpointFromService(svc)
		if endpoint != nil {
			if endpoint.Source == "nodePort" && allowFallback {
				if len(fallbacks) == 0 {
					return nil, fmt.Errorf("no node fallback addresses available for gateway")
				}
				endpoint.Host = fallbacks[0]
				return endpoint, nil
			}
			if endpoint.Source != "nodePort" {
				return endpoint, nil
			}
		}

		if allowFallback && len(fallbacks) > 0 && time.Now().After(fallbackAfter) {
			port := nodePortForGateway(svc)
			if port != 0 {
				return &gatewayEndpoint{Host: fallbacks[0], Port: port, Source: "nodePort"}, nil
			}
		}

		if time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for gateway address")
		}

		time.Sleep(5 * time.Second)
	}
}

func endpointFromService(svc *corev1.Service) *gatewayEndpoint {
	if svc == nil {
		return nil
	}

	port := tlsPortForGateway(svc)
	if port == 0 {
		return nil
	}

	if ingress := svc.Status.LoadBalancer.Ingress; len(ingress) > 0 {
		if host := ingress[0].IP; host != "" {
			return &gatewayEndpoint{Host: host, Port: port, Source: "loadBalancer"}
		}
		if host := ingress[0].Hostname; host != "" {
			return &gatewayEndpoint{Host: host, Port: port, Source: "loadBalancer"}
		}
	}

	if len(svc.Spec.ExternalIPs) > 0 {
		return &gatewayEndpoint{Host: svc.Spec.ExternalIPs[0], Port: port, Source: "externalIP"}
	}

	if svc.Spec.ClusterIP != "" && svc.Spec.Type == corev1.ServiceTypeClusterIP {
		return &gatewayEndpoint{Host: svc.Spec.ClusterIP, Port: port, Source: "clusterIP"}
	}

	if svc.Spec.Type == corev1.ServiceTypeNodePort {
		if nodePort := nodePortForGateway(svc); nodePort != 0 {
			return &gatewayEndpoint{Host: "", Port: nodePort, Source: "nodePort"}
		}
	}

	return nil
}

func tlsPortForGateway(svc *corev1.Service) int32 {
	for _, p := range svc.Spec.Ports {
		if p.Name == "tls" || p.Port == 15443 {
			return p.Port
		}
	}
	return 0
}

func nodePortForGateway(svc *corev1.Service) int32 {
	for _, p := range svc.Spec.Ports {
		if p.Name == "tls" || p.Port == 15443 {
			return p.NodePort
		}
	}
	return 0
}

func (o *Orchestrator) readCACertsFromDir() (map[string][]byte, error) {
	dir := envOrDefault("CACERTS_DIR", filepath.Join(o.projectRoot, "cacerts"))
	files := []string{"root-cert.pem", "cert-chain.pem", "key.pem"}
	data := make(map[string][]byte)
	for _, name := range files {
		path := filepath.Join(dir, name)
		bytes, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("failed to read %s: %w", path, err)
		}
		data[name] = bytes
	}
	return data, nil
}

func (o *Orchestrator) syncCAToPeer(ctx context.Context, peerClient *k8s.Client, localSecret *corev1.Secret) error {
	// Create istio-system namespace if it doesn't exist
	if err := peerClient.CreateNamespace(ctx, istioNamespace); err != nil {
		return fmt.Errorf("failed to create istio-system namespace on peer: %w", err)
	}

	// Copy the CA secret to peer cluster
	peerSecret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:        localSecret.Name,
			Namespace:   localSecret.Namespace,
			Labels:      localSecret.Labels,
			Annotations: localSecret.Annotations,
		},
		Type: localSecret.Type,
		Data: localSecret.Data,
	}

	if err := peerClient.CreateOrUpdateSecret(ctx, peerSecret); err != nil {
		return fmt.Errorf("failed to sync CA secret to peer: %w", err)
	}

	log.Info("Successfully synced CA to peer cluster", "peer", o.peerClusterName())
	return nil
}

func (o *Orchestrator) ensureGatewayTLSSecret(ctx context.Context, client *k8s.Client, cluster string) error {
	certB64, err := o.secretsManager.GetEnvValue("EASTWEST_CERT_B64")
	if err != nil {
		return err
	}
	keyB64, err := o.secretsManager.GetEnvValue("EASTWEST_KEY_B64")
	if err != nil {
		return err
	}

	if strings.TrimSpace(certB64) == "" || strings.TrimSpace(keyB64) == "" {
		if o.isNAS {
			log.Info("Generating east-west gateway TLS certificate")
			var genErr error
			certB64, keyB64, genErr = o.generateGatewayTLSMaterial()
			if genErr != nil {
				return genErr
			}
		} else {
			log.Debug("East-west gateway TLS material not provided; skipping secret management")
			return nil
		}
	}

	certBytes, err := base64.StdEncoding.DecodeString(certB64)
	if err != nil {
		return fmt.Errorf("failed to decode EASTWEST_CERT_B64: %w", err)
	}
	keyBytes, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return fmt.Errorf("failed to decode EASTWEST_KEY_B64: %w", err)
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      eastWestGatewayTLSSecretName,
			Namespace: istioNamespace,
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			corev1.TLSCertKey:       certBytes,
			corev1.TLSPrivateKeyKey: keyBytes,
		},
	}

	if err := client.CreateOrUpdateSecret(ctx, secret); err != nil {
		return fmt.Errorf("failed to apply east-west TLS secret: %w", err)
	}

	log.Debug("Ensured east-west TLS secret", "cluster", cluster)
	return nil
}

func (o *Orchestrator) generateGatewayTLSMaterial() (string, string, error) {
	cn, err := o.secretsManager.GetEnvValue("EASTWEST_CERT_CN")
	if err != nil {
		return "", "", err
	}
	if strings.TrimSpace(cn) == "" {
		cn = "istiod.istio-system.svc.cluster.local"
	}

	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		return "", "", fmt.Errorf("failed to generate certificate serial: %w", err)
	}

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return "", "", fmt.Errorf("failed to generate private key: %w", err)
	}

	now := time.Now()
	template := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    now.Add(-5 * time.Minute),
		NotAfter:     now.Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{
			cn,
			"istiod.istio-system.svc",
			"istiod.istio-system.svc.cluster.local",
		},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return "", "", fmt.Errorf("failed to create certificate: %w", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	certB64 := base64.StdEncoding.EncodeToString(certPEM)
	keyB64 := base64.StdEncoding.EncodeToString(keyPEM)

	updates := map[string]string{
		"EASTWEST_CERT_CN":  cn,
		"EASTWEST_CERT_B64": certB64,
		"EASTWEST_KEY_B64":  keyB64,
	}
	if err := o.secretsManager.UpdateGeneratedEnv(updates); err != nil {
		return "", "", fmt.Errorf("failed to update .env.generated with TLS material: %w", err)
	}

	return certB64, keyB64, nil
}

func (o *Orchestrator) ensureWebhookTargetsService(ctx context.Context, client *k8s.Client, cluster string) error {
	mwcClient := client.GetClientset().AdmissionregistrationV1().MutatingWebhookConfigurations()
	config, err := mwcClient.Get(ctx, sidecarWebhookName, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return fmt.Errorf("failed to fetch mutating webhook: %w", err)
	}

	updated := false
	for i := range config.Webhooks {
		wh := &config.Webhooks[i]
		if wh.ClientConfig.URL != nil && *wh.ClientConfig.URL != "" {
			wh.ClientConfig.URL = nil
			wh.ClientConfig.Service = &admissionv1.ServiceReference{
				Name:      "istiod",
				Namespace: istioNamespace,
				Path:      pointer.String("/inject"),
				Port:      pointer.Int32(443),
			}
			updated = true
		} else if wh.ClientConfig.Service != nil {
			ref := wh.ClientConfig.Service
			if ref.Name != "istiod" || ref.Namespace != istioNamespace || ref.Port == nil || *ref.Port != 443 {
				ref.Name = "istiod"
				ref.Namespace = istioNamespace
				ref.Path = pointer.String("/inject")
				ref.Port = pointer.Int32(443)
				updated = true
			}
		}
	}

	if !updated {
		return nil
	}

	if _, err := mwcClient.Update(ctx, config, metav1.UpdateOptions{}); err != nil {
		return fmt.Errorf("failed to update mutating webhook: %w", err)
	}

	log.Debug("Updated mutating webhook to target istiod service", "cluster", cluster)
	return nil
}

func secretToBase64(secret *corev1.Secret) (string, error) {
	if secret == nil {
		return "", nil
	}
	data, err := yaml.Marshal(secret)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

func secretFromBase64(encoded string) (*corev1.Secret, error) {
	if strings.TrimSpace(encoded) == "" {
		return nil, fmt.Errorf("empty secret payload")
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("failed to decode base64 secret: %w", err)
	}
	var secret corev1.Secret
	if err := yaml.Unmarshal(decoded, &secret); err != nil {
		return nil, fmt.Errorf("failed to unmarshal secret payload: %w", err)
	}
	return &secret, nil
}

func fingerprint(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (o *Orchestrator) isServiceMeshEnabled() bool {
	if o.isNAS {
		return true
	}
	if o.config.Homelab == nil {
		return false
	}
	return o.config.Homelab.Networking.ServiceMesh.Enabled
}

func (o *Orchestrator) localClusterName() string {
	if o.isNAS {
		return "nas"
	}
	return "homelab"
}

func (o *Orchestrator) peerClusterName() string {
	if o.isNAS {
		return "homelab"
	}
	return "nas"
}

func (o *Orchestrator) localKubeconfigPath() string {
	if o.isNAS {
		return o.resolveKubeconfig(o.options.NASKubeconfigPath, "NAS_KUBECONFIG_PATH",
			filepath.Join("infrastructure", "nas", "kubeconfig.yaml"))
	}
	return o.resolveKubeconfig(o.options.HomelabKubeconfigPath, "HOMELAB_KUBECONFIG_PATH",
		filepath.Join("infrastructure", "homelab", "kubeconfig.yaml"), "kubeconfig")
}

func (o *Orchestrator) peerKubeconfigPath() string {
	if o.isNAS {
		return o.resolveKubeconfig(o.options.HomelabKubeconfigPath, "HOMELAB_KUBECONFIG_PATH",
			filepath.Join("infrastructure", "homelab", "kubeconfig.yaml"), "kubeconfig")
	}
	return o.resolveKubeconfig(o.options.NASKubeconfigPath, "NAS_KUBECONFIG_PATH",
		filepath.Join("infrastructure", "nas", "kubeconfig.yaml"))
}

func (o *Orchestrator) localGatewayFallbacks() []string {
	if o.isNAS {
		if o.config.NAS != nil && o.config.NAS.Cluster.Host != "" {
			return []string{o.config.NAS.Cluster.Host}
		}
		return nil
	}

	if o.config.Homelab != nil && len(o.config.Homelab.Cluster.Nodes) > 0 {
		return append([]string{}, o.config.Homelab.Cluster.Nodes...)
	}

	return nil
}

func (o *Orchestrator) peerGatewayFallbacks() []string {
	if o.isNAS {
		host := o.lookupEnvValue("HOMELAB_EW_GATEWAY_ADDR")
		if host != "" {
			return []string{host}
		}
		return nil
	}
	host := o.lookupEnvValue("NAS_EW_GATEWAY_ADDR")
	if host != "" {
		return []string{host}
	}
	return nil
}

func (o *Orchestrator) localGatewayVarKeys() (string, string) {
	if o.isNAS {
		return "NAS_EW_GATEWAY_ADDR", "NAS_EW_GATEWAY_PORT"
	}
	return "HOMELAB_EW_GATEWAY_ADDR", "HOMELAB_EW_GATEWAY_PORT"
}

func (o *Orchestrator) peerGatewayVarKeys() (string, string) {
	if o.isNAS {
		return "HOMELAB_EW_GATEWAY_ADDR", "HOMELAB_EW_GATEWAY_PORT"
	}
	return "NAS_EW_GATEWAY_ADDR", "NAS_EW_GATEWAY_PORT"
}

func (o *Orchestrator) lookupEnvValue(key string) string {
	if o.secretsManager != nil {
		if val, err := o.secretsManager.GetEnvValue(key); err == nil {
			if trimmed := strings.TrimSpace(val); trimmed != "" {
				return trimmed
			}
		}
	}
	return strings.TrimSpace(os.Getenv(key))
}

func (o *Orchestrator) resolveKubeconfig(optionPath, envKey string, fallbacks ...string) string {
	candidates := make([]string, 0, 3+len(fallbacks))
	if val := strings.TrimSpace(optionPath); val != "" {
		candidates = append(candidates, val)
	}
	if o.secretsManager != nil {
		if val, err := o.secretsManager.GetGeneratedEnvValue(envKey); err == nil {
			if trimmed := strings.TrimSpace(val); trimmed != "" {
				candidates = append(candidates, trimmed)
			}
		}
	}
	if val := strings.TrimSpace(os.Getenv(envKey)); val != "" {
		candidates = append(candidates, val)
	}
	candidates = append(candidates, fallbacks...)

	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		path := candidate
		if !filepath.IsAbs(path) {
			path = filepath.Join(o.projectRoot, path)
		}
		return path
	}

	if len(fallbacks) > 0 {
		last := fallbacks[len(fallbacks)-1]
		if !filepath.IsAbs(last) {
			return filepath.Join(o.projectRoot, last)
		}
		return last
	}

	return ""
}

func (o *Orchestrator) reconcileTargets() []string {
	if o.isNAS {
		return []string{"nas-platform-foundation"}
	}
	return []string{"controllers", "platform-foundation"}
}

func (o *Orchestrator) buildPeerClient() (*k8s.Client, error) {
	path := o.peerKubeconfigPath()
	if path == "" {
		return nil, fmt.Errorf("peer kubeconfig path not configured")
	}
	return k8s.NewClient(path)
}

func (o *Orchestrator) newFluxClient() (*flux.Client, error) {
	cfg := o.gitOpsConfig()
	if cfg == nil {
		return nil, fmt.Errorf("gitops configuration not found")
	}
	return flux.NewClient(o.k8sClient, cfg), nil
}

func (o *Orchestrator) gitOpsConfig() *config.GitOpsConfig {
	if o.isNAS && o.config.NAS != nil {
		return &o.config.NAS.GitOps
	}
	if !o.isNAS && o.config.Homelab != nil {
		return &o.config.Homelab.GitOps
	}
	return nil
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

type gatewayEndpoint struct {
	Host   string
	Port   int32
	Source string
}
