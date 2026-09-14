# PR 4441: why the launch loop must fail fast on non-capacity errors

Reproducer for the review comment on `pmm/v3/vars/runSpotInstance.groovy:48` in
[Percona-Lab/jenkins-pipelines PR 4441](https://github.com/Percona-Lab/jenkins-pipelines/pull/4441).

The real AWS CLI v2 runs the loop. Its EC2 calls go to a local fixture that returns canned responses,
so the CLI's real exit codes, error text, and retry behaviour are exercised without an account or network.

- `launch-head.sh` is the shell block of `runSpotInstance.groovy` at head `fd191278`, verbatim (lines 9 to 98, dedented, nothing added).
- `launch-fixed.sh` is the same block with the proposed change: subnet discovery outside the pipeline so a failed `describe-subnets` aborts with the real error, an empty subnet list fails with a clear message, and each `run-instances` attempt keeps its stderr and acts on the exact error code (capacity refusals try the next combination, a full subnet skips to the next subnet, anything else exits 1).
- `fixture.py` answers DescribeImages, DescribeSubnets, RunInstances, DescribeInstances, and DescribeInstanceStatus. `SCENARIO` picks what RunInstances returns: a capacity refusal is HTTP 500 like AWS, client errors are HTTP 400.
- `aws` is a thin wrapper that counts `run-instances` invocations and runs the real CLI with `--endpoint-url` pinned to the fixture on the command line.
- `repro.sh` runs both versions against every scenario under `bash -e` (Jenkins runs the step as `sh -xe`), prints one row per run, compares each row with the expected outcome, and exits 1 on any difference. It refuses to run unless `aws` resolves to the wrapper.

## Run

```
docker build -t pr4441-repro https://github.com/nogueiraanderson/probe-pr4441-launch-loop.git
docker run --rm --network none pr4441-repro
docker run --rm --network none -e VERBOSE=1 pr4441-repro
```

`--network none` is belt and braces: the container needs only loopback, and it proves nothing leaves the box.

## What it shows

| Scenario | Head | Fixed |
|---|---|---|
| `bad-keypair` (a configuration error) | 9 attempts, ends with the capacity message | 1 attempt, exits with the real `InvalidKeyPair.NotFound` |
| `quota` (`MaxSpotInstanceCountExceeded`, another AZ cannot help) | 9 attempts, capacity message | 1 attempt, exits with the real error |
| `no-subnets` (`describe-subnets` denied, pipeline has no pipefail) | 0 attempts, capacity message | exits with the real `UnauthorizedOperation` |
| `capacity-then-success` | CLI retries each refusal, then falls back and launches | same |
| `subnet-full` (`InsufficientFreeAddressesInSubnet`) | next type in the same subnet, launches | skips to the next subnet, launches |
| `all-capacity` | 9 attempts, capacity message | same, and now the message is true |

The HTTP column exceeds CALLS on capacity rows because the CLI retries HTTP 500 (standard retry mode,
3 attempts), which is why production consoles show `(reached max retries: 2)`. Client errors are not retried.

## What it proves and what it assumes

Proves: how the two loops react to each error class, with the real CLI producing the exit codes and
messages. Assumes: that AWS returns these error codes with these HTTP status classes, which is documented
and was also observed live on the real job (`InsufficientInstanceCapacity` and `InvalidParameterValue` in
builds on pmm, exit 254 for both).

The AWS CLI zip is pinned to 2.33.17 and verified against a sha256 in the Dockerfile for both aarch64 and x86_64.
