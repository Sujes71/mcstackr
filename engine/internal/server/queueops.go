package server

import (
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/docker"
)

// ── DTOs ─────────────────────────────────────────────────────────────────────

type queueEnvDTO struct {
	Name               string           `json:"name"`
	QueueType          string           `json:"queueType"`
	Host               string           `json:"host"`
	Port               string           `json:"port"`
	User               string           `json:"user"`
	ToolImage          string           `json:"toolImage"`
	BootstrapServers   string           `json:"bootstrapServers"`
	ManagementEndpoint string           `json:"managementEndpoint"`
	VHost              string           `json:"vhost"`
	BrokerURL          string           `json:"brokerUrl"`
	CustomActions      []queueCustomDTO `json:"customActions"`
	IsLocal            bool             `json:"isLocal"`
}

// queueCustomDTO is a custom action of a queue environment.
type queueCustomDTO struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

type queueActionDTO struct {
	ID             string   `json:"id"`
	Label          string   `json:"label"`
	Group          string   `json:"group"`
	Params         []string `json:"params"`
	Destructive    bool     `json:"destructive"`
	Enabled        bool     `json:"enabled"`
	DisabledReason string   `json:"disabledReason,omitempty"`
}

type queueOpsResponse struct {
	QueueType string           `json:"queueType"`
	Envs      []queueEnvDTO    `json:"envs"`
	Actions   []queueActionDTO `json:"actions"`
	Running   bool             `json:"running"`
}

// queueTableDTO is a table of the result of an operation, so the app can
// show it as a table instead of a wall of text.
type queueTableDTO struct {
	Columns []string   `json:"columns"`
	Rows    [][]string `json:"rows"`
}

type queueRunRequest struct {
	Env    string            `json:"env"`
	Action string            `json:"action"`
	Params map[string]string `json:"params"`
}

type queueSyncEnvRequest struct {
	Name               string `json:"name"`
	QueueType          string `json:"queueType"`
	Host               string `json:"host"`
	Port               string `json:"port"`
	User               string `json:"user"`
	Password           string `json:"password"`
	ToolImage          string `json:"toolImage"`
	BootstrapServers   string `json:"bootstrapServers"`
	ManagementEndpoint string `json:"managementEndpoint"`
	VHost              string `json:"vhost"`
	BrokerURL          string `json:"brokerUrl"`
}

// ── Actions ──────────────────────────────────────────────────────────────────

// queueAction describes one operation of a queue, with the parameters it
// needs. The commands are the ones of the original runtime.
type queueAction struct {
	id          string
	label       string
	group       string
	params      []string
	destructive bool
}

func queueActions(queueType string) []queueAction {
	switch queueType {
	case "kafka":
		return []queueAction{
			{id: "kafka-list-topics", label: "List topics", group: "Topics"},
			{id: "kafka-describe-topic", label: "Describe topic", group: "Topics", params: []string{"topic"}},
			{id: "kafka-create-topic", label: "Create topic", group: "Topics", params: []string{"topic", "partitions", "replication_factor"}},
			{id: "kafka-delete-topic", label: "Delete topic", group: "Topics", params: []string{"topic"}, destructive: true},
			{id: "kafka-send-message", label: "Send message", group: "Messaging", params: []string{"topic", "message"}},
			{id: "kafka-consume-messages", label: "Consume messages", group: "Messaging", params: []string{"topic"}},
			{id: "kafka-list-groups", label: "List groups", group: "Consumer Groups"},
			{id: "kafka-describe-group", label: "Describe group", group: "Consumer Groups", params: []string{"group"}},
			{id: "kafka-reset-offset", label: "Reset offset", group: "Consumer Groups", params: []string{"group", "topic"}, destructive: true},
		}
	case "rabbitmq":
		return []queueAction{
			{id: "rabbitmq-list-queues", label: "List queues", group: "Queues"},
			{id: "rabbitmq-create-queue", label: "Create queue", group: "Queues", params: []string{"name"}},
			{id: "rabbitmq-delete-queue", label: "Delete queue", group: "Queues", params: []string{"name"}, destructive: true},
			{id: "rabbitmq-purge-queue", label: "Purge queue", group: "Queues", params: []string{"name"}, destructive: true},
			{id: "rabbitmq-list-exchanges", label: "List exchanges", group: "Exchanges & Bindings"},
			{id: "rabbitmq-list-bindings", label: "List bindings", group: "Exchanges & Bindings"},
			{id: "rabbitmq-list-connections", label: "List connections", group: "Connections"},
			{id: "rabbitmq-list-channels", label: "List channels", group: "Connections"},
			{id: "rabbitmq-list-consumers", label: "List consumers", group: "Connections"},
		}
	case "activemq":
		return []queueAction{
			{id: "activemq-list-destinations", label: "List destinations", group: "Queues"},
			{id: "activemq-browse-queue", label: "Browse queue", group: "Queues", params: []string{"queue"}},
			{id: "activemq-purge-queue", label: "Purge queue", group: "Queues", params: []string{"queue"}, destructive: true},
			{id: "activemq-send-message", label: "Send message", group: "Messaging", params: []string{"queue", "message"}},
			{id: "activemq-consume-messages", label: "Consume messages", group: "Messaging", params: []string{"queue"}},
		}
	default:
		return nil
	}
}

