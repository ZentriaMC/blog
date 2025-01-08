---
title: "Container bind mount pitfalls: DNS"
author: Mark V.
date: 2021-06-06T19:56:22+03:00
draft: false
summary: "_It's not DNS. There's no way it's DNS. It was DNS._"
---

{{< figure src="/img/dns-haiku.png" alt="DNS Haiku" title="It's not DNS. There's no way it's DNS. It was DNS." >}}

## Story time? Story time.

I had this very old deployment of Clojure app around, orchestrating quite many Docker containers and their data volumes. It was set up to connect
to a PostgreSQL database and Redis running on the container host, implying no magical DNS solutions nor any convenience at all
(manual /24 subnet configuration and firewalling). [^1]

It also bound whole `/var/run` into the container to access Docker API socket (it's still sitting at `/var/run/docker.sock` at the time of writing).
Binding only the socket file breaks with Docker's [live restore](https://docs.docker.com/config/containers/live-restore/) functionality, as socket file has to be recreated on restart, thus breaking orchestrator's access to the Docker API.

## How the all hell broke loose

One day I got annoyed because how often and unnecessarily NixOS decides to restart crucial services, bringing down the database, Redis etc.; so I
decided to move all needed services into Docker and call it a day.

15 minutes into moving data and partially rewiring everything inside `docker-compose.yml`, I ended up with a very bizarre issue:
Clojure app is unable to resolve anything; no database, Redis, nothing. Internal DNS was completely broken.

I checked if container name aliases weren't missing, using `docker inspect`. Resolving e.g `google.com` worked just fine, which was even more stunning.

## How DNS works on Linux

For DNS, all programs usually end up calling [`gethostbyname(3)`](https://man7.org/linux/man-pages/man3/gethostbyname_r.3.html). That'll go through
`/etc/hosts`, then hops into `/etc/resolv.conf` etc. depending on your `/etc/nsswitch.conf` configuration (if you are using [glibc](https://www.gnu.org/software/libc/)).  
It's usually hidden into implementation details how this all works.

## Let the digging begin

First I tried fresh Ubuntu container - `docker run --rm -ti --name=pinger --network=orchestrator_network ubuntu:latest ping -c database`, and it well...
worked.

Then I tried Alpine container - yup, that also worked.

My first suspect was `/etc/resolv.conf` being poorly configured, such as `ndots:n` or `options edns0` conflicting hard. Removing either or both of them fixed
nothing.

I talked to few people I know, they simply said Linux DNS is plain broken and only way to get around it was to not use any DNS. I dismissed that because
it sounded very silly and unhelpful. Or is it really...?

### Difference between Ubuntu and Alpine

Ubuntu uses [glibc](https://www.gnu.org/software/libc/), Alpine uses [musl libc](https://musl.libc.org/). 

My next suspect was `/etc/nsswitch.conf` - maybe that's poorly configured? musl libc does not consult with it, but glibc does.
I bind mounted a known good configuration (from my Arch Linux laptop) over Ubuntu's; still no bueno.

Then I simply replaced Java Docker image with AdoptOpenJDK's Alpine based image in `docker-compose.yml` - Java app still did not start working properly, but
other utilities worked just fine (`dig`, `ping` etc.)... So I'm one step closer - seems like Java is doing DNS in some other way.

I tried tweaking Java DNS options (disabling DNS caching, by setting TTL to 0) with no success.

Now I went after the Alpine AdoptOpenJDK Dockerfile. [Turns out that Alpine images still use glibc for AdoptOpenJDK binaries!](https://archive.is/O6S6Z).
OK, so I can blame glibc now.

### DNS query using glibc

I decided to write a small C program to test `gethostbyname(3)` with `strace`.

```c
#include <stdio.h>
#include <arpa/inet.h>
#include <netdb.h>

main(int argc, char **argv) {
    struct hostent *lh = gethostbyname(argv[1]);
    printf("res: %s\n", (lh ? inet_ntoa(*((struct in_addr*) lh->h_addr_list[0])) : "(failed)"));
}
```

...and the one-liner copypasteable version:

```bash
echo -e '#include<stdio.h>\n#include<arpa/inet.h>\n#include<netdb.h>\nmain(int argc,char **argv){struct hostent *lh=gethostbyname(argv[1]); printf("res: %s\\n",(lh?inet_ntoa(*((struct in_addr*)lh->h_addr_list[0])):"(failed)"));}' | gcc -x c - -o /dns
```

Compiled and ran it on Ubuntu container, I saw this: [^2]

```strace
stat("/etc/resolv.conf", {st_mode=S_IFREG|0444, st_size=36, ...}) = 0
openat(AT_FDCWD, "/etc/host.conf", O_RDONLY|O_CLOEXEC) = 3
fstat(3, {st_mode=S_IFREG|0444, st_size=9, ...}) = 0
read(3, "multi on\n", 4096)             = 9
read(3, "", 4096)                       = 0
close(3)                                = 0
openat(AT_FDCWD, "/etc/resolv.conf", O_RDONLY|O_CLOEXEC) = 3
fstat(3, {st_mode=S_IFREG|0444, st_size=36, ...}) = 0
read(3, "nameserver 127.0.0.11\nnameserver "..., 4096) = 36
read(3, "", 4096)                       = 0
uname({sysname="Linux", nodename="89e72f443fc3", ...}) = 0
fstat(3, {st_mode=S_IFREG|0444, st_size=36, ...}) = 0
close(3)                                = 0
socket(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK, 0) = 3
connect(3, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = 0
sendto(3, "\2\0\0\0\r\0\0\0\6\0\0\0hosts\0", 18, MSG_NOSIGNAL, NULL, 0) = 18
poll([{fd=3, events=POLLIN|POLLERR|POLLHUP}], 1, 5000) = 1 ([{fd=3, revents=POLLIN|POLLHUP}])
recvmsg(3, {msg_name=NULL, msg_namelen=0, msg_iov=[{iov_base="hosts\0", iov_len=6}, {iov_base="\310O\3\0\0\0\0\0", iov_len=8}], msg_iovlen=2, msg_control=[{cmsg_len=20, cmsg_level=SOL_SOCKET, cmsg_type=SCM_RIGHTS, cmsg_data=[4]}], msg_controllen=20, msg_flags=MSG_CMSG_CLOEXEC}, MSG_CMSG_CLOEXEC) = 14
mmap(NULL, 217032, PROT_READ, MAP_SHARED, 4, 0) = 0x7fa966376000
close(4)                                = 0
close(3)                                = 0
socket(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK, 0) = 3
connect(3, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = 0
sendto(3, "\2\0\0\0\4\0\0\0\6\0\0\0redis\0", 18, MSG_NOSIGNAL, NULL, 0) = 18
poll([{fd=3, events=POLLIN|POLLERR|POLLHUP}], 1, 5000) = 1 ([{fd=3, revents=POLLIN|POLLHUP}])
read(3, "\2\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\377\377\377\377\377\377\377\377\0\0\0\0\1\0\0\0", 32) = 32
close(3)                                = 0
fstat(1, {st_mode=S_IFCHR|0620, st_rdev=makedev(0x88, 0x4), ...}) = 0
write(1, "res: (failed)\n", 14res: (failed)
)         = 14
exit_group(0)                           = ?
+++ exited with 0 +++
```

wait wait wait... it's consulting with [NSCD](https://linux.die.net/man/8/nscd) over `/var/run/nscd/socket`, instead of reading `/etc/resolv.conf` and doing DNS query on its own! No wonder why DNS worked properly on Alpine / musl libc.

This container has been sending DNS queries to the host all the time, host will never be aware of container-specific internal DNS.

Turns out there is no way to override using nscd on runtime either.

## Solutions

Gah, finally hours of debugging got me somewhere and I can sleep in peace now.

### Option 1: do not bind mount /var/run

That's it, just don't do that. Unless you run pure musl libc/statically linked programs, perhaps?

I made Docker listen on socket file at `/var/run/zentria/docker.sock` for example, and then I simply mounted
`/var/lib/zentria` into the container.

### Option 2: mount tmpfs over /var/run/nscd

That's rather a temporary solution.

### Option 3: mount /var/run somewhere else, like /host/var/run

That'll work too, but you'll also very likely expose unwanted files into the container. Less access the better it is.

You should consider picking Option 1 instead.

### Option 4: access Docker API over TCP+TLS

That's the most secure way, as this allows more fine grained control. Besides PKI based auth, you are able
to set up an authorization plugin to apply limits to the API - making Docker API access less equal to `root` access on host ;)

## TL;DR

Linux DNS is not broken. Do not mount `/var/run` into container's `/var/run` blindly - especially if you have `nscd` running on host.

[^1]: I think Docker on Linux still does not have this `host.docker.internal` DNS address set up.
[^2]: Well this `strace` output is from my current NixOS installation. Only had poor quality pictures around from the real environment.
