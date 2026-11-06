package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
)

// ── DTOs ─────────────────────────────────────────────────────────────────────

type mockActionDTO struct {
	ID             string            `json:"id"`
	Label          string            `json:"label"`
	Group          string            `json:"group"`
	Params         []string          `json:"params"`
	Defaults       map[string]string `json:"defaults,omitempty"`
	Destructive    bool              `json:"destructive"`
	Enabled        bool              `json:"enabled"`
	DisabledReason string            `json:"disabledReason,omitempty"`
}

type mockOpsResponse struct {
	Port    string          `json:"port"`
	Actions []mockActionDTO `json:"actions"`
	Running bool            `json:"running"`
}

type mockRunRequest struct {
	Action string            `json:"action"`
	Params map[string]string `json:"params"`
}

// ── Actions ──────────────────────────────────────────────────────────────────

// mockAction describes one operation of the mock server.
type mockAction struct {
	id          string
	label       string
	group       string
	params      []string
	destructive bool
}

func mockActions() []mockAction {
	return []mockAction{
		{id: "create-expectation", label: "Create expectation", group: "Expectations",
			params: []string{"method", "path", "query_params", "status_code", "content_type", "body"}},
		{id: "import-expectation", label: "Import expectation", group: "Expectations",
			params: []string{"body"}},
		{id: "list-expectations", label: "List active expectations", group: "Expectations"},
		{id: "reset-all", label: "Reset all", group: "Expectations", destructive: true},
		{id: "verify-request", label: "Verify request", group: "Verification",
			params: []string{"method", "path", "at_least"}},
		{id: "retrieve-requests", label: "Retrieve requests", group: "Verification"},
	}
}

// mockParamDefaults are the values a parameter starts with.
func mockParamDefaults(actionID string) map[string]string {
	defaults := map[string]string{
		"method":       "GET",
		"status_code":  "200",
		"content_type": "application/json",
		"at_least":     "1",
	}
	if actionID == "create-expectation" {
		defaults["path"] = "/"
	}
	return defaults
}

// ── List ─────────────────────────────────────────────────────────────────────

func (s *Server) handleMockOps(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var response mockOpsResponse
	err := s.store.View(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		if svc.MockType() == "" {
			return fmt.Errorf("service %q is not a mock server", serviceName)
		}

		port := mockHostPort(svc)
		reason := ""
		if !mockServerReady(port) {
			reason = "start the service first"
		}
		for _, action := range mockActions() {
			enabled := true
			if !action.destructive && reason != "" {
				enabled = false
			}
			response.Actions = append(response.Actions, mockActionDTO{
				ID:             action.id,
				Label:          action.label,
				Group:          action.group,
				Params:         action.params,
				Defaults:       mockParamDefaults(action.id),
				Destructive:    action.destructive,
				Enabled:        enabled,
				DisabledReason: reason,
			})
		}
		response.Port = port
		response.Running = reason == ""
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

// ── Run ──────────────────────────────────────────────────────────────────────

func (s *Server) handleMockOpRun(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var req mockRunRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Action = strings.TrimSpace(req.Action)

	var (
		port string
		def  *mockAction
	)
	err := s.store.View(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		if svc.MockType() == "" {
			return fmt.Errorf("service %q is not a mock server", serviceName)
		}
		port = mockHostPort(svc)
		all := mockActions()
		for i := range all {
			if all[i].id == req.Action {
				def = &all[i]
				break
			}
		}
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	if def == nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q not found", req.Action))
		return
	}
	for _, name := range def.params {
		if strings.TrimSpace(req.Params[name]) == "" && def.id != "import-expectation" {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("%s is required", name))
			return
		}
	}

	out, err := runMockAction(port, def, req.Params)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"output":     out,
		"finishedAt": time.Now().UTC().Format(time.RFC3339),
	})
}