// ── List ─────────────────────────────────────────────────────────────────────

func (s *Server) handleQueueOps(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var response queueOpsResponse
	err := s.store.View(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		queueType := svc.QueueType()
		if queueType == "" {
			return fmt.Errorf("service %q is not a queue", serviceName)
		}

		container := docker.ContainerName(profileName, envName, serviceName)
		running, _ := docker.QueueContainerRunning(container)

		// The local queue is always the first one, then the remote ones.
		envs := []queueEnvDTO{{
			Name:          "(local)",
			QueueType:     queueType,
			Host:          "localhost",
			CustomActions: make([]queueCustomDTO, 0),
			IsLocal:       true,
		}}
		for _, qse := range svc.QueueSyncEnvs {
			env := queueEnvDTO{
				Name:               qse.Name,
				QueueType:          qse.QueueType,
				Host:               qse.Host,
				Port:               qse.Port,
				User:               qse.User,
				ToolImage:          qse.ToolImage,
				BootstrapServers:   qse.BootstrapServers,
				ManagementEndpoint: qse.ManagementEndpoint,
				VHost:              qse.VHost,
				BrokerURL:          qse.BrokerURL,
				CustomActions:      make([]queueCustomDTO, 0, len(qse.CustomActions)),
			}
			for _, action := range qse.CustomActions {
				env.CustomActions = append(env.CustomActions, queueCustomDTO{
					Name:    action.Name,
					Command: action.Command,
				})
			}
			envs = append(envs, env)
		}

		reason := ""
		if !running {
			reason = "start the service first"
		}
		for _, action := range queueActions(queueType) {
			enabled := true
			if !action.destructive && reason != "" {
				enabled = false
			}
			response.Actions = append(response.Actions, queueActionDTO{
				ID:             action.id,
				Label:          action.label,
				Group:          action.group,
				Params:         action.params,
				Destructive:    action.destructive,
				Enabled:        enabled,
				DisabledReason: reason,
			})
		}

		response.QueueType = queueType
		response.Envs = envs
		response.Running = running
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

// ── Run ──────────────────────────────────────────────────────────────────────

func (s *Server) handleQueueOpRun(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var req queueRunRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Env = strings.TrimSpace(req.Env)
	req.Action = strings.TrimSpace(req.Action)
	if req.Action == "" {
		writeError(w, http.StatusBadRequest, "action is required")
		return
	}

	var (
		queueType string
		container string
		qse       *config.QueueSyncEnv
	)
	err := s.store.View(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		queueType = svc.QueueType()
		if queueType == "" {
			return fmt.Errorf("service %q is not a queue", serviceName)
		}
		container = docker.ContainerName(profileName, envName, serviceName)
		if req.Env != "" {
			found := svc.FindQueueSyncEnv(req.Env)
			if found == nil {
				return notFoundf("queue environment %q not found", req.Env)
			}
			qse = found
		}
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}

	// A custom action of the environment runs its own command.
	if strings.HasPrefix(req.Action, "custom:") {
		s.runQueueCustomAction(w, r, qse, container, profileName, envName, serviceName, req)
		return
	}

	var action *queueAction
	all := queueActions(queueType)
	for i := range all {
		if all[i].id == req.Action {
			action = &all[i]
			break
		}
	}
	if action == nil {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q not found", req.Action))
		return
	}
	for _, name := range action.params {
		if strings.TrimSpace(req.Params[name]) == "" {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("%s is required", name))
			return
		}
	}

	program, args := queueCommand(action, qse, req.Params)
	var out string
	if qse != nil {
		out, err = docker.QueueExecRemote(qse, program, args...)
	} else {
		out, err = docker.QueueExecLocal(container, program, args...)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, queueRunResponse(out, action.id))
}

// queueRunResponse answers with the output of an operation and, when the
// output is a table, with its rows parsed.
func queueRunResponse(out, actionID string) map[string]any {
	clean := cleanQueueOutput(out)
	response := map[string]any{"output": clean}
	if table := parseQueueTable(clean, actionID); table != nil {
		response["table"] = table
	}
	return response
}

// parseQueueTable reads the table of the destinations that ActiveMQ prints.
func parseQueueTable(out, actionID string) *queueTableDTO {
	if actionID != "activemq-list-destinations" {
		return nil
	}
	lines := strings.Split(out, "\n")
	var table *queueTableDTO
	for _, line := range lines {
		fields := splitTableRow(line)
		if len(fields) == 0 {
			continue
		}
		if fields[0] == "Name" {
			table = &queueTableDTO{Columns: fields}
			continue
		}
		if table == nil {
			continue
		}
		table.Rows = append(table.Rows, fields)
	}
	return table
}

// splitTableRow splits a row of the table on the runs of spaces.
func splitTableRow(line string) []string {
	var fields []string
	for _, field := range regexp.MustCompile(`\s{2,}`).Split(strings.TrimSpace(line), -1) {
		if field != "" {
			fields = append(fields, field)
		}
	}
	return fields
}

// cleanQueueOutput makes the output of a queue readable: the activemq CLI
// prints a Java banner before the real output, and every line comes with
// trailing spaces.
func cleanQueueOutput(out string) string {
	lines := strings.Split(out, "\n")
	cleaned := make([]string, 0, len(lines))
	inBanner := false
	for i, line := range lines {
		line = strings.TrimRight(line, " \t\r")
		if i == 0 && strings.HasPrefix(line, "Java Runtime:") {
			inBanner = true
			continue
		}
		if inBanner {
			if line == "" || isActivemqBannerLine(line) {
				continue
			}
			inBanner = false
		}
		cleaned = append(cleaned, line)
	}
	for len(cleaned) > 0 && cleaned[0] == "" {
		cleaned = cleaned[1:]
	}
	return strings.TrimRight(strings.Join(cleaned, "\n"), "\n")
}

// isActivemqBannerLine tells whether a line belongs to the banner the
// activemq CLI prints before its output.
func isActivemqBannerLine(line string) bool {
	for _, prefix := range []string{
		"  Heap sizes:", "    JVM args:", "Extensions classpath:", "  [",
		"ACTIVEMQ_HOME:", "ACTIVEMQ_BASE:", "ACTIVEMQ_CONF:", "ACTIVEMQ_DATA:",
	} {
		if strings.HasPrefix(line, prefix) {
			return true
		}
	}
	return false
}

// runQueueCustomAction runs a custom action of a queue environment: its own
// command, with the variables of the environment and the auto variables of
// the original runtime.
func (s *Server) runQueueCustomAction(
	w http.ResponseWriter,
	r *http.Request,
	qse *config.QueueSyncEnv,
	container string,
	profileName, envName, serviceName string,
	req queueRunRequest,
) {
	name := strings.TrimPrefix(req.Action, "custom:")
	var command string
	if qse != nil {
		for _, action := range qse.CustomActions {
			if action.Name == name {
				command = action.Command
				break
			}
		}
	} else {
		// The local queue keeps its custom actions in the service.
		var svc *config.Service
		_ = s.store.View(func(c *config.Config) error {
			found, err := findService(c, profileName, envName, serviceName)
			if err != nil {
				return err
			}
			svc = found
			return nil
		})
		if svc != nil {
			for _, action := range svc.QueueSyncEnvs {
				for _, custom := range action.CustomActions {
					if custom.Name == name {
						command = custom.Command
					}
				}
			}
		}
	}
	if command == "" {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q not found", name))
		return
	}

	autoVars := map[string]string{
		"service":   serviceName,
		"container": container,
	}
	if qse != nil {
		autoVars["qs_host"] = qse.Host
		autoVars["qs_port"] = qse.Port
		autoVars["qs_user"] = qse.User
		autoVars["qs_pass"] = qse.Password
		autoVars["qs_type"] = qse.QueueType
		autoVars["qs_bs"] = qse.BootstrapServers
		autoVars["qs_vhost"] = qse.VHost
		autoVars["qs_broker"] = qse.BrokerURL
	}

	substituted := command
	for key, value := range req.Params {
		substituted = strings.ReplaceAll(substituted, "{"+key+"}", value)
	}
	for key, value := range autoVars {
		if value != "" {
			substituted = strings.ReplaceAll(substituted, "{"+key+"}", value)
		}
	}

	var out string
	var err error
	if qse != nil {
		out, err = docker.QueueExecRemote(qse, "sh", "-c", substituted)
	} else {
		out, err = docker.QueueExecLocal(container, "sh", "-c", substituted)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"output": cleanQueueOutput(out)})
}

