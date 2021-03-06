# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# If you update this file, please follow
# https://suva.sh/posts/well-documented-makefiles

# Ensure Make is run with bash shell as some syntax below is bash-specific
SHELL:=/usr/bin/env bash

.DEFAULT_GOAL:=help

# Use GOPROXY environment variable if set
GOPROXY := $(shell go env GOPROXY)
ifeq ($(GOPROXY),)
GOPROXY := https://proxy.golang.org
endif
export GOPROXY

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on

# Directories.
ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(abspath $(TOOLS_DIR)/bin)
TEMPLATES_DIR := $(ROOT_DIR)/templates
BIN_DIR := $(abspath $(ROOT_DIR)/bin)
EXP_DIR := exp
GO_INSTALL = ./scripts/go_install.sh

# Binaries.
CLUSTERCTL := $(BIN_DIR)/clusterctl
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/controller-gen
CONVERSION_GEN := $(TOOLS_BIN_DIR)/conversion-gen
ENVSUBST := $(TOOLS_BIN_DIR)/envsubst
ETCD=$(TOOLS_BIN_DIR)/etcd
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
KUBE_APISERVER=$(TOOLS_BIN_DIR)/kube-apiserver
KUBECTL=$(TOOLS_BIN_DIR)/kubectl
KUSTOMIZE := $(TOOLS_BIN_DIR)/kustomize
MOCKGEN := $(TOOLS_BIN_DIR)/mockgen
RELEASE_NOTES := $(TOOLS_BIN_DIR)/release-notes
GO_APIDIFF := $(TOOLS_BIN_DIR)/go-apidiff
EXP_DIR := exp

# Define Docker related variables. Releases should modify and double check these vars.
REGISTRY ?= gcr.io/$(shell gcloud config get-value project)
STAGING_REGISTRY := gcr.io/k8s-staging-cluster-api-azure
PROD_REGISTRY := us.gcr.io/k8s-artifacts-prod/cluster-api-azure
IMAGE_NAME ?= cluster-api-azure-controller
CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)
TAG ?= dev
ARCH ?= amd64
ALL_ARCH = amd64 arm arm64 ppc64le s390x

# Allow overriding manifest generation destination directory
MANIFEST_ROOT ?= config
CRD_ROOT ?= $(MANIFEST_ROOT)/crd/bases
WEBHOOK_ROOT ?= $(MANIFEST_ROOT)/webhook
RBAC_ROOT ?= $(MANIFEST_ROOT)/rbac

# Allow overriding the imagePullPolicy
PULL_POLICY ?= Always

# Allow overriding the e2e configurations
ARTIFACTS ?= $(ROOT_DIR)/_artifacts
E2E_CONF_FILE ?= $(ROOT_DIR)/test/e2e/config/azure-dev.yaml
E2E_CONF_FILE_ENVSUBST := $(ROOT_DIR)/test/e2e/config/azure-dev-envsubst.yaml
SKIP_CLEANUP ?= false
SKIP_CREATE_MGMT_CLUSTER ?= false

# Build time versioning details.
LDFLAGS := $(shell hack/version.sh)

CLUSTER_TEMPLATE ?= cluster-template.yaml
MANAGED_CLUSTER_TEMPLATE ?= cluster-template-aks.yaml

## --------------------------------------
## Help
## --------------------------------------

help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Testing
## --------------------------------------

test: export TEST_ASSET_KUBECTL = $(KUBECTL)
test: export TEST_ASSET_KUBE_APISERVER = $(KUBE_APISERVER)
test: export TEST_ASSET_ETCD = $(ETCD)

.PHONY: test
test: $(KUBECTL) $(KUBE_APISERVER) $(ETCD) generate lint ## Run tests
	go test ./...


.PHONY: test-integration
test-integration: ## Run integration tests
	go test -v -tags=integration ./test/integration/...

.PHONY: test-e2e
test-e2e: $(ENVSUBST) ## Run e2e tests
	PULL_POLICY=IfNotPresent $(MAKE) docker-build
	MANAGER_IMAGE=$(CONTROLLER_IMG)-$(ARCH):$(TAG) \
	$(ENVSUBST) < $(E2E_CONF_FILE) > $(E2E_CONF_FILE_ENVSUBST) && \
	go test ./test/e2e -v -tags=e2e -ginkgo.v -ginkgo.trace -count=1 -timeout=90m \
		-e2e.artifacts-folder="$(ARTIFACTS)" \
		-e2e.config="$(E2E_CONF_FILE_ENVSUBST)" \
		-e2e.skip-resource-cleanup="$(SKIP_CLEANUP)" \
		-e2e.use-existing-cluster="$(SKIP_CREATE_MGMT_CLUSTER)"

