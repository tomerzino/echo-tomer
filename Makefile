CLUSTER_NAME ?= ping-pong
NAMESPACE    ?= ping-pong
IMAGE        ?= ghcr.io/tomer-zino/ping-pong
TAG          ?= dev-$(shell date +%s)
DEV_TOKEN    ?= dev-secret-token
REPLICAS     ?= 2

.PHONY: up down restart test

up:
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	kind create cluster --name $(CLUSTER_NAME)
	helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
		--namespace envoy-gateway-system --create-namespace --wait --timeout 120s
	kubectl create namespace $(NAMESPACE)
	kubectl apply -f docs/local/gateway.yaml
	docker build -t $(IMAGE):$(TAG) .
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER_NAME)
	helm dependency build deploy/ping-pong/
	helm install ping-pong deploy/ping-pong/ \
		--namespace $(NAMESPACE) \
		--set common.image.tag=$(TAG) \
		--set common.secret.data.token=$(DEV_TOKEN) \
		--set common.replicaCount=$(REPLICAS)
	kubectl rollout status deployment/ping-pong --namespace $(NAMESPACE) --timeout=120s
	@echo "\n📊 Running with $(REPLICAS) replicas:"
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=ping-pong
	@kubectl port-forward -n $(NAMESPACE) svc/ping-pong 8081:80 &>/dev/null & PF_PID=$$!; \
		sleep 3; \
		echo "\n🧪 Testing endpoints..."; \
		echo "  Health: $$(curl -sf http://localhost:8081/health | grep -o '"status":"[^"]*"')"; \
		echo "  Ping:   $$(curl -sf -H 'Authorization: Bearer $(DEV_TOKEN)' http://localhost:8081/ping | grep -o '"message":"[^"]*"')"; \
		echo "  Pong:   $$(curl -sf -H 'Authorization: Bearer $(DEV_TOKEN)' http://localhost:8081/pong | grep -o '"message":"[^"]*"')"; \
		echo "  Unauth: $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/ping)"; \
		kill $$PF_PID 2>/dev/null; \
		echo "\n✅ All endpoints responding with $(REPLICAS) replicas"

down:
	kind delete cluster --name $(CLUSTER_NAME)

restart:
	docker build -t $(IMAGE):$(TAG) .
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER_NAME)
	helm upgrade ping-pong deploy/ping-pong/ \
		--namespace $(NAMESPACE) \
		--set common.image.tag=$(TAG) \
		--set common.secret.data.token=$(DEV_TOKEN) \
		--reuse-values
	kubectl rollout status deployment/ping-pong --namespace $(NAMESPACE) --timeout=120s

GOBIN := $(shell go env GOPATH)/bin

test:
	@command -v golangci-lint > /dev/null 2>&1 || (echo "Installing golangci-lint..." && curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b $(GOBIN) v2.12.1)
	@command -v govulncheck > /dev/null 2>&1 || (echo "Installing govulncheck..." && go install golang.org/x/vuln/cmd/govulncheck@latest)
	@command -v hadolint > /dev/null 2>&1 || (echo "Installing hadolint..." && brew install hadolint)
	go test -v -race ./...
	go vet ./...
	$(GOBIN)/golangci-lint run
	$(GOBIN)/govulncheck ./...
	hadolint Dockerfile
