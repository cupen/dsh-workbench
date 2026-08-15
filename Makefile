.PHONY: build run stop shell

build:
	docker compose build

run:
	docker compose up -d

stop:
	docker compose down

shell:
	docker compose exec dsh bash
