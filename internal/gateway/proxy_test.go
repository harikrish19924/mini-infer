package gateway

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// These tests use a small fake vLLM written inline. Once internal/teststub
// exists (phase 1), they can switch to it.

const (
	roleChunk  = `data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""}}],"usage":null}`
	helloChunk = `data: {"choices":[{"index":0,"delta":{"content":"Hello"}}],"usage":null}`
	worldChunk = `data: {"choices":[{"index":0,"delta":{"content":" world"}}],"usage":null}`
	usageChunk = `data: {"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11}}`
	doneChunk  = `data: [DONE]`
)

// fakeVLLM streams the given events, each followed by a blank line, and records
// the body it received. If gate is non-nil, it waits on gate after the first event.
type fakeVLLM struct {
	events  []string
	gate    chan struct{}
	gotBody chan []byte
}

func (f *fakeVLLM) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	f.gotBody <- body
	w.Header().Set("Content-Type", "text/event-stream")
	for i, ev := range f.events {
		io.WriteString(w, ev+"\n\n")
		w.(http.Flusher).Flush()
		if i == 0 && f.gate != nil {
			select {
			case <-f.gate:
			case <-r.Context().Done():
				return
			}
		}
	}
}

func newFake(events ...string) *fakeVLLM {
	return &fakeVLLM{events: events, gotBody: make(chan []byte, 1)}
}

// startGateway runs a real gateway (over TCP, not a recorder) in front of upstream.
func startGateway(t *testing.T, upstream http.Handler) *httptest.Server {
	t.Helper()
	up := httptest.NewServer(upstream)
	t.Cleanup(up.Close)
	gw := httptest.NewServer(newEngine([]Model{{Name: "qwen-0.5b", MaxModelLen: 4096, Endpoint: up.URL}}))
	t.Cleanup(gw.Close)
	return gw
}

func postChat(t *testing.T, gw *httptest.Server, body string) *http.Response {
	t.Helper()
	resp, err := http.Post(gw.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// readEvents returns the data lines of every event in an SSE body.
func readEvents(t *testing.T, r io.Reader) []string {
	t.Helper()
	var events []string
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		if line := sc.Text(); line != "" {
			events = append(events, line)
		}
	}
	return events
}

func TestStreamRelaysEventsAndHidesUnrequestedUsage(t *testing.T) {
	fake := newFake(roleChunk, helloChunk, worldChunk, usageChunk, doneChunk)
	gw := startGateway(t, fake)

	resp := postChat(t, gw, `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":true,"temperature":0.3}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q, want text/event-stream", ct)
	}

	got := readEvents(t, resp.Body)
	want := []string{roleChunk, helloChunk, worldChunk, doneChunk} // no usage: the client didn't ask
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("events:\n got %q\nwant %q", got, want)
	}

	// vLLM must have been asked for usage, and unknown fields must have survived.
	var sent map[string]any
	json.Unmarshal(<-fake.gotBody, &sent)
	opts, _ := sent["stream_options"].(map[string]any)
	if opts["include_usage"] != true {
		t.Errorf("upstream stream_options = %v, want include_usage true", sent["stream_options"])
	}
	if sent["temperature"] != 0.3 {
		t.Errorf("upstream temperature = %v, want 0.3", sent["temperature"])
	}
}

func TestStreamKeepsUsageWhenClientAsked(t *testing.T) {
	gw := startGateway(t, newFake(helloChunk, usageChunk, doneChunk))
	resp := postChat(t, gw, `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{"include_usage":true}}`)

	got := readEvents(t, resp.Body)
	want := []string{helloChunk, usageChunk, doneChunk}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("events:\n got %q\nwant %q", got, want)
	}
}

// The first event must reach the client while vLLM is still generating,
// which only happens if the gateway flushes after every event.
func TestStreamFlushesEachEvent(t *testing.T) {
	fake := newFake(helloChunk, worldChunk, doneChunk)
	fake.gate = make(chan struct{})
	gw := startGateway(t, fake)

	resp := postChat(t, gw, `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":true}`)
	first := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(resp.Body).ReadString('\n')
		first <- strings.TrimSpace(line)
	}()

	select {
	case line := <-first:
		if line != helloChunk {
			t.Errorf("first line = %q, want %q", line, helloChunk)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("first event did not arrive while vLLM was paused: the gateway is buffering")
	}
	close(fake.gate)
}

func TestNonStreamForwardedAsIs(t *testing.T) {
	const answer = `{"id":"cmpl-1","choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`
	var gotBody []byte
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, answer)
	})
	gw := startGateway(t, upstream)

	const req = `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"top_p":0.9}`
	resp := postChat(t, gw, req)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != answer {
		t.Errorf("got %d %s, want 200 %s", resp.StatusCode, body, answer)
	}
	if string(gotBody) != req {
		t.Errorf("upstream got %s, want the original bytes %s", gotBody, req)
	}
}

