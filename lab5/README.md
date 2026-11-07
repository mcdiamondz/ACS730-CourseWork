# Lab 5 — One Terraform configuration, two targets (LocalStack and AWS)

## What I built

`lab5/` is a single Terraform 1.10.3 configuration (`versions.tf`, `providers.tf`,
`variables.tf`, `network.tf`, `compute.tf`, `outputs.tf`, `localstack.tfvars`) that
builds a complete public network and a web server, and points at **LocalStack or real AWS
depending on one input variable**, `use_localstack`:

- **Provider** (`providers.tf`): one `provider "aws"` block. When `use_localstack` is true it
  sends the dummy `test`/`test` key pair LocalStack insists on, turns on the four `skip_*`
  switches and `s3_use_path_style`, and a `dynamic "endpoints"` block (`for_each = [1]` or
  `[]`) redirects `ec2`, `s3`, `sts` and `iam` to `http://localhost:4566`. When it is false
  the block renders zero `endpoints` and the provider falls back to the normal credential
  chain (LabRole on the workstation). `default_tags` stamps `Course`, `Lab` and `Owner` on
  everything.
- **Variables** (`variables.tf`): every variable is typed and described; `owner` has no
  default so a plan refuses to run without it; validation blocks on `project` (regex),
  `vpc_cidr` (`cidrnetmask`) and `instance_type` (`t3.micro`/`t3.small` only).
- **Data sources**: `aws_region.current`, `aws_availability_zones.available`, and a
  count‑gated `aws_ami.al2023` (0 against LocalStack, which has no AMI catalogue; 1 against
  AWS). No AMI, VPC, subnet or security‑group id is typed anywhere — everything is an
  attribute reference (`vpc_id = aws_vpc.main.id`, `subnet_id = aws_subnet.public[...].id`,
  `vpc_security_group_ids = [aws_security_group.web.id]`).
- **Network** (`network.tf`): VPC, public subnets via `for_each` over `local.public_subnets`
  (AZ resolved from the data source by `az_index`), internet gateway, route table with a
  `0.0.0.0/0` route, one route‑table association per subnet (`for_each = aws_subnet.public`),
  and a security group whose ingress rules are rendered from `var.ingress_rules` by a
  `dynamic "ingress"` block.
- **Compute** (`compute.tf`): `aws_instance.web` with nginx `user_data`, placed in the first
  subnet (`keys()` is sorted, so stable), `depends_on = [aws_route_table_association.public]`
  so the default route exists before `user_data` runs; an optional `aws_s3_bucket.artifacts`
  gated with `count`.
- **Outputs**: `vpc_id`, `subnet_ids`, `web_public_ip`, `web_url`, `artifact_bucket`
  (`one(aws_s3_bucket.artifacts[*].bucket)` → name or `null`), `provider_target`.

### Run it

```bash
docker run -d --name localstack -p 4566:4566 -e SERVICES=ec2,s3,sts,iam localstack/localstack:3.8
cd lab5
terraform init
terraform fmt -check -recursive && terraform validate
terraform plan  -var-file=localstack.tfvars -out=tfplan
terraform apply -auto-approve tfplan
terraform output          # provider_target = "localstack (http://localhost:4566)"
terraform destroy -auto-approve -var-file=localstack.tfvars
docker rm -f localstack
```

Output of the LocalStack apply on the workstation (`Apply complete! Resources: 10 added`):

```
artifact_bucket = "acs730-lab5-amibifa-artifacts"
provider_target = "localstack (http://localhost:4566)"
subnet_ids = { "a" = "subnet-4d1baa73", "b" = "subnet-5abe169c" }
vpc_id = "vpc-11c88176"
web_public_ip = "54.214.53.188"
web_url = "http://54.214.53.188/"
```

`aws --endpoint-url=http://localhost:4566 ec2 describe-vpcs` showed `172.31.0.0/16 10.42.0.0/16`
before the destroy; `evidence/describe-vpcs-after-destroy.json` holds only LocalStack's own
default `172.31.0.0/16` afterwards. Against real AWS the same configuration is
`terraform plan -var owner=<username>` — see Experiment 5; it was never applied.

One deviation from the handout: `skip_requester_charged` is not an argument of the AWS
provider 5.x and fails validation, so the config uses the real switch,
`skip_requesting_account_id = var.use_localstack`, which turns off the STS
`GetCallerIdentity` call the provider makes at init time.

## Why for_each here and count there

**Subnets use `for_each`** because they are distinct things with stable names, and the map
key becomes the resource address (`aws_subnet.public["a"]`). Measured against LocalStack
(Experiment 1): going from `{a,b}` to `{a,b,c}` planned `2 to add, 0 to change, 0 to destroy`
(subnet + association for `c`); removing the *middle* key `b` planned
`0 to add, 0 to change, 2 to destroy` — `aws_subnet.public["b"]` and
`aws_route_table_association.public["b"]` only, `a` and `c` untouched.

