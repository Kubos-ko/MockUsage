# Supported container runtimes

Mock Usage connects with `docker --context <context> exec -i <container> python3 - <provider>`. The collector is supplied over standard input. It does not expose a monitoring port, install packages, or copy tokens to the host.

| Provider | Validated runtime versions | Adapter | Image requirement |
| --- | --- | --- | --- |
| GPTMock | Python package `gptmock` 2026.9.29 and 2026.11.16 | `codex-wham-v1` | Python 3 with the GPTMock package importable and an authenticated GPTMock home |
| Claude Code | CLI 2.1.325 | `claude-oauth-v1` | Python 3 plus `claude` on PATH, authenticated for the Docker exec user |

Any locally built image satisfying this contract may work; this app does not bundle container images. Upstream distribution links are listed below. Tags such as `gptmock:local` are examples, not version detection. GPTMock's package metadata and `claude --version` are the source of truth. Image tags/digests are not substituted for runtime versions.

Unknown versions use read-only fallback adapters with direct resets disabled. Explicitly incompatible versions can be listed as unsupported and are blocked before authentication. The app currently has no production version marked explicitly unsupported. Adding a new supported runtime requires a manual app release.

## Where to obtain containers

- **GPTMock source and Compose files:** [rapidrabbit76/GPTMock](https://github.com/rapidrabbit76/GPTMock). Its upstream Compose configuration references the published `rapidrabbit76/gptmock:latest` image. [Upstream Docker setup](https://github.com/rapidrabbit76/GPTMock#quick-start-docker-recommended) also describes building the checked-out source. This is a community project, not an OpenAI container image.
- **Claude Code:** follow Anthropic's [development-container guide](https://code.claude.com/docs/en/devcontainer) and [reference configuration](https://github.com/anthropics/claude-code/tree/main/.devcontainer). The reference is an example to build, not a maintained base image. Ensure Python 3 is present for Mock Usage and complete the CLI login inside the container.

Use the upstream installation/authentication instructions, then select the resulting running container in Sources. A `latest` image can change independently of this application's tested compatibility list. Check its actual runtime version before relying on direct reset support. No claim is made that every newer image tag has been tested.

## GPTMock

Build or obtain a GPTMock image independently, authenticate it using GPTMock's own supported flow, and keep its data directory persistent. The collector imports `gptmock.infra.auth.load_chatgpt_tokens` for lock-aware credential renewal and `get_home_dir` for reset journaling. It reads the local model registry when available.

Example connection checks for a container you already run:

```sh
docker exec your-gptmock-container python3 -c 'import importlib.metadata; print(importlib.metadata.version("gptmock"))'
```

Select GPTMock in Sources and choose that container. Model catalog checks also need an installed Codex CLI on the host so the actual client version can be supplied. If the CLI cannot be found, the app reports the catalog check as unavailable instead of inventing a version.

## Claude Code

Use a Linux image containing Python 3 and an installed Claude Code CLI. Authenticate interactively using the CLI's own login flow before connecting the source. The collector reads `.credentials.json` inside `CLAUDE_CONFIG_DIR`, or `~/.claude` if it is unset. The user executing `docker exec` must have access to that same authenticated directory.

```sh
docker exec your-claude-container python3 --version
docker exec your-claude-container claude --version
```

Credentials and renewal belong to Claude Code. Do not put OAuth tokens in Dockerfiles, Compose files, images, build arguments or Git. The app does not turn a generic Node image into an authenticated Claude container.

## Isolation and persistence

Use separate provider homes for separate accounts. Persist those homes in private volumes and restrict access. The host's Docker access is powerful; connect only to an engine you trust. The app's schema checks and account grouping do not replace Docker security boundaries.

Keep the reset journal persistent across container recreation. Removing it can remove protection against repeating an uncertain submission. No Compose credentials or private image definitions are included in this source distribution.
