# Lab 4 — Docker and a GitHub Actions pipeline

Repository: `mcdiamondz/ACS730-CourseWork`. Application files live in `lab4/`; the
three pipeline files live at the repository root under `.github/` because that is
the only place Actions reads from:

- `.github/workflows/lab4-ci.yml` — the pipeline (test matrix → build → smoke → publish, plus the reusable-workflow call and an `always()` summary)
- `.github/workflows/docker-build.yml` — reusable workflow (`workflow_call`)
- `.github/actions/python-deps/action.yml` — composite action

## Build and run

```bash
cd lab4

# the image we ship
docker build -t acs730-lab4:slim .
docker run -d --name lab4 -p 8000:8000 acs730-lab4:slim
curl -s http://localhost:8000/healthz      # {"status":"ok","version":"dev"}
curl -s http://localhost:8000/             # ACS730 Lab 4 -- version dev
docker exec lab4 whoami                    # appuser  (not root)
docker rm -f lab4

# the deliberately bad image, kept so the comparison can be re-run
docker build -f Dockerfile.naive -t acs730-lab4:naive .

# tests (pytest reads pytest.ini: testpaths=tests, pythonpath=.)
python3 -m pip install --user -r requirements.txt -r requirements-dev.txt
python3 -m pytest                          # 3 passed

# the image CI publishes, tagged by commit SHA
docker pull ghcr.io/mcdiamondz/acs730-lab4:sha-<first 12 chars of a main commit>
```

`EXPOSE 8000` in the Dockerfile only documents the port; `-p 8000:8000` on
`docker run` is what publishes it. The `Dockerfile` pins `python:3.12-slim-bookworm`,
copies `requirements.txt` and installs dependencies **before** copying `app.py`,
creates `appuser` (uid 10001) and switches to it, and uses exec-form `CMD` so
gunicorn is PID 1. `.dockerignore` keeps `.git`, `.github`, `__pycache__/`, `*.pyc`,
`.pytest_cache/`, `evidence/`, `*.png`, `*.md` and `Dockerfile*` out of the build context.

## Image size comparison (Part 4)

Measured on the workstation (t3.small, Docker 25, BuildKit). Screenshot: `evidence/image-sizes.png`.

| Image   | Base image                         | Size   | Rebuild after a one-line code change                        |
|---------|------------------------------------|--------|-------------------------------------------------------------|
| `naive` | `python:latest` (1.13 GB, Python 3.15.1 on full Debian) | **1.15 GB** | **4.8 s** — `RUN pip install` ran again (not CACHED) |
| `slim`  | `python:3.12-slim-bookworm` (124 MB) | **130 MB**  | **0.26 s** — every layer `CACHED` except `COPY app.py`    |

`docker history` receipts (bytes each layer added):

| Layer                       | naive   | slim    |
|-----------------------------|---------|---------|
| base image                  | 1.13 GB | 124 MB  |
| `RUN pip install …`         | 17.8 MB | 6.38 MB |
| `COPY . .` / `COPY app.py`  | 395 B   | 285 B   |
| `useradd` + `chown`         | —       | 4.63 kB |

- **Base image:** essentially all of the difference. `python:latest` is 1.13 GB and `python:3.12-slim-bookworm` is 124 MB, so 1.006 GB of the 1.02 GB gap (≈98 %) is line 1 of the Dockerfile; our own layers add only ~18 MB (naive) and ~6.4 MB (slim) on top.
- **Dependency layer:** in the slim image the `RUN pip install` layer is reported `CACHED` on a code-only rebuild (0.26 s total) because `requirements.txt` is copied and installed before `app.py`. In the naive image `COPY . .` sits above `pip install`, so a one-word edit to `app.py` invalidated the copy layer and every layer after it — pip reinstalled flask and gunicorn (4.8 s, and it would be much longer with a real dependency list).
- **.dockerignore:** it shrank the build context from 666 kB to 181 B. It kept out `.git`, the `evidence/` PNGs, `README.md`, both Dockerfiles, `__pycache__`, `.pytest_cache` and `tests/`. `ls -a /app` inside the naive image shows `.dockerignore`, `app.py`, `requirements.txt`, `tests` — and before the `.dockerignore` existed it also shipped `.git`, `Dockerfile*`, `README.md` and `evidence/` to anyone who pulled the image.

Three more faults in `Dockerfile.naive`, with evidence:
1. `docker run --rm acs730-lab4:naive whoami` → `root`. Anything escaping the app is root in the container. The slim image prints `appuser`.
2. `docker run --rm acs730-lab4:naive ls -a /app` → the whole build context, including `.git` when no `.dockerignore` exists, i.e. the commit history goes into the image.
3. `FROM python:latest` is a moving target — it resolved to Python **3.15.1** today, while the slim image pins `3.12` **and** Debian `bookworm`, so CI next week builds the same thing.

## CI timings (Part 8)

Three runs of `lab4-ci` on branch `lab4-pipeline`, timings from `gh run view <id> --json jobs`
(`startedAt`/`completedAt`), log lines from `gh run view <id> --log`:

