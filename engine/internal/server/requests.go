package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
)

// ── DTOs ─────────────────────────────────────────────────────────────────────

type requestBaseURLDTO struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type requestVarDTO struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type requestEnvDTO struct {
	Name      string              `json:"name"`
	BaseURLs  []requestBaseURLDTO `json:"baseUrls"`
	Variables []requestVarDTO     `json:"variables"`
}

type requestKVDTO struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type requestDefDTO struct {
	Name         string         `json:"name"`
	Method       string         `json:"method"`
	BaseURLName  string         `json:"baseUrlName"`
	Path         string         `json:"path"`
	IsLogin      bool           `json:"isLogin"`
	TokenPath    string         `json:"tokenPath"`
	Headers      []requestKVDTO `json:"headers"`
	Params       []requestKVDTO `json:"params"`
	Body         string         `json:"body"`
	VariableRefs []string       `json:"variableRefs"`
}

type requestsResponse struct {
	Envs     []requestEnvDTO `json:"envs"`
	Folders  []string        `json:"folders"`
	Requests []requestDefDTO `json:"requests"`
}

type requestRunRequest struct {
	Env       string            `json:"env"`
	Request   string            `json:"request"`
	Variables map[string]string `json:"variables"`
}

type requestRunResponse struct {
	Status     int    `json:"status"`
	StatusText string `json:"statusText"`
	Body       string `json:"body"`
	DurationMs int64  `json:"durationMs"`
	Token      string `json:"token,omitempty"`
	URL        string `json:"url"`
}

// ── List ─────────────────────────────────────────────────────────────────────

func (s *Server) handleRequests(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")

	var response requestsResponse
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		response = requestsResponse{
			Envs:     requestEnvsDTO(p.RequestEnvs),
			Folders:  requestFoldersDTO(p.RequestFolders),
			Requests: requestDefsDTO(p.RequestDefs),
		}
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func requestEnvsDTO(envs []config.RequestEnv) []requestEnvDTO {
	out := make([]requestEnvDTO, 0, len(envs))
	for _, env := range envs {
		// Empty lists are sent as [] and never as null: a null array is not
		// a valid value for a list on the other side.
		dto := requestEnvDTO{
			Name:      env.Name,
			BaseURLs:  make([]requestBaseURLDTO, 0, len(env.BaseURLs)),
			Variables: make([]requestVarDTO, 0, len(env.Variables)),
		}
		for _, u := range env.BaseURLs {
			dto.BaseURLs = append(dto.BaseURLs, requestBaseURLDTO{Name: u.Name, URL: u.URL})
		}
		for _, v := range env.Variables {
			dto.Variables = append(dto.Variables, requestVarDTO{Name: v.Name, Value: v.Value})
		}
		out = append(out, dto)
	}
	return out
}

func requestFoldersDTO(folders []config.RequestFolder) []string {
	out := make([]string, 0, len(folders))
	for _, f := range folders {
		out = append(out, f.Name)
	}
	return out
}

func requestDefsDTO(defs []config.RequestDef) []requestDefDTO {
	out := make([]requestDefDTO, 0, len(defs))
	for _, d := range defs {
		dto := requestDefDTO{
			Name:         d.Name,
			Method:       d.Method,
			BaseURLName:  d.BaseURLName,
			Path:         d.Path,
			IsLogin:      d.IsLogin,
			TokenPath:    d.TokenPath,
			Body:         d.Body,
			Headers:      make([]requestKVDTO, 0, len(d.Headers)),
			Params:       make([]requestKVDTO, 0, len(d.Params)),
			VariableRefs: make([]string, 0, len(d.VariableRefs)),
		}
		for _, h := range d.Headers {
			dto.Headers = append(dto.Headers, requestKVDTO{Key: h.Key, Value: h.Value})
		}
		for _, p := range d.Params {
			dto.Params = append(dto.Params, requestKVDTO{Key: p.Key, Value: p.Value})
		}
		out = append(out, dto)
	}
	return out
}

// ── Run ──────────────────────────────────────────────────────────────────────

func (s *Server) handleRunRequest(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")

	var req requestRunRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Env = strings.TrimSpace(req.Env)
	req.Request = strings.TrimSpace(req.Request)
	if req.Env == "" || req.Request == "" {
		writeError(w, http.StatusBadRequest, "env and request are required")
		return
	}

	var (
		def      config.RequestDef
		baseURL  string
		vars     map[string]string
		token    string
		envIndex int
	)
	err := s.store.View(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		envIndex = -1
		for i := range p.RequestEnvs {
			if p.RequestEnvs[i].Name == req.Env {
				envIndex = i
				break
			}
		}
		if envIndex < 0 {
			return notFoundf("request environment %q not found", req.Env)
		}
		env := p.RequestEnvs[envIndex]
		for _, d := range p.RequestDefs {
			if d.Name == req.Request {
				def = d
				break
			}
		}
		if def.Name == "" {
			return notFoundf("request %q not found", req.Request)
		}
		for _, u := range env.BaseURLs {
			if u.Name == def.BaseURLName {
				baseURL = u.URL
				break
			}
		}
		if baseURL == "" {
			return fmt.Errorf("base url %q not found in request environment %q", def.BaseURLName, req.Env)
		}
		vars = map[string]string{}
		for _, v := range env.Variables {
			vars[v.Name] = v.Value
			if v.Name == "_token" {
				token = v.Value
			}
		}
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	// The values the user typed win over the ones stored in the environment.
	for name, value := range req.Variables {
		vars[name] = value
	}

	result, err := runRequestDef(def, baseURL, vars, token)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	// A login request stores the token it got back, and the values the user
	// typed are kept in the environment.
	if err := s.persistRequestRun(profileName, req.Env, envIndex, req.Variables, result.Token); err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	writeJSON(w, http.StatusOK, result)
}

// persistRequestRun stores the prompted variables and the extracted token in
// the request environment.
func (s *Server) persistRequestRun(profileName, envName string, envIndex int, values map[string]string, token string) error {
	return s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		if envIndex < 0 || envIndex >= len(p.RequestEnvs) {
			return notFoundf("request environment %q not found", envName)
		}
		env := &p.RequestEnvs[envIndex]
		for name, value := range values {
			setRequestVar(env, name, value)
		}
		if token != "" {
			setRequestVar(env, "_token", token)
		}
		p.UpdatedAt = time.Now()
		return c.Save()
	})
}

