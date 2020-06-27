# Docker Setup

## Requirements

- docker
- docker-compose

## Getting the wrapper up and running

Navigate to the cloned repo, then run `docker-compose up -d` to start the admin wrapper. This will build the container and start it in the background.
To stop the wrapper execute `docker-compose down`. This will stop and remove the running container. The config folders are mounted in volumes to prevent you have to configure the wrapper every time you start it up. The Server itself will also be downloaded once into a volume, and then reused. This means the first startup can take up to a couple minutes, but all others should only take a few seconds.
