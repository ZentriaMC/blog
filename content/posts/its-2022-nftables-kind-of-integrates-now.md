---
title: "It's 2022: nftables kind of integrates now"
date: 2022-09-03T22:38:50+03:00
author: "Mark V."
---

This is a follow up to the [It's 2021: nftables still does not integrate][older-nftables-post].

# The good: What works compared to 2021?

Pretty much everything is still revolving around the iptables-nft compatibility layer, but it has improved a lot so
things seem to work just fine now.

## libvirt

Everything works. Seems to implicitly use compatibility layer very likely (assuming from [libvirt Network Filters][libvirt-nwfilter]).

## Docker

Everything works out of the box, without having to write own rules or handle wiring with own Docker event handler. Implicitly uses compatibility layer.

## CNI firewall plugin

Also [uses compatibility layer][cni-firewall-plugin]. This was worth mentioning because podman, Kubernetes, containerd etc. rely on CNI.

# The bad

## Scripting/firewall management by shelling out to iptables

Pretty much all open & popular solutions mentioning firewall management on Linux simply shell out to iptables commands.

I've seen one edge case with `iptables-nft` - if you try to list rules in nonexistent chain, it fails with unrelated error:

```shell
$ iptables-nft -t filter -X SWDFW-INPUT || true
$ iptables-nft -t filter -S SWDFW-INPUT 1
iptables v1.8.8 (nf_tables): chain `SWDFW-INPUT' in table `filter' is incompatible, use 'nft' tool.
```

[coreos/go-iptables ChainExists][go-iptables-chainexists] is using `-S <chain> 1` to report whether chain exists.

Alternative would be doing something similar to this:

```shell
nft --json --stateless --terse list ruleset | jq --arg table "filter" --arg chain "SWDFW-INPUT" -e -r '.nftables[] | select(.chain and .chain.table == $table and .chain.name == $chain) | "ok"'
```

...however not all systems have `nftables` installed next to `iptables-nft` (NixOS - there are `nftables` and `iptables-nftables-compat` packages).

# The ugly

## Translation layer makes use of iptables kernel modules in the background

Throw following into `/etc/modprobe.d/blacklist-iptables.conf` & reboot:

```modprobe
install ip_tables /bin/true
install ip6_tables /bin/true
```

And try following rules:
```shell
ip6tables -A INPUT -p icmpv6 --icmpv6-type redirect -j DROP
ip6tables -A INPUT -p icmpv6 --icmpv6-type 139 -j DROP
```

Get `Extension icmpv6 revision 0 not supported, missing kernel module?`, why?

`modinfo ip6_tables` shows `alias: ip6t_icmp6`, loading it gets it working, therefore icmpv6 filtering is provided by that,
even though nftables support icmp natively...

Legacy iptables is using `/proc/net/ip_tables_names` for table names, but that's unsurprisingly empty on a system which doesn't use legacy framework.

# Future

RHEL 9 [deprecated ipset & iptables-nft][rhel9-iptables-nft-deprecated]  
OpenWRT 22.03.0 [is using nftables for its firewall management][openwrt-nftables]. It's doing [rule templating][firewall4-templates] instead of using JSON though.

I hope legacy iptables and its compatibility layer is going to be replaced on other distributions as well in next following years.

Until then, enjoy iptables and its compatibility cruft.

[older-nftables-post]: {{< relref "its-2021-nftables-still-does-not-integrate.md" >}}
[libvirt-nwfilter]: https://libvirt.org/formatnwfilter.html#writing-your-own-filters
[cni-firewall-plugin]: https://github.com/containernetworking/plugins/blob/8c3664b2b158614171eedadf471c8236421aa07f/plugins/meta/firewall/firewall.go#L117
[go-iptables-chainexists]: https://github.com/coreos/go-iptables/blob/ff76ef3cab301766d9e92b22666403ce455054b4/iptables/iptables.go#L263
[rhel9-iptables-nft-deprecated]: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html-single/9.0_release_notes/index#deprecated-functionality_networking
[openwrt-nftables]: https://openwrt.org/releases/22.03/notes-22.03.0#firewall4_based_on_nftables
[firewall4-templates]: https://git.openwrt.org/?p=project/firewall4.git;a=tree;f=root/usr/share/firewall4/templates;h=13f86dd93a84a3693247536e3402e9a1a7fc06bc;hb=HEAD
