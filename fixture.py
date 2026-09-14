#!/usr/bin/env python3
"""Local EC2 Query API fixture for the real AWS CLI.

Answers the five calls runSpotInstance.groovy makes with canned XML, so the CLI's real exit codes,
stderr formatting, and retry behaviour are exercised without an account or network.

Environment:
  SCENARIO        success | capacity-then-success | all-capacity | bad-keypair | quota | subnet-full | no-subnets
  CALLS_LOG       file the aws wrapper appends one line to per CLI run-instances invocation
  REQUESTS_LOG    file this fixture appends one line to per RunInstances HTTP request (shows CLI retries)
  CAPACITY_FAILS  for capacity-then-success: how many CLI invocations are refused first (default 2)
Usage: fixture.py PORT
GET /healthz returns the scenario name, so the runner can confirm it is talking to the fixture it started.
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

NS = 'xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"'
SCENARIO = os.environ.get("SCENARIO", "success")
CALLS_LOG = os.environ.get("CALLS_LOG", "/dev/null")
REQUESTS_LOG = os.environ.get("REQUESTS_LOG", "/dev/null")
CAPACITY_FAILS = int(os.environ.get("CAPACITY_FAILS", "2"))
INSTANCE_ID = "i-0123456789abcdef0"
SUBNETS = ["subnet-75d2011d", "subnet-c1b0a5ba", "subnet-b3571ffe"]


def count_lines(path):
    try:
        with open(path) as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def append(path, line):
    with open(path, "a") as handle:
        handle.write(line + "\n")


def error_xml(code, message):
    return (
        "<Response><Errors><Error>"
        f"<Code>{code}</Code><Message>{message}</Message>"
        "</Error></Errors><RequestID>local-fixture</RequestID></Response>"
    )


def describe_images():
    return (
        f"<DescribeImagesResponse {NS}><requestId>local-fixture</requestId><imagesSet><item>"
        "<imageId>ami-0f7558887ed9fb0a3</imageId><architecture>arm64</architecture>"
        "<imageState>available</imageState></item></imagesSet></DescribeImagesResponse>"
    )


def describe_subnets():
    items = "".join(
        f"<item><subnetId>{subnet}</subnetId><state>available</state><vpcId>vpc-3eb57e56</vpcId></item>"
        for subnet in SUBNETS
    )
    return f"<DescribeSubnetsResponse {NS}><requestId>local-fixture</requestId><subnetSet>{items}</subnetSet></DescribeSubnetsResponse>"


def run_instances(params):
    instance_type = params.get("InstanceType", ["?"])[0]
    subnet = params.get("SubnetId", ["?"])[0]
    return (
        f"<RunInstancesResponse {NS}><requestId>local-fixture</requestId><reservationId>r-0123456789abcdef0</reservationId>"
        "<ownerId>000000000000</ownerId><instancesSet><item>"
        f"<instanceId>{INSTANCE_ID}</instanceId><instanceState><code>0</code><name>pending</name></instanceState>"
        f"<instanceType>{instance_type}</instanceType><subnetId>{subnet}</subnetId>"
        "</item></instancesSet></RunInstancesResponse>"
    )


def describe_instances():
    return (
        f"<DescribeInstancesResponse {NS}><requestId>local-fixture</requestId><reservationSet><item>"
        "<reservationId>r-0123456789abcdef0</reservationId><instancesSet><item>"
        f"<instanceId>{INSTANCE_ID}</instanceId><instanceState><code>16</code><name>running</name></instanceState>"
        "<ipAddress>3.143.210.49</ipAddress></item></instancesSet></item></reservationSet></DescribeInstancesResponse>"
    )


def describe_instance_status():
    return (
        f"<DescribeInstanceStatusResponse {NS}><requestId>local-fixture</requestId><instanceStatusSet><item>"
        f"<instanceId>{INSTANCE_ID}</instanceId><availabilityZone>us-east-2b</availabilityZone>"
        "<instanceState><code>16</code><name>running</name></instanceState>"
        "<systemStatus><status>ok</status></systemStatus><instanceStatus><status>ok</status></instanceStatus>"
        "</item></instanceStatusSet></DescribeInstanceStatusResponse>"
    )


def run_instances_outcome(params):
    """Return (http_status, body) for a RunInstances request under the current scenario."""
    instance_type = params.get("InstanceType", ["?"])[0]
    cli_calls_so_far = count_lines(CALLS_LOG)
    capacity = error_xml(
        "InsufficientInstanceCapacity",
        f"We currently do not have sufficient {instance_type} capacity in the Availability Zone you requested.",
    )
    if SCENARIO == "all-capacity":
        return 500, capacity  # AWS answers a capacity refusal with HTTP 500, which the CLI retries before giving up
    if SCENARIO == "capacity-then-success" and cli_calls_so_far <= CAPACITY_FAILS:
        return 500, capacity
    if SCENARIO == "bad-keypair":
        return 400, error_xml("InvalidKeyPair.NotFound", "The key pair 'jenkins' does not exist")
    if SCENARIO == "quota":
        return 400, error_xml("MaxSpotInstanceCountExceeded", "Max spot instance count exceeded")
    if SCENARIO == "subnet-full" and cli_calls_so_far <= 1:
        subnet = params.get("SubnetId", ["?"])[0]
        return 400, error_xml("InsufficientFreeAddressesInSubnet", f"There are not enough free addresses in subnet '{subnet}'.")
    return 200, run_instances(params)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="text/xml;charset=UTF-8"):
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, SCENARIO, "text/plain")
        return self.reply(404, "not found", "text/plain")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        params = parse_qs(self.rfile.read(length).decode())
        action = params.get("Action", ["?"])[0]

        if action == "DescribeImages":
            return self.reply(200, describe_images())

        if action == "DescribeSubnets":
            if SCENARIO == "no-subnets":
                return self.reply(403, error_xml("UnauthorizedOperation", "You are not authorized to perform this operation."))
            return self.reply(200, describe_subnets())

        if action == "RunInstances":
            instance_type = params.get("InstanceType", ["?"])[0]
            subnet = params.get("SubnetId", ["?"])[0]
            append(REQUESTS_LOG, f"RunInstances {instance_type} {subnet}")
            status, body = run_instances_outcome(params)
            return self.reply(status, body)

        if action == "DescribeInstances":
            return self.reply(200, describe_instances())

        if action == "DescribeInstanceStatus":
            return self.reply(200, describe_instance_status())

        return self.reply(400, error_xml("InvalidAction", f"The fixture does not implement {action}"))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4566
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