// vLLM's own errors are already OpenAI-shaped, so they pass through with their status.
func TestUpstreamErrorRelayed(t *testing.T) {
	const vllmErr = `{"error":{"message":"prompt is too long","type":"BadRequestError","param":null,"code":400}}`
	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, vllmErr)
	})
	gw := startGateway(t, upstream)

	resp := postChat(t, gw, `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}],"stream":true}`)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusBadRequest || string(body) != vllmErr {
		t.Errorf("got %d %s, want 400 %s", resp.StatusCode, body, vllmErr)
	}
}

func TestUpstreamDownIs502(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close() // nothing listens on this address any more
	gw := httptest.NewServer(newEngine([]Model{{Name: "qwen-0.5b", MaxModelLen: 4096, Endpoint: dead.URL}}))
	defer gw.Close()

	resp := postChat(t, gw, `{"model":"qwen-0.5b","messages":[{"role":"user","content":"hi"}]}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	rec := httptest.NewRecorder()
	rec.Code = resp.StatusCode
	rec.Header().Set("Content-Type", resp.Header.Get("Content-Type"))
	io.Copy(rec, resp.Body)
	if e := decodeError(t, rec); e.Type != "server_error" {
		t.Errorf("type = %q, want server_error", e.Type)
	}
}

func TestInjectIncludeUsage(t *testing.T) {
	tests := []struct {
		name      string
		body      string
		wantAsked bool
		wantErr   string // param of the expected error, "" for none
		wantOpts  map[string]any
	}{
		{name: "no stream_options", body: `{"stream":true}`,
			wantOpts: map[string]any{"include_usage": true}},
		{name: "client asked", body: `{"stream":true,"stream_options":{"include_usage":true}}`,
			wantAsked: true, wantOpts: map[string]any{"include_usage": true}},
		{name: "client said false", body: `{"stream":true,"stream_options":{"include_usage":false}}`,
			wantOpts: map[string]any{"include_usage": true}},
		{name: "other options kept", body: `{"stream":true,"stream_options":{"continuous_usage_stats":true}}`,
			wantOpts: map[string]any{"include_usage": true, "continuous_usage_stats": true}},
		{name: "null stream_options", body: `{"stream":true,"stream_options":null}`,
			wantOpts: map[string]any{"include_usage": true}},
		{name: "stream_options not an object", body: `{"stream":true,"stream_options":"yes"}`,
			wantErr: "stream_options"},
		{name: "include_usage not a boolean", body: `{"stream":true,"stream_options":{"include_usage":"yes"}}`,
			wantErr: "stream_options.include_usage"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out, asked, apiErr := injectIncludeUsage([]byte(tt.body))
			if tt.wantErr != "" {
				if apiErr == nil || apiErr.param != tt.wantErr {
					t.Fatalf("got err %v, want error on %q", apiErr, tt.wantErr)
				}
				return
			}
			if apiErr != nil {
				t.Fatalf("unexpected error: %v", apiErr)
			}
			if asked != tt.wantAsked {
				t.Errorf("asked = %v, want %v", asked, tt.wantAsked)
			}
			var got struct {
				Stream        bool           `json:"stream"`
				StreamOptions map[string]any `json:"stream_options"`
			}
			json.Unmarshal(out, &got)
			if !got.Stream {
				t.Errorf("stream field lost: %s", out)
			}
			if len(got.StreamOptions) != len(tt.wantOpts) {
				t.Fatalf("stream_options = %v, want %v", got.StreamOptions, tt.wantOpts)
			}
			for k, v := range tt.wantOpts {
				if got.StreamOptions[k] != v {
					t.Errorf("stream_options[%s] = %v, want %v", k, got.StreamOptions[k], v)
				}
			}
		})
	}
}
