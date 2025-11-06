{
  description = "Tiny Tapeout Verilog Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in f { inherit system pkgs; });
    in
    {
      devShells = forAllSystems ({ pkgs, ... }:
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              # Verilog simulation tools
              verilator
              iverilog
              gtkwave

              uv
              python313

              # Build tools
              gnumake
            ];

            shellHook = ''
                export UV_PYTHON="${pkgs.python313}/bin/python3"

                echo "🔧 Tiny Tapeout Development Environment"
                echo ""
                echo "Quick start:"
                echo "  cd test && uv run make -B"
                echo "  gtkwave tb.vcd"
            '';
          };
        }
      );
    };
}
