package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strconv"
	"strings"

	"github.com/mcstackr/mcstackr/engine/internal/config"
	"github.com/mcstackr/mcstackr/engine/internal/git"
)

// ── Types ────────────────────────────────────────────────────────────────────

// GitFile is one entry of the working tree status.
type GitFile struct {
	Path       string `json:"path"`
	StatusCode string `json:"statusCode"`
	IndexCode  string `json:"indexCode"`
	Staged     bool   `json:"staged"`
}

// GitBranch is one local branch.
type GitBranch struct {
	Name       string `json:"name"`
	Current    bool   `json:"current"`
	Tracking   string `json:"tracking"`
	Ahead      int    `json:"ahead"`
	Behind     int    `json:"behind"`
	LastCommit string `json:"lastCommit"`
	Head       string `json:"head"`
}

// GitStash is one stash entry.
type GitStash struct {
	Ref     string `json:"ref"`
	Message string `json:"message"`
}

// GitCommit is one entry of the log.
type GitCommit struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Date    string `json:"date"`
	Message string `json:"message"`
}

// GitState is everything the git view shows about the repository.
type GitState struct {
	Profile          string      `json:"profile"`
	IsRepo           bool        `json:"isRepo"`
	GitFound         bool        `json:"gitFound"`
	Root             string      `json:"root"`
	Branch           string      `json:"branch"`
	Tracking         string      `json:"tracking"`
	Ahead            int         `json:"ahead"`
	Behind           int         `json:"behind"`
	Files            []GitFile   `json:"files"`
	StagedStart      int         `json:"stagedStart"`
	LastCommit       string      `json:"lastCommit"`
	HeadPushed       bool        `json:"headPushed"`
	HasUnpushed      bool        `json:"hasUnpushed"`
	HasStash         bool        `json:"hasStash"`
	Stashes          []GitStash  `json:"stashes"`
	Branches         []GitBranch `json:"branches"`
	Commits          []GitCommit `json:"commits"`
	RebaseInProgress bool        `json:"rebaseInProgress"`
	MergeInProgress  bool        `json:"mergeInProgress"`
	Conflicts        []string    `json:"conflicts"`
}

// gitOpsRequest is the body of a git operation.
type gitOpsRequest struct {
	Op     string         `json:"op"`
	Params map[string]any `json:"params"`
}

// gitOpsResponse is what an operation returns.
type gitOpsResponse struct {
	Output string `json:"output"`
}

// gitWorkDir is the directory the git operations act on: the one the app was
// launched from, the same way the console used the directory it was launched
// from.
func (s *Server) gitWorkDir() string {
	dir, err := exec.Command("pwd").Output()
	if err == nil {
		if out := strings.TrimSpace(string(dir)); out != "" {
			return out
		}
	}
	return "."
}

// branchHead is the commit a branch points at, empty when it cannot be read.
func branchHead(dir, branch string) string {
	head, err := git.BranchHead(dir, branch)
	if err != nil {
		return ""
	}
	return head
}

