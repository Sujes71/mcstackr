package portforward

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// K8sDeployment represents a deployment fetched from kubectl.
type K8sDeployment struct {
	Name          string
	Desired       int
	Available     int
	Updated       int
	Progressing   bool
	LastRestarted string // human-readable time since last rollout (e.g. "5m", "2h")
	Age           string
	Strategy      string
}

// DiscoverDeployments returns the deployments of a namespace.
// Runs: kubectl get deploy -n <ns> --context <ctx> -o json
func DiscoverDeployments(ctxName, namespace string) ([]K8sDeployment, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "get", "deploy",
		"-n", namespace, "--context", ctxName, "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl: %w", err)
	}

	var result struct {
		Items []struct {
			Metadata struct {
				Name              string `json:"name"`
				CreationTimestamp string `json:"creationTimestamp"`
			} `json:"metadata"`
			Spec struct {
				Replicas *int `json:"replicas"`
				Strategy struct {
					Type string `json:"type"`
				} `json:"strategy"`
			} `json:"spec"`
			Status struct {
				AvailableReplicas int32 `json:"availableReplicas"`
				UpdatedReplicas   int32 `json:"updatedReplicas"`
				Conditions        []struct {
					Type               string `json:"type"`
					Status             string `json:"status"`
					LastUpdateTime     string `json:"lastUpdateTime"`
					LastTransitionTime string `json:"lastTransitionTime"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}

	if err := json.Unmarshal(out, &result); err != nil {
		return nil, fmt.Errorf("parse k8s response: %w", err)
	}

	var depls []K8sDeployment
	for _, item := range result.Items {
		d := K8sDeployment{
			Name:      item.Metadata.Name,
			Strategy:  item.Spec.Strategy.Type,
			Age:       computeAge(item.Metadata.CreationTimestamp),
			Available: int(item.Status.AvailableReplicas),
			Updated:   int(item.Status.UpdatedReplicas),
		}
		// The Progressing condition is updated by Kubernetes on every
		// rollout, so its last update time is when the last rollout
		// happened.
		for _, cond := range item.Status.Conditions {
			if cond.Type == "Progressing" && cond.LastUpdateTime != "" {
				d.LastRestarted = computeAge(cond.LastUpdateTime)
			}
		}
		if item.Spec.Replicas != nil {
			d.Desired = *item.Spec.Replicas
		} else {
			d.Desired = int(item.Status.AvailableReplicas)
		}
		// Progressing means not every pod is on the latest revision yet.
		d.Progressing = d.Updated < d.Desired
		depls = append(depls, d)
	}
	return depls, nil
}

// RolloutRestart runs kubectl rollout restart deployment/<name>.
func RolloutRestart(ctxName, namespace, deploy string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "rollout", "restart",
		"deployment/"+deploy, "--context", ctxName, "-n", namespace).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

// ScaleDeployment runs kubectl scale deployment/<name> --replicas=<N>.
func ScaleDeployment(ctxName, namespace, deploy string, replicas int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "scale",
		"deployment/"+deploy, fmt.Sprintf("--replicas=%d", replicas),
		"--context", ctxName, "-n", namespace).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

// GetDeploymentLogs runs kubectl logs deployment/<name> --tail=<lines>.
//
// It does not follow the logs: the console runtime streamed them to the
// terminal, but an app cannot hand its terminal over to kubectl. The last
// lines are read instead, and the view asks for them again when it wants
// more.
func GetDeploymentLogs(ctxName, namespace, deploy string, lines int) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "logs",
		"deployment/"+deploy, fmt.Sprintf("--tail=%d", lines),
		"--context", ctxName, "-n", namespace).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// DescribeDeployment runs kubectl describe deployment/<name>.
func DescribeDeployment(ctxName, namespace, deploy string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "describe",
		"deployment/"+deploy, "--context", ctxName, "-n", namespace).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// DeleteDeployment runs kubectl delete deployment/<name>.
func DeleteDeployment(ctxName, namespace, deploy string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "kubectl", "delete",
		"deployment/"+deploy, "--context", ctxName, "-n", namespace).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

// computeAge converts a Kubernetes timestamp string (RFC 3339) into a
// human-readable age like "10d", "5h", "30m", "12s".
func computeAge(creationTimestamp string) string {
	t, err := time.Parse(time.RFC3339, creationTimestamp)
	if err != nil {
		return "unknown"
	}
	d := time.Since(t)
	switch {
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case d >= time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d >= time.Minute:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	default:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
}
