{
  lib,
  stdenv,
  zig_0_16,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "cliphizt";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [zig_0_16.hook];

  zigBuildFlags = ["-Doptimize=ReleaseSafe"];

  meta = {
    description = "Wayland clipboard history manager with TTL and ephemeral mode";
    homepage = "https://github.com/luisnquin/clipz";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "cliphizt";
  };
})