func setRequestVar(env *config.RequestEnv, name, value string) {
	for i := range env.Variables {
		if env.Variables[i].Name == name {
			env.Variables[i].Value = value
			return
		}
	}
	env.Variables = append(env.Variables, config.RequestEnvVar{Name: name, Value: value})
}

// runRequestDef builds and runs a request, with the same substitution rules
// as the original runtime: the variables of the environment and {token} are
// replaced in the path, the query params, the headers and the body.
func runRequestDef(def config.RequestDef, baseURL string, vars map[string]string, token string) (requestRunResponse, error) {
	path := def.Path
	if path != "" && !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	fullURL := strings.TrimRight(baseURL, "/") + path
	fullURL = substituteVars(fullURL, vars, token)

	if len(def.Params) > 0 {
		parts := make([]string, 0, len(def.Params))
		for _, p := range def.Params {
			parts = append(parts, substituteVars(p.Key, vars, token)+"="+substituteVars(p.Value, vars, token))
		}
		fullURL += "?" + strings.Join(parts, "&")
	}

	var body io.Reader
	if def.Body != "" {
		body = bytes.NewReader([]byte(substituteVars(def.Body, vars, token)))
	}

	method := strings.ToUpper(strings.TrimSpace(def.Method))
	if method == "" {
		method = http.MethodGet
	}
	httpReq, err := http.NewRequest(method, fullURL, body)
	if err != nil {
		return requestRunResponse{}, fmt.Errorf("build request: %w", err)
	}
	for _, h := range def.Headers {
		httpReq.Header.Set(
			substituteVars(h.Key, vars, token),
			substituteVars(h.Value, vars, token),
		)
	}
	if def.Body != "" && httpReq.Header.Get("Content-Type") == "" {
		httpReq.Header.Set("Content-Type", "application/json")
	}

	client := &http.Client{Timeout: 10 * time.Second}
	started := time.Now()
	resp, err := client.Do(httpReq)
	if err != nil {
		return requestRunResponse{}, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()
	respData, _ := io.ReadAll(resp.Body)

	result := requestRunResponse{
		Status:     resp.StatusCode,
		StatusText: http.StatusText(resp.StatusCode),
		Body:       prettyBody(respData),
		DurationMs: time.Since(started).Milliseconds(),
		URL:        fullURL,
	}

	if def.IsLogin && def.TokenPath != "" && len(respData) > 0 {
		result.Token = extractTokenFromJSON(respData, def.TokenPath)
	}
	return result, nil
}

// substituteVars replaces the environment variables and {token} in a string.
func substituteVars(s string, vars map[string]string, token string) string {
	result := s
	for k, v := range vars {
		result = strings.ReplaceAll(result, "{"+k+"}", v)
	}
	return strings.ReplaceAll(result, "{token}", token)
}

// extractTokenFromJSON reads a value from a JSON response using a dot path.
func extractTokenFromJSON(data []byte, dotPath string) string {
	if dotPath == "" {
		return ""
	}
	var raw interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return ""
	}
	parts := strings.Split(dotPath, ".")
	current := raw
	for _, part := range parts {
		switch v := current.(type) {
		case map[string]interface{}:
			val, ok := v[part]
			if !ok {
				return ""
			}
			current = val
		case []interface{}:
			idx := 0
			if _, err := fmt.Sscanf(part, "%d", &idx); err != nil || idx < 0 || idx >= len(v) {
				return ""
			}
			current = v[idx]
		default:
			return ""
		}
	}
	switch v := current.(type) {
	case string:
		return v
	default:
		return ""
	}
}

// prettyBody indents a JSON body, and leaves anything else untouched.
func prettyBody(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, data, "", "  ") == nil {
		return pretty.String()
	}
	return string(data)
}
