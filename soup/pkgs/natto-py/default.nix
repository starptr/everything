{
  lib,
  python3Packages,
  fetchPypi,
}:

python3Packages.buildPythonPackage rec {
  pname = "natto-py";
  version = "1.0.1";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-dgEDuzlyMu4DPJkk0TV+MrFCu+Ey/GpDuM+C3WtlToY=";
  };

  # do not run tests
  doCheck = false;

  # specific to buildPythonPackage, see its reference
  pyproject = true;
  build-system = with python3Packages; [
    setuptools
    wheel
  ];
  dependencies = with python3Packages; [
    cffi
  ];
}