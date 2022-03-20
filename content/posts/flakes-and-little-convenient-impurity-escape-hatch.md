---
title: "Flakes and little convenient impurity escape hatch"
date: 2022-03-20T23:20:00+02:00
draft: false
author: "Mark V."
---

Started using flakes recently? But then you found that:
1) You need per-machine configuration for experimentation/secrets (well, e.g firewall config), but don't want to publish them.
2) Your configuration is against your usual quality standards, so it'd be shame to show them to the world.

Here's one solution to that - works similarly to how current NixOS deployments are still done.

### `flake.nix`

```nix
{
  inputs = {
    impure-local.url = "path:./impure-local";
    impure-local.flake = false;
  };

  outputs = { nixpkgs, impure-local }: {
    nixosConfigurations."impure" = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        "${impure-local}"
      ];
    };
  };
}
```

### `impure-local` (directory)

```shell
$ mkdir -p ./impure-local
$ echo '{ ... }: {}' > ./impure-local/default.nix
$ nix flake lock
```

Keep this in your repository at all times, it'll be used when override is not specified, and helps to keep flake.lock hash constant.

### Usage

```shell
$ nixos-rebuild build --flake '.#impure' --override-input impure-local path:/etc/nixos
```

Keep in mind that `--override-input impure-local ./path` will not work! You need to prefix it with `path:` (like `path:./path`), otherwise Nix won't pick the correct directory (sounds like a bug?):
```
warning: Git tree '/home/mark/home' is dirty
warning: Git tree '/home/mark/home' is dirty
warning: not writing modified lock file of flake 'git+file:///home/mark/home':
• Updated input 'impure-local':
    'path:./impure-local?narHash=sha256-6pJ2Ev9tyW6cLAwqqqb5+VUhqvlVne1+IlB9DtFc0Fo='
  → 'git+file:///home/mark/home?dir=impure-local' (2022-03-20)
error: getting status of '/nix/store/pjc26z765hj1gqhs2cac81g58fk5gvgr-source/default.nix': No such file or directory
```

## Pros
- Impure - restores `/etc/nixos/configuration.nix`-like solution, allows to be lazy.
    - **However** you cannot reference configurations outside the override path (good)
    - e.g `/etc/nixos/default.nix` imports `./foo.nix` => this works
    - e.g `/etc/nixos/default.nix` imports `/home/mark/foo.nix` => this will not, Nix will require `--impure` flag (to access files outside the store)
- You can experiment with system changes more easily, and then refactor them into your flake
- Don't have to deal with encrypting configuration when publishing flake publicly
- Per-machine configuration (firewall rules etc.)

## Cons
- Impure, since configuration is machine-local, then deploying same flake to new machine wouldn't yield same end result (duh).
- Whole configuration is copied into the store, secrets will be world-readable (if you declare them there)

## Example configurations using this

- [mikroskeem/home](https://github.com/mikroskeem/home/tree/fff80360df1e56aa540e63c2d35901768cdb66fa)
