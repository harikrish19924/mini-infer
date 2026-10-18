// Package openai holds the OpenAI API types the gateway (and later loadgen) reads and writes.
//
// The request types declare only the fields the gateway checks. The gateway
// forwards the client's original bytes, so fields not declared here
// (temperature, tools, top_p, ...) still reach vLLM.
package openai

import "encoding/json"

// ChatCompletionRequest is the part of a POST /v1/chat/completions body the gateway validates.
type ChatCompletionRequest struct {
	Model               string    `json:"model"`
	Messages            []Message `json:"messages"`
	MaxTokens           *int      `json:"max_tokens"`
	MaxCompletionTokens *int      `json:"max_completion_tokens"`
	Stream              *bool     `json:"stream"`
}

// Message is one chat message. Content stays raw because it can be a string
// or an array of parts (text, images).
type Message struct {
	Role      string          `json:"role"`
	Content   json.RawMessage `json:"content"`
	ToolCalls json.RawMessage `json:"tool_calls"`
}

// CompletionRequest is the part of a POST /v1/completions body the gateway validates.
// Prompt stays raw because it can be a string, an array of strings or token IDs.
type CompletionRequest struct {
	Model     string          `json:"model"`
	Prompt    json.RawMessage `json:"prompt"`
	MaxTokens *int            `json:"max_tokens"`
	Stream    *bool           `json:"stream"`
}

// ErrorResponse is the body of every error the gateway returns.
type ErrorResponse struct {
	Error Error `json:"error"`
}

// Error matches OpenAI's error object; Param and Code are null when not set.
type Error struct {
	Message string  `json:"message"`
	Type    string  `json:"type"`
	Param   *string `json:"param"`
	Code    *string `json:"code"`
}

// ModelList is the body of GET /v1/models.
type ModelList struct {
	Object string  `json:"object"`
	Data   []Model `json:"data"`
}

// Model is one entry in a ModelList.
type Model struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	OwnedBy string `json:"owned_by"`
}
