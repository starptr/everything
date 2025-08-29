# Use pkgs.callPackage
{ remarshal, runCommand, writeTextFile }: let
 toYAML = data: let
    asJson = builtins.toJSON data;
    asFile = writeTextFile {
      name = "data.json";
      text = asJson;
    };
  in builtins.readFile (runCommand "to-yaml" {} ''
    ${remarshal}/bin/remarshal \
      --input-format json \
      --output-format yaml \
      < ${asFile} > $out
  '');
in {
  inherit toYAML;
}