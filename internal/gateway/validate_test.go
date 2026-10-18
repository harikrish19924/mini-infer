package gateway

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"github.com/harikrish19924/mini-infer/internal/openai"
)

func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
	os.Exit(m.Run())
}

var testModels = []Model{{Name: "qwen-0.5b", MaxModelLen: 4096}}

// A request that passes validation reaches the proxy, which still answers 501
// until step 3; so 501 here means "valid".
const passed = http.StatusNotImplemented

func TestValidation(t *testing.T) {
	tests := []struct {
		name        string
		path        string
		body        string
		wantCode    int
		wantParam   string // "" means param must be null
		wantErrCode string
	}{
		// --- chat: valid requests ---
		{name: "chat minimal", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}]}`, wantCode: passed},
		{name: "chat unknown fields pass through", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"temperature":0.2,"tools":[]}`, wantCode: passed},
		{name: "chat content as parts", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}`, wantCode: passed},
		{name: "assistant with only tool calls", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"},{"role":"assistant","tool_calls":[{"id":"1"}]}]}`, wantCode: passed},
		{name: "max_tokens at the limit", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":4096}`, wantCode: passed},
		{name: "streaming", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":true}`, wantCode: passed},

		// --- body problems ---
		{name: "empty body", path: "/v1/chat/completions", body: ``, wantCode: 400},
		{name: "broken JSON", path: "/v1/chat/completions", body: `{"model":`, wantCode: 400},
		{name: "array instead of object", path: "/v1/chat/completions", body: `[]`, wantCode: 400},

		// --- model ---
		{name: "missing model", path: "/v1/chat/completions",
			body: `{"messages":[{"role":"user","content":"hi"}]}`, wantCode: 400, wantParam: "model"},
		{name: "model wrong type", path: "/v1/chat/completions",
			body: `{"model":123,"messages":[{"role":"user","content":"hi"}]}`, wantCode: 400, wantParam: "model"},
		{name: "unknown model", path: "/v1/chat/completions",
			body: `{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}`, wantCode: 404, wantParam: "model", wantErrCode: "model_not_found"},

		// --- messages ---
		{name: "missing messages", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b"}`, wantCode: 400, wantParam: "messages"},
		{name: "empty messages", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[]}`, wantCode: 400, wantParam: "messages"},
		{name: "message without role", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"content":"hi"}]}`, wantCode: 400, wantParam: "messages[0].role"},
		{name: "unknown role", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"wizard","content":"hi"}]}`, wantCode: 400, wantParam: "messages[0].role"},
		{name: "user without content", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user"}]}`, wantCode: 400, wantParam: "messages[0].content"},
		{name: "user with null content", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":null}]}`, wantCode: 400, wantParam: "messages[0].content"},
		{name: "second message bad", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"},{"role":"assistant"}]}`, wantCode: 400, wantParam: "messages[1].content"},

		// --- token limits ---
		{name: "max_tokens zero", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":0}`, wantCode: 400, wantParam: "max_tokens"},
		{name: "max_tokens negative", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":-5}`, wantCode: 400, wantParam: "max_tokens"},
		{name: "max_tokens over context", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":4097}`, wantCode: 400, wantParam: "max_tokens"},
		{name: "max_completion_tokens over context", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":5000}`, wantCode: 400, wantParam: "max_completion_tokens"},
		{name: "max_tokens wrong type", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"max_tokens":"abc"}`, wantCode: 400, wantParam: "max_tokens"},
		{name: "stream wrong type", path: "/v1/chat/completions",
			body: `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":"yes"}`, wantCode: 400, wantParam: "stream"},

		// --- completions ---
		{name: "completion string prompt", path: "/v1/completions",
			body: `{"model":"qwen-0.5b","prompt":"Once upon a time"}`, wantCode: passed},
		{name: "completion array prompt", path: "/v1/completions",
			body: `{"model":"qwen-0.5b","prompt":["a","b"]}`, wantCode: passed},
		{name: "completion missing prompt", path: "/v1/completions",
			body: `{"model":"qwen-0.5b"}`, wantCode: 400, wantParam: "prompt"},
		{name: "completion empty prompt", path: "/v1/completions",
			body: `{"model":"qwen-0.5b","prompt":""}`, wantCode: 400, wantParam: "prompt"},
		{name: "completion number prompt", path: "/v1/completions",
			body: `{"model":"qwen-0.5b","prompt":123}`, wantCode: 400, wantParam: "prompt"},
		{name: "completion max_tokens over context", path: "/v1/completions",
			body: `{"model":"qwen-0.5b","prompt":"hi","max_tokens":9999}`, wantCode: 400, wantParam: "max_tokens"},
	}

	engine := newEngine(testModels)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, tt.path, strings.NewReader(tt.body))
			engine.ServeHTTP(rec, req)

			if rec.Code != tt.wantCode {
				t.Fatalf("status = %d, want %d; body: %s", rec.Code, tt.wantCode, rec.Body)
			}
			e := decodeError(t, rec)
			if tt.wantCode == passed {
				return
			}
			if e.Type != "invalid_request_error" {
				t.Errorf("type = %q, want invalid_request_error", e.Type)
			}
			if got := deref(e.Param); got != tt.wantParam {
				t.Errorf("param = %q, want %q", got, tt.wantParam)
			}
			if got := deref(e.Code); got != tt.wantErrCode {
				t.Errorf("code = %q, want %q", got, tt.wantErrCode)
			}
		})
	}
}

func TestBodyTooLarge(t *testing.T) {
	body := `{"model":"qwen-0.5b","prompt":"` + strings.Repeat("a", maxBodyBytes) + `"}`
	rec := httptest.NewRecorder()
	newEngine(testModels).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/completions", strings.NewReader(body)))
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413", rec.Code)
	}
	decodeError(t, rec)
}

// The proxy must forward the client's exact bytes, so fields the gateway
// doesn't know about still reach vLLM.
func TestParseChatKeepsOriginalBody(t *testing.T) {
	body := []byte(`{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"top_p":0.9,"stream":true}`)
	req, err := newAPI(testModels).parseChat(body)
	if err != nil {
		t.Fatalf("parseChat: %v", err)
	}
	if !bytes.Equal(req.Body, body) {
		t.Errorf("body changed:\n got %s\nwant %s", req.Body, body)
	}
	if !req.Stream || req.Model.Name != "qwen-0.5b" {
		t.Errorf("got stream=%v model=%q, want stream=true model=qwen-0.5b", req.Stream, req.Model.Name)
	}
}

func TestListModels(t *testing.T) {
	rec := httptest.NewRecorder()
	newEngine(testModels).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/models", nil))
	var list openai.ModelList
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if list.Object != "list" || len(list.Data) != 1 || list.Data[0].ID != "qwen-0.5b" {
		t.Errorf("got %+v", list)
	}
}

// decodeError checks the body has OpenAI's error shape and returns the error object.
func decodeError(t *testing.T, rec *httptest.ResponseRecorder) openai.Error {
	t.Helper()
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("body is not JSON: %v; body: %s", err, rec.Body)
	}
	if _, ok := raw["error"]; !ok {
		t.Fatalf("body has no \"error\" field: %s", rec.Body)
	}
	var resp openai.ErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if resp.Error.Message == "" {
		t.Errorf("error message is empty")
	}
	return resp.Error
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