**The same subnets with `count` would be a trap.** Addresses become `[0]`, `[1]`, `[2]`, and
an index is a position, not an identity. In the count copy of the configuration, removing the
middle CIDR from a three‑element list planned `0 to add, 0 to change, 4 to destroy` with
**2 to replace**: `aws_subnet.public[1]` *must be replaced* (its CIDR changed from
`10.42.2.0/24` to `10.42.3.0/24` because everything shifted down a slot) and
`aws_subnet.public[2]` destroyed, plus the two matching route‑table associations. Removing one
subnet costs two subnets and, on real AWS, anything running in them.

**The bucket uses `count`** because the input is a yes/no about one resource. There are
exactly two plans — `create_artifact_bucket = false` → `0 to add`, `true` → `1 to add` — and
there is no key to be stable about; `aws_s3_bucket.artifacts[0]` is the only address that can
exist. The output uses `one(aws_s3_bucket.artifacts[*].bucket)` so it is `null` rather than an
index error when the bucket is off (Experiment 4).

In short: **count when the question is "how many", for_each when the question is "which ones".**

## CI: cheap gates first, then LocalStack

`.github/workflows/lab5-ci.yml` is scoped with `paths: ['lab5/**', '.github/workflows/lab5-ci.yml']`
and runs two jobs in order:

1. **`fmt and validate`** — `terraform fmt -check -recursive`, `terraform init -backend=false`,
   `terraform validate`. Seconds, no state, no backend, no credentials.
2. **`plan and apply against LocalStack`** — `needs: gates`, so it only runs when the first
   job passed. LocalStack 3.8 runs as a `services:` sidecar on the runner's `localhost:4566`,
   so the endpoint that worked on the workstation works in CI unchanged. It runs
   `init → plan -var-file=localstack.tfvars -out=tfplan → apply tfplan → output`, and an
   `if: always()` destroy.

The only credential in the file is the default read‑only `GITHUB_TOKEN`
(`permissions: contents: read`); `grep -rin "aws_access\|aws_secret\|secrets\.\|configure-aws-credentials"`
on the workflow finds nothing. The `test`/`test` pair in `providers.tf` is a required‑field
filler LocalStack ignores, not a credential.

**Breaking it on purpose:** `var.vpc_cidr` → `var.vpc_cdir` in `network.tf`. `fmt` passed
(the file is still formatted), `validate` failed with *Reference to undeclared input
variable*, and the LocalStack job was **skipped**, not run — `needs:` cancelled it before a
container was pulled, which is the ordering saving ~2 minutes per bad push. With
`fmt and validate` and `plan and apply against LocalStack` as required status checks on
`main`, the pull request showed the red check, **Required**, and a greyed‑out merge button
(`evidence/required-check-blocked.png`, `evidence/pr-blocked.json`:
`"mergeStateStatus": "BLOCKED"`). `evidence/ci-runs.txt` shows the failed run followed by the
passing one after the fix.

## Why not plan and apply against real AWS on every pull request

- **It costs money per run, not per month.** Every pull request would build and destroy a
  VPC, subnets, an instance and a bucket. 27 students pushing a few times each is thousands of
  create/destroy cycles against one fixed $50 pot per student for the term — and an
  instance that fails to destroy (a stuck `terraform destroy`, a cancelled job) keeps billing.
  LocalStack costs nothing and the container is thrown away at the end of the job.
- **It needs a long‑lived AWS credential in the repository.** Applying from Actions means an
  access key in GitHub secrets that can leak and must be rotated. In an Academy account you
  cannot even scope it: IAM writes are denied, so there is no OIDC role and no least‑privilege
  user — the only key that works is the broad LabRole session key.
- **Academy sessions expire.** Lab credentials last a few hours, so the `lab3-deploy`
  workflow in this very repository fails on every push with *The security token included in
  the request is expired* — a red check for a reason unrelated to the code. People learn to
  ignore red checks, and a check people ignore is worse than no check.
- **It is slow and flaky.** Minutes each way for a real apply and destroy, API rate limits,
  eventual‑consistency errors, and two concurrent pull requests colliding on
  `acs730-lab5-<owner>-web` names and on one state file in one account. The LocalStack job
  here finishes in ~2 minutes, the gates job in ~10 seconds.
- **Be honest about the limit.** A green LocalStack run proves the configuration is coherent,
  the variables validate, and the dependency graph builds and destroys cleanly. It does not
  prove IAM is right (LocalStack does not enforce it), that the AMI filter matches (the data
  source is counted out), or that `user_data` installs nginx (LocalStack never boots the
  instance — see Experiment 2). The real‑AWS check belongs on merge to `main` or on a
  schedule, once, with a destroy right after — not on every pull request.

## Experiments