// queueCommand builds the command of an action, for the local queue or for a
// remote one.
func queueCommand(action *queueAction, qse *config.QueueSyncEnv, params map[string]string) (string, []string) {
	value := func(name string) string { return params[name] }

	switch action.id {
	// ── kafka ──
	case "kafka-list-topics":
		return "/usr/bin/kafka-topics", []string{"--bootstrap-server", kafkaBootstrap(qse), "--list"}
	case "kafka-describe-topic":
		return "/usr/bin/kafka-topics", []string{"--bootstrap-server", kafkaBootstrap(qse), "--describe", "--topic", value("topic")}
	case "kafka-create-topic":
		return "/usr/bin/kafka-topics", []string{
			"--bootstrap-server", kafkaBootstrap(qse),
			"--create", "--topic", value("topic"),
			"--partitions", value("partitions"),
			"--replication-factor", value("replication_factor"),
		}
	case "kafka-delete-topic":
		return "/usr/bin/kafka-topics", []string{"--bootstrap-server", kafkaBootstrap(qse), "--delete", "--topic", value("topic")}
	case "kafka-send-message":
		return "sh", []string{"-c", fmt.Sprintf(
			"/usr/bin/kafka-console-producer --bootstrap-server '%s' --topic '%s' <<'INNEREOF'\n%s\nINNEREOF",
			kafkaBootstrap(qse), value("topic"), value("message"),
		)}
	case "kafka-consume-messages":
		return "/usr/bin/kafka-console-consumer", []string{
			"--bootstrap-server", kafkaBootstrap(qse),
			"--topic", value("topic"), "--max-messages", "1", "--from-beginning",
		}
	case "kafka-list-groups":
		return "/usr/bin/kafka-consumer-groups", []string{"--bootstrap-server", kafkaBootstrap(qse), "--list"}
	case "kafka-describe-group":
		return "/usr/bin/kafka-consumer-groups", []string{"--bootstrap-server", kafkaBootstrap(qse), "--describe", "--group", value("group")}
	case "kafka-reset-offset":
		return "/usr/bin/kafka-consumer-groups", []string{
			"--bootstrap-server", kafkaBootstrap(qse),
			"--reset-offsets", "--group", value("group"), "--to-earliest", "--execute", "--topic", value("topic"),
		}

	// ── rabbitmq ──
	case "rabbitmq-list-queues":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "queues")
	case "rabbitmq-create-queue":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "declare", "queue", "name="+value("name"))
	case "rabbitmq-delete-queue":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "delete", "queue", "name="+value("name"))
	case "rabbitmq-purge-queue":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "purge", "queue", "name="+value("name"))
	case "rabbitmq-list-exchanges":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "exchanges")
	case "rabbitmq-list-bindings":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "bindings")
	case "rabbitmq-list-connections":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "connections")
	case "rabbitmq-list-channels":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "channels")
	case "rabbitmq-list-consumers":
		return "/usr/local/bin/rabbitmqadmin", rabbitArgs(qse, "list", "consumers")

	// ── activemq ──
	case "activemq-list-destinations":
		return "activemq", []string{"dstat", "--jmxurl", activemqJmxURL(qse)}
	case "activemq-browse-queue":
		args := []string{"browse", value("queue")}
		if qse != nil {
			args = append(args, "--amqurl", activemqBrokerURL(qse))
		}
		return "activemq", args
	case "activemq-purge-queue":
		if qse != nil {
			return "activemq", []string{"purge", value("queue"), "--jmxurl", activemqJmxURL(qse)}
		}
		return "activemq", []string{"purge", value("queue"), "--jmxlocal"}
	case "activemq-send-message":
		args := []string{"producer", "--destination", value("queue"), "--message", value("message"), "--messageCount", "1"}
		if qse != nil {
			args = append(args, "--brokerUrl", activemqBrokerURL(qse))
		}
		return "activemq", args
	case "activemq-consume-messages":
		args := []string{"consumer", "--destination", value("queue"), "--messageCount", "1"}
		if qse != nil {
			args = append(args, "--brokerUrl", activemqBrokerURL(qse))
		}
		return "activemq", args
	}
	return "", nil
}

