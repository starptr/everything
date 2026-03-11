{
  lib,
  python3Packages,
  fetchPypi,
  natto-py,
}:

python3Packages.buildPythonPackage rec {
  pname = "lute3";
  version = "3.10.1";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-gqwoyINuP54ve6R2OonLUT2oZYmpjvUopyWbJ+stJrE=";
  };

  # do not run tests
  doCheck = false;

  # specific to buildPythonPackage, see its reference
  pyproject = true;
  build-system = with python3Packages; [
    setuptools
    wheel
    flit-core
  ];
  dependencies = with python3Packages; [
    flask-sqlalchemy
    flask-wtf
    natto-py
    jaconv
    platformdirs
    requests
    beautifulsoup4
    pyyaml
    toml
    waitress
    pyparsing
    pypdf
  ];
}