$(KUBECTL) $(KUBE_APISERVER) $(ETCD): ## install test asset kubectl, kube-apiserver, etcd
	source ./scripts/fetch_ext_bins.sh && fetch_tools

## --------------------------------------
## Binaries
## --------------------------------------

.PHONY: binaries
binaries: manager ## Builds and installs all binaries

.PHONY: manager
manager: ## Build manager binary.
	go build -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/manager .

## --------------------------------------
## Tooling Binaries
## --------------------------------------

$(CLUSTERCTL): ## Build clusterctl binary.
	GOBIN=$(BIN_DIR) $(GO_INSTALL) sigs.k8s.io/cluster-api/cmd/clusterctl@v0.3.5

$(CONTROLLER_GEN): ## Build controller-gen from tools folder.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.9

$(CONVERSION_GEN): ## Build conversion-gen
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) k8s.io/code-generator/cmd/conversion-gen@v0.18.2

$(ENVSUBST): ## Build envsubst from tools folder.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/a8m/envsubst/cmd/envsubst@v1.1.0

$(GOLANGCI_LINT): ## Build golangci-lint from tools folder.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/golangci/golangci-lint/cmd/golangci-lint@v1.27.0

$(KUSTOMIZE): ## Build kustomize from tools folder.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/kustomize/kustomize/v3@v3.5.4

$(MOCKGEN): ## Build mockgen from tools folder.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/golang/mock/mockgen@v1.4.3

$(RELEASE_NOTES): ## Build release notes
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) sigs.k8s.io/cluster-api/hack/tools/release
	mv $(TOOLS_BIN_DIR)/release $(RELEASE_NOTES)

$(GO_APIDIFF): ## Build go-apidiff.
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) github.com/joelanford/go-apidiff

## --------------------------------------
## Linting
## --------------------------------------

.PHONY: lint
lint: $(GOLANGCI_LINT) ## Lint codebase
	$(GOLANGCI_LINT) run -v

lint-full: $(GOLANGCI_LINT) ## Run slower linters to detect possible issues
	$(GOLANGCI_LINT) run -v --fast=false

## --------------------------------------
## Generate
## --------------------------------------

.PHONY: modules
modules: ## Runs go mod to ensure proper vendoring.
	go mod tidy
	cd $(TOOLS_DIR); go mod tidy

.PHONY: generate
generate: ## Generate code
	$(MAKE) generate-go
	$(MAKE) generate-manifests
	$(MAKE) generate-flavors

.PHONY: generate-go
generate-go: $(CONTROLLER_GEN) $(MOCKGEN) $(CONVERSION_GEN) ## Runs Go related generate targets
	$(CONTROLLER_GEN) \
		paths=./api/... \
		paths=./$(EXP_DIR)/api/... \
		object:headerFile=./hack/boilerplate/boilerplate.generatego.txt
	$(CONVERSION_GEN) \
		--input-dirs=./api/v1alpha2 \
		--output-file-base=zz_generated.conversion \
		--go-header-file=./hack/boilerplate/boilerplate.generatego.txt
	go generate ./...

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate manifests e.g. CRD, RBAC etc.
	$(CONTROLLER_GEN) \
		paths=./api/... \
		paths=./$(EXP_DIR)/api/... \
		crd:crdVersions=v1 \
		output:crd:dir=$(CRD_ROOT) \
		output:webhook:dir=$(WEBHOOK_ROOT) \
		webhook
	$(CONTROLLER_GEN) \
		paths=./controllers/... \
		paths=./$(EXP_DIR)/controllers/... \
		output:rbac:dir=$(RBAC_ROOT) \
		rbac:roleName=manager-role

.PHONY: generate-flavors ## Generate template flavors
generate-flavors: $(KUSTOMIZE)
	./hack/gen-flavors.sh

## --------------------------------------
## Docker
## --------------------------------------

.PHONY: docker-build
docker-build: ## Build the docker image for controller-manager
	docker build --pull --build-arg ARCH=$(ARCH) . -t $(CONTROLLER_IMG)-$(ARCH):$(TAG)
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(MAKE) set-manifest-pull-policy

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CONTROLLER_IMG)-$(ARCH):$(TAG)

