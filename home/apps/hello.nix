{ pkgs, ... }:
{
  # Hello is a simple program that prints "Hello, world!" to the console.
  # This is used as an easy way to verify that the Home Manager configuration
  # is being applied correctly.
  home.packages = [
    pkgs.hello
  ];
}