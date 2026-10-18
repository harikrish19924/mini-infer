package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/harikrish19924/mini-infer/internal/openai"
)

// maxBodyBytes caps a request body. A 4,096-token prompt is about 16 KB of text,
// so 8 MiB leaves room for long contexts and images while stopping abuse.
const maxBodyBytes = 8 << 20

// apiError is a request the gateway refuses, with everything writeError needs.
type apiError struct {
	status  int
	errType string // OpenAI error type, e.g. invalid_request_error
	param   string // the offending field, "" if none
	code    string // machine-readable code, "" if none
	message string
}

func (e *apiError) Error() string { return e.message }

func badRequest(param, format string, args ...any) *apiError {
	return &apiError{
		status:  http.StatusBadRequest,
		errType: "invalid_request_error",
		param:   param,
		message: fmt.Sprintf(format, args...),
	}
}

// proxyRequest is a request that passed validation: what the proxy (step 3) needs.
type proxyRequest struct {
	Model  Model
	Stream bool
	Body   []byte // the client's original bytes, unknown fields included
}

// chatRoles are the message roles OpenAI's chat API accepts.
var chatRoles = map[string]bool{
	"system": true, "developer": true, "user": true, "assistant": true, "tool": true,
}

func (a *api) parseChat(body []byte) (*proxyRequest, *apiError) {
	var req openai.ChatCompletionRequest
	if err := decodeJSON(body, &req); err != nil {
		return nil, err
	}
	model, err := a.lookupModel(req.Model)
	if err != nil {
		return nil, err
	}
	if len(req.Messages) == 0 {
		return nil, badRequest("messages", "messages must be a non-empty array")
	}
	for i, msg := range req.Messages {
		if err := checkMessage(i, msg); err != nil {
			return nil, err
		}
	}
	if err := checkMaxTokens("max_tokens", req.MaxTokens, model); err != nil {
		return nil, err
	}
	if err := checkMaxTokens("max_completion_tokens", req.MaxCompletionTokens, model); err != nil {
		return nil, err
	}
	return &proxyRequest{Model: model, Stream: req.Stream != nil && *req.Stream, Body: body}, nil
}

func (a *api) parseCompletion(body []byte) (*proxyRequest, *apiError) {
	var req openai.CompletionRequest
	if err := decodeJSON(body, &req); err != nil {
		return nil, err
	}
	model, err := a.lookupModel(req.Model)
	if err != nil {
		return nil, err
	}
	if isEmptyJSON(req.Prompt) {
		return nil, badRequest("prompt", "prompt is required")
	}
	if first := req.Prompt[0]; first != '"' && first != '[' {
		return nil, badRequest("prompt", "prompt must be a string or an array")
	}
	if err := checkMaxTokens("max_tokens", req.MaxTokens, model); err != nil {
		return nil, err
	}
	return &proxyRequest{Model: model, Stream: req.Stream != nil && *req.Stream, Body: body}, nil
}

// decodeJSON reads the fields the gateway checks and turns JSON errors into
// messages that name the field at fault.
func decodeJSON(body []byte, v any) *apiError {
	if len(bytes.TrimSpace(body)) == 0 {
		return badRequest("", "request body is empty; send a JSON object")
	}
	err := json.Unmarshal(body, v)
	if err == nil {
		return nil
	}
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	switch {
	case errors.As(err, &syntaxErr):
		return badRequest("", "request body is not valid JSON: %v", err)
	case errors.As(err, &typeErr) && typeErr.Field == "":
		return badRequest("", "request body must be a JSON object, not %s", typeErr.Value)
	case errors.As(err, &typeErr):
		return badRequest(typeErr.Field, "%s must be of type %s, not %s", typeErr.Field, jsonType(typeErr.Type.Kind().String()), typeErr.Value)
	default:
		return badRequest("", "request body could not be read: %v", err)
	}
}

// jsonType names a Go kind the way a client thinks of the JSON value.
func jsonType(kind string) string {
	switch kind {
	case "int", "int64", "float64":
		return "number"
	case "bool":
		return "boolean"
	case "slice":
		return "array"
	case "struct", "map":
		return "object"
	default:
		return kind
	}
}

func (a *api) lookupModel(name string) (Model, *apiError) {
	if name == "" {
		return Model{}, badRequest("model", "model is required")
	}
	m, ok := a.byName[name]
	if !ok {
		return Model{}, &apiError{
			status:  http.StatusNotFound,
			errType: "invalid_request_error",
			param:   "model",
			code:    "model_not_found",
			message: fmt.Sprintf("The model `%s` does not exist. GET /v1/models lists the available models.", name),
		}
	}
	return m, nil
}

func checkMessage(i int, msg openai.Message) *apiError {
	param := fmt.Sprintf("messages[%d]", i)
	if msg.Role == "" {
		return badRequest(param+".role", "%s.role is required", param)
	}
	if !chatRoles[msg.Role] {
		return badRequest(param+".role", "%s.role is %q; it must be one of system, developer, user, assistant, tool", param, msg.Role)
	}
	// An assistant message may carry only tool calls; every other role needs content.
	if msg.Role == "assistant" {
		if isEmptyJSON(msg.Content) && isEmptyJSON(msg.ToolCalls) {
			return badRequest(param+".content", "%s needs content or tool_calls", param)
		}
		return nil
	}
	if isEmptyJSON(msg.Content) {
		return badRequest(param+".content", "%s.content is required", param)
	}
	return nil
}

// checkMaxTokens checks an output-token limit against the model's context length.
// TODO(phase 3): the real rule is prompt tokens + max tokens <= MaxModelLen,
// which needs vLLM's /tokenize to count the prompt.
func checkMaxTokens(param string, v *int, m Model) *apiError {
	if v == nil {
		return nil
	}
	if *v < 1 {
		return badRequest(param, "%s must be at least 1, got %d", param, *v)
	}
	if *v > m.MaxModelLen {
		return badRequest(param, "%s is %d, but model %s has a context length of %d tokens", param, *v, m.Name, m.MaxModelLen)
	}
	return nil
}

// isEmptyJSON reports whether a raw field is missing, null, "" or [].
func isEmptyJSON(raw json.RawMessage) bool {
	switch string(bytes.TrimSpace(raw)) {
	case "", "null", `""`, "[]":
		return true
	}
	return false
}
