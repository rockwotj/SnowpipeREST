APP_NAME = post_load_gen
TAG = v9
TAGGED_DOCKER_IMAGE = rockwoodredpanda/$(APP_NAME):$(TAG)
LATEST_DOCKER_IMAGE = rockwoodredpanda/$(APP_NAME):latest

.PHONY: build push infra clean

build:
	docker build -t $(TAGGED_DOCKER_IMAGE) -t $(LATEST_DOCKER_IMAGE) .

push: build
	docker push $(TAGGED_DOCKER_IMAGE)
	docker push $(LATEST_DOCKER_IMAGE)

infra:
	terraform apply -auto-approve

clean:
	docker rmi $(DOCKER_IMAGE)

