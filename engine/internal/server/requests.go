package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
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

	// Every variable the request and the address of its folder reference has
	// to have a value, wherever it was written.
	needed := variableNamesIn([]string{baseURL, def.Path})
	for _, h := range def.Headers {
		needed = append(needed, variableNamesIn([]string{h.Key, h.Value})...)
	}
	for _, param := range def.Params {
		needed = append(needed, variableNamesIn([]string{param.Key, param.Value})...)
	}
	needed = append(needed, variableNamesIn([]string{def.Body})...)
	var missing []string
	seen := map[string]bool{}
	for _, name := range needed {
		if seen[name] || vars[name] != "" {
			continue
		}
		seen[name] = true
		missing = append(missing, name)
	}
	if len(missing) > 0 {
		writeError(w, http.StatusBadRequest, "missing values for "+strings.Join(missing, ", "))
		return
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
	// The address of the folder can carry variables too, and they are needed
	// by every request that uses it.
	baseURL = substituteVars(baseURL, vars, token)
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

// ── Folders (base URLs) ──────────────────────────────────────────────────────

type folderRequest struct {
	Name string `json:"name"`
	URL  string `json:"url"`
	Env  string `json:"env"`
}

// handleAddFolder adds a base URL folder. The folder is global: every
// request environment gets the entry, and the current one gets the URL.
func (s *Server) handleAddFolder(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")

	var req folderRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "folder name is required")
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		for _, f := range p.RequestFolders {
			if f.Name == req.Name {
				return fmt.Errorf("folder %q already exists", req.Name)
			}
		}
		p.RequestFolders = append(p.RequestFolders, config.RequestFolder{Name: req.Name})
		for i := range p.RequestEnvs {
			p.RequestEnvs[i].BaseURLs = append(p.RequestEnvs[i].BaseURLs, config.RequestBaseURL{Name: req.Name, URL: ""})
		}
		if req.Env != "" {
			if err := setEnvBaseURL(p, req.Env, req.Name, strings.TrimSpace(req.URL)); err != nil {
				return err
			}
		}
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

// handleUpdateFolder renames a folder and sets its URL in the current
// environment. A rename follows in every environment and in the requests
// that use it.
func (s *Server) handleUpdateFolder(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	origName := r.PathValue("folder")

	var req folderRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "folder name is required")
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		idx := -1
		for i, f := range p.RequestFolders {
			if f.Name == origName {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("folder %q not found", origName)
		}
		if req.Name != origName {
			for _, f := range p.RequestFolders {
				if f.Name == req.Name {
					return fmt.Errorf("folder %q already exists", req.Name)
				}
			}
			p.RequestFolders[idx].Name = req.Name
			for i := range p.RequestEnvs {
				for j := range p.RequestEnvs[i].BaseURLs {
					if p.RequestEnvs[i].BaseURLs[j].Name == origName {
						p.RequestEnvs[i].BaseURLs[j].Name = req.Name
					}
				}
			}
			for i := range p.RequestDefs {
				if p.RequestDefs[i].BaseURLName == origName {
					p.RequestDefs[i].BaseURLName = req.Name
				}
			}
		}
		if req.Env != "" {
			if err := setEnvBaseURL(p, req.Env, req.Name, strings.TrimSpace(req.URL)); err != nil {
				return err
			}
		}
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

// handleDeleteFolder removes a folder and the requests that use it.
func (s *Server) handleDeleteFolder(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	name := r.PathValue("folder")

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		idx := -1
		for i, f := range p.RequestFolders {
			if f.Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("folder %q not found", name)
		}
		p.RequestFolders = append(p.RequestFolders[:idx], p.RequestFolders[idx+1:]...)
		for i := range p.RequestEnvs {
			kept := make([]config.RequestBaseURL, 0, len(p.RequestEnvs[i].BaseURLs))
			for _, bu := range p.RequestEnvs[i].BaseURLs {
				if bu.Name != name {
					kept = append(kept, bu)
				}
			}
			p.RequestEnvs[i].BaseURLs = kept
		}
		kept := make([]config.RequestDef, 0, len(p.RequestDefs))
		for _, def := range p.RequestDefs {
			if def.BaseURLName != name {
				kept = append(kept, def)
			}
		}
		p.RequestDefs = kept
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

// setEnvBaseURL sets the URL of a base URL inside one request environment.
func setEnvBaseURL(p *config.Profile, envName, folderName, url string) error {
	for i := range p.RequestEnvs {
		if p.RequestEnvs[i].Name != envName {
			continue
		}
		for j := range p.RequestEnvs[i].BaseURLs {
			if p.RequestEnvs[i].BaseURLs[j].Name == folderName {
				p.RequestEnvs[i].BaseURLs[j].URL = url
				ensureURLVariables(p, envName, url)
				return nil
			}
		}
		p.RequestEnvs[i].BaseURLs = append(p.RequestEnvs[i].BaseURLs, config.RequestBaseURL{Name: folderName, URL: url})
		ensureURLVariables(p, envName, url)
		return nil
	}
	return notFoundf("request environment %q not found", envName)
}

// ensureURLVariables creates in the environment the variables of a folder
// address. A {variable} in the address of a folder is needed by every request
// that uses it, so it belongs to the environment as well.
func ensureURLVariables(p *config.Profile, envName, url string) {
	names := variableNamesIn([]string{url})
	if len(names) == 0 {
		return
	}
	for i := range p.RequestEnvs {
		if p.RequestEnvs[i].Name != envName {
			continue
		}
		for _, name := range names {
			found := false
			for _, v := range p.RequestEnvs[i].Variables {
				if v.Name == name {
					found = true
					break
				}
			}
			if !found {
				p.RequestEnvs[i].Variables = append(
					p.RequestEnvs[i].Variables,
					config.RequestEnvVar{Name: name},
				)
			}
		}
	}
}

// variableNamesIn returns the variables a list of texts references.
func variableNamesIn(texts []string) []string {
	var names []string
	seen := map[string]bool{}
	for _, text := range texts {
		for _, match := range requestVariablePattern.FindAllStringSubmatch(text, -1) {
			name := match[1]
			if name == "token" || seen[name] {
				continue
			}
			seen[name] = true
			names = append(names, name)
		}
	}
	return names
}

// ── Requests ─────────────────────────────────────────────────────────────────

// requestDefInput is the payload to create or update a request.
type requestDefInput struct {
	Env         string         `json:"env"`
	Name        string         `json:"name"`
	Method      string         `json:"method"`
	BaseURLName string         `json:"baseUrlName"`
	Path        string         `json:"path"`
	IsLogin     bool           `json:"isLogin"`
	TokenPath   string         `json:"tokenPath"`
	Headers     []requestKVDTO `json:"headers"`
	Params      []requestKVDTO `json:"params"`
	Body        string         `json:"body"`
}

func (in requestDefInput) toDef() (config.RequestDef, error) {
	def := config.RequestDef{
		Name:        strings.TrimSpace(in.Name),
		Method:      strings.ToUpper(strings.TrimSpace(in.Method)),
		BaseURLName: strings.TrimSpace(in.BaseURLName),
		Path:        strings.TrimSpace(in.Path),
		IsLogin:     in.IsLogin,
		TokenPath:   strings.TrimSpace(in.TokenPath),
		Body:        in.Body,
	}
	if def.Name == "" {
		return def, fmt.Errorf("name is required")
	}
	if def.Method == "" {
		return def, fmt.Errorf("method is required")
	}
	if def.BaseURLName == "" {
		return def, fmt.Errorf("base url is required")
	}
	if def.Path == "" {
		return def, fmt.Errorf("path is required")
	}
	if def.IsLogin && def.TokenPath == "" {
		return def, fmt.Errorf("token path is required when the request is a login")
	}
	for _, h := range in.Headers {
		key := strings.TrimSpace(h.Key)
		if key == "" {
			continue
		}
		def.Headers = append(def.Headers, config.RequestKV{Key: key, Value: h.Value})
	}
	for _, p := range in.Params {
		key := strings.TrimSpace(p.Key)
		if key == "" {
			continue
		}
		def.Params = append(def.Params, config.RequestKV{Key: key, Value: p.Value})
	}
	return def, nil
}

// requestVariablePattern matches the {variable} references of a request.
// The names can carry dashes, like {activity-ids-list}.
var requestVariablePattern = regexp.MustCompile(`\{([\w-]+)\}`)

// requestVariableNames returns the variables a request references, in the
// order they appear and without duplicates. The token is not one of them: it
// comes from the login request.
func requestVariableNames(def config.RequestDef) []string {
	// The same order the app asks them in: path, headers, params, body.
	var texts []string
	texts = append(texts, def.Path)
	for _, h := range def.Headers {
		texts = append(texts, h.Key, h.Value)
	}
	for _, p := range def.Params {
		texts = append(texts, p.Key, p.Value)
	}
	texts = append(texts, def.Body)
	return variableNamesIn(texts)
}

// ensureRequestVariables creates in the environment the variables the request
// references. Writing {variable} anywhere in a request is enough: the
// variable exists from that moment, and it is asked for when the request runs.
func ensureRequestVariables(p *config.Profile, envName string, def config.RequestDef) {
	if envName == "" {
		return
	}
	names := requestVariableNames(def)
	if len(names) == 0 {
		return
	}
	for i := range p.RequestEnvs {
		if p.RequestEnvs[i].Name != envName {
			continue
		}
		for _, name := range names {
			found := false
			for _, v := range p.RequestEnvs[i].Variables {
				if v.Name == name {
					found = true
					break
				}
			}
			if !found {
				p.RequestEnvs[i].Variables = append(
					p.RequestEnvs[i].Variables,
					config.RequestEnvVar{Name: name},
				)
			}
		}
	}
}

func (s *Server) handleAddRequestItem(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")

	var in requestDefInput
	if err := decodeJSON(r, &in); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	def, err := in.toDef()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	err = s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		for _, d := range p.RequestDefs {
			if d.Name == def.Name {
				return fmt.Errorf("request %q already exists", def.Name)
			}
		}
		p.RequestDefs = append(p.RequestDefs, def)
		ensureRequestVariables(p, in.Env, def)
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

func (s *Server) handleUpdateRequestItem(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	origName := r.PathValue("name")

	var in requestDefInput
	if err := decodeJSON(r, &in); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	def, err := in.toDef()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	err = s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		idx := -1
		for i, d := range p.RequestDefs {
			if d.Name == origName {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("request %q not found", origName)
		}
		if def.Name != origName {
			for _, d := range p.RequestDefs {
				if d.Name == def.Name {
					return fmt.Errorf("request %q already exists", def.Name)
				}
			}
		}
		p.RequestDefs[idx] = def
		ensureRequestVariables(p, in.Env, def)
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

func (s *Server) handleDeleteRequestItem(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	name := r.PathValue("name")

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		idx := -1
		for i, d := range p.RequestDefs {
			if d.Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("request %q not found", name)
		}
		p.RequestDefs = append(p.RequestDefs[:idx], p.RequestDefs[idx+1:]...)
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

// ── Request environments ─────────────────────────────────────────────────────

func (s *Server) handleAddRequestEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")

	var req struct {
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required")
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		for _, env := range p.RequestEnvs {
			if env.Name == req.Name {
				return fmt.Errorf("request environment %q already exists", req.Name)
			}
		}
		env := config.RequestEnv{Name: req.Name}
		// Every folder gets an entry in the new environment.
		for _, folder := range p.RequestFolders {
			env.BaseURLs = append(env.BaseURLs, config.RequestBaseURL{Name: folder.Name})
		}
		p.RequestEnvs = append(p.RequestEnvs, env)
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

func (s *Server) handleDeleteRequestEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	name := r.PathValue("name")

	err := s.store.Update(func(c *config.Config) error {
		p, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		idx := -1
		for i, env := range p.RequestEnvs {
			if env.Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("request environment %q not found", name)
		}
		if name == "local" {
			return fmt.Errorf("the local request environment cannot be removed")
		}
		p.RequestEnvs = append(p.RequestEnvs[:idx], p.RequestEnvs[idx+1:]...)
		p.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeRequests(w, profileName)
}

// writeRequests answers with the refreshed request payload.
func (s *Server) writeRequests(w http.ResponseWriter, profileName string) {
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
