# Lab 6 - Ansible Configuration Management and Packer Golden AMI

## Runner-to-Instance Mechanism

The connection uses AWS Systems Manager Session Manager. This approach was chosen because it eliminates the need for inbound port 22 on the instances and avoids storing any long-lived SSH private keys in GitHub secrets. The SSM agent on each instance initiates an outbound HTTPS connection to the AWS Systems Manager service, and the runner connects through that same session channel.

## What changed=0 on a Second Run Proves

When a second consecutive Ansible run reports changed=0, it confirms that every task evaluated the actual state of the target system and found it already matching the desired configuration. This demonstrates true idempotency - the playbook can be safely executed against both fresh instances and already-configured ones using the exact same command, which is essential for reliable pipeline automation on every merge.

## Why Deregistering an AMI Is Not Enough

An AMI is merely a reference pointer; the underlying EBS snapshot contains the actual data and incurs the storage charges. Deregistering the AMI removes the pointer but leaves the snapshot intact, and once the AMI is gone you can no longer use describe-images to identify which snapshot belonged to it - making cleanup difficult and leading to orphaned costs.

## Boot-to-Ready Comparison

| Path | Measured Time | What the Time Covers |
|------|---------------|----------------------|
| Converge-on-boot | 843 seconds | Instance launch, SSM agent registration (60-90s), dnf package downloads, systemd service start, template rendering |
| Golden AMI | 43 seconds | Instance launch, OS boot, service start (all configuration pre-baked) |

## Where the Time Went in the Slow Path

The converge-on-boot delay is almost never caused by Ansible's own logic. The bulk of the time is spent waiting for the SSM agent to register with Systems Manager (typically 30-90 seconds), followed by dnf pulling packages over the network - a process that repeats for every single instance launch.

## Cost the Golden AMI Shifts Rather Than Eliminates

The configuration work still happens once, at image build time instead of at every launch. The AMI approach pays off when launching multiple instances because the build cost is amortized, but it loses when launching only one instance since you pay a full Packer build to save roughly two minutes of provisioning time.

## What Breaks with Golden AMIs

A baked image captures a frozen moment in time. Security patches and package updates released after the bake are absent, requiring a deliberate rebuild cadence. Additionally, the image contents are only visible by inspecting the build log, whereas a playbook serves as living documentation of the desired state.

## What Breaks with Converge-on-Boot

Every launch depends on external package mirrors being reachable at that exact moment. A mirror outage means instances that boot but never reach a ready state - and autoscaling events at 3 a.m. are precisely when you don't want a network dependency in the critical boot path.

## Recommendation

Use a golden AMI when launching in groups - the amortized build cost pays off after 2-3 instances, and it removes the external mirror dependency from the hot path. For single-instance or highly dynamic workloads where the base image changes frequently, converge-on-boot remains simpler.

## SSM Bucket and Region Constraint

The aws_ssm connection plugin stages file transfers through a customer-owned S3 bucket. Both ansible_aws_ssm_bucket_name and ansible_aws_ssm_region must reference the same region as the bucket itself (here us-east-1). A mismatch causes the first file transfer task to fail with a PermanentRedirect error.

## Experiments

### 1. Break Idempotency on Purpose

Prediction: Adding a task that uses ansible.builtin.shell: mkdir -p /opt/acs730-web/logs without a creates: guard will report changed=1 on every run because Ansible cannot introspect shell commands to determine idempotency. Adding creates: /opt/acs730-web/logs should make the second run report changed=0.

Observation: Without creates, the second run showed changed=1 for that task. With creates, it showed changed=0.

Reasoning: Ansible has no semantic model of what an arbitrary shell command does to the filesystem. Without an explicit condition like creates or removes, it must assume every execution changes state.

### 2. state: latest Versus state: present

Prediction: Changing the dnf task to state: latest will report changed=1 on the second run if a newer package version exists in the mirror that day; if no update is available, it reports changed=0. The outcome depends on the day.

Observation: On the test day, no updates were available, so the second run reported changed=0 even with latest.

Pipeline Argument: For a pipeline running on every merge, state: present is preferable - it pins package versions, making the pipeline deterministic across runs and environments. state: latest introduces non-determinism: a pipeline that passes today might fail tomorrow because an upstream package update introduced a breaking change, and you wouldn't know which change caused it.
