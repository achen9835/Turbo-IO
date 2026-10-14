# Issue tracker: Gitee

Issues and specs for this repo live as **Gitee issues** (repo `achen9835/Turbo-IO`, remote `gitee`).

> **Why not GitHub**: `github.com` web/OAuth endpoints are unreachable from this machine
> (`api.github.com` and `ssh.github.com:443` do work), so GitHub Issues cannot be driven
> from here. Gitee, the mirror remote, is directly reachable.

## Prerequisites

- A Gitee **personal access token** with repo write scope, supplied by the maintainer
  per call (form/query param `access_token`). **Never commit the token** to any file in
  this repo.

## Conventions (Gitee OpenAPI v5, base `https://gitee.com/api/v5`)

- **Create an issue**: `POST /repos/{owner}/issues` with form params `repo=<repo-path>`, `title`, `body`, `labels` (comma-separated label names).
- **Read an issue**: `GET /repos/{owner}/{repo}/issues/{number}` (issue numbers look like `IKLAZ2`).
- **List issues**: `GET /repos/{owner}/{repo}/issues?state=open`, optionally `labels=` filter.
- **Comment on an issue**: `POST /repos/{owner}/{repo}/issues/{number}/comments` with `body` — **requires the token to include the `notes` scope**; a token without it returns `401 no 'notes' scope`. Without that scope, fold the comment content into the issue body via the update endpoint instead.
- **Create a label**: `POST /repos/{owner}/{repo}/labels` with JSON body `{"name": ..., "color": "RRGGBB"}`.
- **Update / close**: `PATCH /repos/{owner}/issues/{number}` with form params `repo=<repo-path>` plus the fields to change (e.g. `state=closed`) — note the path is `/repos/{owner}/issues/{number}` (repo NOT in the path), same shape as create.

If issue creation fails with 「此仓库关闭Issue模块」, enable the module first:
`PATCH /repos/{owner}/{repo}` with `name=<repo-path>&has_issues=true` (name is required by this endpoint even when unchanged).

## Blocking edges

Gitee has no native issue-dependency graph. Blocking is expressed **in the issue body**:

```
## Blocked by

- <blocking issue number / title>
```

A ticket is unblocked when every issue referenced in its `Blocked by` list is closed. Skills scanning for the frontier parse that list.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says "publish to the issue tracker"

Create a Gitee issue.

## When a skill says "fetch the relevant ticket"

`GET /repos/achen9835/Turbo-IO/issues/<number>`, comments via the comments endpoint.

## Wayfinding operations

Used by `/wayfinder`. Gitee has no sub-issues or native dependencies, so:

- **Map**: a single issue labelled `wayfinder:map` whose body holds Notes / Decisions-so-far / Fog plus a task list of child issues (`- [ ] #<number> <title>`).
- **Child ticket**: an issue labelled `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`), listed in the map's task list, with `Part of #<map>` at the top of its body.
- **Blocking**: the body `Blocked by` convention above; a ticket is unblocked when every referenced issue is closed.
- **Frontier query**: open children from the map's task list minus any with an open `Blocked by` entry or an assignee; first in map order wins.
- **Claim**: comment claiming it, then set assignee via the update endpoint.
- **Resolve**: comment the answer, close the child, append a context pointer to the map's Decisions-so-far.