// gitState builds the state of the repository the same way the console did.
func (s *Server) gitState(profile string) GitState {
	state := GitState{
		Profile:   profile,
		Files:     []GitFile{},
		Branches:  []GitBranch{},
		Commits:   []GitCommit{},
		Stashes:   []GitStash{},
		Conflicts: []string{},
	}
	dir := s.gitWorkDir()

	if _, err := exec.LookPath("git"); err != nil {
		return state
	}
	state.GitFound = true

	if !git.IsRepo(dir) {
		return state
	}
	state.IsRepo = true
	if root, err := git.Root(dir); err == nil {
		state.Root = root
	}

	// The file list: staged first, then unstaged.
	statuses, err := git.StatusPorcelain(dir)
	if err == nil {
		var staged, unstaged []GitFile
		for _, f := range statuses {
			entry := GitFile{
				Path:       f.Path,
				StatusCode: string(f.StatusCode),
				IndexCode:  string(f.IndexCode),
				Staged:     f.Staged,
			}
			if f.Staged {
				staged = append(staged, entry)
			} else {
				unstaged = append(unstaged, entry)
			}
		}
		files := make([]GitFile, 0, len(staged)+len(unstaged))
		files = append(files, staged...)
		files = append(files, unstaged...)
		state.Files = files
		state.StagedStart = len(staged)
	}

	// The branches, with their tracking and ahead/behind.
	if branches, err := git.BranchesDetailed(dir); err == nil {
		for _, b := range branches {
			state.Branches = append(state.Branches, GitBranch{
				Name:       b.Name,
				Current:    b.Current,
				Tracking:   b.Tracking,
				Ahead:      b.Ahead,
				Behind:     b.Behind,
				LastCommit: b.LastCommit,
				Head:       branchHead(dir, b.Name),
			})
			if b.Current {
				state.Branch = b.Name
				state.Tracking = b.Tracking
				state.Ahead = b.Ahead
				state.Behind = b.Behind
			}
		}
	} else if branch, err := git.CurrentBranch(dir); err == nil {
		state.Branch = branch
	}

	// The last commit and whether it is already on the remote.
	if commits, err := git.Log(dir, 1); err == nil && len(commits) > 0 {
		state.LastCommit = commits[0].Message
	}
	state.HeadPushed = git.HEADIsPushed(dir)
	state.HasUnpushed = git.HasUnpushedCommits(dir)

	// The stashes.
	if stashes, err := git.StashList(dir); err == nil {
		for _, st := range stashes {
			state.Stashes = append(state.Stashes, GitStash{Ref: st.Ref, Message: st.Message})
		}
		state.HasStash = len(state.Stashes) > 0
	}

	// The recent commits.
	if commits, err := git.Log(dir, 50); err == nil {
		for _, c := range commits {
			state.Commits = append(state.Commits, GitCommit{
				Hash:    c.Hash,
				Author:  c.Author,
				Date:    c.Date,
				Message: c.Message,
			})
		}
	}

	// The work in progress: a rebase or a merge waiting for an answer.
	state.RebaseInProgress = git.RebaseInProgress(dir)
	state.MergeInProgress = git.MergeInProgress(dir)
	if state.RebaseInProgress || state.MergeInProgress {
		if files, err := git.ConflictingFiles(dir); err == nil {
			state.Conflicts = files
		}
	}
	return state
}

// ── Handlers ─────────────────────────────────────────────────────────────────

// handleGitOps answers with the state of the repository.
func (s *Server) handleGitOps(w http.ResponseWriter, r *http.Request) {
	profile := r.PathValue("profile")
	found := false
	s.store.View(func(c *config.Config) error {
		_, found = c.GetProfile(profile)
		return nil
	})
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "profile not found"})
		return
	}
	writeJSON(w, http.StatusOK, s.gitState(profile))
}

