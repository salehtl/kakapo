{
  lib,
  stdenv,
  buildNpmPackage,
  importNpmLock,
  fetchurl,
  nodejs,
  jq,
  autoPatchelfHook,
}:
let
  lockFile = lib.importJSON ./package-lock.json;

  # Optional packages npm would skip here anyway: other OSes and CPUs, plus
  # sharp's linuxmusl builds (npm cannot tell glibc from musl, so it installs
  # those too, and they cannot be patched for glibc). Dropping them before
  # importNpmLock saves ~380 MiB of downloads on every cold build.
  forHost =
    path: p:
    !(p.optional or false)
    || (
      builtins.elem "linux" (p.os or [ "linux" ])
      && builtins.elem "x64" (p.cpu or [ "x64" ])
      && !lib.hasInfix "linuxmusl" path
    );
  packageLock = lockFile // {
    packages = lib.filterAttrs forHost lockFile.packages;
  };
in
buildNpmPackage (finalAttrs: {
  pname = "cf";
  version = "1.0.0-beta.12";

  # The published npm tarball, not the GitHub source: dist/ ships prebuilt, and
  # the source's devDependencies point at tarballs under the monorepo's vendor/
  # that are not public. The hash is npm's own `dist.integrity` for this
  # version, so it pins exactly what `npm install cf` would fetch.
  src = fetchurl {
    url = "https://registry.npmjs.org/cf/-/cf-${finalAttrs.version}.tgz";
    hash = "sha512-tyQ+Jpnw+4NDwDtl7ZNteXBm7N0TeJ6gYww79kkabpcYoCEXkUUpmt9BlDUKH8ub17tjAeiuyqa9NQzH0vp2Aw==";
  };

  # npm tarballs carry no lockfile, so ./package-lock.json is generated and
  # committed here. Every dependency is fetched by the integrity hash recorded
  # in it, so there is no separate npmDepsHash to keep in step. To bump: unpack
  # the new tarball, drop devDependencies and scripts from package.json, run
  # `npm install --package-lock-only --ignore-scripts`, copy the lock here, and
  # update `version` and `hash` above.
  npmDeps = importNpmLock {
    package = packageLock.packages."";
    inherit packageLock;
  };
  inherit (importNpmLock) npmConfigHook;

  postPatch = ''
    jq 'del(.devDependencies, .scripts)' package.json > package.json.new
    mv package.json.new package.json
    cp ${./package-lock.json} package-lock.json
  '';

  inherit nodejs;
  dontNpmBuild = true;

  # workerd (via miniflare, for local Workers dev) and sharp ship prebuilt
  # glibc binaries; patch them so those commands run on NixOS. API commands
  # like `cf dns records list` never touch them.
  nativeBuildInputs = [ jq ] ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ (lib.getLib stdenv.cc.cc) ];

  meta = {
    description = "Cloudflare's CLI for the whole Cloudflare API";
    homepage = "https://developers.cloudflare.com/cf/";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "cf";
    platforms = [ "x86_64-linux" ];
  };
})
