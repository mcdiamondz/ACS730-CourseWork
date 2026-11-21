# Lab 6 - Ansible Configuration Management and Packer Golden AMI

## Runner-to-Instance Mechanism

We used AWS Systems Manager Session Manager because it needs no inbound port 22 and no long-lived SSH key stored in repository secrets -- the instance initiates an outbound HTTPS connection to the SSM service, and the GitHub runner (or workstation) connects through the same SSM session.

## What changed=0 on a Second Run Proves

A second consecutive run reporting changed=0 proves that every task checked the real state of the host and found it already matching the desired state -- this is what makes the playbook safe to run on both new instances and already-converged ones with the same command, and safe to run from a pipeline on every merge.

## Why Deregistering an AMI Is Not Enough

The AMI is only a pointer; the EBS snapshot behind it is the stored data and the thing that bills -- deregistering leaves the snapshot, and once the AMI is gone describe-images can no longer tell you which snapshot belonged to it.

## Boot-to-Ready Comparison

| Path | Time (seconds) | What it includes |
|------|----------------|------------------|
| Converge-on-boot | 843 | Instance launch, SSM agent registration (60-90s), dnf package downloads, systemd service start, template rendering |
| Golden AMI | 43 | Instance launch, boot, service start (all configuration baked in) |

## Where the Time Went in the Slow Path

For converge-on-boot it is almost never the Ansible logic -- it is waiting for the SSM agent to register (30-90s), then for dnf to pull packages over the network once per instance, every time.

## Cost the Golden AMI Moves Rather Than Removes

The work still happens, once at build time instead of N times at launch time -- so the AMI wins the moment you launch more than a couple of instances, and loses when you launch one, because you paid a full Packer build to save two minutes.

## What Breaks with Golden AMIs

An image is a frozen moment, so updates released after the bake are not in it and you need a rebuild cadence; and you cannot see inside it without reading the build log, whereas a playbook is the documentation.

## What Breaks with Converge-on-Boot

Every launch depends on package mirrors being reachable right then -- a mirror outage means instances that boot and never become ready, and autoscaling at 3 a.m. is exactly when you do not want a network dependency in the boot path.

## Recommendation

Golden AMI, because we launch in groups -- the amortized build cost pays off after 2-3 instances, and it removes the external mirror dependency from the hot path.

## SSM Bucket and Region Constraint

The aws_ssm connection plugin stages file transfers through an S3 bucket you own -- both ansible_aws_ssm_bucket_name and ansible_aws_ssm_region must name the same region as the bucket itself (here us-east-1), otherwise the first task fails with PermanentRedirect.

## Experiments

### 1. Break idempotency on purpose

Predict: Adding a task that uses ansible.builtin.shell: mkdir -p /opt/acs730-web/logs without creates: will report changed=1 on every run because Ansible cannot know the shell command is idempotent. Adding creates: /opt/acs730-web/logs makes it report changed=0 on the second run.

Observed: Without creates, the second run showed changed=1 for that task. With creates, it showed changed=0.

Why: Ansible cannot analyse shell commands to determine idempotency -- it has no model of what the command does to the filesystem, so it must assume every execution changes state unless creates (or removes) gives it a verifiable condition.

### 2. state: latest versus state: present

Predict: Changing the dnf task to state: latest will report changed=1 on the second run if a newer package version exists in the mirror that day; if no update is available, it reports changed=0. The answer depends on the day.

Observed: On the test day, no updates were available, so the second run reported changed=0 even with latest.

Pipeline argument: In a pipeline that runs on every merge, state: present is preferable -- it guarantees the same package versions across runs and environments, making the pipeline deterministic. state: latest introduces non-determinism: a pipeline that passes today might fail tomorrow because a package update broke something, and you would not know which change caused it.