// kafkaBootstrap returns the bootstrap servers of a kafka queue.
func kafkaBootstrap(qse *config.QueueSyncEnv) string {
	if qse == nil {
		return "localhost:9092"
	}
	if qse.BootstrapServers != "" {
		return qse.BootstrapServers
	}
	return qse.Host + ":" + qse.Port
}

// rabbitArgs builds the arguments of rabbitmqadmin.
func rabbitArgs(qse *config.QueueSyncEnv, sub ...string) []string {
	host := "localhost"
	port := "15672"
	user := ""
	pass := ""
	if qse != nil {
		host = qse.Host
		if qse.Port != "" {
			port = qse.Port
		}
		user = qse.User
		pass = qse.Password
	}
	args := []string{"-H", host, "-P", port}
	if user != "" {
		args = append(args, "-u", user, "-p", pass)
	}
	return append(args, sub...)
}

// activemqJmxURL returns the JMX url of an activemq queue.
func activemqJmxURL(qse *config.QueueSyncEnv) string {
	if qse == nil {
		return "service:jmx:rmi:///jndi/rmi://localhost:1099/jmxrmi"
	}
	return "service:jmx:rmi:///jndi/rmi://" + qse.Host + ":1099/jmxrmi"
}

// activemqBrokerURL returns the broker url of an activemq queue.
func activemqBrokerURL(qse *config.QueueSyncEnv) string {
	port := "61616"
	if qse != nil && qse.Port != "" {
		port = qse.Port
	}
	host := "localhost"
	if qse != nil {
		host = qse.Host
	}
	return "tcp://" + host + ":" + port
}

