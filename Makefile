ARCHLINUX_IMAGE ?= archlinux:latest
ARCHLINUX_IMAGE_LOCAL ?= docker.m.daocloud.io/library/archlinux:latest

.PHONY: build build-local run stop shell

build:
	docker compose build

# Mainland China build: uses a domestic Docker Hub mirror for the Arch base.
build-local:
	ARCHLINUX_IMAGE=$(ARCHLINUX_IMAGE_LOCAL) docker compose build

run:
	docker compose up -d

stop:
	docker compose down

shell:
	docker compose exec dsh bash
