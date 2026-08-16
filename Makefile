.PHONY: build build-dev run stop shell

build:
	docker compose build

build-dev:
	docker compose build --build-arg DSH_DEV_MODE=true

run:
	docker compose up -d

stop:
	docker compose down

shell:
	docker compose exec dsh bash
