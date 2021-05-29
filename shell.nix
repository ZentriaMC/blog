{ pkgs ? import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/84aa23742f6c72501f9cc209f29c438766f5352d.tar.gz") { } }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ hugo ];
}
