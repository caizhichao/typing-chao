package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 代理路由必须只接受带 capability 的 completion 路径，不能把上游密钥暴露给桌面客户端。
func TestProxyRoutesRequireCapabilityAndForwardValidRequest(t *testing.T) {
	var upstreamRequestCount atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		upstreamRequestCount.Add(1)
		if request.Method != http.MethodPost {
			t.Fatalf("unexpected upstream method: %s", request.Method)
		}
		if request.Header.Get("Authorization") != "Bearer upstream-key" {
			t.Fatal("proxy did not attach upstream authorization")
		}
		if request.URL.Path != "/v1/chat/completions" {
			t.Fatalf("unexpected upstream path: %s", request.URL.Path)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil || string(body) != `{"model":"deepseek-v4-flash"}` {
			t.Fatalf("proxy did not preserve request body: %q, %v", body, err)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"choices":[{"message":{"content":"Hello"}}]}`))
	}))
	defer upstream.Close()

	server := &proxyServer{
		client:         upstream.Client(),
		upstreamURL:    upstream.URL,
		deepSeekAPIKey: "upstream-key",
		accessToken:    "expected-capability",
		rateByIP:       make(map[string]rateEntry),
	}

	healthRequest := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	healthResponse := httptest.NewRecorder()
	server.routes().ServeHTTP(healthResponse, healthRequest)
	if healthResponse.Code != http.StatusOK || strings.TrimSpace(healthResponse.Body.String()) != `{"status":"ok"}` {
		t.Fatalf("unexpected health response: %d %s", healthResponse.Code, healthResponse.Body.String())
	}

	invalidRequest := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
	invalidResponse := httptest.NewRecorder()
	server.routes().ServeHTTP(invalidResponse, invalidRequest)
	if invalidResponse.Code != http.StatusNotFound || upstreamRequestCount.Load() != 0 {
		t.Fatalf("missing capability must not reach upstream: status=%d count=%d", invalidResponse.Code, upstreamRequestCount.Load())
	}

	validRequest := httptest.NewRequest(
		http.MethodPost,
		"/v1/chat/completions/expected-capability",
		strings.NewReader(`{"model":"deepseek-v4-flash"}`),
	)
	validRequest.Header.Set("Content-Type", "application/json")
	validResponse := httptest.NewRecorder()
	server.routes().ServeHTTP(validResponse, validRequest)
	if validResponse.Code != http.StatusOK || validResponse.Body.String() != `{"choices":[{"message":{"content":"Hello"}}]}` {
		t.Fatalf("valid capability response mismatch: %d %s", validResponse.Code, validResponse.Body.String())
	}
	if upstreamRequestCount.Load() != 1 {
		t.Fatalf("valid capability must forward exactly once, got %d", upstreamRequestCount.Load())
	}
}

// 访问频率限制按远端地址分桶，超限不得透传到付费上游。
func TestRateLimitRejectsThirtyFirstRequest(t *testing.T) {
	server := &proxyServer{rateByIP: make(map[string]rateEntry)}
	for index := 0; index < 30; index++ {
		if !server.allowRequest("127.0.0.1:12345") {
			t.Fatalf("request %d should be allowed", index+1)
		}
	}
	if server.allowRequest("127.0.0.1:12345") {
		t.Fatal("thirty-first request should be rejected")
	}
	server.rateByIP["127.0.0.1"] = rateEntry{startedAt: time.Now().Add(-time.Minute), count: 30}
	if !server.allowRequest("127.0.0.1:12345") {
		t.Fatal("next minute must reset the per-IP request window")
	}
}
