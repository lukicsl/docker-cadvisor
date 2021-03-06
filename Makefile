#ARCHITECTURES = amd64 i386 arm32v5 arm32v7 arm64v8
ARCHITECTURES = arm32v7 
IMAGE_TARGET = debian:buster-slim
BUILD_BASE = base
MULTIARCH = multiarch/qemu-user-static:register
QEMU_VERSION = v2.11.0
VERSION = $(shell cat VERSION)
#DOCKER_USER = test
#DOCKER_PASS = test
ifeq ($(REPO),)
  REPO = cadvisor
endif
ifeq ($(CIRCLE_TAG),)
	TAG = latest
else
	TAG = $(CIRCLE_TAG)
endif

all: $(ARCHITECTURES)

$(ARCHITECTURES): base
	@echo "[x]    Building $(REPO):linux-$@-$(TAG)"
	@docker run --rm --privileged $(MULTIARCH) --reset
	@docker build \
			--build-arg BUILD_BASE=$(BUILD_BASE):$(TAG) \
			--build-arg IMAGE_TARGET=$@/$(IMAGE_TARGET) \
			--build-arg QEMU=$(strip $(call qemuarch,$@)) \
			--build-arg QEMU_VERSION=$(QEMU_VERSION) \
			--build-arg ARCH=$@ \
			--build-arg CADVISOR_ARCH=$(strip $(call xgoarch,$@)) \
			--build-arg BUILD_DATE=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ") \
			--build-arg VCS_REF=$(shell git rev-parse --short HEAD) \
			--build-arg VCS_URL=$(shell git config --get remote.origin.url) \
			--build-arg VERSION=$(VERSION) \
			-t $(REPO):linux-$@-$(TAG) .

base:
	@ID=$$(docker images -q $(BUILD_BASE):$(TAG)) && \
	if test "$$ID" = ""; then \
	    echo "[x]    Building Base Image $(BUILD_BASE):$(TAG)"; \
			docker build \
					--build-arg VERSION=$(VERSION) \
					-f Dockerfile.compile -t $(BUILD_BASE):$(TAG) .; \
	else \
			echo "[x]    Image $(BUILD_BASE):$(TAG) already exists"; \
	fi

push:
#	@docker login -u $(DOCKER_USER) -p $(DOCKER_PASS)
	@$(foreach arch,$(ARCHITECTURES), docker push $(REPO):linux-$(arch)-$(TAG);)
#	@docker logout

manifest:
	@wget -O docker https://6582-88013053-gh.circle-artifacts.com/1/work/build/docker-linux-amd64
	@chmod +x docker
	@./docker login -u $(DOCKER_USER) -p $(DOCKER_PASS)
	@./docker manifest create $(REPO):$(TAG) \
			$(foreach arch,$(ARCHITECTURES), $(REPO):linux-$(arch)-$(TAG)) --amend
	@$(foreach arch,$(ARCHITECTURES), ./docker manifest annotate \
			$(REPO):$(TAG) $(REPO):linux-$(arch)-$(TAG) \
			--os linux $(strip $(call convert_variants,$(arch)));)
	@./docker manifest push $(REPO):$(TAG)
	@./docker logout
	@rm -f docker

test:
	@docker network create -d bridge trial
	@$(foreach arch,$(ARCHITECTURES), docker run \
			--volume=/:/rootfs:ro \
			--volume=/var/run:/var/run:rw \
			--volume=/sys:/sys:ro \
			--volume=/var/lib/docker/:/var/lib/docker:ro \
			--volume=/dev/disk/:/dev/disk:ro \
			--publish=8080:8080 \
			--detach=true \
			--name=cadvisor \
			$(REPO):linux-$(arch)-$(TAG); \
			sleep 10; \
			docker run --network trial \
				jwilder/dockerize dockerize -wait tcp://cadvisor:8080 -timeout 300s; \
			curl -sSL --retry 10 --retry-delay 5 localhost:8080 | grep cAdvisor; \
			docker rm -f cadvisor;)
	@docker network rm trial

clean:
	@echo "[x]    Removing Images"
	@docker rmi -f $(BUILD_BASE):$(TAG)
  $(foreach arch,$(ARCHITECTURES), docker rmi -f $(REPO):linux-$(arch)-$(TAG);)

# Needed convertions for different architecture naming schemes
# Convert qemu archs to naming scheme of https://github.com/multiarch/qemu-user-static/releases
define qemuarch
	$(shell echo $(1) | sed -e "s|arm32.*|arm|g" -e "s|arm64.*|aarch64|g" -e "s|amd64|x86_64|g")
endef
# Convert GOARCH to naming scheme of https://gist.github.com/asukakenji/f15ba7e588ac42795f421b48b8aede63
define xgoarch
	$(shell echo $(1) | sed -e "s|arm32v5|arm-5|g" -e "s|arm32v6|arm-6|g" -e "s|arm32v7|arm-7|g" -e "s|arm64.*|arm64|g" -e "s|i386|386|g")
endef
# Convert Docker manifest entries according to https://docs.docker.com/registry/spec/manifest-v2-2/#manifest-list-field-descriptions
define convert_variants
	$(shell echo $(1) | sed -e "s|amd64|--arch amd64|g" -e "s|i386|--arch 386|g" -e "s|arm32v5|--arch arm --variant v5|g" -e "s|arm32v6|--arch arm --variant v6|g" -e "s|arm32v7|--arch arm --variant v7|g" -e "s|arm64v8|--arch arm64 --variant v8|g" -e "s|ppc64le|--arch ppc64le|g" -e "s|s390x|--arch s390x|g")
endef