## --------------------------------------
## Docker — All ARCH
## --------------------------------------

.PHONY: docker-build-all ## Build all the architecture docker images
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH))

docker-build-%:
	$(MAKE) ARCH=$* docker-build

.PHONY: docker-push-all ## Push all the architecture docker images
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))
	$(MAKE) docker-push-manifest

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: docker-push-manifest
docker-push-manifest: ## Push the fat manifest docker image.
	## Minimum docker version 18.06.0 is required for creating and pushing manifest images.
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge ${CONTROLLER_IMG}:${TAG}
	MANIFEST_IMG=$(CONTROLLER_IMG) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(MAKE) set-manifest-pull-policy

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' ./config/manager/manager_image_patch.yaml

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resource)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/manager/manager_pull_policy.yaml

## --------------------------------------
## Release
## --------------------------------------

RELEASE_TAG := $(shell git describe --abbrev=0 2>/dev/null)
RELEASE_DIR := out

$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)/

.PHONY: release
release: clean-release  ## Builds and push container images using the latest git tag for the commit.
	@if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	@if ! [ -z "$$(git status --porcelain)" ]; then echo "Your local git repository contains uncommitted changes, use git clean before proceeding."; exit 1; fi
	git checkout "${RELEASE_TAG}"
	# Set the manifest image to the production bucket.
	$(MAKE) set-manifest-image MANIFEST_IMG=$(PROD_REGISTRY)/$(IMAGE_NAME) MANIFEST_TAG=$(RELEASE_TAG)
	$(MAKE) set-manifest-pull-policy PULL_POLICY=IfNotPresent
	$(MAKE) release-manifests
	$(MAKE) release-templates

.PHONY: release-manifests
release-manifests: $(KUSTOMIZE) $(RELEASE_DIR) ## Builds the manifests to publish with a release
	kustomize build config > $(RELEASE_DIR)/infrastructure-components.yaml

.PHONY: release-templates
release-templates: $(RELEASE_DIR)
	cp templates/cluster-template* $(RELEASE_DIR)/

.PHONY: release-binary
release-binary: $(RELEASE_DIR)
	docker run \
		--rm \
		-e CGO_ENABLED=0 \
		-e GOOS=$(GOOS) \
		-e GOARCH=$(GOARCH) \
		-v "$$(pwd):/workspace" \
		-w /workspace \
		golang:1.13.8 \
		go build -a -ldflags '$(LDFLAGS) -extldflags "-static"' \
		-o $(RELEASE_DIR)/$(notdir $(RELEASE_BINARY))-$(GOOS)-$(GOARCH) $(RELEASE_BINARY)

.PHONY: release-staging
release-staging: ## Builds and push container images to the staging bucket.
	REGISTRY=$(STAGING_REGISTRY) $(MAKE) docker-build-all docker-push-all release-alias-tag

RELEASE_ALIAS_TAG=$(PULL_BASE_REF)

.PHONY: release-alias-tag
release-alias-tag: # Adds the tag to the last build tag.
	gcloud container images add-tag $(CONTROLLER_IMG):$(TAG) $(CONTROLLER_IMG):$(RELEASE_ALIAS_TAG)

.PHONY: release-notes
release-notes: $(RELEASE_NOTES)
	$(RELEASE_NOTES)

## --------------------------------------
## Development
## --------------------------------------

.PHONY: create-management-cluster
create-management-cluster: $(KUSTOMIZE) $(ENVSUBST)
	## Create kind management cluster.
	$(MAKE) kind-create

	# Install cert manager and wait for availability
	kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v0.11.1/cert-manager.yaml
	kubectl wait --for=condition=Available --timeout=5m apiservice v1beta1.webhook.cert-manager.io

	# Deploy CAPI
	kubectl apply -f https://github.com/kubernetes-sigs/cluster-api/releases/download/v0.3.6/cluster-api-components.yaml

	# Deploy CAPZ
	kind load docker-image $(CONTROLLER_IMG)-$(ARCH):$(TAG) --name=capz
	$(KUSTOMIZE) build config | $(ENVSUBST) | kubectl apply -f -

	# Wait for CAPI pods
	kubectl wait --for=condition=Ready --timeout=5m -n capi-system pod -l cluster.x-k8s.io/provider=cluster-api
	kubectl wait --for=condition=Ready --timeout=5m -n capi-kubeadm-bootstrap-system pod -l cluster.x-k8s.io/provider=bootstrap-kubeadm
	kubectl wait --for=condition=Ready --timeout=5m -n capi-kubeadm-control-plane-system pod -l cluster.x-k8s.io/provider=control-plane-kubeadm

	# Wait for CAPZ pods
	kubectl wait --for=condition=Ready --timeout=5m -n capz-system pod -l cluster.x-k8s.io/provider=infrastructure-azure

	# required sleep for when creating management and workload cluster simultaneously
	sleep 10
	@echo 'Set kubectl context to the kind management cluster by running "kubectl config set-context kind-capz"'