// ── Queue environments ───────────────────────────────────────────────────────

func (s *Server) handleAddQueueSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")

	var req queueSyncEnvRequest
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
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		for _, existing := range svc.QueueSyncEnvs {
			if existing.Name == req.Name {
				return fmt.Errorf("queue environment %q already exists", req.Name)
			}
		}
		qse := config.QueueSyncEnv{
			Name:               req.Name,
			QueueType:          strings.TrimSpace(req.QueueType),
			Host:               strings.TrimSpace(req.Host),
			Port:               strings.TrimSpace(req.Port),
			User:               req.User,
			Password:           req.Password,
			ToolImage:          strings.TrimSpace(req.ToolImage),
			BootstrapServers:   strings.TrimSpace(req.BootstrapServers),
			ManagementEndpoint: strings.TrimSpace(req.ManagementEndpoint),
			VHost:              strings.TrimSpace(req.VHost),
			BrokerURL:          strings.TrimSpace(req.BrokerURL),
		}
		if qse.QueueType == "" {
			qse.QueueType = svc.QueueType()
		}
		if qse.Password != "" {
			if err := qse.SetPassword(qse.Password); err != nil {
				return err
			}
		}
		svc.QueueSyncEnvs = append(svc.QueueSyncEnvs, qse)
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		profile.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