### 1. Swap `for_each` for `count` on the subnets
**Prediction:** with `for_each`, removing the middle key plans `0 add / 0 change / 1 destroy`
per resource type (so 2 to destroy with the association). With `count` over three CIDRs,
removing the middle one plans `0 add / 0 change / 4 destroy` with 2 replacements, because
`[1]` now holds the old `[2]`'s CIDR.
**Result:** exactly that. `for_each`: `aws_subnet.public["b"]` and
`aws_route_table_association.public["b"]` *will be destroyed*, nothing else. `count` (a copy of
the config with `count = length(var.subnet_cidrs)`, applied as 12 resources): `aws_subnet.public[1]`
*must be replaced*, `aws_subnet.public[2]` *will be destroyed*, and the same for
`aws_route_table_association.public[1]`/`[2]`. **Why:** Terraform compares addresses in state
against addresses in config. A map key is an identity that survives edits to its neighbours;
a list index is a position, so deleting an element renumbers everything after it and Terraform
sees "the subnet at [1] changed its CIDR", which for a subnet forces replacement.

### 2. Delete the `depends_on`
**Prediction:** the plan will not change at all (`No changes`) — `depends_on` adds a graph
edge, not an attribute — so LocalStack can never show this bug.
**Result:** `No changes. Your infrastructure matches the configuration.` with the line
commented out, and `terraform graph | grep -c "aws_instance.web.*->.*aws_route_table_association"`
went from `1` (with `depends_on`) to `0` (without). **Why:** the instance references the
subnet and the security group, so those are built first, but nothing in the instance block
references the route‑table association, so Terraform is free to create the instance in
parallel with it. On real AWS `user_data` then runs `dnf -y install nginx` on a subnet with no
default route yet; dnf hangs, cloud‑init gives up, and the instance is "running" with no web
server and no Terraform error. LocalStack never boots the instance, so the broken ordering is
invisible there and only shows as a dead `web_url` on AWS.

### 4. Turn the bucket off
**Prediction:** with `one()`, `terraform output artifact_bucket` prints `null` and exits 0;
with `[0]` the plan errors with an invalid‑index message.
**Result:** `apply -var create_artifact_bucket=false` destroyed the bucket
(`0 added, 0 changed, 1 destroyed`). `terraform output artifact_bucket` did not print `null`;
Terraform 1.10 drops null outputs from state entirely and answered
`Error: Output "artifact_bucket" not found` (exit 1) — `terraform output -json` shows the
other five outputs and no `artifact_bucket` key. With `aws_s3_bucket.artifacts[0].bucket` the
plan itself fails: `Error: Invalid index — The given key does not identify an element in this
collection value`, i.e. the whole configuration is unusable whenever the option is off.
**Why:** `[*]` yields a zero‑or‑one‑element list and `one()` maps that to `null` or the value,
so the output is valid for both plans; `[0]` on an empty list is an error at plan time. The
surprise was that a `null`‑valued output is omitted from state rather than stored, which is
worth knowing before scripting against `terraform output <name>`.

### 5. Point at real AWS on purpose, plan only
**Prediction:** `provider_target` says `aws (us-east-1)`, 9 resources appear (no bucket —
`create_artifact_bucket` defaults to `false`), and the AMI resolves through
`data.aws_ami.al2023` to a real `ami-` id instead of the placeholder.
**Result:** `terraform plan -var owner=amibifa` with no `-var-file`, in a copy of the config
with no state: `Plan: 9 to add, 0 to change, 0 to destroy`, `provider_target = "aws (us-east-1)"`,
and `ami = "ami-0820d0c589175bc01"` (the current `al2023-ami-2023.*-kernel-6.1-x86_64`
image) — real LabRole credentials from the instance profile, real region, real AMI. **Not
applied.** The one line that would have warned me is
`+ provider_target = "aws (us-east-1)"` in *Changes to Outputs* — which is why that output
exists and why the handout says to read it first.

## Evidence

- `evidence/ci-green.png` — the `lab5-ci` run on `main` with both jobs green.
- `evidence/required-check-blocked.png` — the pull request with the deliberate break: red
  `fmt and validate`, **Required**, LocalStack job skipped, merge button disabled.
- `evidence/pr-blocked.json` — `gh pr view --json number,mergeable,mergeStateStatus,statusCheckRollup` while blocked.
- `evidence/ci-runs.txt` — `gh run list --workflow lab5-ci.yml`: failed run followed by the passing one.
- `evidence/describe-vpcs-after-destroy.json` — LocalStack after `terraform destroy`: only the default `172.31.0.0/16`.
- `evidence/Screenshot 2026-11-06 215238.png` — workstation terminal: `Destroy complete! Resources: 10 destroyed.`
- `evidence/Screenshot 2026-11-06 221721.png` — workstation terminal: `gh pr checks` with both lab5-ci jobs passing.
