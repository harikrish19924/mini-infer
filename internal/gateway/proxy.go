package gateway

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/harikrish19924/mini-infer/internal/openai"
)

// maxEventLine caps one SSE line from vLLM. Token chunks are a few hundred
// bytes; bufio.Scanner's 64 KB default would still be too tight for logprobs.
const maxEventLine = 1 << 20

// newUpstreamClient returns the one http.Client every upstream request shares.
// Its Transport keeps idle TCP connections to each vLLM pod open for reuse.
func newUpstreamClient() *http.Client {
	return &http.Client{
		// No Client.Timeout: it covers the whole response, so it would cut off
		// long streams. Per-phase timeouts (first token, idle gap) come in step 9.
		Transport: &http.Transport{
			DialContext:         (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			MaxIdleConns:        256,
			MaxIdleConnsPerHost: 64, // the default of 2 would open a new connection for most requests
			IdleConnTimeout:     90 * time.Second,
		},
	}
}

// proxy sends a validated request to vLLM and relays the answer: streamed
// event by event when the client asked for a stream, in one piece otherwise.
func (a *api) proxy(c *gin.Context, req *proxyRequest) {
	start := time.Now()
	log := slog.With("model", req.Model.Name, "path", c.Request.URL.Path, "stream", req.Stream)

	body, clientWantsUsage := req.Body, false
	if req.Stream {
		var apiErr *apiError
		body, clientWantsUsage, apiErr = injectIncludeUsage(req.Body)
		if apiErr != nil {
			writeError(c, apiErr)
			return
		}
	}

	// The upstream request uses the client's context: when the client
	// disconnects, Go cancels it and closes the connection to vLLM, and vLLM
	// stops generating (step 4 checks this live).
	upReq, err := http.NewRequestWithContext(c.Request.Context(), http.MethodPost,
		req.Model.Endpoint+c.Request.URL.Path, bytes.NewReader(body))
	if err != nil {
		log.Error("building upstream request", "err", err)
		writeError(c, &apiError{status: http.StatusInternalServerError, errType: "server_error", message: "gateway could not build the upstream request"})
		return
	}
	upReq.Header.Set("Content-Type", "application/json")
	if req.Stream {
		upReq.Header.Set("Accept", "text/event-stream")
	}

	resp, err := a.client.Do(upReq)
	if err != nil {
		if c.Request.Context().Err() != nil {
			log.Info("client disconnected before vLLM answered")
			return
		}
		log.Error("upstream request failed", "endpoint", req.Model.Endpoint, "err", err)
		writeError(c, &apiError{status: http.StatusBadGateway, errType: "server_error", message: "the model backend is unavailable; try again shortly"})
		return
	}
	defer resp.Body.Close()

	// vLLM's own errors (e.g. prompt longer than the context) are JSON in
	// OpenAI's shape, so they're relayed as they are, even for stream requests.
	if !req.Stream || resp.StatusCode != http.StatusOK {
		copyWhole(c, resp)
		log.Info("request done", "status", resp.StatusCode, "duration_ms", time.Since(start).Milliseconds())
		return
	}
	streamSSE(c, resp, clientWantsUsage, start, log)
}

// copyWhole relays a non-streamed response: status, content type and body.
func copyWhole(c *gin.Context, resp *http.Response) {
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		c.Header("Content-Type", ct)
	}
	c.Status(resp.StatusCode)
	if _, err := io.Copy(c.Writer, resp.Body); err != nil {
		slog.Info("copying response to client stopped", "err", err)
	}
}