.PHONY: create-workload-cluster
create-workload-cluster: $(ENVSUBST)
	# Create workload Cluster.
	$(ENVSUBST) < $(TEMPLATES_DIR)/$(CLUSTER_TEMPLATE) | kubectl apply -f -

	# Wait for the kubeconfig to become available.
	timeout --foreground 300 bash -c "while ! kubectl get secrets | grep $(CLUSTER_NAME)-kubeconfig; do sleep 1; done"
	# Get kubeconfig and store it locally.
	kubectl get secrets $(CLUSTER_NAME)-kubeconfig -o json | jq -r .data.value | base64 --decode > ./kubeconfig
	timeout --foreground 600 bash -c "while ! kubectl --kubeconfig=./kubeconfig get nodes | grep master; do sleep 1; done"

	# Deploy calico
	kubectl --kubeconfig=./kubeconfig apply -f templates/addons/calico.yaml

	@echo 'run "kubectl --kubeconfig=./kubeconfig ..." to work with the new target cluster'

.PHONY: create-aks-cluster
create-aks-cluster: $(KUSTOMIZE) $(ENVSUBST)
	# Create managed Cluster.
	$(ENVSUBST) < $(TEMPLATES_DIR)/$(MANAGED_CLUSTER_TEMPLATE) | kubectl apply -f -

	# Wait for the kubeconfig to become available.
	timeout --foreground 300 bash -c "while ! kubectl get secrets | grep $(CLUSTER_NAME)-kubeconfig; do sleep 1; done"
	# Get kubeconfig and store it locally.
	kubectl get secrets $(CLUSTER_NAME)-kubeconfig -o json | jq -r .data.value | base64 --decode > ./kubeconfig
	timeout --foreground 600 bash -c "while ! kubectl --kubeconfig=./kubeconfig get nodes | grep master; do sleep 1; done"

	@echo 'run "kubectl --kubeconfig=./kubeconfig ..." to work with the new target cluster'


.PHONY: create-cluster
create-cluster: create-management-cluster create-workload-cluster ## Create a workload development Kubernetes cluster on Azure in a kind management cluster.

.PHONY: delete-workload-cluster
delete-workload-cluster: ## Deletes the example workload Kubernetes cluster
	@echo 'Your Azure resources will now be deleted, this can take up to 20 minutes'
	kubectl delete cluster $(CLUSTER_NAME)

## --------------------------------------
## Tilt / Kind
## --------------------------------------

.PHONY: kind-create
kind-create: ## create capz kind cluster if needed
	./scripts/kind-with-registry.sh

.PHONY: tilt-up
tilt-up: kind-create ## start tilt and build kind cluster if needed
	tilt up

.PHONY: delete-cluster
delete-cluster: delete-workload-cluster  ## Deletes the example kind cluster "capz"
	kind delete cluster --name=capz

.PHONY: kind-reset
kind-reset: ## Destroys the "capz" kind cluster.
	kind delete cluster --name=capz || true


## --------------------------------------
## Cleanup / Verification
## --------------------------------------

.PHONY: clean
clean: ## Remove all generated files
	$(MAKE) clean-bin
	$(MAKE) clean-temporary

.PHONY: clean-bin
clean-bin: ## Remove all generated binaries
	rm -rf bin
	rm -rf hack/tools/bin

.PHONY: clean-temporary
clean-temporary: ## Remove all temporary files and folders
	rm -f minikube.kubeconfig
	rm -f kubeconfig

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

.PHONY: verify
verify: verify-boilerplate verify-modules verify-gen

.PHONY: verify-boilerplate
verify-boilerplate:
	./hack/verify-boilerplate.sh

.PHONY: verify-modules
verify-modules: modules
	@if !(git diff --quiet HEAD -- go.sum go.mod hack/tools/go.mod hack/tools/go.sum); then \
		echo "go module files are out of date"; exit 1; \
	fi

.PHONY: verify-gen
verify-gen: generate
	@if !(git diff --quiet HEAD); then \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi
