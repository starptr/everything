import os
import sys
import pathlib
import logging as std_logging

# Set up logging
# Modify the `level` value to change the logging level
std_logging.basicConfig(stream=sys.stdout, level=std_logging.DEBUG)

class logging:
    @staticmethod
    def debug(msg):
        print(msg)
    @staticmethod
    def info(msg):
        print(msg)
    @staticmethod
    def error(msg):
        print(msg)

def _get_cwd():
    return pathlib.Path(os.getcwd())

# Deprecate generated_json_path
#generated_json_path = _get_cwd().joinpath('generated.json')
generated_nixie_path = _get_cwd().joinpath('generated-nixie.json')
generated_serverref_path = _get_cwd().joinpath('generated-serverref.json')
octodns_config_template_path = _get_cwd().joinpath('octodns-config-template')
octodns_config_build_path = _get_cwd().joinpath('octodns-config-build')