| Run                       | Run id        | Verdict source in the log                                                    |
|---------------------------|---------------|------------------------------------------------------------------------------|
| baseline (no caches)      | 39986350761   | no cache steps at all                                                        |
| cache miss (caches added) | 39987130455   | `Cache saved with the key: setup-python-Linux-x64-24.04-Ubuntu-python-3.12.15-pip-2c9ba…`; buildx `importing cache manifest from gha` found nothing to reuse |
| cache hit (trivial change)| 39987377608   | `Cache restored from key: setup-python-Linux-x64-24.04-Ubuntu-python-3.11.17-pip-2c9ba…`, `Cache hit for: …`, pip `Using cached flask-3.0.3…`; buildx `#8 CACHED … #12 CACHED` |

| Step / job                                        | Baseline | Cache miss | Cache hit | Worth it? |
|---------------------------------------------------|----------|------------|-----------|-----------|
| pip install step, `test (3.12)` (setup-python + Install dependencies) | 0 s + 4 s = **4 s** | 0 s + 2 s = **2 s** | 2 s + 2 s = **4 s** (restore 2 s, install 2 s from wheel cache) | **No** |
| docker build step (`build` job, "Build image")    | **14 s** | **12 s** (+ 2 s "Post Build image" cache export) | **8 s** (all layers CACHED) | **Marginally no** |
| whole workflow, wall clock (created → updated)    | **58 s** | **71 s**   | **73 s**  | No |
| `test (3.12)` job                                 | 9 s      | 8 s        | 9 s       |           |
| `build` job                                       | 25 s     | 32 s       | 35 s      |           |

- **pip cache — not worth it here.** The two pinned packages plus pytest install from PyPI in 2–4 s; restoring the cache costs about 2 s and `pip install` still runs (it just resolves from the cached wheels), so the job is a wash at 8–9 s either way. It would start paying off with a dependency list whose cold install takes tens of seconds (numpy/pandas-style wheels), which is the "install step from 41 s to 6 s" case — not this app.
- **Docker layer cache — not worth it for this image.** The build step itself did drop 14 s → 8 s on the hit (the `pip install` layer came back `CACHED` from GHA), but `setup-buildx-action`, importing the cache manifest and exporting it in "Post Build image" added roughly 10 s to the `build` job, so the job got slower (25 s → 35 s) and the workflow went from 58 s to 73 s. The `RUN pip install --no-cache-dir` layer only costs ~5 s on a cold build because the base image is small and the dependencies are two pure-Python wheels; the cache would win once that layer took longer than the ~10 s overhead of maintaining it.
- Both verdicts come from the log lines above, not from the clock: the "hit" run was *slower* than the baseline even though every cache reported a hit, which is exactly why a verdict written from two runs or from timing alone is wrong.

## GHCR, tagged by SHA (Part 9)

The `publish` job runs only on `main` (`if: github.ref == 'refs/heads/main'`) and is the only
job in the workflow that widens past `contents: read`:

```yaml
permissions:
  contents: read     # restated on purpose: a job-level block REPLACES the workflow-level one
  packages: write    # the only widening in the whole workflow
```

It logs in to `ghcr.io` with the automatically minted `GITHUB_TOKEN` (nothing is created,
stored or rotated by me), lowercases the owner with `${GITHUB_REPOSITORY_OWNER,,}` because
`docker push` rejects capitals, and pushes `ghcr.io/mcdiamondz/acs730-lab4:sha-<12-char SHA>`.
Pulled back on the workstation: `docker pull ghcr.io/mcdiamondz/acs730-lab4:sha-d24ca605e3d3`
→ 130 MB, digest `sha256:3aa01361…`. Screenshot: `evidence/ghcr-package.png`.

**Why SHA, not `latest`:** `sha-d24ca605e3d3` points at exactly one commit forever, so "which
code is in the running container" always has an answer and a rollback is just pulling an
older tag. `latest` is overwritten by whatever was pushed most recently — two deployments can
pull `latest` minutes apart and get different code, and once it is overwritten the previous
image has no name at all. The same reasoning applies to `python:latest` in `Dockerfile.naive`.

## Composite action vs reusable workflow (Part 10)

- `.github/actions/python-deps` is a **composite action** because the dependency setup is
  two steps (`setup-python` with a pip cache, then `pip install`) that must run *inside* the
  test job, on the same runner as pytest, for each matrix cell — an action packages steps and
  runs on the caller's runner with the caller's permissions, which is exactly what repeated
  in-job setup needs.
- `.github/workflows/docker-build.yml` is a **reusable workflow** because building and
  pushing the image is a *whole job*: it needs its own runner and, when pushing,
  `packages: write` — a permission the test job must never have. A `workflow_call` workflow
  carries its own `permissions:` and `runs-on`, and hands the result back through the
  three-hop output pattern (`steps.ref` → `jobs.build.outputs` → `on.workflow_call.outputs`),
  which the `report` job consumes: `built ghcr.io/mcdiamondz/acs730-lab4:sha-…`.

## Required status check (Part 11)