func (s *Server) handleUpdateQueueSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	origName := r.PathValue("name")

	var req queueSyncEnvRequest
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
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		idx := -1
		for i := range svc.QueueSyncEnvs {
			if svc.QueueSyncEnvs[i].Name == origName {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("queue environment %q not found", origName)
		}
		qse := &svc.QueueSyncEnvs[idx]
		if req.Name != origName {
			for i := range svc.QueueSyncEnvs {
				if svc.QueueSyncEnvs[i].Name == req.Name {
					return fmt.Errorf("queue environment %q already exists", req.Name)
				}
			}
		}
		qse.Name = req.Name
		if req.QueueType != "" {
			qse.QueueType = strings.TrimSpace(req.QueueType)
		}
		qse.Host = strings.TrimSpace(req.Host)
		qse.Port = strings.TrimSpace(req.Port)
		qse.User = req.User
		qse.ToolImage = strings.TrimSpace(req.ToolImage)
		qse.BootstrapServers = strings.TrimSpace(req.BootstrapServers)
		qse.ManagementEndpoint = strings.TrimSpace(req.ManagementEndpoint)
		qse.VHost = strings.TrimSpace(req.VHost)
		qse.BrokerURL = strings.TrimSpace(req.BrokerURL)
		if req.Password != "" {
			if err := qse.SetPassword(req.Password); err != nil {
				return err
			}
		}
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		profile.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

func (s *Server) handleDeleteQueueSyncEnv(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	name := r.PathValue("name")

	err := s.store.Update(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		idx := -1
		for i := range svc.QueueSyncEnvs {
			if svc.QueueSyncEnvs[i].Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("queue environment %q not found", name)
		}
		svc.QueueSyncEnvs = append(svc.QueueSyncEnvs[:idx], svc.QueueSyncEnvs[idx+1:]...)
		profile, ok := c.GetProfile(profileName)
		if !ok {
			return notFoundf("profile %q not found", profileName)
		}
		profile.UpdatedAt = time.Now()
		return c.Save()
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

// ── Custom actions of a queue environment ────────────────────────────────────

type queueCustomRequest struct {
	Name    string `json:"name"`
	Command string `json:"command"`
}

// handleAddQueueCustom adds a custom action to a queue environment.
func (s *Server) handleAddQueueCustom(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	env := r.PathValue("name")

	var req queueCustomRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Command = strings.TrimSpace(req.Command)
	if req.Name == "" || req.Command == "" {
		writeError(w, http.StatusBadRequest, "name and command are required")
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		qse, err := findQueueSyncEnv(c, profileName, envName, serviceName, env)
		if err != nil {
			return err
		}
		for _, action := range qse.CustomActions {
			if action.Name == req.Name {
				return fmt.Errorf("action %q already exists", req.Name)
			}
		}
		qse.CustomActions = append(qse.CustomActions, config.CustomAction{Name: req.Name, Command: req.Command})
		return touchProfile(c, profileName)
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

// handleUpdateQueueCustom renames or changes the command of a custom action.
func (s *Server) handleUpdateQueueCustom(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	env := r.PathValue("name")
	origName := r.PathValue("action")

	var req queueCustomRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.Command = strings.TrimSpace(req.Command)
	if req.Name == "" || req.Command == "" {
		writeError(w, http.StatusBadRequest, "name and command are required")
		return
	}

	err := s.store.Update(func(c *config.Config) error {
		qse, err := findQueueSyncEnv(c, profileName, envName, serviceName, env)
		if err != nil {
			return err
		}
		idx := -1
		for i, action := range qse.CustomActions {
			if action.Name == origName {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("action %q not found", origName)
		}
		qse.CustomActions[idx] = config.CustomAction{Name: req.Name, Command: req.Command}
		return touchProfile(c, profileName)
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

// handleDeleteQueueCustom removes a custom action of a queue environment.
func (s *Server) handleDeleteQueueCustom(w http.ResponseWriter, r *http.Request) {
	profileName := r.PathValue("profile")
	envName := r.PathValue("env")
	serviceName := r.PathValue("service")
	env := r.PathValue("name")
	name := r.PathValue("action")

	err := s.store.Update(func(c *config.Config) error {
		qse, err := findQueueSyncEnv(c, profileName, envName, serviceName, env)
		if err != nil {
			return err
		}
		idx := -1
		for i, action := range qse.CustomActions {
			if action.Name == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return notFoundf("action %q not found", name)
		}
		qse.CustomActions = append(qse.CustomActions[:idx], qse.CustomActions[idx+1:]...)
		return touchProfile(c, profileName)
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	s.writeQueueOps(w, profileName, envName, serviceName)
}

// findQueueSyncEnv returns the queue environment of a service.
func findQueueSyncEnv(c *config.Config, profileName, envName, serviceName, name string) (*config.QueueSyncEnv, error) {
	svc, err := findService(c, profileName, envName, serviceName)
	if err != nil {
		return nil, err
	}
	qse := svc.FindQueueSyncEnv(name)
	if qse == nil {
		return nil, notFoundf("queue environment %q not found", name)
	}
	return qse, nil
}

// touchProfile marks the profile as updated and saves the config.
func touchProfile(c *config.Config, profileName string) error {
	profile, ok := c.GetProfile(profileName)
	if !ok {
		return notFoundf("profile %q not found", profileName)
	}
	profile.UpdatedAt = time.Now()
	return c.Save()
}

// writeQueueOps answers with the refreshed queue operations payload.
func (s *Server) writeQueueOps(w http.ResponseWriter, profileName, envName, serviceName string) {
	var response queueOpsResponse
	err := s.store.View(func(c *config.Config) error {
		svc, err := findService(c, profileName, envName, serviceName)
		if err != nil {
			return err
		}
		queueType := svc.QueueType()
		container := docker.ContainerName(profileName, envName, serviceName)
		running, _ := docker.QueueContainerRunning(container)

		envs := []queueEnvDTO{{
			Name:          "(local)",
			QueueType:     queueType,
			Host:          "localhost",
			CustomActions: make([]queueCustomDTO, 0),
			IsLocal:       true,
		}}
		for _, qse := range svc.QueueSyncEnvs {
			env := queueEnvDTO{
				Name:               qse.Name,
				QueueType:          qse.QueueType,
				Host:               qse.Host,
				Port:               qse.Port,
				User:               qse.User,
				ToolImage:          qse.ToolImage,
				BootstrapServers:   qse.BootstrapServers,
				ManagementEndpoint: qse.ManagementEndpoint,
				VHost:              qse.VHost,
				BrokerURL:          qse.BrokerURL,
				CustomActions:      make([]queueCustomDTO, 0, len(qse.CustomActions)),
			}
			for _, action := range qse.CustomActions {
				env.CustomActions = append(env.CustomActions, queueCustomDTO{
					Name:    action.Name,
					Command: action.Command,
				})
			}
			envs = append(envs, env)
		}

		reason := ""
		if !running {
			reason = "start the service first"
		}
		for _, action := range queueActions(queueType) {
			enabled := true
			if !action.destructive && reason != "" {
				enabled = false
			}
			response.Actions = append(response.Actions, queueActionDTO{
				ID:             action.id,
				Label:          action.label,
				Group:          action.group,
				Params:         action.params,
				Destructive:    action.destructive,
				Enabled:        enabled,
				DisabledReason: reason,
			})
		}
		response.QueueType = queueType
		response.Envs = envs
		response.Running = running
		return nil
	})
	if err != nil {
		writeError(w, statusForError(err), err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

// queuePortNumber returns the numeric port of a queue environment.
func queuePortNumber(port string, fallback int) int {
	value, err := strconv.Atoi(strings.TrimSpace(port))
	if err != nil {
		return fallback
	}
	return value
}