// streamSSE relays vLLM's event stream. Each event (lines up to a blank line)
// is written to the client and flushed at once, so tokens aren't held in a
// buffer. Once the 200 has gone out the status can't change: if vLLM fails
// mid-stream, the stream just ends.
func streamSSE(c *gin.Context, resp *http.Response, clientWantsUsage bool, start time.Time, log *slog.Logger) {
	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache")
	c.Header("X-Accel-Buffering", "no") // ask any proxy in front (nginx) not to buffer
	c.Status(http.StatusOK)
	c.Writer.WriteHeaderNow()
	c.Writer.Flush()

	var (
		event    bytes.Buffer // the current event's lines
		drop     bool         // true if the current event is a usage chunk the client didn't ask for
		usage    *openai.Usage
		sawDone  bool
		ttft     time.Duration
		clientOK = true
	)

	// send writes the buffered event plus its closing blank line, then flushes.
	send := func() {
		defer func() { event.Reset(); drop = false }()
		if event.Len() == 0 || drop || !clientOK {
			return
		}
		event.WriteByte('\n')
		if _, err := c.Writer.Write(event.Bytes()); err != nil {
			clientOK = false
			return
		}
		c.Writer.Flush()
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64<<10), maxEventLine)
	for clientOK && scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 { // a blank line ends an event
			send()
			continue
		}
		if data, ok := bytes.CutPrefix(line, []byte("data:")); ok {
			data = bytes.TrimSpace(data)
			if string(data) == "[DONE]" {
				sawDone = true
			} else {
				var chunk openai.StreamChunk
				if json.Unmarshal(data, &chunk) == nil {
					if chunk.Usage != nil && len(chunk.Choices) == 0 {
						usage = chunk.Usage
						drop = !clientWantsUsage
					} else if ttft == 0 && hasText(chunk) {
						ttft = time.Since(start)
					}
				}
			}
		}
		event.Write(line)
		event.WriteByte('\n')
	}
	send() // an event the upstream didn't close with a blank line

	attrs := []any{"status", http.StatusOK, "ttft_ms", ttft.Milliseconds(), "duration_ms", time.Since(start).Milliseconds()}
	if usage != nil {
		attrs = append(attrs, "prompt_tokens", usage.PromptTokens, "completion_tokens", usage.CompletionTokens)
	}
	switch {
	case !clientOK || c.Request.Context().Err() != nil:
		log.Info("client disconnected mid-stream", attrs...)
	case scanner.Err() != nil:
		log.Warn("vLLM stream broke", append(attrs, "err", scanner.Err())...)
	case !sawDone:
		log.Warn("vLLM stream ended without [DONE]", attrs...)
	default:
		log.Info("request done", attrs...)
	}
}

// hasText reports whether a chunk carries generated text. vLLM's first chat
// chunk only announces the assistant role, so it doesn't count for TTFT.
func hasText(chunk openai.StreamChunk) bool {
	for _, ch := range chunk.Choices {
		if ch.Delta.Content != "" || ch.Text != "" {
			return true
		}
	}
	return false
}

// injectIncludeUsage sets stream_options.include_usage to true, so every
// stream ends with exact token counts (needed for metering in phase 3). It
// keeps every other field, including other stream_options, and reports
// whether the client had asked for usage itself.
func injectIncludeUsage(body []byte) ([]byte, bool, *apiError) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return nil, false, badRequest("", "request body must be a JSON object")
	}

	opts := map[string]json.RawMessage{}
	if raw, ok := fields["stream_options"]; ok && !isEmptyJSON(raw) {
		if err := json.Unmarshal(raw, &opts); err != nil {
			return nil, false, badRequest("stream_options", "stream_options must be an object")
		}
	}
	clientWantsUsage := false
	if raw, ok := opts["include_usage"]; ok {
		if err := json.Unmarshal(raw, &clientWantsUsage); err != nil {
			return nil, false, badRequest("stream_options.include_usage", "stream_options.include_usage must be a boolean")
		}
	}

	opts["include_usage"] = json.RawMessage("true")
	rawOpts, err := json.Marshal(opts)
	if err != nil {
		return nil, false, badRequest("stream_options", "stream_options could not be encoded: %v", err)
	}
	fields["stream_options"] = rawOpts
	out, err := json.Marshal(fields)
	if err != nil {
		return nil, false, badRequest("", "request could not be re-encoded: %v", err)
	}
	return out, clientWantsUsage, nil
}
