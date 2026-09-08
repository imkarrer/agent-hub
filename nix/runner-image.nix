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
      # The image's own filesystem is the read-only nix store; /workspace
      # (the bind-mounted host tmpdir) is the only writable path, so HOME
      # has to point there too -- gh's config and any tool that insists on
      # a real $HOME would otherwise fail to write it.
      "HOME=/workspace"
    ];
    WorkingDir = "/workspace";
    Entrypoint = [ "bash" ];
    # Numeric, not a named user -- avoids needing to fabricate /etc/passwd
    # entries in the image. run-task.sh passes --user "$(id -u):$(id -g)"
    # matching whatever host user owns the bind-mounted workdir, so this is
    # just the documented fallback when the image is run directly without
    # that override (e.g. `docker run agent-hub-runner:latest` by hand).
    User = "1000:1000";
  };
}
