---
title: "An adventure of getting Docker on NixOS running only with cgroups v2"
date: 2020-10-24T14:46:00+03:00
author: "Mark V."
draft: false
---

After discovering Linux's wonderful [Pressure Stall Information](https://www.kernel.org/doc/html/latest/accounting/psi.html) (PSI for short) subsystem, I've been trying to set up monitoring on
Docker containers where I run very memory, CPU and I/O hungry game servers (not hard to guess - it's [Minecraft](https://minecraft.net)).

Since I monitor pretty much everything using Prometheus, then finding [Cloudflare's psi_exporter](https://github.com/cloudflare/psi_exporter) project made my life a lot easier - I
didn't have to write an exporter myself.

## Why do cgroups v2 matter? Why isn't v1 sufficient?

But wait, hold up. Docker [v19.03.13](https://github.com/docker/docker-ce/releases/tag/v19.03.13) does not support cgroups v2 yet, and only uses cgroups v1 to do its things!
Thus we're not able to get very precise information about resource starvation per container. We're just stuck with getting PSI only
about `/system.slice/docker.service`, which is not very informative - I would have hard time figuring out which of those 50+ containers
were starved of either CPU, memory or I/O (purely using that metric - probably could assume what was using metrics from [cAdvisor](https://github.com/google/cadvisor), but
that's not ideal either).

So we're kind of stuck... or are we?

Here's my story about finding a solution to that problem.

## Figuring out where to start

Good starting point was forcing my NixOS system to disable cgroups v1 completely, that can be easily done using kernel arguments.

```
boot.kernelParams = [ "cgroup_no_v1=all" "systemd.unified_cgroup_hierarchy=1" ];
```

And that should be enough to break Docker on NixOS (as of 23rd October 2020) - check it yourself, for example using `docker run -d alpine:latest`.

You'll end up with the following:
```
<container id>
docker: Error response from daemon: cgroups: cgroup mountpoint does not exist: unknown.
```

Alright, since we've confirmed that things are broken, now we need to figure out what to actually do.
Let's start from lowering Docker's log level to debug. It's as easy as `virtualisation.docker.extraOptions = "-D";`. Let's try starting a new container...

Now we have very likely something in the journal, let's check.

```
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694386175+03:00" level=warning msg="Your kernel does not support swap memory limit"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694446465+03:00" level=warning msg="Your kernel does not support memory reservation"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694500678+03:00" level=warning msg="Your kernel does not support oom control"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694540575+03:00" level=warning msg="Your kernel does not support memory swappiness"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694587777+03:00" level=warning msg="Your kernel does not support kernel memory limit"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694628169+03:00" level=warning msg="Your kernel does not support kernel memory TCP limit"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694667286+03:00" level=warning msg="Your kernel does not support cgroup cpu shares"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694704696+03:00" level=warning msg="Your kernel does not support cgroup cfs period"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694741032+03:00" level=warning msg="Your kernel does not support cgroup cfs quotas"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694788141+03:00" level=warning msg="Your kernel does not support cgroup rt period"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694823573+03:00" level=warning msg="Your kernel does not support cgroup rt runtime"
Oct 23 23:47:06 nixos dockerd[3453]: time="2020-10-23T23:47:06.694860484+03:00" level=warning msg="Unable to find blkio cgroup in mounts"
```

Clearly, does not support cgroups v2 as it "cannot find" the required cgroups.

Time to check what's up in NixOS [Docker derivation](https://github.com/NixOS/nixpkgs/blob/066397c0fe3686efcbaf6505c535494e63bdc9b2/pkgs/applications/virtualization/docker/default.nix)

## Researching what to update

Docker consists of two extra parts: containerd and OCI runtime (runc by default and even in this case here). So we need to update 3 things in total.

Now it's time to look into [docker-ce repository](https://github.com/docker/docker-ce)'s [changelog](https://github.com/docker/docker-ce/blob/6d281252d3fbbff836e94caeb37e104830bd700f/CHANGELOG.md) on master branch - it contains the freshest changes. Seems like cgroups v2 support in Docker
is rather fresh - changelog change mentioning it was done on 18th September.  Last pieces of the required code were merged in March as much as I looked
into the issues. Since there are no beta release tags (side note: there was one for about 21 hours for `20.10.0-beta1`, but it has vanished), then I'm
going to proceed with commit `3b9fb515ce3a39e2d9a1dcd7f094eb3ed511581d`.

Searching `containerd cgroups v2 support` leads me to [an issue with same title](https://github.com/containerd/containerd/issues/3726) - turns out cgroups v2 support has already landed.
Linked [PR](https://github.com/containerd/containerd/issues/3726) in the end of the issue tells me that its support is present in [1.4.0-beta.0](https://github.com/containerd/containerd/releases/tag/v1.4.0-beta.0). So we can freely use stable [1.4.1](https://github.com/containerd/containerd/releases/tag/v1.4.1).

Now it's time to hunt down 2nd part - `runc cgroups v2 support` leads me to its [cgroup v2 support document](https://github.com/opencontainers/runc/blob/b4483305148986b5b693cdc62ebbe7eaa0e330be/docs/cgroup-v2.md) - sweet. We need at least `v1.0.0-rc91`,
we're going to get slightly newer version [v1.0.0-rc92](https://github.com/opencontainers/runc/releases/tag/v1.0.0-rc92).

## Time to edit the derivation

I simply copied the previously linked Docker derivation into `/etc/nixos/updated-docker.nix` and added needed modifications.

```diff
--- /etc/nixos/updated-docker.orig.nix
+++ /etc/nixos/updated-docker.nix
@@ -33,7 +33,7 @@
       name = "docker-containerd-${version}";
       inherit version;
       src = fetchFromGitHub {
-        owner = "docker";
+        owner = "containerd"; # https://github.com/NixOS/nixpkgs/pull/101453
         repo = "containerd";
         rev = containerdRev;
         sha256 = containerdSha256;
@@ -79,7 +79,7 @@
       sha256 = sha256;
     };

-    patches = lib.optional (versionAtLeast version "19.03") [
+    patches = lib.optional ((versionAtLeast version "19.03") && (versionOlder version "20.10")) [
       # Replace hard-coded cross-compiler with $CC
       (fetchpatch {
         url = https://github.com/docker/docker-ce/commit/2fdfb4404ab811cb00227a3de111437b829e55cf.patch;
@@ -132,7 +132,7 @@
       substituteInPlace ./components/engine/daemon/logger/journald/read.go --replace libsystemd-journal libsystemd
     '';

-    outputs = ["out" "man"];
+    outputs = ["out"] ++ optional (versionOlder version "20.10") "man";

     extraPath = optionals (stdenv.isLinux) (makeBinPath [ iproute iptables e2fsprogs xz xfsprogs procps utillinux git ]);

@@ -171,7 +171,7 @@
       mkdir -p ./man/man1
       go build -o ./gen-manpages github.com/docker/cli/man
       ./gen-manpages --root . --target ./man/man1
-    '' + ''
+    '' + optionalString (versionOlder version "20.10") ''
       # Generate legacy pages from markdown
       echo "Generate legacy manpages"
       ./man/md2man-all.sh -q
@@ -220,4 +220,16 @@
     tiniRev = "fec3683b971d9c3ef73f284f176672c44b448662"; # v0.18.0
     tiniSha256 = "1h20i3wwlbd8x4jr2gz68hgklh0lb0jj7y5xk1wvr8y58fip1rdn";
   };
+
+  docker_20_10 = makeOverridable dockerGen rec {
+    version = "20.10.0-beta1";
+    rev = "3b9fb515ce3a39e2d9a1dcd7f094eb3ed511581d";
+    sha256 = "1wbz6xhv74nxbc24h2nvmifw5ldr0flnl3l3r8f8ga4nany9av9j";
+    runcRev = "ff819c7e9184c13b7c2607fe6c30ae19403a7aff"; # v1.0.0-rc92
+    runcSha256 = "0r4zbxbs03xr639r7848282j1ybhibfdhnxyap9p76j5w8ixms94";
+    containerdRev = "c623d1b36f09f8ef6536a057bd658b3aa8632828"; # v1.4.1
+    containerdSha256 = "1k6dqaidnldf7kpxdszf0wn6xb8m6vaizm2aza81fri1q0051213";
+    tiniRev = "fec3683b971d9c3ef73f284f176672c44b448662"; # v0.18.0
+    tiniSha256 = "1h20i3wwlbd8x4jr2gz68hgklh0lb0jj7y5xk1wvr8y58fip1rdn";
+  };
 }

```

Note that disabing manpages is not really intentional - their building failed and I did not want to stop on
that step for too long.

To make my system use newly created Docker derivation, I added following part into my system configuration:

```nix
  nixpkgs.overlays = [
    (self: super: {
      docker = (super.callPackage ./updated-docker.nix {}).docker_20_10;
    })
  ];
```

And now good old `nixos-rebuild switch`.

Note that building Docker and its components takes more than 1GiB of disk space, so if you installed [NixOS on tmpfs](https://elis.nu/blog/2020/05/nixos-tmpfs-as-root/) (or have small tmpfs, or not much RAM),
then you should consider reconfiguring your system to have larger /tmp part or let Nix build on persistent storage (e.g `sudo env TMPDIR=/home/mark/tmp nixos-rebuild switch`)

After moderate build time, I'll see Docker successfully being restarted. Now I have functional Docker instance.

Running `sudo docker run --rm -ti alpine:latest /bin/sh -c "echo it works"` to confirm. If you see `it works`, then obviously, it works.

## Exploring the gains

Now starting e.g nginx (`docker run -d -p 8080:80 nginx:latest`) and doing `systemd-cgls`, I can see nginx running in its own scope instead of being
under `docker.service`.

```
  ├─docker.service
  │ ├─1316 /nix/store/ci6jdb9f25nkc938zj7mzgl367336klf-docker-20.10.0-beta1/libexec/docker/dockerd --group=docker --host=fd:// --log-driver=journald --live-restore -D
  │ ├─1336 containerd --config /var/run/docker/containerd/containerd.toml --log-level debug
  │ ├─1680 /nix/store/ci6jdb9f25nkc938zj7mzgl367336klf-docker-20.10.0-beta1/libexec/docker/docker-proxy -proto tcp -host-ip 0.0.0.0 -host-port 8080 -container-ip 172.17.0.2 -container-port 80
  │ └─1694 /nix/store/2bkm2hn2jj6nwpgs320z586w7raqczkj-docker-containerd-20.10.0-beta1/bin/containerd-shim-runc-v2 -namespace moby -id 98819ab92f08b5ce1a0287edf3c7b68da981265d45d6e54b862f76518de6b8ca -address /var/run/docker/containerd/>
  ├─docker-98819ab92f08b5ce1a0287edf3c7b68da981265d45d6e54b862f76518de6b8ca.scope
  │ ├─1714 nginx: master process nginx -g daemon off;
  │ └─1782 nginx: worker process
```

And hey, now I can poke into the PSI subsystem:

```
[mark@nixos:~]$ cat /sys/fs/cgroup/system.slice/docker-98819ab92f08b5ce1a0287edf3c7b68da981265d45d6e54b862f76518de6b8ca.scope/memory.pressure
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

That's all for today.
