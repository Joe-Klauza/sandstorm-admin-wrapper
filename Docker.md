# Docker Setup

## Requirements

- docker
- docker-compose

## Getting the wrapper up and running

Navigate to the cloned repo, then run `docker-compose up -d` to start the admin wrapper. This will build the container and start it in the background.
To stop the wrapper execute `docker-compose down`. This will stop and remove the running container. The config folders are mounted in volumes to prevent you have to configure the wrapper every time you start it up. The Server itself will also be downloaded once into a volume, and then reused. This means the first startup can take up to a couple minutes, but all others should only take a few seconds.

# Post-1.20 Mod Support

## io_uring

Starting with Sandstorm 1.20, mod.io functionality appears to use Linux's `io_uring` interface. In our testing, enabling access to `io_uring` resolved mod initialization and installation issues in Docker.

Docker's default seccomp security profile blocks the `io_uring_setup`, `io_uring_enter`, and `io_uring_register` system calls due to known security vulnerabilities, including potential container escapes.

An optional workaround is included in `docker-compose.yml`. If your server encounters mod.io initialization or installation failures related to this restriction, uncomment:

```yaml
security_opt:
  - seccomp=unconfined
```

**Security warning:** This disables Docker's entire seccomp syscall filter for the container, not just the `io_uring` restrictions. It reduces container isolation and should only be enabled when necessary and when the security implications are understood.

A custom seccomp profile permitting the required `io_uring` calls is a more targeted alternative, although enabling those calls still carries potential security risks.

## Mod.io Volume Ownership

The mod.io content directory is now persisted using a dedicated Docker named volume.

For fresh installations using the updated Dockerfile, the directory should be created with the correct `sandstorm:sandstorm` ownership automatically.

Existing installations may have a mod.io volume that was initialized with incorrect ownership, such as `root:root`. This can prevent the non-root Sandstorm server process from writing downloaded mod files.

If server logs report `Insufficient permission for filesystem operation`, verify the directory ownership:

```bash
docker compose exec sandstorm-wrapper \
  ls -ld /home/sandstorm/steamcmd/mod.io
```

If ownership is incorrect, run the following one-time correction:

```bash
docker compose exec -u 0 sandstorm-wrapper \
  chown -R sandstorm:sandstorm /home/sandstorm/steamcmd/mod.io
```

Restart the game server afterward to retry any failed mod installations.

**Note:** Rebuilding the Docker image does not correct ownership of existing named volumes. The Dockerfile ownership change applies when initializing new volumes.