// handleGitOpRun runs one git operation.
func (s *Server) handleGitOpRun(w http.ResponseWriter, r *http.Request) {
	profile := r.PathValue("profile")
	found := false
	s.store.View(func(c *config.Config) error {
		_, found = c.GetProfile(profile)
		return nil
	})
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "profile not found"})
		return
	}
	var req gitOpsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}
	dir := s.gitWorkDir()
	if !git.IsRepo(dir) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "this directory is not a git repository"})
		return
	}

	out, err := s.runGitOp(dir, req.Op, req.Params)
	if err != nil {
		writeJSON(w, http.StatusOK, gitOpsResponse{Output: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, gitOpsResponse{Output: out})
}

// gitParam reads one parameter as text, whatever type it came in.
func gitParam(params map[string]any, key string) string {
	if params == nil {
		return ""
	}
	value, ok := params[key]
	if !ok || value == nil {
		return ""
	}
	switch v := value.(type) {
	case string:
		return v
	case float64:
		if v == float64(int64(v)) {
			return strconv.FormatInt(int64(v), 10)
		}
		return strconv.FormatFloat(v, 'f', -1, 64)
	case bool:
		if v {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", v)
	}
}

// runGitOp performs one operation and returns its output.
func (s *Server) runGitOp(dir, op string, raw map[string]any) (string, error) {
	params := map[string]string{}
	for key := range raw {
		params[key] = gitParam(raw, key)
	}
	switch op {
	case "stage":
		if err := git.Stage(dir, params["path"]); err != nil {
			return "", err
		}
		return "staged " + params["path"], nil
	case "stage_all":
		if err := git.StageAll(dir); err != nil {
			return "", err
		}
		return "staged everything", nil
	case "unstage":
		if err := git.Unstage(dir, params["path"]); err != nil {
			return "", err
		}
		return "unstaged " + params["path"], nil
	case "unstage_all":
		if err := git.UnstageAll(dir); err != nil {
			return "", err
		}
		return "unstaged everything", nil
	case "commit":
		if err := git.Commit(dir, params["subject"], params["body"]); err != nil {
			return "", err
		}
		return "committed: " + params["subject"], nil
	case "amend":
		if err := git.AmendCommit(dir, params["subject"], params["body"]); err != nil {
			return "", err
		}
		return "amended: " + params["subject"], nil
	case "discard":
		if err := git.DiscardChanges(dir, params["path"]); err != nil {
			return "", err
		}
		return "discarded " + params["path"], nil
	case "checkout":
		if err := git.CheckoutBranch(dir, params["branch"]); err != nil {
			return "", err
		}
		return "checked out " + params["branch"], nil
	case "create_branch":
		if err := git.CreateBranch(dir, params["name"]); err != nil {
			return "", err
		}
		return "created branch " + params["name"], nil
	case "delete_branch":
		if err := git.DeleteBranch(dir, params["name"]); err != nil {
			return "", err
		}
		return "deleted branch " + params["name"], nil
	case "merge":
		if err := git.MergeBranch(dir, params["source"]); err != nil {
			return "", err
		}
		return "merged " + params["source"], nil
	case "push":
		if err := git.Push(dir); err != nil {
			return "", err
		}
		return "pushed", nil
	case "pull":
		if err := git.Pull(dir); err != nil {
			return "", err
		}
		return "pulled", nil
	case "stash":
		message := params["message"]
		if message == "" {
			message = "wip"
		}
		if err := git.StashCreate(dir, message); err != nil {
			return "", err
		}
		return "stashed: " + message, nil
	case "stash_pop":
		if err := git.StashPop(dir); err != nil {
			return "", err
		}
		return "popped the stash", nil
	case "cherry_pick":
		// The hashes come in order, oldest first, like the original runtime.
		var hashes []string
		for _, h := range strings.Split(params["hashes"], ",") {
			h = strings.TrimSpace(h)
			if h != "" {
				hashes = append(hashes, h)
			}
		}
		if len(hashes) == 0 {
			if h := strings.TrimSpace(params["hash"]); h != "" {
				hashes = append(hashes, h)
			}
		}
		if len(hashes) == 0 {
			return "", fmt.Errorf("no commits to cherry-pick")
		}
		if err := git.CherryPick(dir, hashes); err != nil {
			return "", err
		}
		// The original runtime pushes right after the cherry-pick.
		if params["push"] == "true" {
			if err := git.Push(dir); err != nil {
				return "", fmt.Errorf("cherry-pick ok but push failed: %w", err)
			}
		}
		return "cherry-picked " + strings.Join(hashes, ", "), nil
	case "resolve_ours":
		if err := git.ResolveOurs(dir, params["path"]); err != nil {
			return "", err
		}
		return "kept our version of " + params["path"], nil
	case "resolve_theirs":
		if err := git.ResolveTheirs(dir, params["path"]); err != nil {
			return "", err
		}
		return "took their version of " + params["path"], nil
	case "rebase_continue":
		if err := git.RebaseContinue(dir); err != nil {
			return "", err
		}
		return "rebase continued", nil
	case "rebase_abort":
		if err := git.RebaseAbort(dir); err != nil {
			return "", err
		}
		return "rebase aborted", nil
	case "merge_continue":
		if err := git.MergeContinue(dir); err != nil {
			return "", err
		}
		return "merge continued", nil
	case "merge_abort":
		if err := git.MergeAbort(dir); err != nil {
			return "", err
		}
		return "merge aborted", nil
	case "diff":
		out, err := git.Diff(dir, params["path"], params["staged"] == "true")
		if err != nil {
			return "", err
		}
		return out, nil
	case "diff_new":
		out, err := git.DiffNew(dir, params["path"])
		if err != nil {
			return "", err
		}
		return out, nil
	case "commit_files":
		files, err := git.CommitFiles(dir, params["hash"])
		if err != nil {
			return "", err
		}
		return strings.Join(files, "\n"), nil
	case "diff_commit_file":
		out, err := git.DiffCommitFile(dir, params["hash"], params["path"])
		if err != nil {
			return "", err
		}
		return out, nil
	case "log_branch":
		n := 50
		if v, err := strconv.Atoi(params["n"]); err == nil && v > 0 {
			n = v
		}
		branch := params["branch"]
		if branch == "" {
			branch, _ = git.CurrentBranch(dir)
		}
		commits, err := git.LogBranch(dir, branch, n)
		if err != nil {
			return "", err
		}
		// The same shape the original runtime parses: hash|author|date|message
		lines := make([]string, 0, len(commits))
		for _, c := range commits {
			lines = append(lines, fmt.Sprintf("%s|%s|%s|%s", c.Hash, c.Author, c.Date, c.Message))
		}
		return strings.Join(lines, "\n"), nil
	default:
		return "", fmt.Errorf("unknown operation %q", op)
	}
}
