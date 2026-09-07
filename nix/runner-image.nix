# Phase 2 sandbox image: the minimal toolset run-task.sh needs inside the
# container to edit a repo, run its tests, and open a PR. Deliberately
# narrow -- no package managers, no compilers, no browser -- so the blast
# radius of anything the model asks the sandbox to run stays bounded by
# what's actually installed here, not by network reachability alone.
{ pkgs ? import <nixpkgs> { } }:

pkgs.dockerTools.buildImage {
  name = "agent-hub-runner";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "agent-hub-runner-root";
    paths = with pkgs; [
      aider-chat
      git
      gh
      bashInteractive
      coreutils
      findutils
      cacert
      python3
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };

  config = {
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/workspace";
    Entrypoint = [ "bash" ];
  };
}
