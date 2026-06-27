{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  wayland,
  libxkbcommon,
  fontconfig,
  freetype,
}:
rustPlatform.buildRustPackage {
  pname = "cliplenz";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [pkg-config makeWrapper];

  buildInputs = [wayland libxkbcommon fontconfig freetype];

  # Force the software renderer and pin runtime libs so the wrapped binary runs
  # without a populated LD_LIBRARY_PATH. No clipboard backend is baked in:
  # cliplenz is a generic dmenu, the producer and preview command come from
  # stdin and args at call time.
  postInstall = ''
    wrapProgram $out/bin/cliplenz \
      --set ICED_BACKEND tiny-skia \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [wayland libxkbcommon fontconfig freetype]}
  '';

  meta = {
    description = "Fast native dmenu with fuzzy search and image preview";
    mainProgram = "cliplenz";
    platforms = lib.platforms.linux;
  };
}