// runMockAction performs the call to the mock server.
func runMockAction(port string, action *mockAction, params map[string]string) (string, error) {
	switch action.id {
	case "list-expectations":
		return mockCall(port, "/mockserver/retrieve", http.MethodPut, nil, map[string]string{"type": "ACTIVE_EXPECTATIONS"})
	case "retrieve-requests":
		return mockCall(port, "/mockserver/retrieve", http.MethodPut, nil, map[string]string{"type": "REQUESTS"})
	case "reset-all":
		return mockCall(port, "/mockserver/reset", http.MethodPut, nil, nil)
	case "create-expectation":
		statusCode := 200
		fmt.Sscanf(params["status_code"], "%d", &statusCode)

		httpRequest := map[string]interface{}{
			"method": params["method"],
			"path":   params["path"],
		}
		if query := strings.TrimSpace(params["query_params"]); query != "" {
			if parsed, err := url.ParseQuery(query); err == nil {
				httpRequest["queryStringParameters"] = map[string][]string(parsed)
			}
		}
		body := map[string]interface{}{
			"httpRequest": httpRequest,
			"httpResponse": map[string]interface{}{
				"statusCode": statusCode,
				"headers": map[string][]string{
					"Content-Type": {params["content_type"]},
				},
				"body": params["body"],
			},
		}
		return mockCall(port, "/mockserver/expectation", http.MethodPut, body, nil)
	case "import-expectation":
		raw := strings.TrimSpace(params["body"])
		var parsed map[string]interface{}
		if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
			return "", fmt.Errorf("invalid JSON: %s", err)
		}
		if _, ok := parsed["httpRequest"]; !ok {
			return "", fmt.Errorf("missing httpRequest field: it must be a MockServer expectation with httpRequest and httpResponse")
		}
		out, err := mockCall(port, "/mockserver/expectation", http.MethodPut, nil, nil, raw)
		if err != nil {
			return "", err
		}
		if strings.TrimSpace(out) == "{}" || strings.TrimSpace(out) == "" {
			return "Expectation imported successfully.", nil
		}
		return out, nil
	case "verify-request":
		atLeast := 1
		fmt.Sscanf(params["at_least"], "%d", &atLeast)
		body := map[string]interface{}{
			"httpRequest": map[string]interface{}{
				"method": params["method"],
				"path":   params["path"],
			},
			"times": map[string]int{
				"atLeast": atLeast,
				"atMost":  atLeast,
			},
		}
		return mockCall(port, "/mockserver/verify", http.MethodPut, body, nil)
	}
	return "", fmt.Errorf("action %q not found", action.id)
}

// mockCall talks to the mock server.
func mockCall(port, endpoint, method string, body interface{}, queryParams map[string]string, raw ...string) (string, error) {
	apiURL := fmt.Sprintf("http://localhost:%s%s", port, endpoint)
	if len(queryParams) > 0 {
		query := url.Values{}
		for key, value := range queryParams {
			query.Set(key, value)
		}
		apiURL += "?" + query.Encode()
	}

	var payload io.Reader
	if len(raw) > 0 {
		payload = strings.NewReader(raw[0])
	} else if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return "", err
		}
		payload = bytes.NewReader(encoded)
	}

	httpReq, err := http.NewRequest(method, apiURL, payload)
	if err != nil {
		return "", fmt.Errorf("request failed: %w", err)
	}
	if body != nil || len(raw) > 0 {
		httpReq.Header.Set("Content-Type", "application/json")
	}

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("cannot reach the mock server at localhost:%s — is the service running? %w", port, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("mock server error (%d): %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if len(data) == 0 {
		return "", nil
	}
	return prettyMockResult(data), nil
}

// prettyMockResult prints the JSON of the mock server in a readable way.
func prettyMockResult(data []byte) string {
	var parsed interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		return strings.TrimSpace(string(data))
	}
	pretty, err := json.MarshalIndent(parsed, "", "  ")
	if err != nil {
		return strings.TrimSpace(string(data))
	}
	return string(pretty)
}

// mockHostPort returns the port where the mock server is listening.
func mockHostPort(svc *config.Service) string {
	for _, p := range svc.Ports {
		if p.Container == "1080" {
			return p.Host
		}
	}
	return "1080"
}

// mockServerReady tells whether the mock server is answering.
func mockServerReady(port string) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequest(http.MethodPut, fmt.Sprintf("http://localhost:%s/mockserver/retrieve?type=ACTIVE_EXPECTATIONS", port), nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// mockPortNumber returns the numeric port, for the messages.
func mockPortNumber(port string) int {
	value, err := strconv.Atoi(strings.TrimSpace(port))
	if err != nil {
		return 1080
	}
	return value
}