Classic branch protection on `main`: *Require status checks to pass before merging* →
`summary`; administrators may still bypass; no review requirement (I work alone).
PR #6 (`lab4-required-check-demo`) carries a deliberately failing test:
`gh pr view --json mergeable,mergeStateStatus` → `"mergeStateStatus": "BLOCKED"`, and the
PR page shows `lab4-ci / summary` **Required** and failing with a greyed-out *Merge pull
request* button. Screenshot: `evidence/required-check.png`. The PR was closed without merging.

`summary` is the right check to require because it is `if: always()` *and* re-raises:
`contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')` → `exit 1`.
Without the re-raise, a failed test would still produce a green `summary` and a mergeable PR.

## GitHub Actions vs AWS-native (CodePipeline / CodeBuild / ECR)

| Aspect              | GitHub Actions (what I built)                                   | AWS-native equivalent                                                          |
|---------------------|------------------------------------------------------------------|--------------------------------------------------------------------------------|
| job graph           | `jobs:` + `needs:` + `strategy.matrix` in one YAML file          | CodePipeline stages/actions; a matrix is N separate CodeBuild projects          |
| runner              | GitHub-hosted `ubuntu-latest`, fresh VM per job, outside AWS     | CodeBuild containers *inside* the AWS account/VPC, billed per build-minute     |
| registry            | GHCR, same account as the code                                   | ECR, an AWS resource with its own repository policy                            |
| credential          | `GITHUB_TOKEN`, minted per run, scope set by `permissions:`; **no cloud credentials anywhere** | IAM roles for CodePipeline, CodeBuild and ECR push; a CodeStar/GitHub connection to read the repo |
| in an Academy account | works today — nothing in the pipeline touches AWS              | blocked — creating the IAM roles and the CodeStar connection are IAM/`iam:PassRole` writes that LabRole denies, and `LabRole` credentials expire every session |

**Recommendation:** for this course and for anything that only needs to *build and test*
code, GitHub Actions is the better fit: the runner lives next to the repository, the only
credential is a per-run token whose scope I control in YAML, and least privilege is one
`permissions:` block per job. The AWS-native shape makes sense when the *deployment target*
is AWS and you want the build inside the VPC and the image in ECR next to ECS/EKS — but every
piece of it needs IAM writes that an Academy account denies, so here it is not buildable at
all, and in a real account it trades a token for three IAM roles to create and maintain.

## Experiments

### 1. Invert the layer order
**Prediction:** moving `COPY app.py ./` above the `requirements.txt` lines will make a
one-character edit to `app.py` re-run `pip install`, so the rebuild will take about as long as
the naive image (≈4–5 s) instead of the slim image's ≈0.3 s; the image size will not change.
**Result:** `Dockerfile.inverted` rebuilt in **4.39 s** with `RUN pip install` executed again
(not `CACHED`), versus **0.62 s** for the normal `Dockerfile` with the same edit, where pip
install was `CACHED`. Both images are 130 MB. **Why:** Docker's cache is a prefix match over
instructions and their inputs — the first instruction whose input changed, and every
instruction after it, is rebuilt. A `COPY app.py` above `pip install` puts the most-often
changing file in front of the most expensive step, so *every* future code change pays the
install; below it, only the cheap `COPY` and `useradd` layers are redone.

### 2. Delete the `.dockerignore`
**Prediction:** the build context will grow a lot (the PNGs alone are ~650 kB), the naive
image will grow slightly and ship everything (`.git`, `evidence/`, `README.md`, Dockerfiles)
because it `COPY . .`, but the slim image's final size will not change because it only copies
`requirements.txt` and `app.py`. **Result:** context went from **181 B** to **666 kB**.
`slim-noignore` is still **130 MB** and `ls -a /app` shows only `app.py` and
`requirements.txt`. `naive-noignore` is 1.15 GB (the extra 666 kB is below the rounding) but
`ls -a /app` now lists `.dockerignore.off`, `.pytest_cache`, `Dockerfile`, `Dockerfile.naive`,
`README.md`, `__pycache__`, `evidence`, `pytest.ini`, `requirements-dev.txt`, `tests` — the
whole folder is inside the published image. **Why:** `.dockerignore` controls what reaches the
daemon; what ends up *in the image* is decided by the `COPY` lines. An explicit `COPY app.py`
is immune to a missing `.dockerignore`, `COPY . .` is not — but the context transfer (and the
cache key of the `COPY` layer) still grows for both, so the slim build also gets slower and
invalidates on any PNG or README change.

## Evidence

`evidence/image-sizes.png` (workstation terminal: sizes and `docker history`),
`evidence/ci-graph.png` (green run 39988501810 on `main`: `test (3.11)`, `test (3.12)`,
`build`, `image / build`, `smoke`, `publish`, `report`, `summary`),
`evidence/ghcr-package.png` (package `acs730-lab4` with `sha-` tags),
`evidence/required-check.png` (PR #6: `summary` Required, failing, merge button disabled).
The remaining `Screenshot …png` files are the Part 0–3 terminal captures (resize, Docker
install, naive build).
