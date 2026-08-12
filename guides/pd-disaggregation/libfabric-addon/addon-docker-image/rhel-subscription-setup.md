# RHEL Subscription Setup for Container Builds

The Dockerfile uses the RHAIIS `vllm-cuda-rhel9` image as the builder base, which requires RHEL entitlement certificates to install `-devel` packages via `dnf`. This guide extracts the certs using a temporary RHEL container — no RHEL host or VM required.

## Prerequisites

- A Red Hat account on the **stage** environment (same credentials used for `registry.stage.redhat.io`)
- Logged into `registry.stage.redhat.io`: `podman login registry.stage.redhat.io`

## Step 1: Extract entitlement certs

Run a temporary RHEL 9 container, register with your Red Hat account, and copy the generated PEM files:

```bash
cd guides/pd-disaggregation/libfabric-addon/addon-docker-image/

# Start a UBI9 container (freely available, no registry auth required)
podman run -it --name rhsm-setup registry.access.redhat.com/ubi9/ubi:9.6 bash
```

Inside the container:

```bash
dnf install -y subscription-manager

# Point subscription-manager to the stage server
subscription-manager config --server.hostname=subscription.rhsm.stage.redhat.com \
                            --rhsm.baseurl=https://cdn.stage.redhat.com

subscription-manager register --username=YOUR_RH_USERNAME --password=YOUR_RH_PASSWORD
subscription-manager attach --auto

# Verify certs were generated
ls /etc/pki/entitlement/*.pem
# Should show: <ID>-key.pem and <ID>.pem

exit
```

Back on the host:

```bash
# Copy certs out of the container
mkdir -p entitlement rhsm-ca
podman cp rhsm-setup:/etc/pki/entitlement/ ./entitlement/
podman cp rhsm-setup:/etc/rhsm/ca/ ./rhsm-ca/

# Verify
ls entitlement/*.pem rhsm-ca/*.pem

# Unregister to free the subscription slot, then remove container
podman start rhsm-setup
podman exec rhsm-setup subscription-manager unregister
podman rm -f rhsm-setup
```

You should now have:

```
entitlement/
├── <ID>-key.pem
└── <ID>.pem
rhsm-ca/
└── redhat-uep.pem
```

## Alternative: Copy from an existing registered RHEL host

If you already have a registered RHEL machine (physical, VM, or cloud instance), simply copy the certs directly:

```bash
mkdir -p entitlement rhsm-ca
scp USER@RHEL_HOST:/etc/pki/entitlement/*.pem ./entitlement/
scp USER@RHEL_HOST:/etc/rhsm/ca/redhat-uep.pem ./rhsm-ca/
```

The PEM files are self-contained X.509 certificates — they work from any build machine regardless of where they were generated.

## Step 2: Build the addon image

Create a config file and run the build script:

```bash
cp build.env.example build.env
# Edit build.env if needed (defaults point to ./entitlement and ./rhsm-ca)

./build.sh
```

The build script reads `build.env`, validates the cert paths, and runs `podman build` with the appropriate `--build-arg` flags. The Dockerfile `COPY`s the certs into the builder stages (they are not present in the final addon image layer).

## Cert expiry

Red Hat entitlement certs typically expire after **1 year** (tied to subscription renewal). If the build fails with `dnf` repo errors after a long time, repeat Step 1 to regenerate.

## Troubleshooting

**`dnf` fails with "This system is not registered":**
The entitlement PEM files are not being mounted correctly. Verify the paths:
```bash
# Check the secret mount points match what the Dockerfile expects
grep "mount=type=secret" Dockerfile
```

**`subscription-manager register` fails with "network unreachable":**
The container needs internet access. Check `podman run --network=host` if behind a proxy.

**"No subscriptions available":**
With Simple Content Access (SCA) enabled, `subscription-manager attach --auto` should succeed. Verify SCA is enabled at [console.stage.redhat.com](https://console.stage.redhat.com) → Subscriptions → Overview.

## Files produced

These files are gitignored (they contain secrets):

```
entitlement/*.pem    — RHEL entitlement certificates
rhsm-ca/*.pem        — Red Hat CDN CA certificate
```

Add to `.gitignore`:
```
entitlement/
rhsm-ca/
```
