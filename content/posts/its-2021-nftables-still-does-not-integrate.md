---
title: "It's 2021: nftables still does not integrate"
author: "Mark V."
date: 2021-05-29T19:25:17+03:00
draft: false
---

You probably have [seen it around][nftables-wiki] somewhere already, for example [Debian trying hard to replace iptables][debian-netfilter] with it.  
Debian 10 (buster) shipped with it already, [Arch Linux wiki][arch-nftables] provided (usable) examples for the adventurous back in 2014 etc.

(nftables is quite promising, don't get me wrong - I quite like it, because how much easier it is to use and integrate. This is rather a rant towards
other projects.)

HOWEVER, integrating it into existing solutions turns out to be VERY painful:
1) [Docker does not support it][docker-nftables-issue] - issue is still open
2) Kubernetes does not seem to support it. [^1]
3) CNI does not support it yet (https://github.com/containernetworking/plugins/issues/519)
4) Unofficial [CNI plugins for nftables][cni-unofficial-nftables] are poor quality at best. [^2]
5) libvirt does not support nftables (directly)

## iptables-nft compatibility layer problems

`iptables-nft` does not support all features what legacy `iptables` does. Few examples:

### libvirt:
```
Error starting network 'default': internal error: Failed to apply firewall rules /usr/bin/iptables -w --table filter --insert LIBVIRT_INP --in-interface virbr0 --protocol tcp --destination-port 67 --jump ACCEPT:
iptables v1.8.7 (nf_tables): unknown option "--destination-port"
Try `iptables -h' or 'iptables --help' for more information.
```

### Docker:
```
time="2021-05-29T18:05:01.787346850+03:00" level=warning msg="could not create bridge network for id a443ac2c9035cec5bafe7205015d6c308a09fcdc25b1a4bb9f537797a900df81 bridge name docker0 while booting up from persistent state: Failed to program NAT chain: Failed to inject DOCKER in PREROUTING chain: iptables failed: iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER: iptables v1.8.7 (nf_tables): Couldn't load match `addrtype':No such file or directory\n\nTry `iptables -h' or 'iptables --help' for more information.\n (exit status 2)"
```

## Workarounds

### Libvirt:

Use [firewalld][firewalld] perhaps? I could not get it working with default network though (NAT, `192.168.122.0/24` - see compatibility layer problems section).

### Docker:

There are few solutions around, like https://archive.is/MHBu3 and https://archive.is/bqKHl, but this involves disabling
Docker's iptables integration, making using managed networks (`docker network create <name>`) painful.

Technically could work this around by writing a events listener for Docker or using a plugin (probably?)

Note that using [firewalld][firewalld] won't save you with Docker - it wants to insert custom rules via [the `--direct` interface][firewalld-direct]

# In conclusion

nftables works, but integrating it into existing solutions is still painful / impossible. Let's revisit this topic in 2022 perhaps?

[nftables-wiki]: https://wiki.nftables.org/
[debian-netfilter]: https://archive.is/Xeyqv
[arch-nftables]: https://wiki.archlinux.org/title/nftables
[docker-nftables-issue]: https://archive.is/uFhG3
[cni-nftables-issue]: https://archive.is/WO8ZM
[cni-unofficial-nftables]: https://archive.ph/ZW71R
[firewalld]: https://archive.ph/uXe1v
[firewalld-direct]: https://archive.is/t3Pyl

[^1]: I'm not entirely sure. It isn't like written into stone or something, but there are discussions around the internet which imply that it does not:
    - https://archive.is/vgJPL
    - https://archive.is/q55MZ
    - https://archive.is/fj5A0#ensure-iptables-tooling-does-not-use-the-nftables-backend
    - https://archive.is/zrnSx

[^2]: Inserting identical jump rule multiple times. See [this gist](https://gist.github.com/mikroskeem/5aaef53bd500435bbb1f900e7a68d627)
